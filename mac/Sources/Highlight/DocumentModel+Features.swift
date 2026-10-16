import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Text recognition, phrase lists, form templates, the shared library file,
/// batches, highlight navigation and page export.
extension DocumentModel {
    // MARK: - Text recognition (scanned pages)

    /// Reads scanned pages of the open PDF in the background. When it's done,
    /// the highlights list shows their text, Find searches them, and saved
    /// passages are looked for there too.
    func startRecognizingText() {
        ocrTask?.cancel()
        ocrTask = nil
        ocrProgress = nil
        guard let document else { return }
        let pages = OCR.pagesNeedingRecognition(in: document)
        guard !pages.isEmpty else { return }
        ocrProgress = JobProgress(done: 0, total: pages.count)
        ocrTask = Task { [weak self] in
            for index in pages {
                guard !Task.isCancelled, let page = document.page(at: index) else { return }
                let words = await OCR.recognize(page)
                guard !Task.isCancelled, let self, self.document === document else { return }
                if !words.isEmpty { self.ocrWords[index] = words }
                self.ocrProgress?.done += 1
            }
            guard !Task.isCancelled, let self, self.document === document else { return }
            self.ocrProgress = nil
            self.ocrTask = nil
            self.recognitionFinished(pages: Set(pages))
        }
    }

    private func recognitionFinished(pages: Set<Int>) {
        guard !ocrWords.isEmpty else { return }
        // Highlights on scanned pages were read as empty before; read them again.
        textCache = [:]
        refreshHighlights()
        checkSavedPassages(onPages: pages)
    }

    // MARK: - Phrase lists

