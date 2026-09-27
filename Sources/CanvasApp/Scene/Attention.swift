import AppKit
import CanvasCore

/// An agent's "look here" on one object: a pulsing ring around it and a message bubble above.
/// Lives in window space above the canvas (`AttentionLayer`) and is re-placed on every pan and
/// pinch step, so it keeps its on-screen size at any zoom and follows the zoom smoothly while
/// everything on the canvas scales. Only the bubble takes clicks (which dismiss it).
@MainActor
final class AttentionMarker: NSView {
    static let inset: CGFloat = 10
    static let bubbleHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let stroke: CGFloat = 4

    let objectID: ObjectID
    var message: String? {
        didSet {
            bubbleWidth = Self.bubbleWidth(message)
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?
    /// The ring and bubble in this view's coordinates, from `place(around:)`.
    private var ringRect = NSRect.zero
    private var bubbleRect = NSRect.zero
    private var bubbleWidth: CGFloat

    init(objectID: ObjectID, message: String?) {
        self.objectID = objectID
        self.message = message
        bubbleWidth = Self.bubbleWidth(message)
        super.init(frame: .zero)
        wantsLayer = true
        // The pulse runs in the render server; the drawn ring below is what snapshots capture.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private static let bubbleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
    private static func text(_ message: String?) -> NSString { (message?.isEmpty == false ? message! : "Look here") as NSString }
    private static func bubbleWidth(_ message: String?) -> CGFloat { text(message).size(withAttributes: bubbleAttributes).width + 24 }

    /// Places the marker around `target`, the object's rect in the superview's coordinates: the
    /// ring hugs it at a fixed on-screen inset and the bubble sits above its top-left corner, kept
    /// inside `clear` (the part of the view the toolbar and tray leave uncovered, same
    /// coordinates) so it stays readable when the object's top is under the chrome or offscreen.
    /// Panning only moves the view; a zoom step resizes the ring and redraws it.
    func place(around target: NSRect, clear: NSRect) {
        let ring = target.insetBy(dx: -Self.inset, dy: -Self.inset)
        var bubble = NSRect(x: ring.minX, y: ring.minY - Self.gap - Self.bubbleHeight, width: bubbleWidth, height: Self.bubbleHeight)
        bubble.origin.x = max(min(bubble.minX, clear.maxX - Self.inset - bubble.width), clear.minX + Self.inset)
        bubble.origin.y = max(min(bubble.minY, clear.maxY - bubble.height), clear.minY)
        let frame = ring.union(bubble).insetBy(dx: -Self.stroke / 2, dy: -Self.stroke / 2)
        let ringRect = ring.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if ringRect != self.ringRect || frame.size != self.frame.size { needsDisplay = true }
        self.ringRect = ringRect
        bubbleRect = bubble.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if self.frame != frame { self.frame = frame }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bubbleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.AttentionMarker", since: perfStart) }
        let path = NSBezierPath(roundedRect: ringRect, xRadius: 12, yRadius: 12)
        path.lineWidth = Self.stroke
        NSColor.systemOrange.setStroke()
        path.stroke()
        let pill = NSBezierPath(roundedRect: bubbleRect, xRadius: bubbleRect.height / 2, yRadius: bubbleRect.height / 2)
        NSColor.systemOrange.setFill()
        pill.fill()
        let text = Self.text(message)
        let size = text.size(withAttributes: Self.bubbleAttributes)
        text.draw(in: NSRect(x: bubbleRect.minX + 12, y: bubbleRect.midY - size.height / 2, width: bubbleRect.width - 24, height: size.height), withAttributes: Self.bubbleAttributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Window-space layer over the canvas holding the attention markers; only their bubbles take
/// clicks, everything else passes through to the canvas.
@MainActor
final class AttentionLayer: NSView {
    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for marker in subviews.reversed() where !marker.isHidden {
            if let hit = marker.hitTest(local) { return hit }
        }
        return nil
    }
}

/// Window-space chevrons at the canvas edge for attention markers whose object is offscreen.
/// Clicking one scrolls to its object; nothing else here takes clicks.
@MainActor
final class AttentionEdgeView: NSView {
    struct Pointer {
        var id: ObjectID
        var message: String?
        /// Target center in this view's coordinates (outside the bounds).
        var target: NSPoint
    }

    var onReveal: ((ObjectID) -> Void)?
    private var chevrons: [EdgeChevron] = []

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return chevrons.first { $0.frame.contains(local) }
    }

    /// `clear`: the part of the view the toolbar and tray leave uncovered (this view's
    /// coordinates); pills sit at its edges, never under the chrome.
    func show(_ pointers: [Pointer], clear: NSRect) {
        while chevrons.count > pointers.count { chevrons.removeLast().removeFromSuperview() }
        while chevrons.count < pointers.count {
            let chevron = EdgeChevron()
            addSubview(chevron)
            chevrons.append(chevron)
        }
        let center = NSPoint(x: clear.midX, y: clear.midY)
        let margin: CGFloat = 16
        for (chevron, pointer) in zip(chevrons, pointers) {
            chevron.objectID = pointer.id
            chevron.message = pointer.message
            chevron.onClick = { [weak self] in self?.onReveal?(pointer.id) }
            let dx = pointer.target.x - center.x, dy = pointer.target.y - center.y
            chevron.angle = atan2(dy, dx)
            // Where the ray from the clear area's center to the target leaves it (inset).
            let halfW = clear.width / 2 - margin, halfH = clear.height / 2 - margin
            let t = min(dx == 0 ? .infinity : halfW / abs(dx), dy == 0 ? .infinity : halfH / abs(dy))
            let edge = NSPoint(x: center.x + dx * t, y: center.y + dy * t)
            let size = chevron.fittingSize
            let origin = NSPoint(x: min(max(edge.x - size.width / 2, clear.minX + margin), clear.maxX - margin - size.width),
                                 y: min(max(edge.y - size.height / 2, clear.minY), clear.maxY - size.height))
            chevron.frame = NSRect(origin: origin, size: size)
            chevron.needsDisplay = true
        }
    }
}

@MainActor
private final class EdgeChevron: NSView {
    var objectID: ObjectID = ""
    var message: String?
    /// Direction to the target in flipped view space (radians, 0 = right, +π/2 = down).
    var angle: CGFloat = 0
    var onClick: (() -> Void)?

    private static let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
    private var text: NSString { ((message?.isEmpty == false ? message! : "Attention") as NSString) }

    nonisolated override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let width = min(text.size(withAttributes: Self.attributes).width, 240)
        return NSSize(width: 44 + width + 12, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.EdgeChevron", since: perfStart) }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.systemOrange.setFill()
        pill.fill()
        // Chevron glyph rotated toward the target.
        let center = NSPoint(x: 18, y: bounds.midY)
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byRadians: angle)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: -4, y: -7))
        arrow.line(to: NSPoint(x: 5, y: 0))
        arrow.line(to: NSPoint(x: -4, y: 7))
        arrow.transform(using: transform)
        arrow.lineWidth = 3
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()
        let size = text.size(withAttributes: Self.attributes)
        text.draw(in: NSRect(x: 36, y: bounds.midY - size.height / 2, width: bounds.width - 48, height: size.height), withAttributes: Self.attributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
