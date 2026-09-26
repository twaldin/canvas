import AppKit
import CanvasCore

/// Draws the visible rows of a code document (CTLine per visible row, cached only while
/// visible) and scrolls itself: its bounds origin is the scroll offset, so its own coordinates
/// are document coordinates. No scroll or clip view: those re-lay out and rebuild tracking
/// areas on every frame of a canvas pan, even behind a zoomed-out card. Also handles character
/// selection, ⌘C, gutter clicks, and "Edit Here".
@MainActor
final class CodeRowsView: NSView {
    var painter: CodePainter? {
        didSet {
            needsDisplay = true
            scroll(to: bounds.origin)
        }
    }

    /// A gutter sign was clicked (peek or unpeek).
    var onSign: ((Int) -> Void)?
    /// The user scrolled, clicked, or selected here.
    var onInteract: (() -> Void)?
    /// The offset changed (by the user or programmatically).
    var onScroll: (() -> Void)?
    var onEditHere: ((NSPoint) -> Void)?

    let cache = CodeLineCache()
    private var anchor: CodePosition?

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private var contentSize: CGSize { painter?.contentSize ?? .zero }

    /// Scroll so `origin` (document coordinates) is the top-left, clamped to the content.
    func scroll(to origin: CGPoint) {
        let maxX = max(0, contentSize.width - bounds.width), maxY = max(0, contentSize.height - bounds.height)
        let clamped = CGPoint(x: min(max(0, origin.x), maxX).rounded(), y: min(max(0, origin.y), maxY).rounded())
        guard clamped != bounds.origin else { return }
        setBoundsOrigin(clamped)
        needsDisplay = true
        onScroll?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroll(to: bounds.origin)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let painter else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        painter.draw(in: context, rect: bounds, gutterX: bounds.minX, cache: cache)
        drawScrollIndicator(content: painter.contentSize)
    }

    /// A thin thumb along the right edge when the file is taller than the view.
    private func drawScrollIndicator(content: CGSize) {
        guard content.height > bounds.height + 0.5 else { return }
        let length = max(24, bounds.height * bounds.height / content.height)
        let y = bounds.minY + (bounds.height - length) * bounds.minY / (content.height - bounds.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: y + 2, width: 3, height: length - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Laid-out lines carry resolved colors.
        cache.removeAll()
        needsDisplay = true
    }

    /// Not live: nothing laid out or rasterized is kept.
    func releaseCaches() {
        cache.removeAll()
        layer?.contents = nil
    }

    // MARK: Hit testing

    func isInGutter(_ point: NSPoint) -> Bool {
        guard let painter else { return false }
        return point.x < bounds.minX + painter.gutterWidth
    }

    func position(at point: NSPoint) -> CodePosition? {
        guard let painter, painter.rows.count > 0 else { return nil }
        let row = min(max(0, CodePainter.row(atY: point.y)), painter.rows.count - 1)
        let line = cache.lines[painter.source(ofRow: row)?.key ?? .line(0)] ?? painter.makeLine(row: row)
        return CodePosition(row: row, offset: painter.offset(inRow: row, x: point.x, line: line))
    }

    // MARK: Mouse

    /// Scrolls along an axis the content overflows; anything else (a file that fits) goes on
    /// to the canvas, which pans.
    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= CodeMetrics.rowHeight
            dy *= CodeMetrics.rowHeight
        }
        let vertical = abs(dy) >= abs(dx)
        let overflows = vertical ? contentSize.height > bounds.height + 0.5 : contentSize.width > bounds.width + 0.5
        guard overflows, dx != 0 || dy != 0 else { return super.scrollWheel(with: event) }
        onInteract?()
        scroll(to: CGPoint(x: bounds.minX - (vertical ? 0 : dx), y: bounds.minY - (vertical ? dy : 0)))
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        if isInGutter(point), let sign = painter?.sign(atY: point.y) {
            onSign?(sign)
            return
        }
        window?.makeFirstResponder(self)
        guard let position = position(at: point) else { return }
        if event.modifierFlags.contains(.shift), let selection = painter?.selection {
            anchor = position < selection.start ? selection.end : selection.start
        } else {
            anchor = position
        }
        select(to: position)
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        // Dragging past an edge scrolls toward it.
        let point = convert(event.locationInWindow, from: nil)
        let dy = point.y < bounds.minY ? point.y - bounds.minY : point.y > bounds.maxY ? point.y - bounds.maxY : 0
        let dx = point.x < bounds.minX ? point.x - bounds.minX : point.x > bounds.maxX ? point.x - bounds.maxX : 0
        if dx != 0 || dy != 0 { scroll(to: CGPoint(x: bounds.minX + dx, y: bounds.minY + dy)) }
        guard let position = position(at: point) else { return }
        select(to: position)
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
    }

    private func select(to position: CodePosition) {
        guard let anchor else { return }
        painter?.selection = anchor < position ? (anchor, position) : (position, anchor)
        onInteract?()
    }

    var selectedText: String? {
        guard let painter, let selection = painter.selection, selection.start < selection.end else { return nil }
        var pieces: [String] = []
        for row in selection.start.row...selection.end.row {
            let text = painter.text(ofRow: row)
            let from = row == selection.start.row ? min(selection.start.offset, text.length) : 0
            let to = row == selection.end.row ? min(selection.end.offset, text.length) : text.length
            pieces.append(text.substring(with: NSRange(location: from, length: max(0, to - from))))
        }
        return pieces.joined(separator: "\n")
    }

    /// Rows the selection spans, when it selects anything.
    var selectedRows: ClosedRange<Int>? {
        guard let selection = painter?.selection, selection.start < selection.end else { return nil }
        return selection.start.row...selection.end.row
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let painter, painter.rows.count > 0 else { return }
        let last = painter.rows.count - 1
        self.painter?.selection = (CodePosition(row: 0, offset: 0), CodePosition(row: last, offset: painter.text(ofRow: last).length))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit Here", action: #selector(editHere(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = NSValue(point: convert(event.locationInWindow, from: nil))
        menu.addItem(edit)
        if selectedText != nil {
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu
    }

    @objc private func editHere(_ sender: NSMenuItem) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else { return }
        onEditHere?(point)
    }
}

extension CodeRowsView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? selectedText != nil : true
    }
}
