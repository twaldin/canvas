import AppKit
import CanvasCore

/// An agent's "look here" on one object: a pulsing ring around it and a message bubble above.
/// Lives in document space above the tiles; only the bubble takes clicks (which dismiss it).
@MainActor
final class AttentionMarker: NSView {
    static let inset: CGFloat = 10
    static let bubbleHeight: CGFloat = 28

    let objectID: ObjectID
    var message: String? { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?

    init(objectID: ObjectID, message: String?) {
        self.objectID = objectID
        self.message = message
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

    private var factor: CGFloat { min(1 / max(scale, 0.01), 4) }

    /// Frame around a target's document rect, leaving room above for the bubble.
    func place(around target: NSRect) {
        let top = Self.bubbleHeight * factor + 6 * factor
        frame = NSRect(x: target.minX - Self.inset * factor, y: target.minY - Self.inset * factor - top,
                       width: target.width + 2 * Self.inset * factor, height: target.height + 2 * Self.inset * factor + top)
    }

    private var bubbleRect: NSRect {
        let size = bubbleText.size(withAttributes: bubbleAttributes)
        return NSRect(x: 0, y: 0, width: min(bounds.width, size.width + 24 * factor), height: Self.bubbleHeight * factor)
    }

    private var bubbleText: NSString { (message?.isEmpty == false ? message! : "Look here") as NSString }
    private var bubbleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13 * factor, weight: .semibold), .foregroundColor: NSColor.white]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bubbleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let bubble = bubbleRect
        let ringTop = bubble.maxY + 6 * factor
        let ring = NSRect(x: 0, y: ringTop, width: bounds.width, height: bounds.height - ringTop).insetBy(dx: 2 * factor, dy: 2 * factor)
        let path = NSBezierPath(roundedRect: ring, xRadius: 12, yRadius: 12)
        path.lineWidth = 4 * factor
        NSColor.systemOrange.setStroke()
        path.stroke()
        let pill = NSBezierPath(roundedRect: bubble, xRadius: bubble.height / 2, yRadius: bubble.height / 2)
        NSColor.systemOrange.setFill()
        pill.fill()
        let size = bubbleText.size(withAttributes: bubbleAttributes)
        bubbleText.draw(in: NSRect(x: bubble.minX + 12 * factor, y: bubble.midY - size.height / 2, width: bubble.width - 24 * factor, height: size.height), withAttributes: bubbleAttributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
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

    func show(_ pointers: [Pointer]) {
        while chevrons.count > pointers.count { chevrons.removeLast().removeFromSuperview() }
        while chevrons.count < pointers.count {
            let chevron = EdgeChevron()
            addSubview(chevron)
            chevrons.append(chevron)
        }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let margin: CGFloat = 16
        for (chevron, pointer) in zip(chevrons, pointers) {
            chevron.objectID = pointer.id
            chevron.message = pointer.message
            chevron.onClick = { [weak self] in self?.onReveal?(pointer.id) }
            let dx = pointer.target.x - center.x, dy = pointer.target.y - center.y
            chevron.angle = atan2(dy, dx)
            // Where the ray from the viewport center to the target leaves the (inset) bounds.
            let halfW = bounds.width / 2 - margin, halfH = bounds.height / 2 - margin
            let t = min(dx == 0 ? .infinity : halfW / abs(dx), dy == 0 ? .infinity : halfH / abs(dy))
            let edge = NSPoint(x: center.x + dx * t, y: center.y + dy * t)
            let size = chevron.fittingSize
            let origin = NSPoint(x: min(max(edge.x - size.width / 2, margin), bounds.width - margin - size.width),
                                 y: min(max(edge.y - size.height / 2, margin), bounds.height - margin - size.height))
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
