import PDFKit

/// PDFView that reports finished mouse selections (for highlighter mode)
/// and lets the model add items to the right-click menu.
final class HighlightPDFView: PDFView {
    /// When true, finishing a text selection with the mouse triggers `onSelectionFinished`.
    var highlighterMode = false
    var onSelectionFinished: (() -> Void)?
    var menuCustomizer: ((NSMenu, NSEvent) -> Void)?

    /// When true, dragging draws a box to highlight instead of selecting text. This
    /// reaches areas text selection can't: blank signature lines, form fields (which
    /// take the click themselves) and scanned pages with no text.
    var areaMode = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    /// Called while dragging (`finished` false) and once on release (`finished` true),
    /// with the box in page coordinates, clipped to the page.
    var onAreaDrag: ((PDFPage, CGRect, _ finished: Bool) -> Void)?
    private var areaStart: (page: PDFPage, point: CGPoint)?

    override func mouseDown(with event: NSEvent) {
        if areaMode {
            // Skip PDFView's own handling so form fields and links don't take the click.
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: true) {
                areaStart = (page, convert(viewPoint, to: page))
            }
            return
        }
        super.mouseDown(with: event)
        // PDFView can run its own drag-tracking loop inside mouseDown and swallow
        // the matching mouseUp. If the button is already released, the drag is over.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishSelectionIfNeeded()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard areaMode else { return super.mouseDragged(with: event) }
        if let rect = areaRect(for: event) { onAreaDrag?(rect.page, rect.box, false) }
    }

    override func mouseUp(with event: NSEvent) {
        guard areaMode else {
            super.mouseUp(with: event)
            finishSelectionIfNeeded()
            return
        }
        if let rect = areaRect(for: event) { onAreaDrag?(rect.page, rect.box, true) }
        areaStart = nil
    }

    override func mouseMoved(with event: NSEvent) {
        if areaMode { NSCursor.crosshair.set() } else { super.mouseMoved(with: event) }
    }

    override func resetCursorRects() {
        if areaMode { addCursorRect(bounds, cursor: .crosshair) } else { super.resetCursorRects() }
    }

    /// The box from the drag start to the mouse, on the start page, clipped to that page.
    private func areaRect(for event: NSEvent) -> (page: PDFPage, box: CGRect)? {
        guard let start = areaStart else { return nil }
        let point = convert(convert(event.locationInWindow, from: nil), to: start.page)
        let box = CGRect(x: min(start.point.x, point.x), y: min(start.point.y, point.y),
                         width: abs(point.x - start.point.x), height: abs(point.y - start.point.y))
            .intersection(start.page.bounds(for: displayBox))
        return box.isNull ? nil : (start.page, box)
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
