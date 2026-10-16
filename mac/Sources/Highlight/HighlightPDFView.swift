import PDFKit

/// PDFView that reports finished mouse selections (for highlighter mode)
/// and lets the model add items to the right-click menu.
final class HighlightPDFView: PDFView {
    /// When true, finishing a text selection with the mouse triggers `onSelectionFinished`.
    var highlighterMode = false
    var onSelectionFinished: (() -> Void)?
    var menuCustomizer: ((NSMenu, NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // PDFView can run its own drag-tracking loop inside mouseDown and swallow
        // the matching mouseUp. If the button is already released, the drag is over.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishSelectionIfNeeded()
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishSelectionIfNeeded()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menuCustomizer?(menu, event)
        return menu
    }

    private func finishSelectionIfNeeded() {
        guard highlighterMode,
              let text = currentSelection?.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        onSelectionFinished?()
    }
}

/// An NSMenuItem that runs a closure, so context-menu items don't need @objc targets.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        self.target = self
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
