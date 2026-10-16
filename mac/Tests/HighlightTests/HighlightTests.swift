import AppKit
import PDFKit
import XCTest
@testable import Highlight

final class HighlightTests: XCTestCase {
    /// A one-page PDF containing real text, so PDFKit selections work.
    @MainActor
    private func makeTextPDF(_ text: String = "Hello highlight world") throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            .draw(at: NSPoint(x: 72, y: 700))
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
        let model = DocumentModel()
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
        let model = DocumentModel()
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
        let model = DocumentModel()
        model.setDocument(document, url: nil)
        let page = try XCTUnwrap(document.page(at: 0))
        model.color = .yellow
        try model.highlight(XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5))))

        model.recolor([model.highlights[0].placed], to: .blue)
        assertSameColor(model.highlights[0].color, HighlightColor.blue.nsColor)
        model.undoManager.undo()
        assertSameColor(model.highlights[0].color, HighlightColor.yellow.nsColor)
    }

    @MainActor
    func testSaveRoundTripKeepsHighlights() throws {
        let document = try makeTextPDF()
        let model = DocumentModel()
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
}
