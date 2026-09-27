import AppKit
import CanvasCore

/// A group drawn as a titled region behind its members: exactly the group's frame (members'
/// bounds, padding, title band), tinted with its color. Only the title takes the mouse: drag
/// moves the members, double-click enters the group; the rest of the region lets clicks through
/// to the canvas so marquee selection still starts inside it. Title and border are in document
/// space: they scale with the canvas like everything on it and never redraw for a zoom.
@MainActor
final class GroupView: NSView {
    let objectID: ObjectID
    private(set) var spec: GroupSpec
    var members: [ObjectID] { spec.members }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// The group's region in document coordinates.
    private(set) var region: NSRect = .zero

    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: ((NSEvent) -> Void)?
    var onEnter: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    init?(object: CanvasObject) {
        guard let spec = GroupSpec(object.props) else { return nil }
        objectID = object.id
        self.spec = spec
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ object: CanvasObject) {
        guard let spec = GroupSpec(object.props), spec != self.spec else { return }
        self.spec = spec
        needsDisplay = true
    }

    /// Places the view for a region (document coordinates).
    func show(region: NSRect) {
        self.region = region
        if frame != region {
            frame = region
            needsDisplay = true
        }
    }

    private var tint: NSColor { spec.color.map { DrawingStyle.color($0) } ?? .secondaryLabelColor }
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private var displayTitle: String { spec.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Group" }

    /// The title's hit and draw area in view coordinates. Hit testing asks on every scroll event
    /// and cursor rects on every pan frame, so the text width is measured once per title.
    var titleRect: NSRect {
        if titleWidth?.title != displayTitle {
            titleWidth = (displayTitle, (displayTitle as NSString).size(withAttributes: [.font: Self.titleFont]).width)
        }
        let width = min(bounds.width, (titleWidth?.width ?? 0) + 28)
        return NSRect(x: 0, y: 0, width: width, height: CGFloat(GroupSpec.titleHeight))
    }

    private var titleWidth: (title: String, width: CGFloat)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return titleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.GroupView", since: perfStart) }
        let box = bounds.insetBy(dx: 1, dy: 1)
        let tint = isSelected ? NSColor.controlAccentColor : self.tint
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        tint.withAlphaComponent(spec.color == nil ? 0.05 : 0.08).setFill()
        path.fill()
        path.lineWidth = isSelected ? 2.5 : 1.5
        tint.withAlphaComponent(0.7).setStroke()
        path.stroke()

        let title = titleRect
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: isSelected ? NSColor.controlAccentColor : (spec.color == nil ? NSColor.labelColor : tint)]
        let text = displayTitle as NSString
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: title.minX + 14, y: title.midY - size.height / 2 + 2)
        text.draw(with: NSRect(origin: origin, size: NSSize(width: max(0, title.width - 20), height: size.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { return onEnter?() ?? () }
        onPress?(event)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onRelease?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func resetCursorRects() {
        addCursorRect(titleRect, cursor: .openHand)
    }
}
