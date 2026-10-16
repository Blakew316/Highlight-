import AppKit
import SwiftUI

/// The highlighter colors offered in the toolbar and Highlight menu.
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, orange

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    /// Fixed sRGB values (not system dynamic colors) so saved highlights look
    /// the same in every PDF viewer and don't shift in Dark Mode.
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.90, blue: 0.20, alpha: 0.5)
        case .green: return NSColor(srgbRed: 0.45, green: 0.90, blue: 0.40, alpha: 0.5)
        case .blue: return NSColor(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 0.5)
        case .pink: return NSColor(srgbRed: 1.00, green: 0.45, blue: 0.70, alpha: 0.5)
        case .orange: return NSColor(srgbRed: 1.00, green: 0.65, blue: 0.20, alpha: 0.5)
        }
    }

    /// Opaque version for UI swatches.
    var swatch: Color { Color(nsColor: nsColor.withAlphaComponent(1)) }

    /// 1-based position, used for the ⌘1…⌘5 shortcuts.
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// A small filled circle for use in AppKit menus.
    var menuImage: NSImage {
        let color = nsColor.withAlphaComponent(1)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
