import AppKit

/// Transparent layer above tiles and drawings: Hyper hover outline, selection rings, the
/// marquee or lasso being dragged, and the dimming around an entered group. Everything is drawn
/// in `draw(_:)` (not layer properties) so `view.snapshot`'s `cacheDisplay` captures it, in
/// document space so it scales with the canvas and never redraws for a zoom. It never takes clicks.
final class SceneOverlay: NSView {
    /// Hyper hover outline (document coordinates).
    var outline: NSRect? { didSet { invalidate(oldValue, outline) } }
    struct Ring: Equatable {
        var rect: NSRect
        /// Drawn objects (shapes, arrows) get a dashed ring; tiles a solid one.
        var dashed: Bool
    }

    /// Selected objects.
    var rings: [Ring] = [] {
        didSet {
            guard rings != oldValue else { return }
            invalidate(oldValue.reduce(NSRect.null) { $0.union($1.rect) }, rings.reduce(NSRect.null) { $0.union($1.rect) })
        }
    }
    /// Marquee box or lasso outline being dragged. Its `lineWidth` is one screen point at the
    /// zoom it is dragged at (set by the canvas; the zoom can't change mid-drag).
    var marquee: NSBezierPath? {
        didSet { invalidate(oldValue.map { $0.bounds.insetBy(dx: -$0.lineWidth, dy: -$0.lineWidth) }, marquee.map { $0.bounds.insetBy(dx: -$0.lineWidth, dy: -$0.lineWidth) }) }
    }
    /// Entered group: everything but these rects is dimmed. Nil when no group is entered.
    var focusHoles: [NSRect]? { didSet { needsDisplay = true } }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func invalidate(_ old: NSRect?, _ new: NSRect?) {
        for rect in [old, new].compactMap({ $0 }) where !rect.isNull {
            setNeedsDisplay(rect.insetBy(dx: -6, dy: -6))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let holes = focusHoles {
            let dim = NSBezierPath(rect: dirtyRect)
            for hole in holes { dim.append(NSBezierPath(roundedRect: hole.insetBy(dx: -12, dy: -12), xRadius: 10, yRadius: 10)) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
        }
        for ring in rings where ring.rect.insetBy(dx: -8, dy: -8).intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: ring.rect.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9)
            path.lineWidth = 2.5
            if ring.dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            marquee.fill()
            marquee.setLineDash([4 * marquee.lineWidth, 3 * marquee.lineWidth], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            marquee.stroke()
        }
        if let outline {
            let path = NSBezierPath(roundedRect: outline.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            NSColor.systemPurple.setStroke()
            NSColor.systemPurple.withAlphaComponent(0.08).setFill()
            path.fill()
            path.stroke()
        }
    }
}
