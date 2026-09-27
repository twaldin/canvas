import AppKit
import CanvasCore

/// Flipped, very large document; canvas coordinates are offset so (0,0) sits in the middle.
/// Mouse input that reaches it landed on empty canvas (marquee, context menu); it also takes
/// keyboard focus for Esc/⌫/⌘A when no terminal holds it.
final class CanvasDocumentView: NSView {
    static let extent: CGFloat = 200_000
    static let origin = NSPoint(x: extent / 2, y: extent / 2)

    weak var canvas: CanvasView?

    // nonisolated: AppKit asks on every coordinate transform, and the @objc thunk of a main-actor
    // override otherwise pays a runtime executor check each time.
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Canvas gestures work on the first click into an inactive window, like any canvas app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The canvas background at `scale` screen points (or render pixels, with `pixelsPerPoint` 1)
    /// per document unit, for offscreen renders; on screen, `CanvasGrid` draws the same grid
    /// behind the document (which draws nothing itself). One tiled image (RenderMath.gridLevel):
    /// a rect fill per dot left ~100k display-list entries at 10% zoom, and one path of all dots
    /// made Core Animation union every rect on each frame of a pan.
    static func drawBackground(in dirtyRect: NSRect, pointsPerUnit scale: CGFloat, pixelsPerPoint backing: CGFloat) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (spacing, fade) = RenderMath.gridLevel(scale: Double(scale))
        let period = CGFloat(spacing)
        guard let tile = gridTile(pixels: gridPixels(period * scale * backing), dot: 2 * backing, color: dotColor.cgColor, fade: CGFloat(fade)) else { return }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.draw(tile, in: CGRect(x: -period / 2, y: -period / 2, width: period, height: period), byTiling: true)
        context.restoreGState()
    }

    static var dotColor: NSColor { NSColor.tertiaryLabelColor.withAlphaComponent(0.35) }

    /// An even pixel count, so the tile's center and edge midpoints fall on pixel boundaries.
    static func gridPixels(_ exact: CGFloat) -> Int { max(2, 2 * Int((exact / 2).rounded())) }

    private static var gridTileCache: (key: String, image: CGImage)?

    /// One grid period: the coarse dot in the center, the finer level's three midpoint dots (at
    /// opacity `fade`) on the edges and corners, split across them so tiling reassembles them.
    /// Symmetric, so flipped and unflipped contexts draw the same lattice.
    static func gridTile(pixels: Int, dot: CGFloat, color: CGColor, fade: CGFloat) -> CGImage? {
        let fade = (fade * 32).rounded() / 32
        let key = "\(pixels) \(dot) \(fade) \(color.components ?? [])"
        if let cached = gridTileCache, cached.key == key { return cached.image }
        guard let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(pixels), half = size / 2
        func mark(_ x: CGFloat, _ y: CGFloat) { bitmap.fill(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)) }
        bitmap.setFillColor(color)
        mark(half, half)
        if fade > 0, let faded = color.copy(alpha: color.alpha * fade) {
            bitmap.setFillColor(faded)
            for (x, y) in [(0, half), (half, 0), (0, 0)] as [(CGFloat, CGFloat)] {
                for dx in [0, size] where x == 0 || dx == 0 {
                    for dy in [0, size] where y == 0 || dy == 0 { mark(x + dx, y + dy) }
                }
            }
        }
        guard let image = bitmap.makeImage() else { return nil }
        gridTileCache = (key, image)
        return image
    }

    override func mouseDown(with event: NSEvent) { canvas?.emptyMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.emptyMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { canvas?.emptyMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { canvas?.emptyCanvasMenu(at: convert(event.locationInWindow, from: nil)) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancelOperation(nil)
        case 51, 117: deleteBackward(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { canvas?.escape() }
    override func deleteBackward(_ sender: Any?) { canvas?.deleteSelection() }
    override func deleteForward(_ sender: Any?) { canvas?.deleteSelection() }
    override func selectAll(_ sender: Any?) { canvas?.selectAll() }
}

/// The pan/zoom scene for one board: tiles are real NSViews positioned by object frames; groups
/// are regions behind them; drawings (installed by the drawing layer) and the overlay sit above.
/// Zoom is capped at 100%; below `liveThreshold` tiles become cards and release resources.
/// The viewport only moves on user input, never in response to agents.
@MainActor
final class CanvasView: NSScrollView {
    static let liveThreshold: CGFloat = 0.3
    /// Live tiles turn to cards only below this share of their live zoom, and offscreen only past
    /// `cardMargin`: a zoom or pan resting near an edge must not flip tiles back and forth.
    static let cardHysteresis: CGFloat = 0.9
    static let liveMargin: CGFloat = 300
    static let cardMargin: CGFloat = 600
    static let lassoDefaultsKey = "canvas.lassoSelection"

    /// Marquee drags draw a freehand lasso instead of a box (View menu, persisted).
    static var lassoSelection: Bool {
        get { UserDefaults.standard.bool(forKey: lassoDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lassoDefaultsKey) }
    }

    let board: Board
    let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    let overlay = SceneOverlay(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    private let attention = AttentionLayer()
    private let edges = AttentionEdgeView()
    private let grid = CanvasGrid()
    private(set) var tiles: [ObjectID: TileFrameView] = [:]
    private var groups: [ObjectID: GroupView] = [:]
    private var markers: [ObjectID: AttentionMarker] = [:]
    /// Terminals whose agent is blocked (waiting on the user), each with a ring and a bubble of
    /// its lifecycle message while on screen and an edge pill while offscreen, like a marker's
    /// but in the blocked style (`AttentionStyle`).
    private var blocked: [ObjectID: AttentionMarker] = [:]
    private(set) var selection: Set<ObjectID> = []
    /// The group being worked in: zoomed to, everything else dimmed.
    private(set) var enteredGroup: ObjectID?
    /// Read by drawing-layer extensions (e.g. hiding handles while rendering an object image).
    private(set) var shapeLayer: NSView?

    private var livenessScheduled = false
    private var geometryDirty = false
    private var magnifying = false
    private var move: MoveGesture?
    private var marquee: MarqueeGesture?
    /// A press on a drawn object is tracked here (the event never reaches a view).
    private var shapePress = false
    private var mouseMonitor: Any?
    /// Terminals seen since their agent last started working (mirrors Board's seen set).
    private var seenLocally: Set<ObjectID> = []
    /// Who the activity log credits for viewport moves: the user, except while the app moves it.
    private var viewportMover: ActivityActor = .user
    private var activitySettle: DispatchWorkItem?
    private lazy var seen = SeenTracker { [weak self] id in self?.didSee(id) }

    /// Where the tray drains and Superwhisper pastes (`PromptTarget`; the window controller
    /// settles it).
    var promptTarget: ObjectID? { didSet { onPromptTargetChange?() } }
    var onPromptTargetChange: (() -> Void)?
    /// The prompt target retitled itself (an agent's OSC title); the tray names it by that.
    var onPromptTargetTitle: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    // MARK: Drawn objects (installed by the drawing layer)

    /// The shape or arrow drawn at a document point. Only strokes, text, and fills hit, so an
    /// empty shape interior never blocks the tiles beneath; drawn objects sit above tiles.
    var shapeHitTest: ((NSPoint) -> ObjectID?)?
    /// Document-space outline of a drawn object at its committed position.
    var shapeOutline: ((ObjectID) -> NSRect?)?
    /// True where the drawing layer handles the mouse itself (active tool, shape handles);
    /// scene selection, marquee, and moves stand down there.
    var drawingOwnsPoint: (NSPoint) -> Bool = { _ in false }
    /// Extra props to merge into a drawn object's move (e.g. translated free arrow endpoints).
    var moveProps: ((CanvasObject, _ dx: Double, _ dy: Double) -> JSONValue?)?
    /// Live offset (document points) of drawn objects being dragged; `.zero` right before commit.
    var onSelectionDrag: ((Set<ObjectID>, NSSize) -> Void)?

    private struct MoveGesture {
        var start: NSPoint
        /// Pressed object that was already part of a multi-selection: a click without a drag
        /// narrows the selection to it.
        var collapseTo: ObjectID?
        var tileOrigins: [ObjectID: NSPoint]
        var drawn: [ObjectID: NSRect]
        var delta = NSSize.zero
    }

    private struct MarqueeGesture {
        var start: NSPoint
        var points: [NSPoint]
        var base: Set<ObjectID>
        var lasso: Bool
    }

    init(board: Board) {
        self.board = board
        super.init(frame: .zero)
        documentView = document
        document.canvas = self
        document.addSubview(overlay)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 1.0
        drawsBackground = false
        addSubview(grid, positioned: .below, relativeTo: contentView)
        addSubview(attention)
        addSubview(edges)
        edges.onReveal = { [weak self] id in self?.jumpToAttention(id) }
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        // A window resize changes what's visible without moving the bounds origin.
        contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(magnifyStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didResignActiveNotification, object: nil)
        // Placement aims at what the user can see: the viewport clear of the toolbar and tray.
        board.viewport = { [weak self] in self?.clearViewport }
        for object in board.snapshot.objects { add(object) }
        // Markers the user hadn't seen when the board was last open.
        for marker in board.attention.values { showMarker(marker.object, message: marker.message) }
        restack()
        refreshGroups()
        DispatchQueue.main.async { [weak self] in self?.centerOnContent() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func tile() {
        super.tile()
        attention.frame = bounds
        edges.frame = bounds
        grid.frame = bounds
        updateGrid()
    }

    private func updateGrid() {
        grid.update(origin: grid.convert(NSPoint.zero, from: document), scale: magnification)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Not `self?.handleMouse(event) ?? event`: that turns "consumed" (nil) back into the event.
            guard let self else { return event }
            return self.handleMouse(event)
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSWindow.didResignKeyNotification, object: window)
        window.initialFirstResponder = document
    }

    // MARK: Coordinates

    /// Document rect of an object's frame: a tile's whole drawn box (title bar included), a
    /// drawn object's box.
    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height)
    }

    /// Where an object is on screen right now, in document coordinates, including an in-flight drag.
    func docFrame(_ id: ObjectID) -> NSRect? {
        if let tile = tiles[id] { return tile.frame }
        if let group = groups[id] { return group.isHidden ? nil : group.region }
        if let start = move?.drawn[id], let delta = move?.delta { return start.offsetBy(dx: delta.width, dy: delta.height) }
        guard let object = board.objects[id] else { return nil }
        return shapeOutline?(id) ?? Self.docRect(object.frame)
    }

    private func docPoint(_ event: NSEvent) -> NSPoint {
        document.convert(event.locationInWindow, from: nil)
    }

    // MARK: Reconciliation

    func apply(_ event: BoardEvent) {
        switch event {
        case .objectCreated(let object):
            add(object)
            restack()
            scheduleGeometry()
        case .objectUpdated(let object):
            if object.type == .group {
                groups[object.id]?.update(object)
            } else if let tile = tiles[object.id] {
                // The user's own resize already laid the content out at this size; any other
                // (an agent's update or fit, undo) re-aims a code tile at its range.
                let body = tile.content.frame.size
                tile.place(Self.docRect(object.frame), scale: CGFloat(object.scale))
                let restacks = tile.z != object.z
                tile.update(object)
                if tile.content.frame.size != body, let code = tile.content as? CodeTile { code.resizedElsewhere() }
                if restacks { restack() }
                if object.type == .terminal { lifecycleChanged(object) }
            } else {
                add(object)
            }
            scheduleGeometry()
        case .objectDeleted(let id):
            tiles.removeValue(forKey: id)?.removeFromSuperview()
            groups.removeValue(forKey: id)?.removeFromSuperview()
            if enteredGroup == id { exitGroup() }
            hideMarker(id)
            if let view = blocked.removeValue(forKey: id) {
                view.removeFromSuperview()
                layoutPills()
            }
            seenLocally.remove(id)
            if selection.contains(id) { setSelection(selection.subtracting([id])) }
            scheduleGeometry()
        case .attentionChanged(let id, let marker):
            if let marker { showMarker(id, message: marker.message) } else { hideMarker(id) }
        default: break
        }
    }

    private func add(_ object: CanvasObject) {
        if object.type == .group { return addGroup(object) }
        guard tiles[object.id] == nil, TileFactory.hasTile(object.type) else { return }
        let id = object.id
        let content = TileFactory.make(object, board: board)
        if let terminal = content as? TerminalTile {
            terminal.onTitle = { [weak self] title in
                self?.tiles[id]?.setTitle(title)
                if self?.promptTarget == id { self?.onPromptTargetTitle?() }
            }
            // A ⌘-clicked reference: user navigation, so the tile is panned into view; one
            // already on the board is selected (keyboard focus stays in the terminal).
            terminal.onOpenedCode = { [weak self] opened, created in
                if !created { self?.setSelection([opened]) }
                self?.reveal(opened)
            }
        }
        (content as? HtmlTile)?.onOpenedCode = { [weak self] opened in self?.reveal(opened) }
        (content as? BrowserTile)?.onOpenedTile = { [weak self] opened in
            self?.reveal(opened)
            self?.setSelection([opened])
        }
        let tile = TileFrameView(object: object, content: content, frame: Self.docRect(object.frame))
        tile.onFrameCommit = { [weak self] rect, scale in
            guard let self, let object = self.board.objects[id] else { return }
            let props: JSONValue? = scale == CGFloat(object.scale) ? nil : .object(["scale": Self.scaleProp(Double(scale))])
            _ = try? self.board.update(id, frame: Self.canvasFrame(rect), props: props)
        }
        tile.onResizing = { [weak self] in self?.objectsMoved() }
        tile.onClose = { [weak self] in self?.delete([id]) }
        tile.onMoveBegan = { [weak self] event in self?.beginMove(event, pressing: id) }
        tile.onMoveDragged = { [weak self] event in self?.dragMove(event) }
        tile.onMoveEnded = { [weak self] event in self?.endMove(event) }
        tile.onTitleDoubleClick = { [weak self] in self?.focus(tile: id) }
        tile.onMenu = { [weak self] in self?.objectMenu(for: id) }
        // Created where it wouldn't be live (a batch building a board zoomed out or offscreen),
        // a code, note, or HTML tile starts as its card rather than building its live view for
        // the liveness pass to swap out. Terminals and browsers start live: they run a session
        // or a page an agent may be driving.
        if object.type != .terminal, object.type != .browser, !magnifying, !shouldBeLive(tile, scale: magnification) { tile.startAsCard() }
        document.addSubview(tile, positioned: .below, relativeTo: shapeLayer ?? overlay)
        tiles[id] = tile
        tile.zoomedOut = magnification * tile.scale < Self.liveThreshold
        if object.type == .terminal { lifecycleChanged(object) }
        scheduleLiveness()
    }

    private func addGroup(_ object: CanvasObject) {
        guard groups[object.id] == nil, let view = GroupView(object: object) else { return }
        let id = object.id
        view.onPress = { [weak self] event in self?.beginMove(event, pressing: id) }
        view.onDrag = { [weak self] event in self?.dragMove(event) }
        view.onRelease = { [weak self] event in self?.endMove(event) }
        view.onEnter = { [weak self] in self?.enter(group: id) }
        view.onMenu = { [weak self] in self?.groupMenu(for: id) }
        document.addSubview(view, positioned: .below, relativeTo: nil)
        groups[id] = view
    }

    /// Orders document subviews: group regions, tiles by `z`, the drawing layer, then the
    /// overlay. Reorders in place so tiles never leave the window.
    private func restack() {
        document.sortSubviews({ a, b, _ in
            MainActor.assumeIsolated {
                let lhs = CanvasView.stackRank(a), rhs = CanvasView.stackRank(b)
                return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
            }
        }, context: nil)
    }

    private static func stackRank(_ view: NSView) -> (Int, Double) {
        switch view {
        case is GroupView: (0, 0)
        case let tile as TileFrameView: (1, tile.z)
        case is SceneOverlay: (4, 0)
        default: (2, 0)
        }
    }

    /// The drawing layer sits above tiles and below the overlay.
    func installShapeLayer(_ view: NSView) {
        shapeLayer = view
        document.addSubview(view, positioned: .below, relativeTo: overlay)
        restack()
    }

    /// Board changes re-lay out what's drawn around objects on the next turn, after every other
    /// consumer of the event (the drawing layer's outlines) has caught up, then re-run culling,
    /// edge pills, and seen eligibility, since an object may have moved into or out of view.
    private func scheduleGeometry() {
        geometryDirty = true
        scheduleLiveness()
    }

    /// Geometry changed (moves, resizes, deletes, drags): everything drawn around objects follows.
    private func objectsMoved() {
        refreshRings()
        refreshGroups()
        layoutPills()
        refreshFocusHoles()
    }

    // MARK: Selection

    func select(_ id: ObjectID, extend: Bool) {
        if extend {
            setSelection(selection.symmetricDifference([id]))
        } else {
            setSelection([id])
            (tiles[id]?.content as? TerminalTile)?.focus()
        }
    }

    func setSelection(_ ids: Set<ObjectID>) {
        guard ids != selection else { return }
        let added = ids.subtracting(selection)
        selection = ids
        for (id, group) in groups { group.isSelected = ids.contains(id) }
        board.activity.selectionChanged(Array(ids), actor: .user, rev: board.revision)
        scheduleActivitySettle()
        refreshRings()
        // Selecting a marked object is the user acknowledging it.
        for id in added where markers[id] != nil { board.clearAttention(id) }
        onSelectionChange?()
    }

    func selectAll() {
        let scope = enteredGroup.flatMap { groups[$0]?.members }.map(Set.init)
        setSelection(Set(selectableRects().map(\.id).filter { scope?.contains($0) ?? true }))
    }

    private func refreshRings() {
        overlay.rings = selection.sorted().compactMap { id in
            guard groups[id] == nil, let rect = docFrame(id) else { return nil }
            return SceneOverlay.Ring(rect: rect, dashed: tiles[id] == nil)
        }
    }

    /// A press on an object's handle (title bar, drawn stroke, group label): a plain press on an
    /// unselected object selects just it; on a selected one it keeps the selection for dragging.
    private func press(_ id: ObjectID, extend: Bool) -> ObjectID? {
        if extend {
            setSelection(selection.symmetricDifference([id]))
            return nil
        }
        if selection.contains(id) { return selection.count > 1 ? id : nil }
        select(id, extend: false)
        return nil
    }

    /// Selection with groups expanded to their members: what a move or new group acts on.
    private func expandedSelection() -> [ObjectID] {
        var ids: Set<ObjectID> = []
        for id in selection {
            if let group = groups[id] {
                ids.formUnion(group.members.filter { board.objects[$0] != nil && groups[$0] == nil })
            } else if board.objects[id] != nil {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    private func selectableRects() -> [(id: ObjectID, rect: NSRect)] {
        board.objects.values.compactMap { object in
            guard object.type != .group else { return nil }
            // Drawn objects: rendered bounds (an arrow reroutes with its tiles without a frame write).
            return (object.id, tiles[object.id]?.frame ?? shapeOutline?(object.id) ?? Self.docRect(object.frame))
        }
    }

    /// Tiles and drawn objects wholly inside a document rect.
    func objects(inDocRect rect: NSRect) -> [ObjectID] {
        selectableRects().filter { rect.contains($0.rect) }.map(\.id).sorted()
    }

    /// Tiles and drawn objects wholly inside a lasso drawn in document coordinates.
    func objects(inLasso points: [NSPoint]) -> [ObjectID] {
        let lasso = Lasso(points: points.map { (Double($0.x), Double($0.y)) })
        return selectableRects().filter { lasso.contains(Frame(x: $0.rect.minX, y: $0.rect.minY, w: $0.rect.width, h: $0.rect.height)) }.map(\.id).sorted()
    }

    // MARK: Mouse

    /// Clicks that land on tiles or drawings, seen before any view: tile bodies select their tile
    /// and still receive the click (a terminal keeps focusing); drawn objects are selected and
    /// dragged here because they have no view of their own.
    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !HyperMonitor.isHyper(event.modifierFlags) else { return event }
        switch event.type {
        case .leftMouseDown:
            guard let hit = hitView(event), hit.isDescendant(of: document) else { return event }
            let point = docPoint(event)
            if drawingOwnsPoint(point) { return event }
            if let shape = shapeHitTest?(point) {
                if event.clickCount >= 2 { return event }
                shapePress = true
                beginMove(event, pressing: shape)
                return nil
            }
            var view: NSView? = hit
            while let current = view, !(current is TileFrameView) { view = current.superview }
            if let tile = view as? TileFrameView, tile.isLive, hit.isDescendant(of: tile.content) {
                select(tile.objectID, extend: event.modifierFlags.contains(.shift))
            }
            return event
        case .leftMouseDragged where shapePress:
            dragMove(event)
            return nil
        case .leftMouseUp where shapePress:
            shapePress = false
            endMove(event)
            return nil
        default:
            return event
        }
    }

    private func hitView(_ event: NSEvent) -> NSView? {
        guard let content = window?.contentView, let frame = content.superview else { return nil }
        return content.hitTest(frame.convert(event.locationInWindow, from: nil))
    }

    private var terminalHasFocus: Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is TerminalTile { return true }
            view = current.superview
        }
        return false
    }

    func emptyMouseDown(_ event: NSEvent) {
        // Keyboard focus stays in the prompt terminal while the mouse selects; otherwise the
        // canvas takes it so Esc, Delete, and ⌘A act on the selection.
        if !terminalHasFocus { window?.makeFirstResponder(document) }
        let extend = event.modifierFlags.contains(.shift)
        if !extend { setSelection([]) }
        let point = docPoint(event)
        marquee = MarqueeGesture(start: point, points: [point], base: selection, lasso: Self.lassoSelection)
    }

    func emptyMouseDragged(_ event: NSEvent) {
        guard var gesture = marquee else { return }
        let point = docPoint(event)
        if gesture.lasso {
            if let last = gesture.points.last, hypot(point.x - last.x, point.y - last.y) * magnification < 3 { return }
            gesture.points.append(point)
            let path = NSBezierPath()
            path.move(to: gesture.points[0])
            gesture.points.dropFirst().forEach(path.line(to:))
            path.close()
            path.lineWidth = 1 / max(magnification, 0.05)
            overlay.marquee = path
        } else {
            gesture.points = [gesture.start, point]
            let rect = HyperMonitor.rect(gesture.start, point)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1 / max(magnification, 0.05)
            overlay.marquee = path
            // Box containment is cheap enough to show live.
            setSelection(gesture.base.union(objects(inDocRect: rect)))
        }
        marquee = gesture
    }

    func emptyMouseUp(_ event: NSEvent) {
        guard let gesture = marquee else { return }
        marquee = nil
        overlay.marquee = nil
        if gesture.lasso, gesture.points.count >= 3 {
            setSelection(gesture.base.union(objects(inLasso: gesture.points)))
        }
    }

    private func beginMove(_ event: NSEvent, pressing id: ObjectID) {
        let collapse = press(id, extend: event.modifierFlags.contains(.shift))
        var origins: [ObjectID: NSPoint] = [:]
        var drawn: [ObjectID: NSRect] = [:]
        for id in expandedSelection() {
            if let tile = tiles[id] {
                origins[id] = tile.frame.origin
            } else if let rect = docFrame(id) {
                drawn[id] = rect
            }
        }
        move = MoveGesture(start: docPoint(event), collapseTo: collapse, tileOrigins: origins, drawn: drawn)
    }

    private func dragMove(_ event: NSEvent) {
        guard var gesture = move else { return }
        let point = docPoint(event)
        gesture.delta = NSSize(width: point.x - gesture.start.x, height: point.y - gesture.start.y)
        move = gesture
        for (id, origin) in gesture.tileOrigins {
            tiles[id]?.setFrameOrigin(NSPoint(x: origin.x + gesture.delta.width, y: origin.y + gesture.delta.height))
        }
        if !gesture.drawn.isEmpty { onSelectionDrag?(Set(gesture.drawn.keys), gesture.delta) }
        objectsMoved()
    }

    /// One board update per moved object, as one undo step; groups re-bound themselves.
    private func endMove(_ event: NSEvent) {
        guard let gesture = move else { return }
        move = nil
        guard gesture.delta != .zero else {
            if let id = gesture.collapseTo { setSelection([id]) }
            return
        }
        if !gesture.drawn.isEmpty { onSelectionDrag?(Set(gesture.drawn.keys), .zero) }
        let dx = Double(gesture.delta.width), dy = Double(gesture.delta.height)
        let moved = Set(gesture.tileOrigins.keys).union(gesture.drawn.keys)
        board.transaction {
            for id in moved.sorted() {
                guard let object = board.objects[id] else { continue }
                var frame = object.frame
                frame.x += dx
                frame.y += dy
                _ = try? board.update(id, frame: frame, props: tiles[id] == nil ? moveProps?(object, dx, dy) : nil)
            }
        }
    }

    // MARK: Groups

    /// Group regions follow their members live (mid-drag too), the same way the board fits
    /// their frames on commit; nested groups count with their committed frames.
    private func refreshGroups() {
        for group in groups.values {
            let rects = group.members.compactMap { id -> NSRect? in
                guard board.objects[id]?.type != .arrow else { return nil }
                if groups[id] != nil { return board.objects[id].map { Self.docRect($0.frame) } }
                return docFrame(id)
            }
            if let region = group.spec.frame(around: rects) {
                group.show(region: region)
                group.isHidden = false
            } else {
                group.isHidden = true
            }
        }
    }

    func groupSelection() {
        let members = expandedSelection()
        guard members.count >= 2, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Group \(members.count) objects"
        alert.informativeText = "Name the group (optional)."
        alert.addButton(withTitle: "Group")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Group"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createGroup(members, name: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func createGroup(_ members: [ObjectID], name: String) {
        guard members.count >= 2 else { return }
        var props: [String: JSONValue] = ["members": .array(members.map(JSONValue.string))]
        if !name.isEmpty { props["title"] = .string(name) }
        let group = board.create(type: .group, props: .object(props))
        setSelection([group.id])
    }

    /// Deletes the selected groups, and groups containing selected objects; members stay.
    func ungroupSelection() {
        let ids = groups.values.filter { selection.contains($0.objectID) || !selection.isDisjoint(with: $0.members) }
        guard !ids.isEmpty else { return }
        let members = Set(ids.flatMap(\.members))
        board.transaction {
            for group in ids { try? board.delete(group.objectID) }
        }
        setSelection(members.filter { board.objects[$0] != nil })
    }

    func enter(group id: ObjectID) {
        guard let view = groups[id], !view.isHidden else { return }
        enteredGroup = id
        setSelection([])
        fit(view.frame)
        refreshFocusHoles()
    }

    func exitGroup() {
        enteredGroup = nil
        overlay.focusHoles = nil
    }

    private func refreshFocusHoles() {
        guard let id = enteredGroup, let view = groups[id] else { return }
        let holes = view.isHidden ? [] : [view.frame]
        if overlay.focusHoles != holes { overlay.focusHoles = holes }
    }

    // MARK: Commands

    func escape() {
        if enteredGroup != nil { exitGroup() } else { setSelection([]) }
    }

    func deleteSelection() {
        delete(Array(selection))
    }

    /// Deletes objects as one undo step. Closing a terminal ends its zmx session (the board
    /// reports it ended; see AppDelegate), so ask first, in a sheet: an app-modal alert would
    /// stall every socket request until answered.
    func delete(_ ids: [ObjectID]) {
        guard !ids.isEmpty else { return }
        let terminals = ids.filter { tiles[$0]?.content is TerminalTile }
        guard !terminals.isEmpty else { return remove(ids) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = terminals.count == 1 ? "Close this terminal?" : "Close \(terminals.count) terminals?"
        alert.informativeText = "Their zmx sessions (and anything running in them) will be ended."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // The board may have changed while the sheet was up.
            self.remove(ids.filter { self.board.objects[$0] != nil })
        }
    }

    private func remove(_ ids: [ObjectID]) {
        board.transaction {
            for id in ids.sorted() { try? board.delete(id) }
        }
        // A closed tile that had the keyboard leaves it with the window: the canvas takes it,
        // so Esc, Delete, ⌘W and the arrows keep working.
        if let window, window.firstResponder === window { window.makeFirstResponder(document) }
    }

    /// ⌘W: closes the selected objects, else the focused terminal (terminals ask first, in the
    /// close sheet). False with neither, so the window's own close (tab or window) runs.
    func closeSelectionOrFocused() -> Bool {
        if !selection.isEmpty {
            deleteSelection()
            return true
        }
        guard let id = focusedTerminal else { return false }
        delete([id])
        return true
    }

    func bringToFront() {
        let ids = expandedSelection().sorted { (board.objects[$0]?.z ?? 0) < (board.objects[$1]?.z ?? 0) }
        var top = board.objects.values.map(\.z).max() ?? 0
        board.transaction {
            for id in ids {
                top += 1
                _ = try? board.update(id, z: top)
            }
        }
    }

    func sendToBack() {
        let ids = expandedSelection().sorted { (board.objects[$0]?.z ?? 0) > (board.objects[$1]?.z ?? 0) }
        var bottom = board.objects.values.map(\.z).min() ?? 0
        board.transaction {
            for id in ids {
                bottom -= 1
                _ = try? board.update(id, z: bottom)
            }
        }
    }

    /// A new terminal with keyboard focus: at a document point (`createHere`), else placed and
    /// revealed like any new object the user asks for (`openForUser`).
    func createTerminal(at point: NSPoint? = nil) {
        let props: JSONValue = .object(["cwd": .string(board.root.path), "command": .array([])])
        guard let point else { return openForUser(.terminal, props: props) }
        takeKeyboard(createHere(.terminal, props: props, at: point).id)
    }

    /// A new terminal in `terminal`'s directory beside it (a Ghostty new window, tab or split
    /// binding pressed in it), placed, revealed, and focused like any object the user asks for.
    func createTerminal(beside terminal: ObjectID) {
        let cwd = board.objects[terminal]?.props["cwd"]?.string ?? board.root.path
        openForUser(.terminal, props: .object(["cwd": .string(cwd), "command": .array([])]), near: terminal)
    }

    /// New Terminal/Note/Browser Here: the object's top-left at a document point, moved to the
    /// nearest free spot on whole points, wholly in view clear of the toolbar and tray when there's
    /// room (`Board.place`); when there isn't, the canvas pans the least that shows it.
    private func createHere(_ type: ObjectType, props: JSONValue, at point: NSPoint) -> CanvasObject {
        let size = Board.defaultSize(type)
        let object = board.create(type: type, props: props, frame: board.place(Frame(x: point.x - CanvasDocumentView.origin.x, y: point.y - CanvasDocumentView.origin.y, w: size.w, h: size.h)))
        reveal(object.id)
        return object
    }

    /// A new object the user asked for without saying where (File › Open File, New Note, New
    /// Browser Tile, ⌘T, Go to's file rows, Edit Here's terminal `near` its code tile): the free
    /// spot nearest the viewport center or that tile, in view when there's room (`Board.place`),
    /// revealed with the least pan otherwise, selected, and given the keyboard.
    func openForUser(_ type: ObjectType, props: JSONValue, near anchor: ObjectID? = nil) {
        let size = Board.defaultSize(type)
        let object = board.create(type: type, props: props, frame: board.place(width: size.w, height: size.h, near: anchor))
        reveal(object.id)
        setSelection([object.id])
        takeKeyboard(object.id)
    }

    /// Keyboard focus for a tile the keyboard just went to: a terminal takes it itself (on the
    /// next turn, once a new one's surface exists); anything else leaves it with the canvas, so
    /// Esc, Delete, ⌘W, ⌘G and the arrows act on the selection.
    func takeKeyboard(_ id: ObjectID) {
        guard board.objects[id]?.type == .terminal else {
            window?.makeFirstResponder(document)
            return
        }
        DispatchQueue.main.async { [weak self] in
            (self?.tiles[id]?.content as? TerminalTile)?.focus()
        }
    }

    /// The tile holding keyboard focus (a terminal, a code tile's rows, a page, a note being
    /// edited, a code tile's find field).
    var focusedTile: ObjectID? {
        var responder = window?.firstResponder as? NSView
        while let view = responder {
            if let tile = view as? TileFrameView { return tile.objectID }
            responder = view.superview
        }
        return nil
    }

    /// The terminal holding keyboard focus.
    var focusedTerminal: ObjectID? {
        focusedTile.flatMap { tiles[$0]?.content is TerminalTile ? $0 : nil }
    }

    /// ⌥⌘-arrow: the nearest tile that way from the focused tile, else the selection, else the
    /// viewport center (`Layout.neighbor`), shown with the least pan, selected, and given the
    /// keyboard.
    func moveToNeighbor(_ heading: Layout.Heading) {
        let sources = focusedTile.map { [$0] } ?? selection.filter { tiles[$0] != nil }.sorted()
        let frames = sources.compactMap { tiles[$0]?.frame }
        let from = frames.dropFirst().reduce(frames.first) { union, frame in union?.union(frame) }
            ?? NSRect(x: documentVisibleRect.midX, y: documentVisibleRect.midY, width: 0, height: 0)
        let candidates = tiles.values.filter { !sources.contains($0.objectID) && !$0.isHidden }
        guard let index = Layout.neighbor(of: from, among: candidates.map(\.frame), toward: heading) else { return }
        let id = candidates[index].objectID
        reveal(id)
        setSelection([id])
        takeKeyboard(id)
    }

    /// ⌘F: the find bar of the focused code tile, else of the one selected code tile. False
    /// when neither (the focused terminal or page keeps ⌘F).
    func findInCodeTile() -> Bool {
        let code: CodeTile?
        if let focused = focusedTile, tiles[focused]?.content is CodeTile {
            code = tiles[focused]?.content as? CodeTile
        } else if selection.count == 1, let id = selection.first {
            code = tiles[id]?.content as? CodeTile
        } else {
            code = nil
        }
        guard let code, tiles[code.object.id]?.isLive == true else { return false }
        code.showFind()
        return true
    }

    /// An empty note at a document point (`createHere`).
    func createNote(at point: NSPoint) {
        setSelection([createHere(.note, props: .object(["markdown": .string("")]), at: point).id])
    }

    /// An empty browser tile at a document point (`createHere`), with the address field focused
    /// for the user to type where to go.
    func createBrowser(at point: NSPoint) {
        let browser = createHere(.browser, props: .object(["url": .string("about:blank")]), at: point)
        setSelection([browser.id])
        DispatchQueue.main.async { [weak self] in
            (self?.tiles[browser.id]?.content as? BrowserTile)?.focusAddress()
        }
    }

    // MARK: Context menus

    func objectMenu(for id: ObjectID) -> NSMenu {
        if !selection.contains(id) { select(id, extend: false) }
        let count = selection.count
        let menu = NSMenu()
        menu.addItem(MenuAction.item(count > 1 ? "Close \(count) Objects" : "Close") { [weak self] in self?.deleteSelection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Bring to Front") { [weak self] in self?.bringToFront() })
        menu.addItem(MenuAction.item("Send to Back") { [weak self] in self?.sendToBack() })
        menu.addItem(.separator())
        if let scale = scaleMenu() { menu.addItem(scale) }
        menu.addItem(MenuAction.item("Group Selection", enabled: expandedSelection().count >= 2) { [weak self] in self?.groupSelection() })
        if count == 1, let terminal = board.objects[id], terminal.type == .terminal {
            // Off removes the follow tile; on, the agent's next file report brings it back.
            let following = terminal.props["follow"]?.bool != false
            let item = MenuAction.item("Follow Files") { [weak self] in try? self?.board.setFollowing(id, !following) }
            item.state = following ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(count > 1 ? "Copy Object IDs" : "Copy Object ID") { [weak self] in self?.copyIDs() })
        return menu
    }

    /// Scale presets and Reset for the selected tiles and text shapes (a preset is checked when
    /// they all show it); nil when nothing selected scales.
    private func scaleMenu() -> NSMenuItem? {
        let scalable = selection.compactMap { board.objects[$0] }.filter { ObjectScale.applies(to: $0.type, props: $0.props) }
        guard !scalable.isEmpty else { return nil }
        let current = Set(scalable.map(\.scale))
        func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
        let submenu = NSMenu()
        for preset in ObjectScale.presets {
            let item = MenuAction.item(percent(preset)) { [weak self] in self?.scaleSelection(to: preset) }
            item.state = current == [preset] ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(MenuAction.item("Reset to 100%", enabled: current != [1]) { [weak self] in self?.scaleSelection(to: 1) })
        submenu.addItem(MenuAction.item("⌥-drag a corner to scale freely", enabled: false) {})
        let title = current.count == 1 && current != [1] ? "Scale (\(percent(current.first!)))" : "Scale"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Sets the selected tiles' and text shapes' `props.scale`, resizing each around its top-left
    /// corner so its content keeps its layout, as one undo step.
    func scaleSelection(to scale: Double) {
        let objects = selection.compactMap { board.objects[$0] }.filter { ObjectScale.applies(to: $0.type, props: $0.props) && $0.scale != scale }
        guard !objects.isEmpty else { return }
        board.transaction {
            for object in objects {
                _ = try? board.update(object.id, frame: ObjectScale.rescaled(object.frame, from: object.scale, to: scale), props: .object(["scale": Self.scaleProp(scale)]))
            }
        }
    }

    /// `props.scale` as written: 1 removes it.
    static func scaleProp(_ scale: Double) -> JSONValue {
        scale == 1 ? .null : .number(scale)
    }

    private func groupMenu(for id: ObjectID) -> NSMenu {
        if !selection.contains(id) { setSelection([id]) }
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Enter Group") { [weak self] in self?.enter(group: id) })
        menu.addItem(MenuAction.item("Ungroup") { [weak self] in self?.ungroupSelection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Copy Object ID") { [weak self] in self?.copyIDs() })
        return menu
    }

    func emptyCanvasMenu(at point: NSPoint) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction.item("New Terminal Here") { [weak self] in self?.createTerminal(at: point) })
        menu.addItem(MenuAction.item("New Note Here") { [weak self] in self?.createNote(at: point) })
        menu.addItem(MenuAction.item("New Browser Here") { [weak self] in self?.createBrowser(at: point) })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Clear Attention Markers", enabled: !board.attention.isEmpty) { [weak self] in self?.board.clearAllAttention() })
        if enteredGroup != nil {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Exit Group") { [weak self] in self?.exitGroup() })
        }
        return menu
    }

    private func copyIDs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection.sorted().joined(separator: "\n"), forType: .string)
    }

    // MARK: Navigation (user-initiated only)

    /// Floating window chrome over the canvas edges (the drawing toolbar at the top, the tray at
    /// the bottom), in view points; the window controller measures it. Jumps land clear of it.
    var chromeInsets: () -> NSEdgeInsets = { NSEdgeInsets() }

    /// Space kept between a jump's target and the floating chrome, in view points.
    static let chromeMargin: CGFloat = 12

    /// The part of the viewport jumps aim at (view points, top-left origin): between the floating
    /// toolbar and the tray, with a margin; never less than half the viewport.
    private var clearArea: CGRect {
        let size = contentView.frame.size
        let insets = chromeInsets()
        let top = insets.top + Self.chromeMargin, bottom = insets.bottom + Self.chromeMargin
        let height = max(size.height - top - bottom, size.height / 2)
        return CGRect(x: 0, y: min(top, size.height - height), width: size.width, height: height)
    }

    /// Where a board opens: the top of its content, or of its largest cluster when the content
    /// doesn't fit at this zoom (the middle of a board with a stray tile far away is empty canvas).
    func centerOnContent() {
        viewportMover = .system
        defer { viewportMover = .user }
        let clear = clearArea
        let target = Layout.fitTarget(tiles.values.map(\.frame), viewport: clear.size, padding: Self.fitPadding, minZoom: 1)
            ?? NSRect(origin: CanvasDocumentView.origin, size: .zero)
        let zoom = magnification
        scroll(to: NSPoint(x: target.midX - clear.midX / zoom, y: target.minY - Self.jumpPadding - clear.minY / zoom))
    }

    private func scroll(to origin: NSPoint) {
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        scheduleLiveness()
    }

    private func apply(_ jump: Layout.Jump) {
        if magnification != jump.zoom { magnification = jump.zoom }
        scroll(to: jump.origin)
    }

    /// The viewport now, as a jump (for minimal pans).
    private var currentJump: Layout.Jump {
        Layout.Jump(zoom: magnification, origin: contentView.bounds.origin)
    }

    func zoom(to scale: CGFloat) {
        let visible = documentVisibleRect
        setMagnification(min(maxMagnification, max(minMagnification, scale)), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        scheduleLiveness()
    }

    /// ⌘= / ⌘-: the next browser-like zoom level (`Layout.zoomStep`).
    func zoomStep(in zoomIn: Bool) {
        zoom(to: Layout.zoomStep(from: magnification, in: zoomIn, limits: minMagnification...maxMagnification))
    }

    /// The part of the viewport clear of the toolbar and tray, in canvas coordinates: where new
    /// objects are placed (`Board.viewport`).
    var clearViewport: Frame {
        let clear = clearArea, zoom = magnification, origin = contentView.bounds.origin
        return Frame(x: origin.x + clear.minX / zoom - CanvasDocumentView.origin.x, y: origin.y + clear.minY / zoom - CanvasDocumentView.origin.y,
                     w: clear.width / zoom, h: clear.height / zoom)
    }

    /// ⌘0: 100%. With a selection, the selection at 100%, centered clear of the chrome (its top
    /// when taller than the view); without one, around the viewport's center.
    func zoomToActualSize() {
        let rects = selection.compactMap(docFrame)
        guard let first = rects.first else { return zoom(to: 1) }
        apply(Layout.center(rects.dropFirst().reduce(first) { $0.union($1) }, in: clearArea, zoom: 1, padding: Self.jumpPadding))
    }

    /// Room kept around whatever a fit shows, in document points.
    static let fitPadding: CGFloat = 60
    /// Room kept around a target shown at a fixed zoom, in document points.
    static let jumpPadding: CGFloat = 20
    /// Below this, a target too tall to read when fitted whole fits its width instead.
    static let readableZoom: CGFloat = 0.5

    /// Zooms (at most to 100%) so a document rect fills the viewport clear of the chrome,
    /// centered. `readable`: a tall target fits its width and shows its top instead of shrinking
    /// below `readableZoom` (objects; not Zoom to Fit, which must show everything).
    func fit(_ rect: NSRect, readable: Bool = false) {
        apply(Layout.fit(rect, in: clearArea, padding: Self.fitPadding, zoom: minMagnification...maxMagnification,
                         readable: readable ? Self.readableZoom : nil))
    }

    /// Everything, or when that can't be read at minimum zoom, the largest cluster of objects
    /// (`Layout.fitTarget`): a few strays far away don't shrink the board to nothing.
    func zoomToFit() {
        let rects = selectableRects().map(\.rect) + groups.values.filter { !$0.isHidden }.map(\.frame)
        guard let target = Layout.fitTarget(rects, viewport: clearArea.size, padding: Self.fitPadding, minZoom: minMagnification) else { return }
        fit(target)
    }

    /// The navigator's "go to": the object fitted (at most 100%, a tall one by its width),
    /// selected, and given the keyboard (a terminal focuses; anything else leaves it with the
    /// canvas, so Delete, Esc and ⌘G act on it).
    func go(to id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        fit(rect, readable: true)
        setSelection([id])
        takeKeyboard(id)
    }

    /// "Zoom in" on the canvas: this tile at 100%, centered, selected, and focused if it types.
    func focus(tile id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        apply(Layout.center(rect, in: clearArea, zoom: 1, padding: Self.jumpPadding))
        setSelection([id])
        (tiles[id]?.content as? TerminalTile)?.focus()
    }

    /// An attention edge pill: framed like Go to, and the marker is acknowledged (the user went
    /// there). Selection and keyboard focus stay.
    func jumpToAttention(_ id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        fit(rect, readable: true)
        board.clearAttention(id)
    }

    /// The least pan that shows an object the user just opened (a code tile from an HTML link),
    /// clear of the chrome; nothing when it is already in view.
    func reveal(_ id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        let jump = Layout.reveal(rect, from: currentJump, clear: clearArea, padding: Self.jumpPadding / magnification)
        if jump != currentJump { apply(jump) }
    }

    // MARK: Attention

    /// Shows the board's marker on an object (`Board.attention`): a pulsing ring and message,
    /// plus an edge pill while the object is offscreen. The user acknowledges it (the board
    /// clears it) by selecting it, focusing it, clicking it or its bubble, or looking at it for
    /// a while; the empty canvas's menu clears them all.
    private func showMarker(_ id: ObjectID, message: String?) {
        guard board.objects[id] != nil else { return }
        if let marker = markers[id] {
            marker.message = message
        } else {
            let marker = AttentionMarker(objectID: id, message: message)
            marker.onClick = { [weak self] in
                self?.board.clearAttention(id)
                self?.select(id, extend: false)
            }
            attention.addSubview(marker)
            markers[id] = marker
        }
        layoutPills()
        scheduleLiveness()
    }

    private func hideMarker(_ id: ObjectID) {
        guard let marker = markers.removeValue(forKey: id) else { return }
        marker.removeFromSuperview()
        layoutPills()
        scheduleLiveness()
    }

    /// Markers, blocked terminals' bubbles, and edge pills live in window space: re-placed on
    /// every pan and pinch step (`boundsChanged`), whenever objects move, and on every scene
    /// pass, around their objects' rects as they are on screen now. `PillLayout` keeps them off
    /// each other and off blocked terminals, a bubble off other tiles where it can, and all of
    /// them in the area the chrome leaves clear (`clearArea`, what jumps aim at). An object in
    /// view shows its bubble; one out of view gets an edge pill instead (a blocked terminal's
    /// says why it is blocked, even when it is also marked).
    private func layoutPills() {
        guard !markers.isEmpty || !blocked.isEmpty || !edges.subviews.isEmpty else { return }
        let visible = documentVisibleRect
        let zoom = magnification
        var shownMarkers: [PillLayout.Marker] = []
        var pointers: [ObjectID: AttentionEdgeView.Pointer] = [:]
        func point(_ rect: NSRect) -> NSPoint { edges.convert(NSPoint(x: rect.midX, y: rect.midY), from: document) }
        let views = Array(markers.values) + Array(blocked.values)
        var shownRects: [ObjectIdentifier: NSRect] = [:]
        for view in views {
            guard let rect = docFrame(view.objectID) else {
                view.isHidden = true
                continue
            }
            view.isHidden = !rect.intersects(visible)
            if view.isHidden {
                if view.style == .blocked || pointers[view.objectID] == nil {
                    pointers[view.objectID] = .init(id: view.objectID, message: view.message, style: view.style, target: point(rect))
                }
                continue
            }
            let shown = attention.convert(rect, from: document)
            let titleBar: CGFloat = if let tile = tiles[view.objectID] { TileFrameView.titleHeight * tile.scale * zoom }
                else if groups[view.objectID] != nil { CGFloat(GroupSpec.titleHeight) * zoom } else { 0 }
            let ringWidth = shown.width + 2 * AttentionMarker.inset
            shownRects[ObjectIdentifier(view)] = shown
            shownMarkers.append(.init(id: view.objectID, target: shown, ringInset: AttentionMarker.inset,
                                      size: CGSize(width: PillLayout.bubbleWidth(natural: view.naturalWidth, ringWidth: ringWidth), height: AttentionMarker.bubbleHeight),
                                      titleBar: titleBar, blocked: view.style == .blocked))
        }
        let onScreen = tiles.values.filter { $0.frame.intersects(visible) }.map { (id: $0.objectID, rect: attention.convert($0.frame, from: document)) }
        let clear = clearArea
        let placement = PillLayout.place(markers: shownMarkers, edges: pointers.values.map { .init(id: $0.id, target: $0.target, size: AttentionEdgeView.size(for: $0.message, style: $0.style)) },
                                         tiles: onScreen, clear: clear)
        for view in views {
            let bubble = view.style == .blocked ? placement.blocked[view.objectID] : placement.bubbles[view.objectID]
            if let bubble, let shown = shownRects[ObjectIdentifier(view)] { view.place(around: shown, bubble: bubble) }
        }
        edges.show(pointers.values.sorted { $0.id < $1.id }.map { pointer in
            var pointer = pointer
            pointer.frame = placement.edges[pointer.id] ?? .zero
            return pointer
        })
    }

    // MARK: Nothing in view

    /// False while the board has objects but none of them is in the viewport; the window then
    /// offers a way back to them. Kept by the scene pass, reported on change.
    private var contentInView = true
    var onContentInViewChange: ((Bool) -> Void)?

    /// Stops at the first object in view and allocates nothing. Tiles first (their views hold
    /// their frames), then group regions, then drawn objects.
    private func updateContentInView() {
        let visible = documentVisibleRect
        let inView = board.objects.isEmpty
            || tiles.values.contains { $0.frame.intersects(visible) }
            || groups.values.contains { !$0.isHidden && $0.frame.intersects(visible) }
            || board.objects.values.contains { object in
                object.type != .group && tiles[object.id] == nil && docFrame(object.id)?.intersects(visible) == true
            }
        guard inView != contentInView else { return }
        contentInView = inView
        onContentInViewChange?(inView)
    }

    // MARK: Seen

    /// Keyboard focus in a terminal counts as seeing it (the controller also marks the board).
    func terminalFocused(_ id: ObjectID) {
        seenLocally.insert(id)
        board.clearAttention(id)
        scheduleLiveness()
    }

    private func lifecycleChanged(_ terminal: CanvasObject) {
        let lifecycle = terminal.props["lifecycle"]
        // A new `working` report starts a new unseen stretch (Board resets its seen set too).
        if lifecycle?["state"]?.string == LifecycleState.working.rawValue, lifecycle?["seen"]?.bool != true {
            seenLocally.remove(terminal.id)
        }
        // A blocked terminal's ring and bubble come and go with the state, the moment it changes.
        if lifecycle?["state"]?.string == LifecycleState.blocked.rawValue {
            let message = lifecycle?["message"]?.string
            if let view = blocked[terminal.id] {
                guard view.message != message else { return scheduleLiveness() }
                view.message = message
            } else {
                let id = terminal.id
                let view = AttentionMarker(objectID: id, message: message, style: .blocked)
                // Answering is what it needs: clicking the bubble puts the keyboard in the terminal.
                view.onClick = { [weak self] in
                    self?.select(id, extend: false)
                    self?.takeKeyboard(id)
                }
                attention.addSubview(view)
                blocked[id] = view
            }
            layoutPills()
        } else if let view = blocked.removeValue(forKey: terminal.id) {
            view.removeFromSuperview()
            layoutPills()
        }
        scheduleLiveness()
    }

    private func didSee(_ id: ObjectID) {
        if tiles[id]?.content is TerminalTile {
            seenLocally.insert(id)
            board.markSeen(id)
        }
        board.clearAttention(id)
    }

    /// What the user can actually look at now: the key window of the active app, at readable zoom,
    /// with at least half of the object (or half the viewport) on screen.
    private func updateSeen() {
        guard let window, window.isKeyWindow, NSApp.isActive, magnification >= Self.liveThreshold else {
            return seen.update(visible: [])
        }
        let visible = documentVisibleRect
        var candidates = Set(markers.keys)
        for (id, tile) in tiles where tile.content is TerminalTile && !seenLocally.contains(id) {
            let state = board.objects[id]?.props["lifecycle"]?["state"]?.string
            if state == "working" || state == "blocked" || state == "done" { candidates.insert(id) }
        }
        seen.update(visible: candidates.filter { id in
            guard let rect = docFrame(id) else { return false }
            let shown = rect.intersection(visible)
            return !shown.isNull && shown.width * shown.height >= 0.5 * min(rect.width * rect.height, visible.width * visible.height)
        })
    }

    // MARK: Scene pass (zoom LOD, offscreen culling, pills, seen)

    @objc private func boundsChanged() {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("scene.boundsChanged", since: perfStart) }
        // Every pan and pinch step, not coalesced: the grid is one layer move, markers a few.
        updateGrid()
        layoutPills()
        board.activity.viewportChanged(viewport, actor: viewportMover, rev: board.revision)
        scheduleActivitySettle()
        scheduleLiveness()
    }

    // MARK: Viewport state (view.get, board.history)

    /// What the window shows, in canvas coordinates.
    var viewport: Viewport {
        let visible = documentVisibleRect
        return Viewport(rect: Frame(x: visible.minX - CanvasDocumentView.origin.x, y: visible.minY - CanvasDocumentView.origin.y,
                                    w: visible.width, h: visible.height), zoom: magnification)
    }

    var viewState: ViewState {
        ViewState(viewport: viewport, promptTarget: promptTarget, focused: focusedTile, selection: selection.sorted(),
                  enteredGroup: enteredGroup, visible: window?.occlusionState.contains(.visible) ?? false)
    }

    /// Viewport and selection changes are logged once they settle; this makes sure that happens
    /// even if nothing reads the log meanwhile.
    private func scheduleActivitySettle() {
        activitySettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.board.activity.settle() }
        }
        activitySettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityLog.settleInterval + 0.05, execute: work)
    }

    @objc private func magnifyStarted() {
        magnifying = true
    }

    @objc private func magnifyEnded() {
        magnifying = false
        scheduleLiveness()
    }

    /// Coalesces every trigger in one run-loop turn into a single pass.
    private func scheduleLiveness() {
        guard !livenessScheduled else { return }
        livenessScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.livenessScheduled = false
            self.updateScene()
        }
    }

    /// The zoom the last scene pass outside a pinch saw.
    private var settledMagnification: CGFloat = 0

    private func updateScene() {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("scene.pass", since: perfStart) }
        if geometryDirty {
            geometryDirty = false
            objectsMoved()
        }
        // Mid-pinch, LOD flips wait for the gesture to end.
        if !magnifying {
            let scale = magnification
            for tile in tiles.values {
                tile.setLive(shouldBeLive(tile, scale: scale))
                tile.zoomedOut = scale * tile.scale < Self.liveThreshold
            }
            // A web page's viewport follows its view's device-pixel size (`BrowserTile.webViewFrame`).
            if scale != settledMagnification {
                settledMagnification = scale
                for tile in tiles.values { (tile.content as? BrowserTile)?.zoomChanged() }
            }
        }
        layoutPills()
        updateSeen()
        updateContentInView()
    }

    /// Live: readable at `scale` (a scaled-up tile's content is bigger on screen, so it stays live
    /// further out) and near the viewport; a live tile stays live a little further out and zoomed
    /// out (hysteresis), so small pans and zooms don't swap it back and forth.
    private func shouldBeLive(_ tile: TileFrameView, scale: CGFloat) -> Bool {
        let margin = tile.isLive ? Self.cardMargin : Self.liveMargin
        let readable = scale * tile.scale >= tile.content.liveZoom * (tile.isLive ? Self.cardHysteresis : 1)
        return readable && tile.frame.intersects(documentVisibleRect.insetBy(dx: -margin, dy: -margin))
    }

    // MARK: Hit testing for mentions

    /// The tile under a window point, and that point in the tile content's coordinates.
    func tile(atWindowPoint point: NSPoint) -> (TileFrameView, NSPoint)? {
        let docPoint = document.convert(point, from: nil)
        let hit = tiles.values.filter { $0.frame.contains(docPoint) }.max { lhs, rhs in
            (document.subviews.firstIndex(of: lhs) ?? 0) < (document.subviews.firstIndex(of: rhs) ?? 0)
        }
        guard let hit else { return nil }
        return (hit, hit.content.convert(point, from: nil))
    }

    func showOutline(_ rect: NSRect?, in tile: TileFrameView?) {
        guard let rect, let tile else {
            overlay.outline = nil
            return
        }
        overlay.outline = overlay.convert(rect, from: tile.content)
    }

    func showOutline(docRect: NSRect?) {
        overlay.outline = docRect.map { overlay.convert($0, from: document) }
    }


    func shape(atWindowPoint point: NSPoint) -> ObjectID? {
        shapeHitTest?(document.convert(point, from: nil))
    }
}
