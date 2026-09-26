import AppKit
import CanvasCore

/// The Swift tile protocol from docs/contracts.md. Implemented by each tile's content view;
/// TileFrameView supplies the shared chrome (title bar, drag, resize, lifecycle badge).
@MainActor
protocol TileContent: NSView {
    /// Live = visible at readable zoom. Not live = release heavy resources and show the card.
    func setLive(_ live: Bool)
    /// Full-resolution image of the content (`object.get --as image`); nil draws a title card.
    func snapshot() -> NSImage?
    /// Image for the zoomed-out card, delivered on the main actor before the tile goes not-live
    /// (defaults to `snapshot()`, synchronously). Tiles whose snapshot blocks on a subprocess
    /// deliver later, from off-main work.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void)
    /// While `view.snapshot` renders the window with `cacheDisplay`, cover content that renders
    /// outside AppKit's drawing (Metal, WebKit) with an image of it; `false` restores the live view.
    func showSnapshot(_ show: Bool)
    /// What a Hyper-click at `point` (in this view's coordinates) would mention. Called on every
    /// hover move, so it must be cheap; tiles whose content answers asynchronously (web views)
    /// return their latest cached answer and post `.tileMentionHoverChanged` when it changes.
    func mentionTarget(at point: NSPoint) -> MentionTarget?
    /// The mention for an actual Hyper-click, which may take a round trip (e.g. JavaScript).
    func resolveMention(at point: NSPoint) async -> MentionTarget?
    /// Outline for a target in this view's coordinates, for the hover highlight.
    func outline(for target: MentionTarget) -> NSRect?
    /// Whether clicking into the tile should take keyboard focus.
    var takesKeyboardFocus: Bool { get }
    /// Apply a new revision of the backing object.
    func update(_ object: CanvasObject)
}

extension Notification.Name {
    /// Posted (object: the tile content view) when an async hover answer arrives.
    static let tileMentionHoverChanged = Notification.Name("canvas.tileMentionHoverChanged")
}

/// An offscreen render of a tile's body (AgentSurface's `view.render` contract): independent of
/// liveness, window, Space, and viewport.
struct TileRenderRequest {
    /// Body in points: the object's frame without the 26 pt title bar.
    var size: CGSize
    /// Pixels per point of the bitmap.
    var scale: CGFloat
    /// The whole content (all rows, full width) instead of the frame's window.
    var full: Bool
    /// Resolve dynamic colors in this appearance.
    var appearance: NSAppearance
}

struct TileRender {
    enum State: String { case rendered, placeholder, failed }
    /// Size in points, top-left at the body's top-left: `request.size`, or at least the content
    /// size when `full`.
    var image: NSImage?
    /// Intrinsic content extent in points at the request's width (overflow = content − size).
    var contentSize: CGSize
    /// Never `.rendered` with a blank image.
    var state: State
    var reason: String?
}

extension TileContent {
    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        mentionTarget(at: point)
    }

    func showSnapshot(_ show: Bool) {}

    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        deliver(snapshot())
    }

    func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
