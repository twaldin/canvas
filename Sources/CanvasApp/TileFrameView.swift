import AppKit
import CanvasCore

/// Shared chrome around every tile: title bar (drag moves the selection), lifecycle badge, close
/// button, resize grip, and the zoomed-out card (tinted by agent lifecycle). Selection rings are
/// drawn by the canvas overlay.
@MainActor
final class TileFrameView: NSView {
    static let titleHeight = CGFloat(RenderMath.tileTitleHeight)

    let objectID: ObjectID
    let content: any TileContent
    private let titleBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let closeButton = NSButton()
    private let card = NSImageView()
    private var cardTitle = NSTextField(labelWithString: "")
    private let cardTint = CardTint()
    private(set) var isLive = true
    /// Stacking order among tiles (the object's `z`).
    private(set) var z: Double = 0
    private var lifecycleState: String?

    /// Called with the new canvas-space frame when a resize ends.
    var onFrameCommit: ((NSRect) -> Void)?
    /// Live resize, so the canvas can keep rings and groups around the tile.
    var onResizing: (() -> Void)?
    var onClose: (() -> Void)?
    /// Title-bar drags move the whole selection; the canvas runs the gesture.
    var onMoveBegan: ((NSEvent) -> Void)?
    var onMoveDragged: ((NSEvent) -> Void)?
    var onMoveEnded: ((NSEvent) -> Void)?
    var onTitleDoubleClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private var resizeStart: (mouse: NSPoint, frame: NSRect)?
    private var moving = false

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
        cardTint.isHidden = true
        addSubview(cardTint)
        update(object)
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        cardTint.frame = bounds
    }

    func update(_ object: CanvasObject) {
        titleLabel.stringValue = titleLabel.stringValue.isEmpty || object.type != .terminal ? Self.title(for: object) : titleLabel.stringValue
        z = object.z
        lifecycleState = object.type == .terminal ? object.props["lifecycle"]?["state"]?.string : nil
        badge.layer?.backgroundColor = Self.badgeColor(lifecycleState).cgColor
        badge.isHidden = object.type != .terminal
        cardTitle.stringValue = titleLabel.stringValue
        updateTint()
        content.update(object)
    }

    /// The title as shown (terminals report theirs).
    var title: String { titleLabel.stringValue }

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

    /// Cards show below `CanvasView.liveThreshold` zoom, so ~0.6 pixels per point is all they need
    /// (a full 2× capture would be ~11× the memory, held for every card on the board).
    static let cardPixelsPerPoint: CGFloat = 0.6

    /// Zoomed-out or offscreen: freeze to a card and let the content release its resources. The
    /// live content stays up until its card has arrived, so a swap never shows a blank or
    /// title-only tile.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        cardRequest += 1
        if live {
            card.image = nil
            card.isHidden = true
            cardTitle.isHidden = true
            showContent(true)
        } else {
            requestCard()
        }
        updateTint()
    }

    /// A new tile where it wouldn't be live (zoomed out or offscreen) starts as its card, the
    /// title until the card is drawn: its content never shows, so it never loads or lays out
    /// its live view (a batch of dozens of tiles would otherwise build every one live and only
    /// then swap it for its card). Called before the tile joins the canvas; the card is
    /// requested once it is in the window (web content renders in it).
    func startAsCard() {
        guard isLive else { return }
        isLive = false
        cardRequest += 1
        cardTitle.isHidden = false
        showContent(false)
        startCardDue = true
        updateTint()
    }

    private var startCardDue = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, startCardDue else { return }
        startCardDue = false
        if !isLive { requestCard() }
    }

    private func requestCard() {
        let request = cardRequest
        content.cardSnapshot { [weak self] image in
            guard let self, !self.isLive, self.cardRequest == request else { return }
            self.card.image = image.map { self.cardImage($0) }
            self.card.isHidden = self.card.image == nil
            self.cardTitle.isHidden = self.card.image != nil
            self.showContent(false)
        }
        // A card that never comes (a page that won't load) mustn't keep the content's
        // resources: after a second the tile goes to its title card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isLive, self.cardRequest == request, self.contentLive else { return }
            self.cardTitle.isHidden = false
            self.showContent(false)
        }
    }

    /// Below the readable zoom: the tile is one handle (click selects, drag moves) and shows its
    /// agent's lifecycle wash, whether it shows a card or lives zoomed out.
    var zoomedOut = false {
        didSet { if zoomedOut != oldValue { updateTint() } }
    }

    private var cardRequest = 0
    private var contentLive = true

    private func showContent(_ live: Bool) {
        guard live != contentLive else { return }
        contentLive = live
        content.isHidden = !live
        content.setLive(live)
    }

    /// The card at the body's size and card resolution (content renders at that resolution
    /// already; web snapshots arrive larger and are scaled down so every card costs the same).
    private func cardImage(_ image: NSImage) -> NSImage {
        let size = card.frame.size
        let width = max(1, Int(size.width * Self.cardPixelsPerPoint)), height = max(1, Int(size.height * Self.cardPixelsPerPoint))
        if let rep = image.representations.first, rep.pixelsWide <= width + 1, rep.pixelsHigh <= height + 1 { return image }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let card = NSImage(size: size)
        card.addRepresentation(rep)
        return card
    }

    /// Zoomed-out cards carry the agent's lifecycle color so a board of agents reads at a glance.
    private func updateTint() {
        let color = Self.badgeColor(lifecycleState)
        cardTint.color = color
        cardTint.isHidden = (isLive && !zoomedOut) || color == .clear
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: Move / resize

    private var resizeGrip: NSRect { NSRect(x: bounds.width - 16, y: bounds.height - 16, width: 16, height: 16) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeGrip.contains(local) { return self }
        // A zoomed-out card is one handle: click selects, drag moves, double-click focuses.
        if !isLive || zoomedOut, bounds.contains(local) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if resizeGrip.contains(convert(event.locationInWindow, from: nil)) {
            resizeStart = (event.locationInWindow, frame)
        } else if event.clickCount == 2 {
            onTitleDoubleClick?()
        } else {
            moving = true
            onMoveBegan?(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if moving { return onMoveDragged?(event) ?? () }
        guard let start = resizeStart, let superview else { return }
        let scale = superview.convert(NSSize(width: 1, height: 1), from: nil).width
        let dx = (event.locationInWindow.x - start.mouse.x) * scale
        let dy = (event.locationInWindow.y - start.mouse.y) * scale
        setFrameSize(NSSize(width: max(160, start.frame.width + dx), height: max(80 + Self.titleHeight, start.frame.height - dy)))
        onResizing?()
    }

    override func mouseUp(with event: NSEvent) {
        if moving {
            moving = false
            onMoveEnded?(event)
        } else if let start = resizeStart, start.frame != frame {
            onFrameCommit?(frame)
        }
        resizeStart = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func resetCursorRects() {
        addCursorRect(resizeGrip, cursor: .crosshair)
        addCursorRect(titleBar.frame, cursor: .openHand)
    }
}

/// Lifecycle wash over a zoomed-out card, drawn (not a layer color) so snapshots include it.
private final class CardTint: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 8, dy: 8))
        border.lineWidth = 16
        color.setStroke()
        border.stroke()
    }
}
