import AppKit
import PDFKit
import Vision

/// One recognized word on a scanned page, in page coordinates.
struct OCRWord: Sendable {
    let text: String
    let rect: CGRect
    /// Which recognized line the word came from, so matches can be boxed per line.
    let line: Int
}

/// Reads text from scanned pages (pages with no text layer) using macOS's
/// built-in text recognition, so phrase lists, saved passages and templates can
/// find text there too.
enum OCR {
    /// True when a page has no selectable text and is upright (rotated pages are skipped).
    static func needsRecognition(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && page.rotation % 360 == 0
    }

    /// Renders a page to an image suitable for recognition. Must run on the main thread
    /// (PDFKit drawing); recognition itself can run anywhere.
    @MainActor
    static func image(of page: PDFPage) -> (CGImage, CGRect)? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(2.0, 2400 / bounds.width)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, bounds)
    }

    /// Renders `page` here on the main thread, then recognizes it off the main thread.
    @MainActor
    static func recognize(_ page: PDFPage) async -> [OCRWord] {
        guard let rendered = image(of: page) else { return [] }
        let (picture, bounds) = rendered
        return await Task.detached(priority: .utility) { OCR.recognize(picture, pageBounds: bounds) }.value
    }

    /// Indexes of the pages in `document` that need recognition.
    static func pagesNeedingRecognition(in document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { document.page(at: $0).map(needsRecognition) ?? false }
    }

    /// Recognizes words in a rendered page. Vision reports boxes normalized to the
    /// image with the origin at the bottom left, the same orientation as PDF space.
    static func recognize(_ image: CGImage, pageBounds: CGRect) -> [OCRWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var words: [OCRWord] = []
        for (lineIndex, observation) in (request.results ?? []).enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
                guard let word, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                let rect = CGRect(x: pageBounds.minX + box.minX * pageBounds.width,
                                  y: pageBounds.minY + box.minY * pageBounds.height,
                                  width: box.width * pageBounds.width,
                                  height: box.height * pageBounds.height)
                words.append(OCRWord(text: word, rect: rect, line: lineIndex))
            }
        }
        return words
    }

    /// The recognized words inside any of `rects`, in reading order.
    static func text(in rects: [CGRect], words: [OCRWord]) -> String {
        words.filter { word in rects.contains { $0.contains(CGPoint(x: word.rect.midX, y: word.rect.midY)) } }
            .map(\.text)
            .joined(separator: " ")
    }
}
