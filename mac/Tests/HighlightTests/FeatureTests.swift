import AppKit
import PDFKit
import XCTest
@testable import Highlight

/// Phrase lists, form templates, the library file, batches, OCR matching,
/// highlight navigation and exporting highlighted pages.
final class FeatureTests: XCTestCase {
    @MainActor
    private func makeModel(mode: AutoHighlightMode = .ask) -> DocumentModel {
        let defaults = UserDefaults(suiteName: "FeatureTests-\(UUID().uuidString)")!
        let library = PassageLibrary(defaults: defaults)
        library.mode = mode
        return DocumentModel(library: library, defaults: defaults)
    }

    /// A PDF with one entry of `pages` per page, each a list of text lines (an empty list is a blank page).
    @MainActor
    private func makePDF(pages: [[String]]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])
                    .draw(at: NSPoint(x: 72, y: 700 - CGFloat(index) * 40))
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor
    private func annotations(_ document: PDFDocument, where match: (PDFAnnotation) -> Bool = Highlighter.isHighlight) -> [PDFAnnotation] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }.flatMap(\.annotations).filter(match)
    }

    private let form = ["Principal #1", "Print Name: ____________", "Title: ____________", "Date: ____________"]

    // MARK: - Phrase lists

    @MainActor
    func testPhraseListParsingDropsBulletsBlanksAndDuplicates() {
        let phrases = DocumentModel.phrases(from: "- Print Name\n\n• Title\n3. Date\n  print   name \nx\n")
        XCTAssertEqual(phrases, ["Print Name", "Title", "Date"])
    }

    @MainActor
    func testHighlightPhrasesIsOneUndoStepAndReportsMissing() throws {
        let document = try makePDF(pages: [form])
        let model = makeModel()
        model.setDocument(document, url: nil)
        model.color = .green

        let outcome = model.highlightPhrases(["print name", "Date", "Witness"], save: true)
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.missing, ["Witness"])
        XCTAssertEqual(model.highlights.count, 2)
        XCTAssertTrue(model.highlights.allSatisfy { $0.paletteColor == .green })
        XCTAssertEqual(Set(model.library.passages.map(\.text)), ["print name", "Date", "Witness"])

        // Already highlighted: found, but nothing new to add.
        XCTAssertEqual(model.highlightPhrases(["Print Name"], save: false).added, 0)
        XCTAssertEqual(model.highlightPhrases(["Print Name"], save: false).missing, [])

        model.undoManager.undo()
        XCTAssertEqual(model.highlights.count, 0)
    }

    // MARK: - Form templates

    @MainActor
    func testFormTemplateIsOfferedOnTheNextCopyOfTheForm() throws {
        let first = makeModel()
        let original = try makePDF(pages: [form])
        first.setDocument(original, url: nil)
        let page = try XCTUnwrap(original.page(at: 0))
        // A box over a blank fill-in line, which has no text to match on.
        XCTAssertTrue(first.highlightArea(CGRect(x: 160, y: 655, width: 160, height: 30), on: page))
        first.color = .pink
        first.highlightPhrases(["Principal #1"], save: false)
        let template = try XCTUnwrap(first.makeTemplate(named: "Signature page"))
        XCTAssertEqual(template.highlights.count, 2)

        let model = makeModel()
        model.library.addTemplate(template)
        model.setDocument(try makePDF(pages: [form]), url: nil)
        model.checkSavedPassages()
        XCTAssertEqual(model.pendingTemplateName, "Signature page")
        XCTAssertEqual(model.pendingSavedCount, 2)
        model.applyPendingSavedMatches()
        XCTAssertEqual(model.highlights.count, 2)
        XCTAssertEqual(Set(model.highlights.map(\.paletteColor)), [.yellow, .pink])
        let rects = model.highlights.flatMap { $0.members.flatMap { Highlighter.lineRects(of: $0.annotation) } }
        XCTAssertTrue(rects.contains { abs($0.minX - 160) < 0.5 && abs($0.minY - 655) < 0.5 && abs($0.width - 160) < 0.5 })

        // Applying again adds nothing: those places are already highlighted.
        XCTAssertTrue(Matcher.templateAnnotations(template, in: try XCTUnwrap(model.document)).isEmpty)
    }

    @MainActor
    func testFormTemplateIgnoresADifferentForm() throws {
        let model = makeModel()
        model.setDocument(try makePDF(pages: [form]), url: nil)
        model.highlightPhrases(["Title"], save: false)
        let template = try XCTUnwrap(model.makeTemplate(named: "Form A"))
        XCTAssertTrue(Matcher.matches(template, try makePDF(pages: [form])))
        XCTAssertFalse(Matcher.matches(template, try makePDF(pages: [["Invoice", "Title"]])), "different text")
        XCTAssertFalse(Matcher.matches(template, try makePDF(pages: [form, form])), "different page count")
    }

    // MARK: - Library file

    @MainActor
    func testLibraryFileRoundTripsPassagesAndTemplates() throws {
        let model = makeModel()
        model.setDocument(try makePDF(pages: [form]), url: nil)
        model.color = .blue
        model.highlightPhrases(["Print Name"], save: true)
        model.library.addTemplate(try XCTUnwrap(model.makeTemplate(named: "Form")))

        let json = try JSONEncoder().encode(model.library.exportFile())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "Highlight")
        XCTAssertEqual(object["version"] as? Int, 1)

        let other = PassageLibrary(defaults: UserDefaults(suiteName: "FeatureTests-\(UUID().uuidString)")!)
        let counts = other.importFile(try JSONDecoder().decode(LibraryFile.self, from: json))
        XCTAssertEqual(counts.passages, 1)
        XCTAssertEqual(counts.templates, 1)
        XCTAssertEqual(other.passages.first?.text, "Print Name")
        XCTAssertEqual(other.passages.first?.color, .blue)
        let original = try XCTUnwrap(model.library.templates.first)
        let imported = try XCTUnwrap(other.templates.first)
        let pairs = zip(imported.highlights.flatMap(\.rects), original.highlights.flatMap(\.rects))
        XCTAssertEqual(imported.highlights.flatMap(\.rects).count, original.highlights.flatMap(\.rects).count)
        for (a, b) in pairs {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
            XCTAssertEqual(a.width, b.width, accuracy: 0.001)
            XCTAssertEqual(a.height, b.height, accuracy: 0.001)
        }
        XCTAssertEqual(imported.signature, original.signature)

        // Importing the same file again adds nothing new.
        XCTAssertEqual(other.importFile(try JSONDecoder().decode(LibraryFile.self, from: json)).passages, 0)
        XCTAssertEqual(other.templates.count, 1)
    }

    @MainActor
    func testLibraryFileFromTheWebsiteDecodes() throws {
        let json = """
        {"app":"Highlight","version":1,"passages":[{"text":"Print Name","color":"green"}],
         "templates":[{"name":"W-9","pageCount":1,"size":[612,792],"signature":"principal #1",
           "highlights":[{"page":0,"rects":[[160,655,320,685]],"color":"pink","text":""}]}]}
        """
        let library = PassageLibrary(defaults: UserDefaults(suiteName: "FeatureTests-\(UUID().uuidString)")!)
        library.importFile(try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8)))
        XCTAssertEqual(library.passages.first?.color, .green)
        let rect = try XCTUnwrap(library.templates.first?.highlights.first?.rects.first)
        XCTAssertEqual(rect.cgRect, CGRect(x: 160, y: 655, width: 160, height: 30))
    }

    // MARK: - Batch

    @MainActor
    func testApplyLibraryHighlightsAClosedDocument() throws {
        let library = PassageLibrary(defaults: UserDefaults(suiteName: "FeatureTests-\(UUID().uuidString)")!)
        library.remember("Print Name", color: .orange)
        let document = try makePDF(pages: [form, ["Nothing here"]])
        XCTAssertEqual(Matcher.applyLibrary(library, to: document), 1)
        XCTAssertEqual(annotations(document).count, 1)
        XCTAssertEqual(Matcher.applyLibrary(library, to: document), 0, "already highlighted")
    }

    @MainActor
    func testBatchDestinationNeverOverwrites() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let out = dir.appendingPathComponent("out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("form.pdf")
        try Data("x".utf8).write(to: source)

        XCTAssertEqual(DocumentModel.batchDestination(for: source, in: dir).lastPathComponent, "form highlighted.pdf")
        XCTAssertEqual(DocumentModel.batchDestination(for: source, in: out).lastPathComponent, "form.pdf")
        try Data("x".utf8).write(to: out.appendingPathComponent("form.pdf"))
        XCTAssertEqual(DocumentModel.batchDestination(for: source, in: out).lastPathComponent, "form 2.pdf")
    }

    // MARK: - Scanned pages

    @MainActor
    private func scannedWords() -> [OCRWord] {
        // Two lines: "Principal signature" / "here please".
        [OCRWord(text: "Principal", rect: CGRect(x: 72, y: 700, width: 100, height: 20), line: 0),
         OCRWord(text: "signature", rect: CGRect(x: 180, y: 700, width: 100, height: 20), line: 0),
         OCRWord(text: "here", rect: CGRect(x: 72, y: 660, width: 50, height: 20), line: 1),
         OCRWord(text: "please.", rect: CGRect(x: 130, y: 660, width: 70, height: 20), line: 1)]
    }

    @MainActor
    func testOCRMatchesAcrossLinesWithOneBoxPerLine() {
        let matches = Matcher.ocrOccurrences(of: "signature HERE", words: scannedWords())
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.count, 2)
        XCTAssertEqual(Matcher.ocrOccurrences(of: "please", words: scannedWords()).count, 1, "punctuation doesn't block a match")
        XCTAssertEqual(OCR.text(in: [CGRect(x: 60, y: 690, width: 400, height: 40)], words: scannedWords()), "Principal signature")
    }

    @MainActor
    func testFindAndSavedPassagesWorkOnRecognizedText() throws {
        let document = try makePDF(pages: [[]])
        XCTAssertEqual(OCR.pagesNeedingRecognition(in: document), [0])
        let model = makeModel(mode: .always)
        model.library.remember("signature here", color: .blue)
        model.setDocument(document, url: nil)
        model.ocrWords = [0: scannedWords()]

        model.checkSavedPassages(onPages: [0])
        XCTAssertEqual(model.highlights.count, 1)
        XCTAssertEqual(model.highlights.first?.text, "signature here", "read from the recognized words")

        model.find("principal")
        XCTAssertEqual(model.findResults.count, 1)
        XCTAssertNil(model.findResults.first?.selection)
        let square = { (a: PDFAnnotation) in (a.type ?? "").contains("Square") }
        XCTAssertEqual(annotations(document, where: square).count, 1, "the match is marked on the page")

        // Find markers never reach the saved file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.write(to: url)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(annotations(saved, where: square).count, 0)
        XCTAssertEqual(annotations(saved).count, 1)

        model.highlightAllMatches()
        XCTAssertEqual(model.highlights.count, 2)
        XCTAssertEqual(annotations(document, where: square).count, 0)
    }

    @MainActor
    func testVisionReadsARenderedPage() async throws {
        let document = try makePDF(pages: [["Principal Signature"]])
        let page = try XCTUnwrap(document.page(at: 0))
        let words = await OCR.recognize(page)
        XCTAssertTrue(words.contains { $0.text.lowercased() == "signature" }, "\(words.map(\.text))")
        // Boxes come back in page coordinates, near where the text was drawn.
        let box = try XCTUnwrap(words.first { $0.text.lowercased() == "signature" }?.rect)
        XCTAssertTrue(box.minY > 650 && box.maxY < 760, "\(box)")
    }

    // MARK: - Navigation and filter

    @MainActor
    func testNextPreviousHighlightAndColorFilter() throws {
        let document = try makePDF(pages: [form, form])
        let model = makeModel()
        model.setDocument(document, url: nil)
        let first = try XCTUnwrap(document.page(at: 0)), second = try XCTUnwrap(document.page(at: 1))
        model.color = .yellow
        model.highlightArea(CGRect(x: 60, y: 690, width: 200, height: 30), on: first)
        model.color = .green
        model.highlightArea(CGRect(x: 60, y: 650, width: 200, height: 30), on: first)
        model.color = .yellow
        model.highlightArea(CGRect(x: 60, y: 690, width: 200, height: 30), on: second)
        XCTAssertEqual(model.highlights.count, 3)

        model.selectNextHighlight()
        XCTAssertEqual(model.selectedHighlightID, model.highlights[0].id)
        model.selectNextHighlight()
        XCTAssertEqual(model.selectedHighlightID, model.highlights[1].id)
        model.selectPreviousHighlight()
        model.selectPreviousHighlight()
        XCTAssertEqual(model.selectedHighlightID, model.highlights[2].id, "wraps around")

        model.colorFilter = .yellow
        XCTAssertEqual(model.visibleHighlights.count, 2)
        model.selectNextHighlight()
        XCTAssertEqual(model.selectedHighlightID, model.highlights[0].id, "skips the green one")

        model.removeHighlights(model.highlights[0].members)
        XCTAssertNil(model.selectedHighlightID, "a removed highlight is no longer selected")
    }

    // MARK: - Export highlighted pages

    @MainActor
    func testExportHighlightedPagesKeepsOnlyThosePages() throws {
        let document = try makePDF(pages: [["Cover"], form, ["Appendix"]])
        let model = makeModel()
        model.setDocument(document, url: nil)
        model.highlightPhrases(["Title"], save: false)
        let pages = try XCTUnwrap(model.highlightedPagesDocument())
        XCTAssertEqual(pages.pageCount, 1)
        XCTAssertTrue(pages.page(at: 0)?.string?.contains("Print Name") ?? false)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pages.write(to: url))
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertEqual(annotations(reopened).count, 1)
        XCTAssertNil(annotations(reopened).first?.contents.flatMap { $0.isEmpty ? nil : $0 }, "no note text")
        XCTAssertEqual(annotations(document).count, 1, "the open PDF is unchanged")
    }
}