    /// Splits pasted text into phrases: one per line, bullets and numbering removed.
    static func phrases(from text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            var phrase = line.trimmingCharacters(in: .whitespaces)
            if let range = phrase.range(of: #"^([-•*–]|\d+[.)])\s+"#, options: .regularExpression) {
                phrase.removeSubrange(range)
            }
            phrase = PassageLibrary.normalize(phrase)
            guard phrase.count >= 2, seen.insert(phrase.lowercased()).inserted else { return nil }
            return phrase
        }
    }

    /// Highlights every occurrence of each phrase in the current color, as one undo step.
    /// Returns how many highlights were added and which phrases don't appear in the PDF.
    @discardableResult
    func highlightPhrases(_ phrases: [String], save: Bool) -> (added: Int, missing: [String]) {
        guard let document, !phrases.isEmpty else { return (0, phrases) }
        let requests = phrases.map { PhraseRequest(text: $0, color: color.nsColor) }
        let result = Matcher.phraseMatches(in: document, phrases: requests, ocr: ocrWords)
        if !result.placed.isEmpty { add(result.placed, actionName: "Highlight Phrases") }
        if save { for phrase in phrases { library.remember(phrase, color: color) } }
        let missing = phrases.filter { !result.found.contains(PassageLibrary.normalize($0).lowercased()) }
        return (result.placed.count, missing)
    }

    // MARK: - Form templates

    /// The open PDF's highlights as a template for the next copy of the same form.
    func makeTemplate(named name: String) -> FormTemplate? {
        guard let document, !highlights.isEmpty else { return nil }
        let signature = Matcher.signature(of: document)
        return FormTemplate(
            name: name, pageCount: signature.pageCount,
            pageWidth: signature.size.width, pageHeight: signature.size.height, signature: signature.text,
            highlights: highlights.map { item in
                FormTemplate.Highlight(page: item.pageNumber - 1,
                                       rects: item.members.flatMap { Highlighter.lineRects(of: $0.annotation) }.map(StoredRect.init),
                                       color: item.paletteColor, text: item.text)
            })
    }

    func presentSaveTemplatePrompt() {
        guard !highlights.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Save as Form Template"
        alert.informativeText = "The next time you open a copy of this form, Highlight will offer to highlight the same places, including boxes over blank lines and fields."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = fileURL?.deletingPathExtension().lastPathComponent ?? "Form"
        field.placeholderString = "Template name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template = makeTemplate(named: name.isEmpty ? "Form" : name) else { return }
        library.addTemplate(template)
    }

    /// Highlights the template's places in the open PDF (one undo step).
    @discardableResult
    func applyTemplate(_ template: FormTemplate) -> Int {
        guard let document else { return 0 }
        dismissPendingSavedMatches()
        let placed = Matcher.templateAnnotations(template, in: document)
        guard !placed.isEmpty else {
            showInfo(title: "Nothing to add", message: "Every place in “\(template.name)” is already highlighted in this PDF.")
            return 0
        }
        add(placed, actionName: "Apply Form Template")
        return placed.count
    }

    // MARK: - Library file (shared with the website)

    func presentLibraryExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Highlight library.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library.exportFile()).write(to: url, options: .atomic)
        } catch {
            showError(title: "Couldn’t export your library", message: error.localizedDescription)
        }
    }

    func presentLibraryImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url))
            guard file.app == "Highlight" else { throw CocoaError(.fileReadCorruptFile) }
            let counts = library.importFile(file)
            showInfo(title: "Library imported",
                     message: "Added \(counts.passages) passage\(counts.passages == 1 ? "" : "s") and \(counts.templates) form template\(counts.templates == 1 ? "" : "s").")
        } catch {
            showError(title: "Couldn’t import “\(url.lastPathComponent)”",
                      message: "It isn’t a library exported from Highlight.")
        }
    }

    // MARK: - Batch

    /// Highlights many PDFs at once with the saved passages and form templates,
    /// writing highlighted copies to a folder. The originals aren't changed.
    func presentBatchPanel() {
        guard batchProgress == nil else { return }
        guard !library.passages.isEmpty || !library.templates.isEmpty else {
            showInfo(title: "Nothing saved yet",
                     message: "A batch highlights your saved passages and form templates. Highlight something first, or import a library.")
            return
        }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.pdf]
        open.allowsMultipleSelection = true
        open.message = "Choose the PDFs to highlight with your saved passages and form templates."
        open.prompt = "Choose"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let folder = NSOpenPanel()
        folder.canChooseFiles = false
        folder.canChooseDirectories = true
        folder.canCreateDirectories = true
        folder.message = "Choose where to save the highlighted copies. The originals aren’t changed."
        folder.prompt = "Save Here"
        folder.directoryURL = open.urls[0].deletingLastPathComponent()
        guard folder.runModal() == .OK, let output = folder.url else { return }
        startBatch(open.urls, to: output)
    }

    func startBatch(_ urls: [URL], to folder: URL) {
        batchProgress = JobProgress(done: 0, total: urls.count)
        batchTask = Task { [weak self] in
            var written: [URL] = [], skipped: [String] = [], failed: [String] = []
            var total = 0
            for url in urls {
                guard !Task.isCancelled else { break }
                // Let the progress sheet draw between files.
                await Task.yield()
                guard let document = PDFDocument(url: url), !document.isLocked else {
                    failed.append(url.lastPathComponent)
                    self?.batchProgress?.done += 1
                    continue
                }
                var words: [Int: [OCRWord]] = [:]
                for index in OCR.pagesNeedingRecognition(in: document) {
                    guard !Task.isCancelled, let page = document.page(at: index) else { break }
                    words[index] = await OCR.recognize(page)
                }
                guard let self, !Task.isCancelled else { break }
                let added = Matcher.applyLibrary(self.library, to: document, ocr: words)
                if added == 0 {
                    skipped.append(url.lastPathComponent)
                } else {
                    let target = Self.batchDestination(for: url, in: folder)
                    if document.write(to: target) {
                        written.append(target)
                        total += added
                    } else {
                        failed.append(url.lastPathComponent)
                    }
                }
                self.batchProgress?.done += 1
            }
            guard let self else { return }
            self.batchProgress = nil
            self.batchTask = nil
            self.reportBatch(written: written, highlights: total, skipped: skipped, failed: failed)
        }
    }

    func cancelBatch() { batchTask?.cancel() }

    /// Where a batch writes its copy of `url`: the same name in `folder`, never
    /// overwriting the original or an existing file.
    static func batchDestination(for url: URL, in folder: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let sameFolder = folder.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL
        var name = sameFolder ? "\(base) highlighted" : base
        var candidate = folder.appendingPathComponent(name).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            name = sameFolder ? "\(base) highlighted \(n)" : "\(base) \(n)"
            candidate = folder.appendingPathComponent(name).appendingPathExtension("pdf")
            n += 1
        }
        return candidate
    }

    private func reportBatch(written: [URL], highlights: Int, skipped: [String], failed: [String]) {
        var lines = ["Saved \(written.count) highlighted PDF\(written.count == 1 ? "" : "s") with \(highlights) highlight\(highlights == 1 ? "" : "s")."]
        if !skipped.isEmpty {
            lines.append("Nothing matched in \(skipped.count): \(skipped.prefix(5).joined(separator: ", "))\(skipped.count > 5 ? "…" : "").")
        }
        if !failed.isEmpty {
            lines.append("Couldn’t open or save \(failed.count): \(failed.prefix(5).joined(separator: ", "))\(failed.count > 5 ? "…" : "").")
        }
        let alert = NSAlert()
        alert.messageText = "Batch finished"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: written.isEmpty ? "OK" : "Show in Finder")
        if !written.isEmpty { alert.addButton(withTitle: "Done") }
        if alert.runModal() == .alertFirstButtonReturn, !written.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(written)
        }
    }

    // MARK: - Highlight navigation and filter

    /// The highlights shown in the list, after the color filter.
    var visibleHighlights: [HighlightItem] {
        guard let colorFilter else { return highlights }
        return highlights.filter { $0.paletteColor == colorFilter }
    }

    func selectNextHighlight() { stepHighlight(1) }
    func selectPreviousHighlight() { stepHighlight(-1) }

    /// Moves to the next or previous highlight in the list, starting from the
    /// selected one or, with none selected, from the page on screen.
    private func stepHighlight(_ delta: Int) {
        let items = visibleHighlights
        guard !items.isEmpty else { return }
        let target: HighlightItem
        if let id = selectedHighlightID, let index = items.firstIndex(where: { $0.id == id }) {
            target = items[(index + delta + items.count) % items.count]
        } else if delta > 0 {
            target = items.first { $0.pageNumber >= currentPageNumber } ?? items[0]
        } else {
            target = items.last { $0.pageNumber <= currentPageNumber } ?? items[items.count - 1]
        }
        if target.id == selectedHighlightID {
            reveal(target)
        } else {
            selectedHighlightID = target.id
        }
    }

    // MARK: - Export highlighted pages

    /// A new PDF with only the pages that have highlights, highlights included.
    func highlightedPagesDocument() -> PDFDocument? {
        guard let document else { return nil }
        let indexes = Set(highlights.map { $0.pageNumber - 1 }).sorted()
        guard !indexes.isEmpty else { return nil }
        let output = PDFDocument()
        withoutFindMarkers { () -> Void in
            for index in indexes {
                guard let source = document.page(at: index), let copy = source.copy() as? PDFPage else { continue }
                // Rebuild the highlights from the source so they don't depend on how PDFKit copies annotations.
                for annotation in copy.annotations where Highlighter.isHighlight(annotation) { copy.removeAnnotation(annotation) }
                for annotation in source.annotations where Highlighter.isHighlight(annotation) {
                    copy.addAnnotation(Highlighter.makeAnnotation(lines: Highlighter.lineRects(of: annotation), color: annotation.color))
                }
                output.insert(copy, at: output.pageCount)
            }
        }
        return output.pageCount > 0 ? output : nil
    }

    func presentExportPagesPanel() {
        guard let pages = highlightedPagesDocument() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = "\(base) highlighted pages.pdf"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !pages.write(to: url) {
            showError(title: "Couldn’t export the highlighted pages", message: SaveError.writeFailed.localizedDescription)
        }
    }
}
