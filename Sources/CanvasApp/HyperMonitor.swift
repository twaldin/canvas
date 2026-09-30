import AppKit
import CanvasCore

/// App-wide Hyper (⌃⌥⇧⌘, Caps Lock via Karabiner) handling, installed ahead of every tile so
/// native ⌘-click keeps working inside terminals, browsers, and code:
///  - Hyper-click stages a mention of whatever is under the cursor (element-level where the tile
///    supports it); on a group's title or empty interior, the whole group
///  - Hyper-drag on empty canvas (or a group's empty interior) stages the enclosed tiles as one group mention
///  - holding Hyper outlines what would be mentioned
@MainActor
final class HyperMonitor {
    static let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var monitor: Any?
    private let canvasFor: (NSWindow?) -> CanvasView?
    /// A Hyper press away from tiles and drawings: a click on the group under it, or a marquee.
    private var press: (canvas: CanvasView, press: GroupMention.Press, focus: NSResponder?)?
    /// Where Hyper is being held, so an async hover answer from a tile can redraw the outline.
    private var hoverContext: (canvas: CanvasView, point: NSPoint)?

    init(canvasFor: @escaping (NSWindow?) -> CanvasView?) {
        self.canvasFor = canvasFor
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .mouseMoved]) { [weak self] event in
            // Not `self?.handle(event) ?? event`: a nil from handle (consumed) would flatten
            // into the fallback and the Hyper-click would reach the view beneath anyway.
            guard let self else { return event }
            return self.handle(event)
        }
        NotificationCenter.default.addObserver(forName: .tileMentionHoverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let context = self.hoverContext else { return }
                self.hover(context.canvas, at: context.point, active: true)
            }
        }
    }

    static func isHyper(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).isSuperset(of: hyper)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let canvas = canvasFor(event.window) else { return event }
        let hyper = Self.isHyper(event.modifierFlags)
        switch event.type {
        case .flagsChanged, .mouseMoved:
            updateHover(canvas, event: event, active: hyper)
            return event
        case .leftMouseDown where hyper:
            let focus = event.window?.firstResponder
            if let shape = canvas.shape(atWindowPoint: event.locationInWindow) {
                canvas.board.toggle(MentionContext.drawingTarget(shape, selection: canvas.selection, on: canvas.board))
                Self.keepFocus(focus, in: event.window)
            } else if let (tile, point) = canvas.tile(atWindowPoint: event.locationInWindow) {
                let content = tile.content
                let fallback = MentionTarget.object(tile.objectID)
                let window = event.window
                Task { @MainActor in
                    canvas.board.toggle(await content.resolveMention(at: point) ?? fallback)
                    Self.keepFocus(focus, in: window)
                }
            } else {
                let start = canvas.document.convert(event.locationInWindow, from: nil)
                press = (canvas, GroupMention.Press(start: start, window: event.locationInWindow, group: canvas.group(atWindowPoint: event.locationInWindow)?.objectID), focus)
            }
            return nil
        case .leftMouseDragged where press != nil:
            guard var current = press else { return nil }
            current.press.move(window: event.locationInWindow)
            press = current
            if current.press.dragging {
                let point = canvas.document.convert(event.locationInWindow, from: nil)
                canvas.overlay.outline = canvas.overlay.convert(Self.rect(current.press.start, point), from: canvas.document)
            }
            return nil
        case .leftMouseUp where press != nil:
            if var current = press {
                let point = canvas.document.convert(event.locationInWindow, from: nil)
                switch current.press.release(at: point, window: event.locationInWindow) {
                case .group(let id):
                    if let target = GroupMention.target(id, on: canvas.board) { canvas.board.toggle(target) }
                case .marquee(let rect):
                    let ids = canvas.objects(inDocRect: rect)
                    if ids.count == 1 { _ = try? canvas.board.stage(.object(ids[0])) }
                    if ids.count > 1 { _ = try? canvas.board.stage(.group(objects: ids, name: nil)) }
                case .nothing:
                    break
                }
                Self.keepFocus(current.focus, in: event.window)
            }
            press = nil
            canvas.overlay.outline = nil
            return nil
        default:
            return event
        }
    }

    private func updateHover(_ canvas: CanvasView, event: NSEvent, active: Bool) {
        guard let window = event.window else { return }
        let point = event.type == .mouseMoved ? event.locationInWindow : DevInput.pointer ?? window.mouseLocationOutsideOfEventStream
        hover(canvas, at: point, active: active)
    }

    private func hover(_ canvas: CanvasView, at point: NSPoint, active: Bool) {
        guard active, press == nil else {
            hoverContext = nil
            if press == nil { canvas.showOutline(nil, in: nil) }
            return
        }
        hoverContext = (canvas, point)
        if let shape = canvas.shape(atWindowPoint: point) {
            // Everything the click would mention: the selection or drawing group it belongs to.
            let ids = MentionContext.drawingTarget(shape, selection: canvas.selection, on: canvas.board).objectIDs
            let rects = ids.compactMap { canvas.shapeOutline?($0) ?? canvas.docFrame($0) }
            return canvas.showOutline(docRect: rects.dropFirst().reduce(rects.first) { $0?.union($1) })
        }
        guard let (tile, local) = canvas.tile(atWindowPoint: point) else {
            // A group's title or empty interior: the click mentions the whole group.
            return canvas.showOutline(docRect: canvas.group(atWindowPoint: point)?.region)
        }
        let target = tile.content.mentionTarget(at: local) ?? .object(tile.objectID)
        canvas.showOutline(tile.content.outline(for: target) ?? tile.content.bounds, in: tile)
    }

    /// Staging a mention never moves keyboard focus: whatever had it when the Hyper-click began
    /// (a terminal, the canvas, a page) still has it, so a key meant for the canvas (Esc) never
    /// reaches an agent the user didn't click into.
    private static func keepFocus(_ responder: NSResponder?, in window: NSWindow?) {
        guard let window, let responder, window.firstResponder !== responder else { return }
        if let view = responder as? NSView, view.window !== window { return }
        window.makeFirstResponder(responder)
    }

    static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
