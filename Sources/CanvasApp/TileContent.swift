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
    /// What a Hyper-click at `point` (in this view's coordinates) would mention.
    func mentionTarget(at point: NSPoint) -> MentionTarget?
    /// Outline for a target in this view's coordinates, for the hover highlight.
    func outline(for target: MentionTarget) -> NSRect?
    /// Whether clicking into the tile should take keyboard focus.
    var takesKeyboardFocus: Bool { get }
    /// Apply a new revision of the backing object.
    func update(_ object: CanvasObject)
}

extension TileContent {
    func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
