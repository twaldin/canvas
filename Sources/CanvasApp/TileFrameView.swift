import AppKit
import CanvasCore

/// Shared chrome around every tile: title bar (drag to move), lifecycle badge, close button,
/// resize grip, selection ring, and the zoomed-out card.
@MainActor
final class TileFrameView: NSView {
    static let titleHeight: CGFloat = 26

    let objectID: ObjectID
    let content: any TileContent
    private let titleBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let closeButton = NSButton()
    private let card = NSImageView()
    private var cardTitle = NSTextField(labelWithString: "")
    private(set) var isLive = true
    var isSelected = false { didSet { needsDisplay = true; updateRing() } }

    /// Called with the new canvas-space frame when a drag or resize ends.
    var onFrameCommit: ((NSRect) -> Void)?
    var onClose: (() -> Void)?
    var onSelect: ((_ extend: Bool) -> Void)?

    private var dragStart: (mouse: NSPoint, frame: NSRect, resizing: Bool)?

    init(object: CanvasObject, content: any TileContent, frame: NSRect) {
        objectID = object.id
        self.content = content
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        titleBar.addSubview(badge)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(closeButton)
        addSubview(titleBar)
        addSubview(content)
        card.imageScaling = .scaleProportionallyUpOrDown
        card.isHidden = true
        cardTitle.font = .systemFont(ofSize: 28, weight: .semibold)
        cardTitle.alignment = .center
        cardTitle.isHidden = true
        addSubview(card)
        addSubview(cardTitle)
        update(object)
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutParts()
    }

    private func layoutParts() {
        let width = bounds.width
        titleBar.frame = NSRect(x: 0, y: 0, width: width, height: Self.titleHeight)
        badge.frame = NSRect(x: 10, y: (Self.titleHeight - 10) / 2, width: 10, height: 10)
        closeButton.frame = NSRect(x: width - 28, y: 3, width: 22, height: 20)
        titleLabel.frame = NSRect(x: 26, y: 5, width: max(0, width - 60), height: 16)
        let body = NSRect(x: 0, y: Self.titleHeight, width: width, height: max(0, bounds.height - Self.titleHeight))
        content.frame = body
        card.frame = body
        cardTitle.frame = body.insetBy(dx: 12, dy: body.height / 3)
    }

    func update(_ object: CanvasObject) {
        titleLabel.stringValue = titleLabel.stringValue.isEmpty || object.type != .terminal ? Self.title(for: object) : titleLabel.stringValue
        let state = object.props["lifecycle"]?["state"]?.string
        badge.layer?.backgroundColor = Self.badgeColor(state).cgColor
        badge.isHidden = object.type != .terminal
        cardTitle.stringValue = titleLabel.stringValue
        content.update(object)
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
        cardTitle.stringValue = title
    }

    static func title(for object: CanvasObject) -> String {
        let props = object.props
        switch object.type {
        case .terminal: return props["title"]?.string ?? props["agent"]?["kind"]?.string ?? "Terminal"
        case .code:
            let path = props["path"]?.string ?? "code"
            return props["followOf"] != nil ? "↳ \(path)" : path
        case .note: return "Note"
        case .browser: return props["title"]?.string ?? props["url"]?.string ?? "Browser"
        case .html: return props["title"]?.string ?? "HTML"
        default: return object.type.rawValue.capitalized
        }
    }

    static func badgeColor(_ state: String?) -> NSColor {
        switch state {
        case "working": .systemBlue
        case "blocked": .systemOrange
        case "done": .systemGreen
        case "idle": .systemGray
        default: .clear
        }
    }

    /// Zoomed-out or offscreen: freeze to a card and let the content release its resources.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        if !live {
            card.image = content.snapshot()
            card.isHidden = card.image == nil
            cardTitle.isHidden = card.image != nil
        } else {
            card.isHidden = true
            cardTitle.isHidden = true
        }
        content.isHidden = !live
        content.setLive(live)
        isLive = live
    }

    private func updateRing() {
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: Move / resize

    private var resizeGrip: NSRect { NSRect(x: bounds.width - 16, y: bounds.height - 16, width: 16, height: 16) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeGrip.contains(local) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(event.modifierFlags.contains(.shift))
        let local = convert(event.locationInWindow, from: nil)
        dragStart = (event.locationInWindow, frame, resizeGrip.contains(local))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let superview else { return }
        let scale = superview.convert(NSSize(width: 1, height: 1), from: nil).width
        let dx = (event.locationInWindow.x - start.mouse.x) * scale
        let dy = (event.locationInWindow.y - start.mouse.y) * scale
        if start.resizing {
            setFrameSize(NSSize(width: max(160, start.frame.width + dx), height: max(80, start.frame.height - dy)))
        } else {
            setFrameOrigin(NSPoint(x: start.frame.minX + dx, y: start.frame.minY - dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = dragStart, start.frame != frame { onFrameCommit?(frame) }
        dragStart = nil
    }

    override func resetCursorRects() {
        addCursorRect(resizeGrip, cursor: .crosshair)
        addCursorRect(titleBar.frame, cursor: .openHand)
    }
}
