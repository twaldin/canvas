import AppKit
import CanvasCore

/// A named group drawn as a labeled dashed region behind its members. Only the label takes the
/// mouse: drag moves the members, double-click enters the group; the rest of the region lets
/// clicks through to the canvas so marquee selection still starts inside it.
@MainActor
final class GroupView: NSView {
    static let padding: CGFloat = 20
    static let labelHeight: CGFloat = 24

    let objectID: ObjectID
    private(set) var name: String
    private(set) var members: [ObjectID]
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }

    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: ((NSEvent) -> Void)?
    var onEnter: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    init(object: CanvasObject) {
        objectID = object.id
        name = ""
        members = []
        super.init(frame: .zero)
        update(object)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ object: CanvasObject) {
        name = object.props["name"]?.string ?? ""
        members = object.props["members"]?.array?.compactMap(\.string) ?? []
        needsDisplay = true
    }

    /// The label grows as the canvas zooms out so it stays legible, up to a point.
    static func labelFactor(_ scale: CGFloat) -> CGFloat { min(1 / max(scale, 0.01), 4) }

    /// Region around the members' document rects, with room for the label above them.
    static func region(around rects: [NSRect], scale: CGFloat) -> NSRect? {
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let label = labelHeight * labelFactor(scale)
        return NSRect(x: union.minX - padding, y: union.minY - padding - label, width: union.width + 2 * padding, height: union.height + 2 * padding + label)
    }

    /// Label in view coordinates.
    var labelRect: NSRect {
        let factor = Self.labelFactor(scale)
        let width = min(bounds.width, (displayName as NSString).size(withAttributes: [.font: labelFont]).width + 20 * factor)
        return NSRect(x: 0, y: 0, width: width, height: Self.labelHeight * factor)
    }

    private var labelFont: NSFont { .systemFont(ofSize: 13 * Self.labelFactor(scale), weight: .semibold) }
    private var displayName: String { name.isEmpty ? "Group" : name }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return labelRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let factor = Self.labelFactor(scale)
        let top = Self.labelHeight * factor / 2
        let region = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top).insetBy(dx: factor, dy: factor)
        let path = NSBezierPath(roundedRect: region, xRadius: 14, yRadius: 14)
        let tint = isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        tint.withAlphaComponent(0.06).setFill()
        path.fill()
        path.lineWidth = (isSelected ? 2.5 : 1.5) * factor
        path.setLineDash([8 * factor, 5 * factor], count: 2, phase: 0)
        tint.withAlphaComponent(0.8).setStroke()
        path.stroke()

        let label = labelRect
        let pill = NSBezierPath(roundedRect: label, xRadius: label.height / 2, yRadius: label.height / 2)
        (isSelected ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        pill.fill()
        tint.setStroke()
        pill.lineWidth = factor
        pill.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: isSelected ? NSColor.white : NSColor.labelColor]
        let text = displayName as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: label.minX + 10 * factor, y: label.midY - size.height / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { return onEnter?() ?? () }
        onPress?(event)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onRelease?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func resetCursorRects() {
        addCursorRect(labelRect, cursor: .openHand)
    }
}
