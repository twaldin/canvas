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
    /// The agent terminal that made the object (`AuthorMark`), small and muted at the right.
    private let authorLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let closeButton = TileCloseButton()
    private let card = NSImageView()
    private var cardTitle = NSTextField(labelWithString: "")
    private let cardTint = CardTint()
    private(set) var isLive = true
    /// Stacking order among tiles (the object's `z`).
    private(set) var z: Double = 0
    private var lifecycleState: String?

    /// Called with the new canvas-space frame and scale when a resize or ⌥-drag scale ends.
    var onFrameCommit: ((NSRect, CGFloat) -> Void)?
    /// Live resize, so the canvas can keep rings and groups around the tile.
    var onResizing: (() -> Void)?
    var onClose: (() -> Void)?
    /// Title-bar drags move the whole selection; the canvas runs the gesture.
    var onMoveBegan: ((NSEvent) -> Void)?
    var onMoveDragged: ((NSEvent) -> Void)?
    var onMoveEnded: ((NSEvent) -> Void)?
    var onTitleDoubleClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private var resizeStart: (mouse: NSPoint, frame: NSRect, scale: CGFloat, scaling: Bool)?
    /// The object's `props.scale`: title bar and content drawn this many times their natural
    /// size. The view's bounds are its natural size (frame ÷ scale), so everything inside lays
    /// out, hit-tests, and converts coordinates in the tile's own points.
    private(set) var scale: CGFloat = 1
    private var moving = false

    /// What the tile is, for accessibility ("terminal", "code", …).
    private let roleDescription: String

    init(object: CanvasObject, content: any TileContent, frame: NSRect) {
        objectID = object.id
        self.content = content
        scale = CGFloat(object.scale)
        roleDescription = object.type == .html ? "HTML" : object.type.rawValue
        super.init(frame: frame)
        closeButton.tile = self
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        titleLabel.font = Self.titleFont
        titleLabel.lineBreakMode = .byTruncatingMiddle
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        authorLabel.font = Self.authorFont
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.isHidden = true
        titleBar.addSubview(badge)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(authorLabel)
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
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Each tile is one accessibility group named by its title (VoiceOver, Full Keyboard Access).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { roleDescription }
    override func accessibilityLabel() -> String? { author.map { "\(title), created by \($0)" } ?? title }

    /// Layout happens in `applyScale`, once the bounds match the new frame.
    override func resizeSubviews(withOldSize oldSize: NSSize) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    /// Moves and scales the tile in one step, so its content never lays out at a size in between.
    func place(_ rect: NSRect, scale: CGFloat) {
        let rescaled = scale != self.scale
        self.scale = scale
        if frame != rect { frame = rect }
        if rescaled { applyScale() }
    }

    /// Bounds are the natural size, so the layer (radius and border included) and everything in
    /// it draw magnified by `scale`.
    private func applyScale() {
        let natural = NSSize(width: frame.width / scale, height: frame.height / scale)
        if bounds.size != natural { setBoundsSize(natural) }
        layoutParts()
    }

    private func layoutParts() {
        let width = bounds.width
        titleBar.frame = NSRect(x: 0, y: 0, width: width, height: Self.titleHeight)
        badge.frame = NSRect(x: 10, y: (Self.titleHeight - 10) / 2, width: 10, height: 10)
        closeButton.frame = NSRect(x: width - 28, y: 3, width: 22, height: 20)
        layoutTitle()
        let body = NSRect(x: 0, y: Self.titleHeight, width: width, height: max(0, bounds.height - Self.titleHeight))
        if content.frame != body { content.frame = body }
        card.frame = body
        cardTitle.frame = body.insetBy(dx: 12, dy: body.height / 3)
        cardTint.frame = bounds
    }

    func update(_ object: CanvasObject) {
        if title.isEmpty || object.type != .terminal { setTitle(Self.title(for: object, branch: branch)) }
        // A file outside the board root shows a short label; the tooltip has its full path.
        let path = object.type == .code ? object.props["path"]?.string : nil
        titleLabel.toolTip = path.flatMap { PathLabel.short($0) == $0 ? nil : $0 }
        z = object.z
        let state = object.type == .terminal ? object.props["lifecycle"]?["state"]?.string : nil
        badge.isHidden = object.type != .terminal
        if state != lifecycleState {
            lifecycleState = state
            badge.layer?.backgroundColor = Self.badgeColor(state).cgColor
            updateTint()
        }
        content.update(object)
    }

    /// The title (terminals report theirs). The labels show it only while the window is visible:
    /// a working agent retitles its terminal ~12 times a second (omp's spinner), and every label
    /// change costs a layout, text drawing, and a commit to the window server, minimized or not.
    private(set) var title = ""
    private var occlusionObserver: NSObjectProtocol?

    func setTitle(_ title: String) {
        guard title != self.title else { return }
        self.title = title
        if window?.occlusionState.contains(.visible) == true { syncTitle() }
    }

    /// Puts the title into the labels (also for `view.snapshot` of a window nobody sees).
    func syncTitle() {
        guard titleLabel.stringValue != title else { return }
        titleLabel.stringValue = title
        cardTitle.stringValue = title
        if author != nil { layoutTitle() }
    }

    // MARK: Author mark

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let authorFont = NSFont.systemFont(ofSize: 11)

    /// The name of the agent terminal that made the object (`AuthorMark`), nil for none.
    private(set) var author: String?

    func setAuthor(_ author: String?) {
        guard author != self.author else { return }
        self.author = author
        authorLabel.stringValue = author.map(AuthorMark.label) ?? ""
        authorLabel.toolTip = author.map { "Created by the terminal “\($0)”" }
        layoutTitle()
    }

    private func layoutTitle() {
        let frames = Self.titleFrames(width: bounds.width, title: titleLabel.stringValue, author: author)
        titleLabel.frame = frames.title
        authorLabel.isHidden = frames.author == nil
        if let rect = frames.author { authorLabel.frame = rect }
    }

    /// Where a title bar `width` wide draws the title and the author mark (nil: none), here and
    /// in `view.render`: the mark right-aligned before the close button, truncated before the
    /// title and dropped in a narrow bar (`AuthorMark.width`).
    static func titleFrames(width: CGFloat, title: String, author: String?) -> (title: NSRect, author: NSRect?) {
        let space = max(0, width - 60)
        let whole = NSRect(x: 26, y: 5, width: space, height: 16)
        guard let author else { return (whole, nil) }
        let natural = (AuthorMark.label(author) as NSString).size(withAttributes: [.font: authorFont]).width.rounded(.up)
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width.rounded(.up)
        let shown = AuthorMark.width(natural: natural, title: titleWidth, space: space)
        guard shown > 0 else { return (whole, nil) }
        let mark = NSRect(x: whole.maxX - shown, y: 6, width: shown, height: 15)
        return (NSRect(x: whole.minX, y: whole.minY, width: max(0, space - shown - AuthorMark.gap), height: whole.height), mark)
    }

    // MARK: Title

    /// A board-root changes tile's branch, which its title names (`title(for:branch:)`).
    func setBranch(_ branch: String?, of object: CanvasObject) {
        guard branch != self.branch else { return }
        self.branch = branch
        setTitle(Self.title(for: object, branch: branch))
    }

    private var branch: String?

    static func title(for object: CanvasObject) -> String { title(for: object, branch: nil) }

    /// The title from the object's props; `branch` is the branch checked out in the board root,
    /// which a changes tile of the whole board root names (`Changes: main`).
    static func title(for object: CanvasObject, branch: String?) -> String {
        let props = object.props
        switch object.type {
        case .terminal: return props["title"]?.string ?? props["agent"]?["kind"]?.string ?? "Terminal"
        case .code:
            let path = props["path"].flatMap(\.string).map(PathLabel.short) ?? "code"
            return props["followOf"] != nil ? "↳ \(path)" : path
        case .note: return props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Note"
        case .browser: return [props["title"], props["pageTitle"], props["url"]].lazy.compactMap { $0?.string }.first { !$0.isEmpty } ?? "Browser"
        case .html: return props["title"]?.string ?? "HTML"
        case .image: return props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? props["path"].flatMap(\.string).map(PathLabel.short) ?? "Image"
        case .changes:
            let spec = ChangesSpec(props)
            if let title = props["title"]?.string { return title }
            let parts = (spec.root.map { [($0 as NSString).lastPathComponent] } ?? []) + spec.paths.map(PathLabel.short)
            return parts.isEmpty ? branch.map { "Changes: \($0)" } ?? "Changes" : "Changes: \(parts.joined(separator: ", "))"
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
    /// title-only tile; going live, the card stays until the content is ready (`revealWhenReady`).
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        cardRequest += 1
        if live {
            showContent(true)
            revealWhenReady()
        } else {
            requestCard()
        }
        updateTint()
    }

    /// Longest a card covers content that never reports ready (a page whose script fails).
    static let revealLimit: TimeInterval = 2

    /// The card stays over the live content, which renders under it, until the content reports
    /// its live view drawn (a web page attaches, loads, lays out, and paints): the swap never
    /// shows a blank, half-loaded, or differently laid-out tile.
    private func revealWhenReady() {
        guard !card.isHidden || !cardTitle.isHidden else { return }
        let request = cardRequest
        let asked = DevPerf.mark()
        let reveal: @MainActor () -> Void = { [weak self] in
            guard let self, self.isLive, self.cardRequest == request else { return }
            if !self.card.isHidden || !self.cardTitle.isHidden { DevPerf.record("live.reveal.\(type(of: self.content))", since: asked) }
            self.card.image = nil
            self.card.isHidden = true
            self.cardTitle.isHidden = true
        }
        content.whenLiveReady(reveal)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealLimit) { reveal() }
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
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                    self.syncTitle()
                }
            }
        }
        guard let window else { return }
        if window.occlusionState.contains(.visible) { syncTitle() }
        guard startCardDue else { return }
        startCardDue = false
        if !isLive { requestCard() }
    }

    private func requestCard() {
        let request = cardRequest
        let asked = DevPerf.mark()
        DevPerf.time("card.call.\(type(of: content))") {
            content.cardSnapshot { [weak self] image in
                guard let self, !self.isLive, self.cardRequest == request else { return }
                DevPerf.record("card.latency.\(type(of: self.content))", since: asked)
                DevPerf.time("card.install.\(type(of: self.content))") {
                    self.card.image = image.map { self.cardImage($0) }
                    self.card.isHidden = self.card.image == nil
                    self.cardTitle.isHidden = self.card.image != nil
                    self.showContent(false)
                }
            }
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
        DevPerf.time("content.\(live ? "live" : "unlive").\(type(of: content))") { content.setLive(live) }
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
        // The context's units are the rep's pixels (its size when the context was made); the rep
        // gets its point size only afterwards.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
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

    /// The bottom-right corner: drag resizes, ⌥-drag scales. 16 canvas points in at any tile
    /// scale (at least the handle's half on screen), and past the corner as far as the handle
    /// the canvas draws for a selected tile (`TileHandles`) reaches, selected or not, inside a
    /// group or not: a drag starting just outside the corner still resizes.
    private var resizeGrip: NSRect {
        let perScreenPoint = convert(NSSize(width: 1, height: 1), from: nil).width
        let reach = TileHandles.reach * perScreenPoint
        let inside = min(max(16 / scale, reach), bounds.width / 2, bounds.height / 2)
        return NSRect(x: bounds.width - inside, y: bounds.height - inside, width: inside + reach, height: inside + reach)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeGrip.contains(local) { return self }
        // A zoomed-out card is one handle: click selects, drag moves, double-click focuses.
        if !isLive || zoomedOut, bounds.contains(local) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if resizeGrip.contains(convert(event.locationInWindow, from: nil)) {
            resizeStart = (event.locationInWindow, frame, scale, event.modifierFlags.contains(.option))
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
        let perPoint = superview.convert(NSSize(width: 1, height: 1), from: nil).width
        let dx = (event.locationInWindow.x - start.mouse.x) * perPoint
        let dy = (start.mouse.y - event.locationInWindow.y) * perPoint
        let w = start.frame.width, h = start.frame.height
        if start.scaling {
            // The drag projected on the diagonal: the tile keeps its proportions and its content
            // its layout, magnified with it.
            let ratio = ((w + dx) * w + (h + dy) * h) / max(w * w + h * h, 1)
            let scale = min(max(start.scale * ratio, ObjectScale.range.lowerBound), ObjectScale.range.upperBound)
            let applied = scale / start.scale
            place(NSRect(origin: start.frame.origin, size: NSSize(width: w * applied, height: h * applied)), scale: scale)
        } else {
            setFrameSize(NSSize(width: max(160 * scale, w + dx), height: max((80 + Self.titleHeight) * scale, h + dy)))
        }
        onResizing?()
    }

    override func mouseUp(with event: NSEvent) {
        if moving {
            moving = false
            onMoveEnded?(event)
        } else if let start = resizeStart, start.frame != frame || start.scale != scale {
            onFrameCommit?(frame, scale)
        }
        resizeStart = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

    override func resetCursorRects() {
        addCursorRect(resizeGrip, cursor: .crosshair)
        addCursorRect(titleBar.frame, cursor: .openHand)
    }
}

/// A tile's close button, named for accessibility after the tile it closes ("Close notes.md").
private final class TileCloseButton: NSButton {
    weak var tile: TileFrameView?

    override func accessibilityLabel() -> String? { "Close \(tile?.title ?? "tile")" }
    override func accessibilityTitle() -> String? { accessibilityLabel() }
}

/// Lifecycle wash over a zoomed-out card, drawn (not a layer color) so snapshots include it.
private final class CardTint: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.CardTint", since: perfStart) }
        color.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 8, dy: 8))
        border.lineWidth = 16
        color.setStroke()
        border.stroke()
    }
}
