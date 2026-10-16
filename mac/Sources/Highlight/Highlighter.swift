import PDFKit

/// A PDF annotation together with the page it lives on.
struct PlacedAnnotation {
    let annotation: PDFAnnotation
    let page: PDFPage
}

/// Stateless helpers for creating, finding and reading highlight annotations.
enum Highlighter {
    /// Builds one highlight annotation per page of `selection`, with one
    /// quadrilateral per selected line. That is how Preview stores multi-line
    /// highlights: the highlight stays tight to each line, yet it is one object
    /// to list, remove or recolor, and it stays one object after saving.
    static func makeAnnotations(for selection: PDFSelection, color: NSColor) -> [PlacedAnnotation] {
        var linesByPage: [(page: PDFPage, lines: [CGRect])] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                if let index = linesByPage.firstIndex(where: { $0.page == page }) {
                    linesByPage[index].lines.append(bounds)
                } else {
                    linesByPage.append((page, [bounds]))
                }
            }
        }
        return linesByPage.map { PlacedAnnotation(annotation: makeAnnotation(lines: $0.lines, color: color), page: $0.page) }
    }

    /// Identifies a highlight for grouping in the sidebar. Each annotation is one highlight.
    static func groupKey(of annotation: PDFAnnotation) -> String {
        "\(ObjectIdentifier(annotation).hashValue)"
    }

    /// Creates a highlight annotation covering `bounds` (page coordinates).
    static func makeAnnotation(bounds: CGRect, color: NSColor) -> PDFAnnotation {
        makeAnnotation(lines: [bounds], color: color)
    }

    /// Creates one highlight annotation over several line rects (page coordinates).
    static func makeAnnotation(lines: [CGRect], color: NSColor) -> PDFAnnotation {
        let bounds = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        // QuadPoints (relative to the annotation's origin) are what PDFKit, Preview and
        // Acrobat use to draw the highlight, one quad per line.
        annotation.quadrilateralPoints = lines.flatMap { line in
            quadPoints(for: line).map { NSValue(point: CGPoint(x: $0.x + line.minX - bounds.minX,
                                                                y: $0.y + line.minY - bounds.minY)) }
        }
        return annotation
    }

    /// The line rects (page coordinates) a highlight covers, from its quads;
    /// falls back to its bounds when it has none.
    static func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        let origin = annotation.bounds.origin
        let points = (annotation.quadrilateralPoints ?? []).map { $0.pointValue }
        guard points.count >= 4 else { return [annotation.bounds] }
        return stride(from: 0, to: points.count - 3, by: 4).map { i in
            let quad = points[i..<(i + 4)]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: origin.x + xs.min()!, y: origin.y + ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
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
                for annotation in page.annotations
                where isHighlight(annotation) && lineRects(of: annotation).contains(where: { $0.intersects(lineRect) }) {
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
            .filter { isHighlight($0) && lineRects(of: $0).contains { $0.contains(point) } }
            .map { PlacedAnnotation(annotation: $0, page: page) }
    }

    /// Where `phrase` occurs in the page text, ignoring case and treating any run of
    /// whitespace (including line breaks) as one space, so a passage that wraps
    /// differently in another PDF still matches. Ranges index `page.string`.
    static func occurrences(of phrase: String, on page: PDFPage) -> [NSRange] {
        let needle = PassageLibrary.normalize(phrase)
        guard !needle.isEmpty, let raw = page.string else { return [] }
        let source = raw as NSString
        var units: [unichar] = []
        var map: [Int] = []
        units.reserveCapacity(source.length)
        map.reserveCapacity(source.length)
        var lastWasSpace = true
        for i in 0..<source.length {
            let unit = source.character(at: i)
            let isSpace = Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            if isSpace {
                if !lastWasSpace { units.append(32); map.append(i); lastWasSpace = true }
            } else {
                units.append(unit); map.append(i); lastWasSpace = false
            }
        }
        let normalized = NSString(characters: units, length: units.count)
        var result: [NSRange] = []
        var start = 0
        while start < normalized.length {
            let found = normalized.range(of: needle, options: [.caseInsensitive],
                                         range: NSRange(location: start, length: normalized.length - start))
            if found.location == NSNotFound { break }
            let first = map[found.location], last = map[found.location + found.length - 1]
            result.append(NSRange(location: first, length: last - first + 1))
            start = found.location + found.length
        }
        return result
    }

    /// The page text underneath a highlight.
    static func text(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        // Read each line along its vertical middle: a rect-based selection either
        // misses glyphs (if shrunk) or grabs neighbouring lines (if not).
        let lines = lineRects(of: annotation).sorted { ($0.maxY, -$0.minX) > ($1.maxY, -$1.minX) }
        // A drawn area box can span several lines: read everything inside it.
        if lines.count == 1, lines[0].height > 24 {
            let raw = page.selection(for: lines[0])?.string ?? ""
            return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let raw = lines.map { b -> String in
            var text = page.selection(from: CGPoint(x: b.minX + 0.5, y: b.midY),
                                      to: CGPoint(x: b.maxX - 0.5, y: b.midY))?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = page.selection(for: b)?.string ?? ""
            }
            return text
        }.joined(separator: " ")
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
