import CoreGraphics
import Foundation

/// A passage the user has highlighted before, matched in PDFs opened later.
struct SavedPassage: Codable, Identifiable, Equatable {
    var text: String
    var color: HighlightColor
    var addedAt: Date

    var id: String { text.lowercased() }
}

/// What happens to saved passages when a PDF is opened.
enum AutoHighlightMode: String, CaseIterable, Identifiable {
    case ask, always, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask"
        case .always: return "Highlight"
        case .off: return "Off"
        }
    }
}

extension HighlightColor: Codable {}

/// A rectangle as stored in templates and library files.
struct StoredRect: Codable, Equatable {
    var x, y, width, height: Double

    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Where a form was highlighted, so the next copy of the same form can be
/// highlighted the same way, including area boxes over blank lines and fields.
struct FormTemplate: Codable, Identifiable, Equatable {
    struct Highlight: Codable, Equatable {
        var page: Int
        var rects: [StoredRect]
        var color: HighlightColor
        var text: String
    }

    var id = UUID()
    var name: String
    var pageCount: Int
    var pageWidth: Double
    var pageHeight: Double
    /// Start of the first page's text, lowercased, to tell different forms of the same size apart.
    var signature: String
    var highlights: [Highlight]
    var createdAt = Date()
}

/// The file format shared by the Mac app and the website for moving saved passages
/// and form templates between them.
struct LibraryFile: Codable {
    struct Passage: Codable { var text: String; var color: String }
    struct Template: Codable {
        struct Highlight: Codable { var page: Int; var rects: [[Double]]; var color: String; var text: String }
        var name: String
        var pageCount: Int
        var size: [Double]
        var signature: String
        var highlights: [Highlight]
    }
    var app = "Highlight"
    var version = 1
    var passages: [Passage]
    var templates: [Template]
}

/// Every passage the user highlights, kept across launches in UserDefaults so
/// newly opened PDFs can be checked for the same wording.
@MainActor
final class PassageLibrary: ObservableObject {
    static let maxPassages = 500
    private static let passagesKey = "savedPassages.v1"
    private static let templatesKey = "formTemplates.v1"
    static let maxTemplates = 50
    private static let modeKey = "autoHighlightMode"

    @Published private(set) var passages: [SavedPassage] = []
    @Published private(set) var templates: [FormTemplate] = []
    @Published var mode: AutoHighlightMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AutoHighlightMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .ask
        if let data = defaults.data(forKey: Self.passagesKey),
           let saved = try? JSONDecoder().decode([SavedPassage].self, from: data) {
            passages = saved
        }
        if let data = defaults.data(forKey: Self.templatesKey),
           let saved = try? JSONDecoder().decode([FormTemplate].self, from: data) {
            templates = saved
        }
    }

    // MARK: - Form templates

    /// Adds a template, replacing one with the same name.
    func addTemplate(_ template: FormTemplate) {
        templates.removeAll { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }
        templates.insert(template, at: 0)
        if templates.count > Self.maxTemplates { templates.removeLast(templates.count - Self.maxTemplates) }
        saveTemplates()
    }

    func removeTemplate(_ template: FormTemplate) {
        templates.removeAll { $0.id == template.id }
        saveTemplates()
    }

    private func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) { defaults.set(data, forKey: Self.templatesKey) }
    }

    // MARK: - Library file (shared with the website)

    func exportFile() -> LibraryFile {
        LibraryFile(
            passages: passages.map { .init(text: $0.text, color: $0.color.rawValue) },
            templates: templates.map { t in
                .init(name: t.name, pageCount: t.pageCount, size: [t.pageWidth, t.pageHeight], signature: t.signature,
                      highlights: t.highlights.map { h in
                          .init(page: h.page, rects: h.rects.map { [$0.x, $0.y, $0.x + $0.width, $0.y + $0.height] },
                                color: h.color.rawValue, text: h.text)
                      })
            })
    }

    /// Merges a library file: passages are added or recolored, templates replace same-named ones.
    /// Returns how many passages and templates were brought in.
    @discardableResult
    func importFile(_ file: LibraryFile) -> (passages: Int, templates: Int) {
        var p = 0, t = 0
        for passage in file.passages {
            let before = passages.count
            remember(passage.text, color: HighlightColor(rawValue: passage.color) ?? .yellow)
            if passages.count > before { p += 1 }
        }
        for template in file.templates where template.size.count == 2 {
            addTemplate(FormTemplate(
                name: template.name, pageCount: template.pageCount,
                pageWidth: template.size[0], pageHeight: template.size[1], signature: template.signature,
                highlights: template.highlights.map { h in
                    .init(page: h.page,
                          rects: h.rects.filter { $0.count == 4 }.map { StoredRect(CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1])) },
                          color: HighlightColor(rawValue: h.color) ?? .yellow, text: h.text)
                }))
            t += 1
        }
        return (p, t)
    }

    /// Collapses runs of whitespace (including line breaks) to single spaces.
    nonisolated static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Saves a highlighted passage, or updates its color if it is already saved.
    func remember(_ text: String, color: HighlightColor) {
        let normalized = Self.normalize(text)
        guard normalized.count >= 3 else { return }
        if let index = passages.firstIndex(where: { $0.id == normalized.lowercased() }) {
            passages[index].color = color
        } else {
            passages.insert(SavedPassage(text: normalized, color: color, addedAt: Date()), at: 0)
            if passages.count > Self.maxPassages { passages.removeLast(passages.count - Self.maxPassages) }
        }
        save()
    }

    /// Keeps a saved passage's color in step when one of its highlights is recolored.
    func recolor(_ text: String, to color: HighlightColor) {
        let key = Self.normalize(text).lowercased()
        guard let index = passages.firstIndex(where: { $0.id == key }) else { return }
        passages[index].color = color
        save()
    }

    func remove(_ passage: SavedPassage) {
        passages.removeAll { $0.id == passage.id }
        save()
    }

    func removeAll() {
        passages = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(passages) {
            defaults.set(data, forKey: Self.passagesKey)
        }
    }
}
