import AppKit

/// Resize handles on the selected tiles' bottom-right corners, in window space above the
/// attention markers, so a marked tile (or a tile in a marked group) still shows where to drag.
/// Screen-sized, drawn like a shape's handles. Takes no clicks: the tile's resize grip reaches
/// under the handle (`TileFrameView.resizeGrip`).
@MainActor
final class TileHandles: NSView {
    /// Side of a handle, in screen points.
    static let size: CGFloat = 12
    /// How far past the corner the handle (and the grip under it) reaches, in screen points.
    static let reach: CGFloat = size / 2 + 2

    /// Handle centers, in this view's coordinates.
    var corners: [NSPoint] = [] {
        didSet {
            guard corners != oldValue else { return }
            for corner in oldValue + corners { setNeedsDisplay(Self.rect(corner).insetBy(dx: -2, dy: -2)) }
        }
    }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func rect(_ corner: NSPoint) -> NSRect {
        NSRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        for corner in corners where Self.rect(corner).intersects(dirtyRect) {
            let path = NSBezierPath(rect: Self.rect(corner))
            path.lineWidth = 1.5
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}
