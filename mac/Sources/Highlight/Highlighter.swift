import PDFKit

/// A PDF annotation together with the page it lives on.
struct PlacedAnnotation {
    let annotation: PDFAnnotation
    let page: PDFPage
}

/// Stateless helpers for creating, finding and reading highlight annotations.
enum Highlighter {
    /// Builds one highlight annotation per selected line, per page.
    /// One-per-line keeps highlights tight to the text instead of painting a
    /// single box over the whole paragraph's bounding rectangle.
    static func makeAnnotations(for selection: PDFSelection, color: NSColor) -> [PlacedAnnotation] {
        var result: [PlacedAnnotation] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                result.append(PlacedAnnotation(annotation: makeAnnotation(bounds: bounds, color: color), page: page))
            }
        }
        return result
    }

    /// Creates a highlight annotation covering `bounds` (page coordinates).
    static func makeAnnotation(bounds: CGRect, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        // QuadPoints are what other viewers (Preview, Acrobat) use to draw the highlight.
        annotation.quadrilateralPoints = quadPoints(for: bounds).map { NSValue(point: $0) }
        return annotation
    }

    /// QuadPoints relative to the annotation origin, in PDF order:
    /// top-left, top-right, bottom-left, bottom-right.
    static func quadPoints(for bounds: CGRect) -> [CGPoint] {
        let w = bounds.width, h = bounds.height
        return [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)]
    }

    /// True for highlight annotations, including ones made by other apps.
    static func isHighlight(_ annotation: PDFAnnotation) -> Bool {
        let type = annotation.type ?? ""
        return type == "Highlight" || type == "/Highlight"
    }

    /// Highlights that overlap any line of `selection`.
    static func highlights(intersecting selection: PDFSelection) -> [PlacedAnnotation] {
        var seen = Set<ObjectIdentifier>()
        var result: [PlacedAnnotation] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let lineRect = line.bounds(for: page)
                for annotation in page.annotations where isHighlight(annotation) && annotation.bounds.intersects(lineRect) {
                    if seen.insert(ObjectIdentifier(annotation)).inserted {
                        result.append(PlacedAnnotation(annotation: annotation, page: page))
                    }
                }
            }
        }
        return result
    }

    /// Highlights on `page` containing `point` (page coordinates).
    static func highlights(at point: CGPoint, on page: PDFPage) -> [PlacedAnnotation] {
        page.annotations
            .filter { isHighlight($0) && $0.bounds.contains(point) }
            .map { PlacedAnnotation(annotation: $0, page: page) }
    }

    /// The page text underneath a highlight.
    static func text(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        // Select along the line's vertical middle: a rect-based selection either
        // misses glyphs (if shrunk) or grabs neighbouring lines (if not).
        let b = annotation.bounds
        var raw = page.selection(from: CGPoint(x: b.minX + 0.5, y: b.midY),
                                 to: CGPoint(x: b.maxX - 0.5, y: b.midY))?.string ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = page.selection(for: b)?.string ?? ""
        }
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
