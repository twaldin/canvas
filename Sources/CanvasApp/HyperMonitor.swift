import AppKit
import CanvasCore

/// App-wide Hyper (⌃⌥⇧⌘, Caps Lock via Karabiner) handling, installed ahead of every tile so
/// native ⌘-click keeps working inside terminals, browsers, and code:
///  - Hyper-click stages a mention of whatever is under the cursor (element-level where the tile supports it)
///  - Hyper-drag on empty canvas stages the enclosed tiles as one group mention
///  - holding Hyper outlines what would be mentioned
@MainActor
final class HyperMonitor {
    static let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var monitor: Any?
    private let canvasFor: (NSWindow?) -> CanvasView?
    private var marquee: (canvas: CanvasView, start: NSPoint, focus: NSResponder?)?
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
                Self.toggle(MentionContext.drawingTarget(shape, selection: canvas.selection, on: canvas.board), on: canvas.board)
                Self.keepFocus(focus, in: event.window)
            } else if let (tile, point) = canvas.tile(atWindowPoint: event.locationInWindow) {
                let content = tile.content
                let fallback = MentionTarget.object(tile.objectID)
                let window = event.window
                Task { @MainActor in
                    Self.toggle(await content.resolveMention(at: point) ?? fallback, on: canvas.board)
                    Self.keepFocus(focus, in: window)
                }
            } else {
                marquee = (canvas, canvas.document.convert(event.locationInWindow, from: nil), focus)
            }
            return nil
        case .leftMouseDragged where marquee != nil:
            guard let marquee else { return nil }
            let current = canvas.document.convert(event.locationInWindow, from: nil)
            canvas.overlay.outline = canvas.overlay.convert(Self.rect(marquee.start, current), from: canvas.document)
            return nil
        case .leftMouseUp where marquee != nil:
            if let marquee {
                let current = canvas.document.convert(event.locationInWindow, from: nil)
                let ids = canvas.objects(inDocRect: Self.rect(marquee.start, current))
                if ids.count == 1 { _ = try? canvas.board.stage(.object(ids[0])) }
                if ids.count > 1 { _ = try? canvas.board.stage(.group(objects: ids, name: nil)) }
                Self.keepFocus(marquee.focus, in: event.window)
            }
            marquee = nil
            canvas.overlay.outline = nil
            return nil
        default:
            return event
        }
    }

    /// Hyper-click stages a target, or unstages it when it is already in the tray.
    static func toggle(_ target: MentionTarget, on board: Board) {
        if let staged = board.tray.first(where: { $0.target == target }) {
            try? board.unstage(staged.id)
        } else {
            _ = try? board.stage(target)
        }
    }

    private func updateHover(_ canvas: CanvasView, event: NSEvent, active: Bool) {
        guard let window = event.window else { return }
        let point = event.type == .mouseMoved ? event.locationInWindow : DevInput.pointer ?? window.mouseLocationOutsideOfEventStream
        hover(canvas, at: point, active: active)
    }

    private func hover(_ canvas: CanvasView, at point: NSPoint, active: Bool) {
        guard active, marquee == nil else {
            hoverContext = nil
            if marquee == nil { canvas.showOutline(nil, in: nil) }
            return
        }
        hoverContext = (canvas, point)
        if let shape = canvas.shape(atWindowPoint: point) {
            // Everything the click would mention: the selection or drawing group it belongs to.
            let ids = MentionContext.drawingTarget(shape, selection: canvas.selection, on: canvas.board).objectIDs
            let rects = ids.compactMap { canvas.shapeOutline?($0) ?? canvas.docFrame($0) }
            return canvas.showOutline(docRect: rects.dropFirst().reduce(rects.first) { $0?.union($1) })
        }
        guard let (tile, local) = canvas.tile(atWindowPoint: point) else { return canvas.showOutline(nil, in: nil) }
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
