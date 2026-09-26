import AppKit
import CanvasCore

/// Colors for code tiles; system colors so light and dark appearances both read. Computed so
/// the background renderer can use them off the main thread.
enum CodeTheme {
    static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    static var deleted: NSColor { NSColor.systemRed.withAlphaComponent(0.14) }
    static var added: NSColor { NSColor.systemGreen.withAlphaComponent(0.14) }
    static var header: NSColor { NSColor.systemBlue.withAlphaComponent(0.09) }
    static var range: NSColor { NSColor.systemYellow.withAlphaComponent(0.22) }

    static func color(_ style: SyntaxStyle) -> NSColor {
        switch style {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemPurple
        case .type: .systemTeal
        case .function: .systemIndigo
        case .property: .systemBrown
        case .variable: .labelColor
        case .builtin: .systemPurple
        case .tag: .systemBlue
        case .punctuation: .secondaryLabelColor
        }
    }

}

/// Read-only TextKit 2 view that paints full-width row tints (deleted, added, hunk headers, the
/// object's range) behind the text and offers "Edit Here" on right-click.
@MainActor
final class CodeTextView: NSTextView {
    var display: DiffDisplay? { didSet { needsDisplay = true } }
    /// Rows of the object's `range`, tinted over the diff colors.
    var rangeRows: ClosedRange<Int>? { didSet { needsDisplay = true } }
    var onEditHere: ((NSPoint) -> Void)?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let display, !display.rows.isEmpty else { return }
        enumerateRowFrames(in: rect) { row, frame in
            if let tint = Self.tint(display.rows[row].kind) {
                tint.setFill()
                frame.fill()
            }
            if let rangeRows, rangeRows.contains(row) {
                CodeTheme.range.setFill()
                frame.fill()
            }
        }
    }

    private static func tint(_ kind: DiffDisplay.RowKind) -> NSColor? {
        switch kind {
        case .deleted: CodeTheme.deleted
        case .added: CodeTheme.added
        case .header: CodeTheme.header
        case .context: nil
        }
    }

    /// Full-width frames (view coordinates) of the rows laid out across `rect`.
    func enumerateRowFrames(in rect: NSRect, _ body: (Int, NSRect) -> Void) {
        guard let display, let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let origin = textContainerOrigin
        let top = NSPoint(x: 0, y: max(0, rect.minY - origin.y))
        let start = layout.textLayoutFragment(for: top)?.rangeInElement.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if let row = display.row(atOffset: offset) {
                body(row, NSRect(x: rect.minX, y: frame.minY + origin.y, width: rect.width, height: frame.height))
            }
            return true
        }
    }

    /// Display row under a point in this view's coordinates.
    func row(at point: NSPoint) -> Int? {
        guard let display, let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let local = NSPoint(x: max(0, point.x - textContainerOrigin.x), y: point.y - textContainerOrigin.y)
        guard let fragment = layout.textLayoutFragment(for: local) else { return nil }
        return display.row(atOffset: content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location))
    }

    /// Frame of display rows in this view's coordinates, laying them out if needed.
    func frame(ofRows rows: ClosedRange<Int>) -> NSRect? {
        guard let display, let layout = textLayoutManager, let content = layout.textContentManager,
              rows.upperBound < display.rows.count else { return nil }
        let first = display.range(ofRow: rows.lowerBound)
        let last = display.range(ofRow: rows.upperBound)
        guard let start = content.location(content.documentRange.location, offsetBy: first.location),
              let end = content.location(content.documentRange.location, offsetBy: NSMaxRange(last)),
              let range = NSTextRange(location: start, end: end) else { return nil }
        layout.ensureLayout(for: range)
        var union = NSRect.null
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            union = union.union(segment)
            return true
        }
        guard !union.isNull else { return nil }
        return NSRect(x: 0, y: union.minY + textContainerOrigin.y, width: bounds.width, height: union.height)
    }

    /// Scroll so a row sits a few rows below the top. The text view is grown to the laid-out
    /// height first: an occluded window never runs the display pass that would size it.
    func scroll(toRow row: Int) {
        guard let display, let layout = textLayoutManager, let content = layout.textContentManager, !display.rows.isEmpty else { return }
        let target = display.rows[max(0, min(row, display.rows.count - 1) - 3)].offset
        guard let location = content.location(content.documentRange.location, offsetBy: target),
              let upToTarget = NSTextRange(location: content.documentRange.location, end: location) else { return }
        layout.ensureLayout(for: upToTarget)
        sizeToFit()
        if let fragment = layout.textLayoutFragment(for: location) {
            scroll(NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let edit = NSMenuItem(title: "Edit Here", action: #selector(editHere(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = NSValue(point: point)
        menu.addItem(edit)
        if selectedRange().length > 0 {
            menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        }
        return menu
    }

    @objc private func editHere(_ sender: NSMenuItem) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else { return }
        onEditHere?(point)
    }
}
