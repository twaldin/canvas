import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

/// A `path:line` reference under the pointer in a terminal's text, resolved to a file.
struct TerminalLinkHit: Equatable {
    var file: String
    var lines: LineRange
    /// Where it is drawn: one (row, first column, columns) run per viewport row it covers.
    var runs: [TerminalTextRows.Run]
}

/// The Ghostty view of a terminal tile, with ⌘-hover and ⌘-click on `path:line` references
/// (`TerminalReferences`) that resolve to a file. Everything else (URLs included) stays Ghostty's.
@MainActor
final class CanvasTerminalView: TerminalView {
    /// The reference at a point in this view's coordinates, if it names an existing file.
    var linkAt: ((NSPoint) -> TerminalLinkHit?)?
    var onHover: ((TerminalLinkHit?) -> Void)?
    var onOpen: ((TerminalLinkHit) -> Void)?

    private var swallowedMouseUp = false
    private var hovered: TerminalLinkHit?
    /// AppKit takes keyboard focus from a view it hides, and a terminal is hidden whenever its
    /// tile turns into its card (panned offscreen, zoomed out, a resize that took it out of
    /// view): the terminal that lost focus that way gets it back when shown again, unless
    /// something took it meanwhile. One at a time: focusing any terminal forgets it.
    private static weak var refocusTarget: CanvasTerminalView?

    override func becomeFirstResponder() -> Bool {
        Self.refocusTarget = nil
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isHiddenOrHasHiddenAncestor { Self.refocusTarget = self }
        return resigned
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard Self.refocusTarget === self, let window else { return }
        Self.refocusTarget = nil
        // Nothing chose a responder since: AppKit leaves the window or hands the canvas the focus.
        if window.firstResponder == nil || window.firstResponder === window || window.firstResponder is CanvasDocumentView {
            window.makeFirstResponder(self)
        }
    }

    /// Out of the key-view loop, so hiding one terminal never passes the focus to another
    /// (which would then take the refocus when it is hidden in turn).
    override var canBecomeKeyView: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let hit = linkAt?(convert(event.locationInWindow, from: nil)) {
            // Ghostty never sees this click, so it neither selects nor opens anything.
            swallowedMouseUp = true
            setHover(nil)
            onOpen?(hit)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowedMouseUp {
            swallowedMouseUp = false
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil)
    }

    private func updateHover(at point: NSPoint, command: Bool) {
        setHover(command && bounds.contains(point) ? linkAt?(point) : nil)
        if hovered != nil { NSCursor.pointingHand.set() }
    }

    private func setHover(_ hit: TerminalLinkHit?) {
        guard hit != hovered else { return }
        hovered = hit
        onHover?(hit)
    }
}

/// Up to three viewport rows of a terminal's text around one row, joined where a full row
/// wrapped into the next, with each UTF-16 unit's cell: enough to find a reference that the
/// terminal soft-wrapped at its right edge.
struct TerminalTextRows {
    struct Run: Equatable {
        var row: Int
        var column: Int
        var width: Int
    }

    private(set) var text = ""
    /// Per UTF-16 unit of `text`: its viewport row and first cell column.
    private var cells: [(row: Int, column: Int, width: Int)] = []

    /// `read(row)` returns a viewport row's text (nil past the screen).
    init(around row: Int, columns: Int, read: (Int) -> String?) {
        func cellCount(_ text: String) -> Int { text.reduce(0) { $0 + TerminalStyledTail.cellWidth($1) } }
        var rows: [(Int, String)] = []
        if row > 0, let previous = read(row - 1), cellCount(previous) >= columns { rows.append((row - 1, previous)) }
        guard let current = read(row) else { return }
        rows.append((row, current))
        if cellCount(current) >= columns, let next = read(row + 1) { rows.append((row + 1, next)) }
        for (index, line) in rows {
            var column = 0
            for character in line {
                let width = TerminalStyledTail.cellWidth(character)
                for _ in character.utf16 { cells.append((index, column, width)) }
                text.append(character)
                column += width
            }
        }
    }

    /// The UTF-16 offset of the character drawn in cell (`row`, `column`).
    func offset(row: Int, column: Int) -> Int? {
        cells.firstIndex { $0.row == row && column >= $0.column && column < $0.column + max($0.width, 1) }
    }

    /// The cells `range` covers, one run per row.
    func runs(_ range: NSRange) -> [Run] {
        var runs: [Run] = []
        for index in range.location..<min(NSMaxRange(range), cells.count) {
            let cell = cells[index]
            if let last = runs.last, last.row == cell.row {
                runs[runs.count - 1].width = max(last.width, cell.column + max(cell.width, 1) - last.column)
            } else {
                runs.append(Run(row: cell.row, column: cell.column, width: max(cell.width, 1)))
            }
        }
        return runs
    }
}

extension TerminalSurface {
    /// The text of viewport row `row`, `columns` cells wide. libghostty-spm reads a grid's text
    /// only for its in-memory backend (`InMemoryTerminalSession.readViewportText`); for exec
    /// surfaces the Ghostty handle is private, so it's taken by reflection and read through
    /// Ghostty's public C API the same way. Nil if a package update renames the handle.
    func viewportRow(_ row: Int, columns: Int) -> String? {
        guard row >= 0, columns > 0,
              let handle = Mirror(reflecting: self).children.first(where: { $0.label == "surface" })?.value as? ghostty_surface_t else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self)
    }
}

/// Underlines the hovered reference over the terminal; transparent to the mouse.
@MainActor
final class TerminalLinkUnderline: NSView {
    var rects: [NSRect] = [] { didSet { if rects != oldValue { needsDisplay = true } } }
    var color: NSColor = .labelColor

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        rects.forEach { $0.fill() }
    }
}
