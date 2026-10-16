import AppKit
import PDFKit

/// A phrase to highlight and the color to use.
struct PhraseRequest {
    let text: String
    let color: NSColor
}

/// Finds where phrases and form templates land in any PDF, open or not. Used by
/// the open document (saved passages, phrase lists, templates) and by batches.
enum Matcher {
    /// Highlight annotations for every occurrence of `phrases` that doesn't overlap an
    /// existing highlight or `alsoTaken`. Longer phrases go first, so a sentence wins
    /// over a phrase inside it. Scanned pages are searched through `ocr` words.
    /// `pages` limits the search to those page indexes.
    static func phraseAnnotations(in document: PDFDocument, phrases: [PhraseRequest],
                                  ocr: [Int: [OCRWord]] = [:], pages: Set<Int>? = nil,
                                  alsoTaken: [Int: [CGRect]] = [:]) -> [PlacedAnnotation] {
        phraseMatches(in: document, phrases: phrases, ocr: ocr, pages: pages, alsoTaken: alsoTaken).placed
    }

    /// Like `phraseAnnotations`, and also reports which phrases (normalized, lowercased)
    /// occur in the document at all, including ones that were already highlighted.
    static func phraseMatches(in document: PDFDocument, phrases: [PhraseRequest],
                              ocr: [Int: [OCRWord]] = [:], pages: Set<Int>? = nil,
                              alsoTaken: [Int: [CGRect]] = [:]) -> (placed: [PlacedAnnotation], found: Set<String>) {
        let sorted = phrases.filter { !PassageLibrary.normalize($0.text).isEmpty }
            .sorted { $0.text.count > $1.text.count }
        guard !sorted.isEmpty else { return ([], []) }
        var found = Set<String>()
        var result: [PlacedAnnotation] = []
        for index in 0..<document.pageCount where pages?.contains(index) ?? true {
            guard let page = document.page(at: index) else { continue }
            var taken = page.annotations.filter(Highlighter.isHighlight).flatMap(Highlighter.lineRects)
                + (alsoTaken[index] ?? [])
            let words = ocr[index] ?? []
            for phrase in sorted {
                var candidates: [[CGRect]] = []
                if !words.isEmpty {
                    candidates = ocrOccurrences(of: phrase.text, words: words)
                } else {
                    for range in Highlighter.occurrences(of: phrase.text, on: page) {
                        guard let selection = page.selection(for: range) else { continue }
                        let lines = selection.selectionsByLine().compactMap { line -> CGRect? in
                            let rect = line.bounds(for: page)
                            return rect.width > 0.5 && rect.height > 0.5 ? rect : nil
                        }
                        if !lines.isEmpty { candidates.append(lines) }
                    }
                }
                if !candidates.isEmpty { found.insert(PassageLibrary.normalize(phrase.text).lowercased()) }
                for lines in candidates {
                    let inset = lines.map { $0.insetBy(dx: 1, dy: 1) }
                    guard !inset.contains(where: { rect in taken.contains { $0.intersects(rect) } }) else { continue }
                    taken.append(contentsOf: inset)
                    result.append(PlacedAnnotation(annotation: Highlighter.makeAnnotation(lines: lines, color: phrase.color), page: page))
                }
            }
        }
        return (result, found)
    }

    /// Line boxes for each occurrence of `phrase` in recognized words (case-insensitive,
    /// across line breaks).
    static func ocrOccurrences(of phrase: String, words: [OCRWord]) -> [[CGRect]] {
        let needle = PassageLibrary.normalize(phrase).lowercased().split(separator: " ").map(String.init)
        guard !needle.isEmpty, words.count >= needle.count else { return [] }
        let lowered = words.map { $0.text.lowercased() }
        var result: [[CGRect]] = []
        var i = 0
        while i + needle.count <= words.count {
            // Words match exactly, except the first and last may be part of a longer word.
            let ok = needle.enumerated().allSatisfy { k, want in
                let got = lowered[i + k]
                if needle.count == 1 { return got.contains(want) }
                if k == 0 { return got.hasSuffix(want) }
                if k == needle.count - 1 { return got.hasPrefix(want) }
                return got == want
            }
            if ok {
                var byLine: [Int: CGRect] = [:]
                var order: [Int] = []
                for word in words[i..<(i + needle.count)] {
                    if let rect = byLine[word.line] { byLine[word.line] = rect.union(word.rect) } else { byLine[word.line] = word.rect; order.append(word.line) }
                }
                result.append(order.compactMap { byLine[$0] })
                i += needle.count
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Form templates

    /// What identifies a form: page count, the first page's size, and the start of its text.
    static func signature(of document: PDFDocument) -> (pageCount: Int, size: CGSize, text: String) {
        let first = document.page(at: 0)
        let size = first?.bounds(for: .mediaBox).size ?? .zero
        let text = String(PassageLibrary.normalize(first?.string ?? "").lowercased().prefix(80))
        return (document.pageCount, size, text)
    }

    /// True when `document` looks like the form `template` was made from.
    static func matches(_ template: FormTemplate, _ document: PDFDocument) -> Bool {
        let sig = signature(of: document)
        guard sig.pageCount == template.pageCount,
              abs(sig.size.width - template.pageWidth) <= 1, abs(sig.size.height - template.pageHeight) <= 1
        else { return false }
        // Scanned forms have no text to compare; size and page count must do.
        return template.signature.isEmpty || sig.text.isEmpty || sig.text == template.signature
    }

    /// Highlights a closed document with the library: the first matching form
    /// template, then saved passages. Returns how many highlights were added.
    @MainActor
    @discardableResult
    static func applyLibrary(_ library: PassageLibrary, to document: PDFDocument, ocr: [Int: [OCRWord]] = [:]) -> Int {
        var placed: [PlacedAnnotation] = []
        if let template = library.templates.first(where: { matches($0, document) }) {
            placed = templateAnnotations(template, in: document)
            for item in placed { item.page.addAnnotation(item.annotation) }
        }
        let phrases = library.passages.map { PhraseRequest(text: $0.text, color: $0.color.nsColor) }
        let more = phraseAnnotations(in: document, phrases: phrases, ocr: ocr)
        for item in more { item.page.addAnnotation(item.annotation) }
        return placed.count + more.count
    }

    /// The template's highlights placed on `document`, skipping any that overlap an existing highlight.
    static func templateAnnotations(_ template: FormTemplate, in document: PDFDocument) -> [PlacedAnnotation] {
        var result: [PlacedAnnotation] = []
        for highlight in template.highlights {
            guard let page = document.page(at: highlight.page), !highlight.rects.isEmpty else { continue }
            let lines = highlight.rects.map(\.cgRect)
            let taken = page.annotations.filter(Highlighter.isHighlight).flatMap(Highlighter.lineRects)
            let inset = lines.map { $0.insetBy(dx: 1, dy: 1) }
            guard !inset.contains(where: { rect in taken.contains { $0.intersects(rect) } }) else { continue }
            result.append(PlacedAnnotation(annotation: Highlighter.makeAnnotation(lines: lines, color: highlight.color.nsColor), page: page))
        }
        return result
    }
}
