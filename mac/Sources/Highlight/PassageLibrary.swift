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

/// Every passage the user highlights, kept across launches in UserDefaults so
/// newly opened PDFs can be checked for the same wording.
@MainActor
final class PassageLibrary: ObservableObject {
    static let maxPassages = 500
    private static let passagesKey = "savedPassages.v1"
    private static let modeKey = "autoHighlightMode"

    @Published private(set) var passages: [SavedPassage] = []
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
    }

    /// Collapses runs of whitespace (including line breaks) to single spaces.
    static func normalize(_ text: String) -> String {
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
