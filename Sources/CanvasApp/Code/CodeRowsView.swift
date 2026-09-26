import AppKit
import CanvasCore

/// The scroll view's document: an empty view sized to the content, so the scroll view knows
/// its extent without anything that large ever being drawn or backed by a bitmap. The rows
/// view inside it covers only the visible rect.
@MainActor
final class CodeScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Draws the visible rows of a code document (CTLine per visible row, cached only while
/// visible) and handles character selection, ⌘C, gutter clicks, and "Edit Here". It sits over
/// the visible rect of a `CodeScrollDocument` with its bounds origin equal to its frame origin,
/// so its own coordinates are document coordinates.
@MainActor
final class CodeRowsView: NSView {
    var painter: CodePainter? {
        didSet { needsDisplay = true }
    }

    /// A gutter sign was clicked (peek or unpeek).
    var onSign: ((Int) -> Void)?
    /// The user scrolled, clicked, or selected here.
    var onInteract: (() -> Void)?
    var onEditHere: ((NSPoint) -> Void)?

    let cache = CodeLineCache()
    private var anchor: CodePosition?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Keep covering the scroll view's visible rect.
    func track(_ visible: NSRect) {
        guard frame != visible || bounds.origin != visible.origin else { return }
        frame = visible
        setBoundsOrigin(visible.origin)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let painter else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        painter.draw(in: context, rect: bounds, gutterX: bounds.minX, cache: cache)
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

    override func scrollWheel(with event: NSEvent) {
        onInteract?()
        super.scrollWheel(with: event)
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
        autoscroll(with: event)
        guard let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
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
