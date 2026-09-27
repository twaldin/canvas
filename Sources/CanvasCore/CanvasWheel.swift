import CoreGraphics

/// What a scroll event does on the canvas itself (empty canvas, or a tile that passes the scroll
/// on). A trackpad's precise scroll is AppKit's own pan (its momentum and rubber band); a mouse
/// wheel's line-based notch pans `lineHeight` screen points per line, as code and changes tiles
/// scroll a row per line, instead of NSScrollView's few points; with ⇧ a vertical wheel pans
/// sideways. ⌘-scroll zooms around the pointer, from a wheel or a trackpad (the Figma and Miro
/// convention; pinch still zooms). Linux study F4: a notch panned 1 pt and nothing zoomed.
public enum CanvasWheel {
    /// Screen points one wheel line pans.
    public static let lineHeight: CGFloat = 48
    /// Screen points of ⌘-scroll that double (or halve) the zoom: about 3 notches.
    public static let pointsPerDoubling: CGFloat = 144

    public enum Action: Equatable, Sendable {
        /// Leave it to the scroll view (a trackpad's precise pan).
        case system
        /// Pan the view by this much in screen points, as the content moves (positive y: down).
        case pan(dx: CGFloat, dy: CGFloat)
        /// Multiply the zoom by this, around the pointer.
        case zoom(CGFloat)
    }

    /// The action for a scroll of (`dx`, `dy`) (NSEvent's `scrollingDelta`), `precise` when it is
    /// in points (a trackpad or Magic Mouse) rather than lines, `command` and `shift` held.
    public static func action(dx: CGFloat, dy: CGFloat, precise: Bool, command: Bool, shift: Bool) -> Action {
        let scale = precise ? 1 : lineHeight
        // Scrolling up (content moving down) zooms in; a mostly sideways ⌘-scroll pans.
        if command, abs(dy) >= abs(dx), dy != 0 {
            return .zoom(pow(2, dy * scale / pointsPerDoubling))
        }
        guard !precise else { return .system }
        // AppKit turns a ⇧-wheel into a sideways scroll on most mice; one that still arrives
        // vertical goes sideways here.
        if shift, dx == 0 { return .pan(dx: dy * scale, dy: 0) }
        return .pan(dx: dx * scale, dy: dy * scale)
    }
}
