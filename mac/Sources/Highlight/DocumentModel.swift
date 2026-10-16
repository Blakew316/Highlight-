import AppKit
import PDFKit
import UniformTypeIdentifiers

/// One highlight as listed in the sidebar.
struct HighlightItem: Identifiable {
    let annotation: PDFAnnotation
    let page: PDFPage
    let pageNumber: Int
    let text: String
    let color: NSColor

    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
    var placed: PlacedAnnotation { PlacedAnnotation(annotation: annotation, page: page) }
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
    @Published var highlighterMode = false {
        didSet { pdfView.highlighterMode = highlighterMode }
    }

    let undoManager = UndoManager()
    let pdfView = HighlightPDFView()

    init() {
        // Explicit groups make undo independent of the run loop (and testable).
        undoManager.groupsByEvent = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.onSelectionFinished = { [weak self] in self?.highlightCurrentSelection() }
        pdfView.menuCustomizer = { [weak self] menu, event in self?.customize(menu, for: event) }
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
    }

    /// Replaces the current document and resets undo/dirty state.
    func setDocument(_ doc: PDFDocument?, url: URL?) {
        document = doc
        fileURL = url
        pdfView.document = doc
        undoManager.removeAllActions()
        isDirty = false
        refreshHighlights()
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
        guard document.write(to: tempURL) else { throw SaveError.writeFailed }
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
        if highlight(selection) { pdfView.clearSelection() }
    }

    /// Highlights `selection` in the current color. Returns false if nothing was highlightable.
    @discardableResult
    func highlight(_ selection: PDFSelection) -> Bool {
        let placed = Highlighter.makeAnnotations(for: selection, color: color.nsColor)
        guard !placed.isEmpty else { return false }
        add(placed, actionName: "Highlight")
        return true
    }

    func removeHighlightsInCurrentSelection() {
        guard let selection = pdfView.currentSelection else { return }
        removeHighlights(in: selection)
    }

    func removeHighlights(in selection: PDFSelection) {
        let hits = Highlighter.highlights(intersecting: selection)
        guard !hits.isEmpty else { return }
        remove(hits, actionName: hits.count == 1 ? "Remove Highlight" : "Remove Highlights")
    }

    func removeHighlights(_ items: [PlacedAnnotation]) {
        guard !items.isEmpty else { return }
        remove(items, actionName: items.count == 1 ? "Remove Highlight" : "Remove Highlights")
    }

    func recolor(_ items: [PlacedAnnotation], to newColor: HighlightColor) {
        guard !items.isEmpty else { return }
        setColors(items, Array(repeating: newColor.nsColor, count: items.count), actionName: "Change Highlight Color")
    }

    /// Scrolls the PDF to a highlight from the sidebar.
    func reveal(_ item: HighlightItem) {
        pdfView.go(to: item.annotation.bounds, on: item.page)
    }

    /// Copies every highlight's text, in page order, to the clipboard.
    func copyAllHighlights() {
        let text = highlights.map { "p. \($0.pageNumber): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func add(_ items: [PlacedAnnotation], actionName: String) {
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

    /// Rebuilds the sidebar list from the document's annotations.
    func refreshHighlights() {
        guard let document else {
            highlights = []
            return
        }
        var items: [HighlightItem] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageHighlights = page.annotations
                .filter(Highlighter.isHighlight)
                // Top of page first (PDF y grows upward), then left to right.
                .sorted { ($0.bounds.maxY, -$0.bounds.minX) > ($1.bounds.maxY, -$1.bounds.minX) }
            for annotation in pageHighlights {
                items.append(HighlightItem(annotation: annotation, page: page, pageNumber: index + 1,
                                           text: Highlighter.text(of: annotation, on: page),
                                           color: annotation.color))
            }
        }
        highlights = items
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

    private func highlightsUnder(_ event: NSEvent) -> [PlacedAnnotation] {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return [] }
        return Highlighter.highlights(at: pdfView.convert(viewPoint, to: page), on: page)
    }

    // MARK: - Errors

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
