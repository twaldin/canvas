import AppKit
import CanvasCore

/// The Swift tile protocol from docs/contracts.md. Implemented by each tile's content view;
/// TileFrameView supplies the shared chrome (title bar, drag, resize, lifecycle badge).
@MainActor
protocol TileContent: NSView {
    /// Live = visible at readable zoom. Not live = release heavy resources and show `snapshot()`.
    func setLive(_ live: Bool)
    /// Cheap image for zoomed-out cards; nil draws a title card.
    func snapshot() -> NSImage?
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

extension TileContent {
    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        mentionTarget(at: point)
    }

    func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
