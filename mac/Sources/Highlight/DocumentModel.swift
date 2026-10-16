import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

/// One highlight as listed in the sidebar (one annotation, with a quad per line).
struct HighlightItem: Identifiable {
    let members: [PlacedAnnotation]
    let pageNumber: Int
    let text: String
    let color: NSColor
    /// The palette color closest to `color`, for filtering the list.
    let paletteColor: HighlightColor

    var id: ObjectIdentifier { ObjectIdentifier(members[0].annotation) }
    var page: PDFPage { members[0].page }
    var firstAnnotation: PDFAnnotation { members[0].annotation }
}

/// One find result. Matches in the text layer carry a selection; matches in
/// recognized (OCR) text on scanned pages carry only their line boxes.
struct FindMatch {
    let page: PDFPage
    let selection: PDFSelection?
    let lines: [CGRect]
}

/// Progress of a long-running job (text recognition, a batch).
struct JobProgress: Equatable {
    var done: Int
    var total: Int
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

enum SaveError: LocalizedError {
    case noDocument
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noDocument: return "There is no document open."
        case .writeFailed: return "PDFKit could not write the file."
        }
    }
}

/// Owns the open PDF, its highlights, undo history and file I/O.
/// The app is single-window, so one shared instance backs the whole UI.
@MainActor
final class DocumentModel: ObservableObject {
    static let shared = DocumentModel()

    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var highlights: [HighlightItem] = []
    @Published var color: HighlightColor = .yellow
    /// Saved passages found in the just-opened PDF, waiting for the user to accept (Ask mode).
    @Published private(set) var pendingSavedMatches: [PlacedAnnotation] = []
    @Published private(set) var findResults: [FindMatch] = []
    @Published private(set) var findIndex = 0
    @Published var highlighterMode = false {
        didSet {
            pdfView.highlighterMode = highlighterMode
            if highlighterMode { areaMode = false }
        }
    }
    /// Drag a box to highlight any area (signature blocks, form fields, scans).
    @Published var areaMode = false {
        didSet {
            pdfView.areaMode = areaMode
            if areaMode { highlighterMode = false; pdfView.clearSelection() }
        }
    }
    /// The live box shown while dragging in area mode (not part of the document's undo history).
    private var areaPreview: PlacedAnnotation?
    /// Boxes marking find matches in recognized text. Never saved: they're taken
    /// off the pages around every write.
    private var findMarkers: [PlacedAnnotation] = []

    /// The form template found in the just-opened PDF, when waiting for the user (Ask mode).
    @Published var pendingTemplateName: String?
    /// The highlight selected in the sidebar or by Next/Previous Highlight.
    @Published var selectedHighlightID: ObjectIdentifier? {
        didSet {
            guard let selectedHighlightID, selectedHighlightID != oldValue,
                  let item = highlights.first(where: { $0.id == selectedHighlightID }) else { return }
            reveal(item)
        }
    }
    /// Shows only highlights of one color in the list (nil shows all).
    @Published var colorFilter: HighlightColor?
    /// Words recognized on scanned pages, by page index.
    @Published var ocrWords: [Int: [OCRWord]] = [:]
    /// Set while scanned pages are being read.
    @Published var ocrProgress: JobProgress?
    var ocrTask: Task<Void, Never>?
    /// Set while a batch of PDFs is being highlighted.
    @Published var batchProgress: JobProgress?
    var batchTask: Task<Void, Never>?
    /// Shows the "Highlight Phrases" sheet.
    @Published var showingPhraseSheet = false

    let undoManager = UndoManager()
    let pdfView = HighlightPDFView()
    let library: PassageLibrary
    private var lastFindQuery = ""

    /// Recently opened PDFs, newest first (kept across launches).
    @Published private(set) var recentFiles: [URL] = []
    /// 1-based page shown in the PDF view, for the toolbar's page indicator.
    @Published private(set) var currentPageNumber = 0
    private let defaults: UserDefaults
    private var pageObserver: AnyCancellable?
    private static let recentsKey = "recentFiles.v1"
    static let maxRecents = 10

    /// Text under each annotation, read once. Reading it means a text-layout
    /// query per line, which made every edit slow once there were hundreds.
    var textCache: [ObjectIdentifier: String] = [:]

