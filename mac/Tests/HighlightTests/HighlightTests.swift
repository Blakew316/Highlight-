import AppKit
import PDFKit
import XCTest
@testable import Highlight

final class HighlightTests: XCTestCase {
    /// A model whose saved-passage library lives in a throwaway defaults suite,
    /// so tests never touch the real app's settings.
    @MainActor
    private func makeModel(mode: AutoHighlightMode = .ask) -> DocumentModel {
        let defaults = UserDefaults(suiteName: "HighlightTests-\(UUID().uuidString)")!
        let library = PassageLibrary(defaults: defaults)
        library.mode = mode
        return DocumentModel(library: library)
    }

    /// A one-page PDF containing real text, so PDFKit selections work.
    @MainActor
    private func makeTextPDF(_ text: String = "Hello highlight world") throws -> PDFDocument {
        try makeTextPDF(lines: [text])
    }

    @MainActor
    private func makeTextPDF(lines: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])
                .draw(at: NSPoint(x: 72, y: 700 - CGFloat(index) * 40))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor
    private func highlightCount(_ document: PDFDocument) -> Int {
        (0..<document.pageCount)
            .compactMap { document.page(at: $0) }
            .flatMap(\.annotations)
            .filter(Highlighter.isHighlight)
            .count
    }

    /// PDFKit may hand back a converted NSColor, so compare sRGB components.
    @MainActor
    private func assertSameColor(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else {
            return XCTFail("color not convertible to sRGB", file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.02, file: file, line: line)
    }

    @MainActor
    func testQuadPointsAreRelativeAndInPDFOrder() {
        let points = Highlighter.quadPoints(for: CGRect(x: 100, y: 200, width: 50, height: 10))
        XCTAssertEqual(points, [CGPoint(x: 0, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
    }

    @MainActor
    func testMakeAnnotationIsHighlight() {
        let annotation = Highlighter.makeAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                    color: HighlightColor.green.nsColor)
        XCTAssertTrue(Highlighter.isHighlight(annotation))
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 4)
    }

    @MainActor
    func testHighlightSelectionThenUndoRedo() throws {
        let document = try makeTextPDF()
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5)))

        XCTAssertTrue(model.highlight(selection))
        XCTAssertEqual(model.highlights.count, 1)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.highlights[0].text.contains("Hello"), "got \(model.highlights[0].text)")

        model.undoManager.undo()
        XCTAssertEqual(model.highlights.count, 0)
        XCTAssertEqual(highlightCount(document), 0)

        model.undoManager.redo()
        XCTAssertEqual(model.highlights.count, 1)
    }

    @MainActor
    func testRemoveHighlightsInSelection() throws {
        let document = try makeTextPDF()
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))

        try model.removeHighlights(in: XCTUnwrap(page.selection(for: NSRange(location: 1, length: 2))))
        XCTAssertEqual(model.highlights.count, 0)

        model.undoManager.undo()
        XCTAssertEqual(model.highlights.count, 1)
    }

    @MainActor
    func testRecolorIsUndoable() throws {
        let document = try makeTextPDF()
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        model.color = .yellow
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))

        model.recolor(model.highlights[0].members, to: .blue)
        assertSameColor(model.highlights[0].color, HighlightColor.blue.nsColor)
        model.undoManager.undo()
        assertSameColor(model.highlights[0].color, HighlightColor.yellow.nsColor)
    }

    @MainActor
    func testSaveRoundTripKeepsHighlights() throws {
        let document = try makeTextPDF()
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.pdf")

        try model.write(to: url)      // new file
        try model.write(to: url)      // overwrite existing file
        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(highlightCount(reloaded), 1)
    }

    @MainActor
    func testMultiLineHighlightIsOneEntryAndSurvivesSave() throws {
        let document = try makeTextPDF(lines: ["First line of text", "Second line of text"])
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        let all = try XCTUnwrap(page.string)
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: all.count))))

        XCTAssertEqual(highlightCount(document), 2, "one annotation per line")
        XCTAssertEqual(model.highlights.count, 1, "but one sidebar entry")
        XCTAssertTrue(model.highlights[0].text.contains("First"), model.highlights[0].text)
        XCTAssertTrue(model.highlights[0].text.contains("Second"), model.highlights[0].text)

        model.removeHighlights(model.highlights[0].members)
        XCTAssertEqual(highlightCount(document), 0, "removing the entry removes every line")
        model.undoManager.undo()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lines.pdf")
        try model.write(to: url)

        let reopened = makeModel()
        reopened.setDocument(try XCTUnwrap(PDFDocument(url: url)), url: url)
        XCTAssertEqual(reopened.highlights.count, 1, "grouping is kept in the saved file")
    }

    @MainActor
    func testFindAndHighlightAllMatches() throws {
        let document = try makeTextPDF(lines: ["apple pie", "banana", "apple tart"])
        let model = makeModel()
        model.setDocument(document, url: nil)

        model.find("APPLE")
        XCTAssertEqual(model.findResults.count, 2)
        model.findNext()
        XCTAssertEqual(model.findIndex, 1)
        model.findNext()
        XCTAssertEqual(model.findIndex, 0, "wraps around")

        model.highlightAllMatches()
        XCTAssertEqual(model.highlights.count, 2)
        XCTAssertTrue(model.findResults.isEmpty)
        model.undoManager.undo()
        XCTAssertEqual(model.highlights.count, 0, "one undo step")
    }

    @MainActor
    func testMarkdownExport() throws {
        let document = try makeTextPDF(lines: ["Alpha beta"])
        let model = makeModel()
        model.setDocument(document, url: URL(fileURLWithPath: "/tmp/Notes.pdf"))
        let page = try XCTUnwrap(document.page(at: 0))
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))

        let md = model.highlightsMarkdown()
        XCTAssertTrue(md.hasPrefix("# Highlights: Notes\n"), md)
        XCTAssertTrue(md.contains("## Page 1"), md)
        XCTAssertTrue(md.contains("- Alpha"), md)
    }

    @MainActor
    func testSavedHighlightsCarryNoCommentText() throws {
        let document = try makeTextPDF()
        let model = makeModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))
        for annotation in page.annotations where Highlighter.isHighlight(annotation) {
            XCTAssertTrue((annotation.contents ?? "").isEmpty, "highlights must not carry note text")
        }
    }

    @MainActor
    func testOccurrencesIgnoreCaseAndLineBreaks() throws {
        let document = try makeTextPDF(lines: ["The tenant must keep the lazy", "dog quiet. LAZY DOG rules apply."])
        let page = try XCTUnwrap(document.page(at: 0))
        let ranges = Highlighter.occurrences(of: "lazy  dog", on: page)
        XCTAssertEqual(ranges.count, 2, "one match wraps a line, one differs in case")
        let text = try XCTUnwrap(page.string) as NSString
        XCTAssertEqual(PassageLibrary.normalize(text.substring(with: ranges[1])).lowercased(), "lazy dog")
    }

    @MainActor
    func testLibraryRemembersNormalizedAndDeduplicates() {
        let defaults = UserDefaults(suiteName: "HighlightTests-\(UUID().uuidString)")!
        let library = PassageLibrary(defaults: defaults)
        library.remember("  Lazy\n dog ", color: .yellow)
        library.remember("lazy dog", color: .blue)
        library.remember("ab", color: .green)  // too short to be useful
        XCTAssertEqual(library.passages.count, 1)
        XCTAssertEqual(library.passages[0].text, "Lazy dog")
        XCTAssertEqual(library.passages[0].color, .blue)

        let reloaded = PassageLibrary(defaults: defaults)
        XCTAssertEqual(reloaded.passages, library.passages, "kept across launches")
    }

    @MainActor
    func testAskModeOffersSavedPassagesInNewPDF() throws {
        let model = makeModel(mode: .ask)
        model.library.remember("lazy dog", color: .pink)
        model.setDocument(try makeTextPDF(lines: ["Mind the lazy dog.", "Another lazy", "dog here."]), url: nil)
        model.checkSavedPassages()

        XCTAssertEqual(model.pendingSavedCount, 2)
        XCTAssertEqual(model.highlights.count, 0, "nothing is added until the user accepts")
        model.applyPendingSavedMatches()
        XCTAssertEqual(model.highlights.count, 2)
        model.undoManager.undo()
        XCTAssertEqual(model.highlights.count, 0, "one undo step")
    }

    @MainActor
    func testAlwaysModeHighlightsAndSkipsExistingHighlights() throws {
        let model = makeModel(mode: .always)
        model.library.remember("lazy dog", color: .green)
        let document = try makeTextPDF(lines: ["Mind the lazy dog."])
        model.setDocument(document, url: nil)
        model.checkSavedPassages()
        XCTAssertEqual(model.highlights.count, 1)

        model.checkSavedPassages()
        XCTAssertEqual(model.highlights.count, 1, "already-highlighted text is not highlighted twice")
    }

    @MainActor
    func testOffModeDoesNothing() throws {
        let model = makeModel(mode: .off)
        model.library.remember("lazy dog", color: .green)
        model.setDocument(try makeTextPDF(lines: ["Mind the lazy dog."]), url: nil)
        model.checkSavedPassages()
        XCTAssertEqual(model.pendingSavedCount, 0)
        XCTAssertEqual(model.highlights.count, 0)
    }

    @MainActor
    func testHighlightAllRemembersQuery() throws {
        let model = makeModel()
        model.setDocument(try makeTextPDF(lines: ["apple pie", "apple tart"]), url: nil)
        model.find("apple pie")
        model.highlightAllMatches()
        XCTAssertEqual(model.library.passages.map(\.text), ["apple pie"])
    }
}
