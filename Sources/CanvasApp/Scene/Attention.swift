import AppKit
import CanvasCore

/// An agent's "look here" on one object: a pulsing ring around it and a message bubble beside it.
/// Lives in window space above the canvas (`AttentionLayer`) and is re-placed on every pan and
/// pinch step, so it keeps its on-screen size at any zoom and follows the zoom smoothly while
/// everything on the canvas scales. Only the bubble takes clicks (which acknowledge it).
@MainActor
final class AttentionMarker: NSView {
    static let inset: CGFloat = 10
    static let bubbleHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let stroke: CGFloat = 4

    let objectID: ObjectID
    var message: String? {
        didSet {
            naturalWidth = Self.naturalWidth(message)
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?
    /// The ring and bubble in this view's coordinates, from `place(around:bubble:)`.
    private var ringRect = NSRect.zero
    private var bubbleRect = NSRect.zero
    /// The bubble's width with its whole message; `PillLayout.bubbleWidth` caps it.
    private(set) var naturalWidth: CGFloat

    init(objectID: ObjectID, message: String?) {
        self.objectID = objectID
        self.message = message
        naturalWidth = Self.naturalWidth(message)
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

    private static let bubbleAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }()
    private static func text(_ message: String?) -> NSString { (message?.isEmpty == false ? message! : "Look here") as NSString }
    private static func naturalWidth(_ message: String?) -> CGFloat { (text(message).size(withAttributes: bubbleAttributes).width + 24).rounded(.up) }

    /// Places the marker: the ring hugs `target` (the object's rect in the superview's
    /// coordinates) at a fixed on-screen inset, and the bubble goes where `PillLayout` put it
    /// (`bubble`, same coordinates). Panning only moves the view; a zoom step resizes the ring
    /// and redraws it.
    func place(around target: NSRect, bubble: NSRect) {
        let ring = target.insetBy(dx: -Self.inset, dy: -Self.inset)
        let frame = ring.union(bubble).insetBy(dx: -Self.stroke / 2, dy: -Self.stroke / 2)
        let ringRect = ring.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let bubbleRect = bubble.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if ringRect != self.ringRect || bubbleRect != self.bubbleRect || frame.size != self.frame.size { needsDisplay = true }
        if bubbleRect != self.bubbleRect {
            // A truncated message reads whole in the bubble's tooltip.
            removeAllToolTips()
            if bubble.width < naturalWidth { addToolTip(bubbleRect, owner: Self.text(message), userData: nil) }
        }
        self.ringRect = ringRect
        self.bubbleRect = bubbleRect
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

/// Window-space pills at the rim of the clear area for offscreen objects that need the user
/// (attention markers, blocked agents), each pointing at its object. Clicking one scrolls to its
/// object; nothing else here takes clicks.
@MainActor
final class AttentionEdgeView: NSView {
    struct Pointer {
        var id: ObjectID
        var message: String?
        /// Target center in this view's coordinates (outside the bounds).
        var target: NSPoint
        /// Where `PillLayout` put the pill, same coordinates.
        var frame: NSRect = .zero
    }

    var onReveal: ((ObjectID) -> Void)?
    private var chevrons: [EdgeChevron] = []

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return chevrons.first { $0.frame.contains(local) }
    }

    /// A pill's size for a message.
    static func size(for message: String?) -> NSSize { EdgeChevron.size(for: message) }

    func show(_ pointers: [Pointer]) {
        while chevrons.count > pointers.count { chevrons.removeLast().removeFromSuperview() }
        while chevrons.count < pointers.count {
            let chevron = EdgeChevron()
            addSubview(chevron)
            chevrons.append(chevron)
        }
        for (chevron, pointer) in zip(chevrons, pointers) {
            chevron.objectID = pointer.id
            chevron.message = pointer.message
            let tip = EdgeChevron.text(pointer.message) as String
            if chevron.toolTip != tip { chevron.toolTip = tip }
            chevron.onClick = { [weak self] in self?.onReveal?(pointer.id) }
            chevron.angle = atan2(pointer.target.y - pointer.frame.midY, pointer.target.x - pointer.frame.midX)
            chevron.frame = pointer.frame
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

    private static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }()
    static func text(_ message: String?) -> NSString { (message?.isEmpty == false ? message! : "Attention") as NSString }
    private var text: NSString { Self.text(message) }

    nonisolated override var isFlipped: Bool { true }

    static func size(for message: String?) -> NSSize {
        let width = min(text(message).size(withAttributes: attributes).width, 240)
        return NSSize(width: (44 + width + 12).rounded(.up), height: 32)
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