    init(library: PassageLibrary? = nil, defaults: UserDefaults = .standard) {
        self.library = library ?? PassageLibrary()
        self.defaults = defaults
        recentFiles = (defaults.stringArray(forKey: Self.recentsKey) ?? []).map { URL(fileURLWithPath: $0) }
        // Explicit groups make undo independent of the run loop (and testable).
        undoManager.groupsByEvent = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.onSelectionFinished = { [weak self] in self?.highlightCurrentSelection() }
        pdfView.menuCustomizer = { [weak self] menu, event in self?.customize(menu, for: event) }
        pdfView.onAreaDrag = { [weak self] page, box, finished in self?.areaDragged(on: page, box: box, finished: finished) }
        // Combine's sink closure is formed here on the main actor and stays isolated to it.
        pageObserver = NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCurrentPage() }
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    private func updateCurrentPage() {
        guard let document, let page = pdfView.currentPage else { currentPageNumber = 0; return }
        currentPageNumber = document.index(for: page) + 1
    }

    // MARK: - Recent files

    /// Puts `url` at the top of the recent list (also feeds the Dock icon's menu).
    private func noteRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = recentFiles.map { $0.standardizedFileURL.path }.filter { $0 != path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(Self.maxRecents))
        recentFiles = paths.map { URL(fileURLWithPath: $0) }
        defaults.set(paths, forKey: Self.recentsKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Recent files that still exist on disk.
    var availableRecentFiles: [URL] {
        recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clearRecentFiles() {
        recentFiles = []
        defaults.removeObject(forKey: Self.recentsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// On launch, picks up where you left off by reopening the last PDF.
    func reopenLastDocument() {
        guard document == nil, let url = availableRecentFiles.first else { return }
        load(url)
    }

    var title: String { fileURL?.lastPathComponent ?? "Highlight" }

    // MARK: - Opening

    func presentOpenPanel() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    /// Opens `url`, asking to save unsaved highlights first.
    func open(_ url: URL) {
        if url.standardizedFileURL == fileURL?.standardizedFileURL { return }
        guard confirmDiscardChanges() else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            showError(title: "Couldn’t open “\(url.lastPathComponent)”",
                      message: "The file may be damaged or may not be a PDF.")
            return
        }
        // Unlocking and re-saving would silently strip the open-password, so refuse instead.
        // (PDFs encrypted with an empty password just for permissions open fine.)
        guard !doc.isLocked else {
            showError(title: "“\(url.lastPathComponent)” is password-protected",
                      message: "Highlight doesn’t edit encrypted PDFs, because saving could remove their protection.")
            return
        }
        setDocument(doc, url: url)
        noteRecent(url)
        checkSavedPassages()
        startRecognizingText()
    }

    /// Replaces the current document and resets undo/dirty state.
    func setDocument(_ doc: PDFDocument?, url: URL?) {
        clearFind()
        ocrTask?.cancel()
        ocrTask = nil
        ocrProgress = nil
        ocrWords = [:]
        pendingTemplateName = nil
        selectedHighlightID = nil
        colorFilter = nil
        document = doc
        fileURL = url
        pdfView.document = doc
        textCache = [:]
        pendingSavedMatches = []
        undoManager.removeAllActions()
        isDirty = false
        refreshHighlights()
        updateCurrentPage()
    }

    // MARK: - Saving

    @discardableResult
    func save() -> Bool {
        guard document != nil else { return false }
        guard let fileURL else { return saveAs() }
        return saveReportingErrors(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard document != nil else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.pdf"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return saveReportingErrors(to: url)
    }

    private func saveReportingErrors(to url: URL) -> Bool {
        do {
            try write(to: url)
            fileURL = url
            isDirty = false
            return true
        } catch {
            showError(title: "Couldn’t save “\(url.lastPathComponent)”", message: error.localizedDescription)
            return false
        }
    }

    /// Writes to a temporary file and swaps it in, so a failed write can never
    /// leave the original PDF truncated or half-written.
    func write(to url: URL) throws {
        guard let document else { throw SaveError.noDocument }
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: url.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
        guard withoutFindMarkers({ document.write(to: tempURL) }) else { throw SaveError.writeFailed }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
    }

    /// Asks the user what to do with unsaved highlights.
    /// Returns false if they cancelled (or saving failed).
    func confirmDiscardChanges() -> Bool {
        guard isDirty, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(title)”?"
        alert.informativeText = "Your highlights will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - Highlighting

    func highlightCurrentSelection() {
        guard let selection = pdfView.currentSelection else { return }
        if highlight(selection) {
            library.remember(selection.string ?? "", color: color)
            pdfView.clearSelection()
        }
    }

    /// Highlights `selection` in the current color. Returns false if nothing was highlightable.
    @discardableResult
    func highlight(_ selection: PDFSelection) -> Bool {
        let placed = Highlighter.makeAnnotations(for: selection, color: color.nsColor)
        guard !placed.isEmpty else { return false }
        add(placed, actionName: "Highlight")
        return true
    }

    /// Highlights a box on a page (page coordinates). Tiny boxes from a plain click are ignored.
    @discardableResult
    func highlightArea(_ box: CGRect, on page: PDFPage) -> Bool {
        guard box.width >= 4, box.height >= 4 else { return false }
        let annotation = Highlighter.makeAnnotation(bounds: box, color: color.nsColor)
        add([PlacedAnnotation(annotation: annotation, page: page)], actionName: "Highlight Area")
        return true
    }

    private func areaDragged(on page: PDFPage, box: CGRect, finished: Bool) {
        if let preview = areaPreview {
            preview.page.removeAnnotation(preview.annotation)
            pdfView.annotationsChanged(on: preview.page)
            areaPreview = nil
        }
        if finished {
            highlightArea(box, on: page)
        } else if box.width >= 1, box.height >= 1 {
            let preview = PlacedAnnotation(annotation: Highlighter.makeAnnotation(bounds: box, color: color.nsColor), page: page)
            page.addAnnotation(preview.annotation)
            pdfView.annotationsChanged(on: page)
            areaPreview = preview
        }
    }

    func removeHighlightsInCurrentSelection() {
        guard let selection = pdfView.currentSelection else { return }
        removeHighlights(in: selection)
    }

    func removeHighlights(in selection: PDFSelection) {
        var seen = Set<ObjectIdentifier>()
        let hits = Highlighter.highlights(intersecting: selection)
            .flatMap { hit -> [PlacedAnnotation] in
                let group = wholeHighlight(containing: hit.annotation)
                return group.isEmpty ? [hit] : group
            }
            .filter { seen.insert(ObjectIdentifier($0.annotation)).inserted }
        guard !hits.isEmpty else { return }
        remove(hits, actionName: hits.count == 1 ? "Remove Highlight" : "Remove Highlights")
    }

    func removeHighlights(_ items: [PlacedAnnotation]) {
        guard !items.isEmpty else { return }
        remove(items, actionName: items.count == 1 ? "Remove Highlight" : "Remove Highlights")
    }

    func recolor(_ items: [PlacedAnnotation], to newColor: HighlightColor) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map { ObjectIdentifier($0.annotation) })
        for item in highlights where item.members.contains(where: { ids.contains(ObjectIdentifier($0.annotation)) }) {
            library.recolor(item.text, to: newColor)
        }
        setColors(items, Array(repeating: newColor.nsColor, count: items.count), actionName: "Change Highlight Color")
    }

    /// Scrolls the PDF to a highlight from the sidebar.
    func reveal(_ item: HighlightItem) {
        pdfView.go(to: item.firstAnnotation.bounds, on: item.page)
    }

    /// Copies every highlight's text, in page order, to the clipboard.
    func copyAllHighlights() {
        let text = highlights.map { "p. \($0.pageNumber): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Markdown export

    /// The highlighted text as Markdown, one bullet per highlight, grouped by page.
    func highlightsMarkdown() -> String {
        let name = fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Untitled"
        var lines = ["# Highlights: \(name)", ""]
        var currentPage = 0
        for item in highlights {
            if item.pageNumber != currentPage {
                if currentPage != 0 { lines.append("") }
                currentPage = item.pageNumber
                lines.append(contentsOf: ["## Page \(currentPage)", ""])
            }
            lines.append("- \(item.text.isEmpty ? "(highlighted area)" : item.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func presentExportPanel() {
        guard !highlights.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = "\(base) highlights.md"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try highlightsMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(title: "Couldn’t export highlights", message: error.localizedDescription)
        }
    }

    // MARK: - Find

    /// Searches the document (case-insensitive), including text recognized on
    /// scanned pages, and shows the first match.
    func find(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, q.count >= 2 else { return clearFind() }
        clearFind()
        lastFindQuery = q
        var matches: [(index: Int, match: FindMatch)] = []
        for selection in document.findString(q, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            selection.color = NSColor.findHighlightColor
            matches.append((document.index(for: page), FindMatch(page: page, selection: selection, lines: [])))
        }
        for (index, words) in ocrWords {
            guard let page = document.page(at: index) else { continue }
            for lines in Matcher.ocrOccurrences(of: q, words: words) {
                matches.append((index, FindMatch(page: page, selection: nil, lines: lines)))
            }
        }
        // Page order; within a page the text layer's order (OCR pages have no text layer).
        let ordered = matches.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element.match)
        for match in ordered where match.selection == nil {
            for line in match.lines {
                let marker = PDFAnnotation(bounds: line.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
                marker.color = .clear
                marker.interiorColor = NSColor.findHighlightColor.withAlphaComponent(0.45)
                marker.border = PDFBorder()
                marker.border?.lineWidth = 0
                match.page.addAnnotation(marker)
                findMarkers.append(PlacedAnnotation(annotation: marker, page: match.page))
            }
            pdfView.annotationsChanged(on: match.page)
        }
        findResults = ordered
        findIndex = 0
        pdfView.highlightedSelections = ordered.compactMap(\.selection)
        showCurrentMatch()
    }

    func findNext() { stepFind(1) }
    func findPrevious() { stepFind(-1) }

    func clearFind() {
        for marker in findMarkers { marker.page.removeAnnotation(marker.annotation) }
        for page in Set(findMarkers.map(\.page)) { pdfView.annotationsChanged(on: page) }
        findMarkers = []
        findResults = []
        findIndex = 0
        pdfView.highlightedSelections = nil
    }

    /// Runs `body` with the find markers taken off their pages, so they're never
    /// written to a file or copied.
    func withoutFindMarkers<T>(_ body: () throws -> T) rethrows -> T {
        for marker in findMarkers { marker.page.removeAnnotation(marker.annotation) }
        defer { for marker in findMarkers { marker.page.addAnnotation(marker.annotation) } }
        return try body()
    }

    /// Turns every search match into a highlight in the current color (one undo step).
    func highlightAllMatches() {
        let placed = findResults.flatMap { match -> [PlacedAnnotation] in
            if let selection = match.selection { return Highlighter.makeAnnotations(for: selection, color: color.nsColor) }
            return [PlacedAnnotation(annotation: Highlighter.makeAnnotation(lines: match.lines, color: color.nsColor), page: match.page)]
        }
        guard !placed.isEmpty else { return }
        clearFind()
        add(placed, actionName: "Highlight All Matches")
        library.remember(lastFindQuery, color: color)
    }

    private func stepFind(_ delta: Int) {
        guard !findResults.isEmpty else { return }
        findIndex = (findIndex + delta + findResults.count) % findResults.count
        showCurrentMatch()
    }

    private func showCurrentMatch() {
        guard findResults.indices.contains(findIndex) else { return }
        let match = findResults[findIndex]
        if let selection = match.selection {
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.scrollSelectionToVisible(nil)
        } else if let first = match.lines.first {
            pdfView.clearSelection()
            pdfView.go(to: match.lines.dropFirst().reduce(first) { $0.union($1) }, on: match.page)
        }
    }

    // MARK: - Saved passages

    /// Number of separate passages waiting in `pendingSavedMatches`.
    var pendingSavedCount: Int {
        Set(pendingSavedMatches.map { Highlighter.groupKey(of: $0.annotation) }).count
    }

    /// Looks for a matching form template and saved passages in the open PDF and,
    /// per the library's mode, highlights them or holds them for the user to accept.
    func checkSavedPassages() {
        pendingSavedMatches = []
        pendingTemplateName = nil
        guard library.mode != .off, let document else { return }
        var found: [PlacedAnnotation] = []
        var templateName: String?
        if let template = library.templates.first(where: { Matcher.matches($0, document) }) {
            found = Matcher.templateAnnotations(template, in: document)
            if !found.isEmpty { templateName = template.name }
        }
        found += Matcher.phraseAnnotations(in: document, phrases: savedPhrases, ocr: ocrWords,
                                           alsoTaken: rectsByPage(found))
        guard !found.isEmpty else { return }
        if library.mode == .always {
            add(found, actionName: templateName == nil ? "Highlight Saved Passages" : "Apply Form Template")
        } else {
            pendingSavedMatches = found
            pendingTemplateName = templateName
        }
    }

    /// Adds saved passages found in newly recognized pages to what's offered or highlighted.
    func checkSavedPassages(onPages pages: Set<Int>) {
        guard library.mode != .off, let document, !library.passages.isEmpty else { return }
        let found = Matcher.phraseAnnotations(in: document, phrases: savedPhrases, ocr: ocrWords, pages: pages,
                                              alsoTaken: rectsByPage(pendingSavedMatches))
        guard !found.isEmpty else { return }
        if library.mode == .always {
            add(found, actionName: "Highlight Saved Passages")
        } else {
            pendingSavedMatches += found
        }
    }

    func applyPendingSavedMatches() {
        let found = pendingSavedMatches
        let fromTemplate = pendingTemplateName != nil
        pendingSavedMatches = []
        pendingTemplateName = nil
        guard !found.isEmpty else { return }
        add(found, actionName: fromTemplate ? "Apply Form Template" : "Highlight Saved Passages")
    }

    func dismissPendingSavedMatches() {
        pendingSavedMatches = []
        pendingTemplateName = nil
    }

    /// Highlights saved passages in the open PDF on request, whatever the mode.
    func highlightSavedPassagesNow() {
        dismissPendingSavedMatches()
        let found = findSavedPassages()
        guard !found.isEmpty else {
            showInfo(title: "No saved passages found",
                     message: "None of the passages you’ve highlighted before appear in this PDF, or they’re already highlighted.")
            return
        }
        add(found, actionName: "Highlight Saved Passages")
    }

    var savedPhrases: [PhraseRequest] {
        library.passages.map { PhraseRequest(text: $0.text, color: $0.color.nsColor) }
    }

    /// Annotations for every saved passage in the document that isn't already highlighted.
    func findSavedPassages() -> [PlacedAnnotation] {
        guard let document, !library.passages.isEmpty else { return [] }
        return Matcher.phraseAnnotations(in: document, phrases: savedPhrases, ocr: ocrWords)
    }

    /// The line boxes of `items`, by page index, so matching can avoid them.
    func rectsByPage(_ items: [PlacedAnnotation]) -> [Int: [CGRect]] {
        guard let document else { return [:] }
        var result: [Int: [CGRect]] = [:]
        for item in items {
            result[document.index(for: item.page), default: []] += Highlighter.lineRects(of: item.annotation)
        }
        return result
    }

    // MARK: - Zoom

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }
    func actualSize() {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    // MARK: - Undoable primitives

    func add(_ items: [PlacedAnnotation], actionName: String) {
        for item in items { item.page.addAnnotation(item.annotation) }
        registerUndo(actionName) { $0.remove(items, actionName: actionName) }
        didChange(items)
    }

    private func remove(_ items: [PlacedAnnotation], actionName: String) {
        for item in items { item.page.removeAnnotation(item.annotation) }
        registerUndo(actionName) { $0.add(items, actionName: actionName) }
        didChange(items)
    }

    private func setColors(_ items: [PlacedAnnotation], _ colors: [NSColor], actionName: String) {
        let previous = items.map { $0.annotation.color }
        for (item, color) in zip(items, colors) { item.annotation.color = color }
        registerUndo(actionName) { $0.setColors(items, previous, actionName: actionName) }
        didChange(items)
    }

    private func registerUndo(_ actionName: String, _ handler: @escaping (DocumentModel) -> Void) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    private func didChange(_ items: [PlacedAnnotation]) {
        isDirty = true
        for page in Set(items.map(\.page)) { pdfView.annotationsChanged(on: page) }
        refreshHighlights()
    }

    /// Rebuilds the sidebar list from the document's annotations, one entry per
    /// highlight (its lines grouped), in reading order.
    func refreshHighlights() {
        guard let document else {
            highlights = []
            return
        }
        var items: [HighlightItem] = []
        var liveKeys = Set<ObjectIdentifier>()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageHighlights = page.annotations
                .filter(Highlighter.isHighlight)
                // Top of page first (PDF y grows upward), then left to right.
                .sorted { ($0.bounds.maxY, -$0.bounds.minX) > ($1.bounds.maxY, -$1.bounds.minX) }
            var order: [String] = []
            var groups: [String: [PDFAnnotation]] = [:]
            for annotation in pageHighlights {
                let key = Highlighter.groupKey(of: annotation)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(annotation)
            }
            for key in order {
                let lines = groups[key] ?? []
                let text = lines.map { annotation -> String in
                    let id = ObjectIdentifier(annotation)
                    liveKeys.insert(id)
                    if let cached = textCache[id] { return cached }
                    var read = Highlighter.text(of: annotation, on: page)
                    if read.isEmpty, let words = ocrWords[index] {
                        read = OCR.text(in: Highlighter.lineRects(of: annotation), words: words)
                    }
                    textCache[id] = read
                    return read
                }.filter { !$0.isEmpty }.joined(separator: " ")
                items.append(HighlightItem(members: lines.map { PlacedAnnotation(annotation: $0, page: page) },
                                           pageNumber: index + 1, text: text, color: lines[0].color,
                                           paletteColor: HighlightColor.nearest(to: lines[0].color)))
            }
        }
        // Drop entries for annotations that are gone, so a recycled identifier never shows stale text.
        textCache = textCache.filter { liveKeys.contains($0.key) }
        highlights = items
        if let selectedHighlightID, !items.contains(where: { $0.id == selectedHighlightID }) {
            self.selectedHighlightID = nil
        }
    }

    /// Every line of the highlight that `annotation` belongs to.
    private func wholeHighlight(containing annotation: PDFAnnotation) -> [PlacedAnnotation] {
        let id = ObjectIdentifier(annotation)
        return highlights.first { $0.members.contains { ObjectIdentifier($0.annotation) == id } }?.members ?? []
    }

    // MARK: - Context menu

    private func customize(_ menu: NSMenu, for event: NSEvent) {
        var items: [NSMenuItem] = []

        if let text = pdfView.currentSelection?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(ClosureMenuItem(title: "Highlight", image: color.menuImage) { [weak self] in
                self?.highlightCurrentSelection()
            })
            items.append(ClosureMenuItem(title: "Remove Highlights in Selection") { [weak self] in
                self?.removeHighlightsInCurrentSelection()
            })
        }

        let hits = highlightsUnder(event)
        if !hits.isEmpty {
            items.append(ClosureMenuItem(title: "Remove Highlight") { [weak self] in
                self?.removeHighlights(hits)
            })
            let colorMenu = NSMenu()
            for option in HighlightColor.allCases {
                colorMenu.addItem(ClosureMenuItem(title: option.name, image: option.menuImage) { [weak self] in
                    self?.recolor(hits, to: option)
                })
            }
            let colorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colorMenu
            items.append(colorItem)
        }

        guard !items.isEmpty else { return }
        items.append(.separator())
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    /// Whole highlights (all their lines) under the mouse.
    private func highlightsUnder(_ event: NSEvent) -> [PlacedAnnotation] {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return [] }
        var seen = Set<ObjectIdentifier>()
        return Highlighter.highlights(at: pdfView.convert(viewPoint, to: page), on: page)
            .flatMap { hit -> [PlacedAnnotation] in
                let group = wholeHighlight(containing: hit.annotation)
                return group.isEmpty ? [hit] : group
            }
            .filter { seen.insert(ObjectIdentifier($0.annotation)).inserted }
    }

    // MARK: - Errors

    func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
