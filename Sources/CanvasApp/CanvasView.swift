import AppKit
import CanvasCore

/// Flipped, very large document; canvas coordinates are offset so (0,0) sits in the middle.
/// Mouse input that reaches it landed on empty canvas (marquee, context menu); it also takes
/// keyboard focus for Esc/⌫/⌘A when no terminal holds it.
final class CanvasDocumentView: NSView {
    static let extent: CGFloat = 200_000
    static let origin = NSPoint(x: extent / 2, y: extent / 2)

    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Canvas gestures work on the first click into an inactive window, like any canvas app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        // Dot grid: 2-point dots at least 16 points apart on screen, whatever the zoom. Drawn as one
        // path: AppKit records view drawing into display lists, and a rect fill per dot at 10% zoom
        // was ~100k retained entries.
        let scale = max(convert(NSSize(width: 1, height: 0), to: nil).width, 0.01)
        var spacing: CGFloat = 40
        while spacing * scale < 16 { spacing *= 2 }
        let dot = 2 / scale
        let path = CGMutablePath()
        var x = (dirtyRect.minX / spacing).rounded(.down) * spacing
        while x < dirtyRect.maxX {
            var y = (dirtyRect.minY / spacing).rounded(.down) * spacing
            while y < dirtyRect.maxY {
                path.addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                y += spacing
            }
            x += spacing
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.fillPath()
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
    static let lassoDefaultsKey = "canvas.lassoSelection"

    /// Marquee drags draw a freehand lasso instead of a box (View menu, persisted).
    static var lassoSelection: Bool {
        get { UserDefaults.standard.bool(forKey: lassoDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lassoDefaultsKey) }
    }

    let board: Board
    let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    let overlay = SceneOverlay(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    private let edges = AttentionEdgeView()
    private(set) var tiles: [ObjectID: TileFrameView] = [:]
    private var groups: [ObjectID: GroupView] = [:]
    private var markers: [ObjectID: AttentionMarker] = [:]
    private(set) var selection: Set<ObjectID> = []
    /// The group being worked in: zoomed to, everything else dimmed.
    private(set) var enteredGroup: ObjectID?
    /// Read by drawing-layer extensions (e.g. hiding handles while rendering an object image).
    private(set) var shapeLayer: NSView?

    private var livenessScheduled = false
    private var geometryDirty = false
    private var magnifying = false
    private var appliedScale: CGFloat = 0
    private var move: MoveGesture?
    private var marquee: MarqueeGesture?
    /// A press on a drawn object is tracked here (the event never reaches a view).
    private var shapePress = false
    private var mouseMonitor: Any?
    /// Terminals seen since their agent last started working (mirrors Board's seen set).
    private var seenLocally: Set<ObjectID> = []
    private lazy var seen = SeenTracker { [weak self] id in self?.didSee(id) }

    /// Last terminal that held keyboard focus: where the tray drains and Superwhisper pastes.
    var promptTarget: ObjectID? { didSet { onPromptTargetChange?() } }
    var onPromptTargetChange: (() -> Void)?
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
        addSubview(edges)
        edges.onReveal = { [weak self] id in self?.reveal(id) }
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(magnifyStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didResignActiveNotification, object: nil)
        board.viewportCenter = { [weak self] in self?.viewportCenter() ?? (0, 0) }
        for object in board.snapshot.objects { add(object) }
        restack()
        refreshGroups()
        DispatchQueue.main.async { [weak self] in self?.centerOnContent() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func tile() {
        super.tile()
        edges.frame = bounds
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

    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h + TileFrameView.titleHeight)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height - TileFrameView.titleHeight)
    }

    /// Document rect of a drawn object's frame (no title bar).
    static func drawnRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h)
    }

    func viewportCenter() -> (x: Double, y: Double) {
        let visible = documentVisibleRect
        return (visible.midX - CanvasDocumentView.origin.x, visible.midY - CanvasDocumentView.origin.y)
    }

    /// Where an object is on screen right now, in document coordinates, including an in-flight drag.
    func docFrame(_ id: ObjectID) -> NSRect? {
        if let tile = tiles[id] { return tile.frame }
        if let group = groups[id] { return group.isHidden ? nil : group.frame }
        if let start = move?.drawn[id], let delta = move?.delta { return start.offsetBy(dx: delta.width, dy: delta.height) }
        guard let object = board.objects[id] else { return nil }
        return shapeOutline?(id) ?? Self.drawnRect(object.frame)
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
                let rect = Self.docRect(object.frame)
                if tile.frame != rect { tile.frame = rect }
                let restacks = tile.z != object.z
                tile.update(object)
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
            clearAttention(id)
            seenLocally.remove(id)
            if selection.contains(id) { setSelection(selection.subtracting([id])) }
            scheduleGeometry()
        default: break
        }
    }

    private func add(_ object: CanvasObject) {
        if object.type == .group { return addGroup(object) }
        guard tiles[object.id] == nil, TileFactory.hasTile(object.type) else { return }
        let id = object.id
        let content = TileFactory.make(object, board: board)
        if let terminal = content as? TerminalTile {
            terminal.onTitle = { [weak self] title in self?.tiles[id]?.setTitle(title) }
        }
        let tile = TileFrameView(object: object, content: content, frame: Self.docRect(object.frame))
        tile.onFrameCommit = { [weak self] rect in
            _ = try? self?.board.update(id, frame: Self.canvasFrame(rect))
        }
        tile.onResizing = { [weak self] in self?.objectsMoved() }
        tile.onClose = { [weak self] in self?.delete([id]) }
        tile.onMoveBegan = { [weak self] event in self?.beginMove(event, pressing: id) }
        tile.onMoveDragged = { [weak self] event in self?.dragMove(event) }
        tile.onMoveEnded = { [weak self] event in self?.endMove(event) }
        tile.onTitleDoubleClick = { [weak self] in self?.focus(tile: id) }
        tile.onMenu = { [weak self] in self?.objectMenu(for: id) }
        document.addSubview(tile, positioned: .below, relativeTo: shapeLayer ?? overlay)
        tiles[id] = tile
        if object.type == .terminal { lifecycleChanged(object) }
        scheduleLiveness()
    }

    private func addGroup(_ object: CanvasObject) {
        guard groups[object.id] == nil else { return }
        let id = object.id
        let view = GroupView(object: object)
        view.scale = magnification
        view.onPress = { [weak self] event in self?.beginMove(event, pressing: id) }
        view.onDrag = { [weak self] event in self?.dragMove(event) }
        view.onRelease = { [weak self] event in self?.endMove(event) }
        view.onEnter = { [weak self] in self?.enter(group: id) }
        view.onMenu = { [weak self] in self?.groupMenu(for: id) }
        document.addSubview(view, positioned: .below, relativeTo: nil)
        groups[id] = view
    }

    /// Orders document subviews: group regions, tiles by `z`, the drawing layer, attention
    /// markers, then the overlay. Reorders in place so tiles never leave the window.
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
        case is AttentionMarker: (3, 0)
        case is SceneOverlay: (4, 0)
        default: (2, 0)
        }
    }

    /// The drawing layer sits above tiles and below markers and the overlay.
    func installShapeLayer(_ view: NSView) {
        shapeLayer = view
        document.addSubview(view, positioned: .below, relativeTo: overlay)
        restack()
    }

    /// Board changes re-lay out what's drawn around objects on the next turn, after every other
    /// consumer of the event (the drawing layer's outlines) has caught up, then re-run culling,
    /// edge chevrons, and seen eligibility, since an object may have moved into or out of view.
    private func scheduleGeometry() {
        geometryDirty = true
        scheduleLiveness()
    }

    /// Geometry changed (moves, resizes, deletes, drags): everything drawn around objects follows.
    private func objectsMoved() {
        refreshRings()
        refreshGroups()
        layoutMarkers()
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
        refreshRings()
        // Selecting a marked object is the user acknowledging it.
        for id in added where markers[id] != nil { clearAttention(id) }
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
            return (object.id, tiles[object.id]?.frame ?? shapeOutline?(object.id) ?? Self.drawnRect(object.frame))
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
            overlay.marquee = path
        } else {
            gesture.points = [gesture.start, point]
            let rect = HyperMonitor.rect(gesture.start, point)
            overlay.marquee = NSBezierPath(rect: rect)
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

    /// One board update per moved object, as one undo step; groups keep their stored bounds.
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
            for group in groups.values where !moved.isDisjoint(with: group.members) {
                if let bounds = memberBounds(group.members) { _ = try? board.update(group.objectID, frame: bounds) }
            }
        }
    }

    // MARK: Groups

    /// Canvas-space union of the members' frames (what a group object stores as its frame).
    private func memberBounds(_ members: [ObjectID]) -> Frame? {
        let frames = members.compactMap { board.objects[$0]?.frame }
        guard let first = frames.first else { return nil }
        let minX = frames.map(\.x).min() ?? first.x, minY = frames.map(\.y).min() ?? first.y
        let maxX = frames.map(\.maxX).max() ?? first.maxX, maxY = frames.map(\.maxY).max() ?? first.maxY
        // Tiles draw their title bar above the frame's content height.
        let titled = members.contains { tiles[$0] != nil }
        return Frame(x: minX, y: minY, w: maxX - minX, h: maxY - minY + (titled ? Double(TileFrameView.titleHeight) : 0))
    }

    private func refreshGroups() {
        for group in groups.values {
            let rects = group.members.compactMap { groups[$0] == nil ? docFrame($0) : nil }
            if let region = GroupView.region(around: rects, scale: group.scale) {
                if group.frame != region { group.frame = region }
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
        guard members.count >= 2, let bounds = memberBounds(members) else { return }
        var props: [String: JSONValue] = ["members": .array(members.map(JSONValue.string))]
        if !name.isEmpty { props["name"] = .string(name) }
        let group = board.create(type: .group, props: .object(props), frame: bounds)
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

    /// Deletes objects as one undo step. Closing a terminal ends its zmx session, so ask first,
    /// in a sheet: an app-modal alert would stall every socket request until answered.
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
            for id in terminals { (self.tiles[id]?.content as? TerminalTile)?.killSession() }
            self.remove(ids.filter { self.board.objects[$0] != nil })
        }
    }

    private func remove(_ ids: [ObjectID]) {
        board.transaction {
            for id in ids.sorted() { try? board.delete(id) }
        }
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

    /// A new terminal (at a document point, else beside the viewport center) with keyboard focus.
    func createTerminal(at point: NSPoint? = nil) {
        let size = Board.defaultSize(.terminal)
        let frame = point.map { Frame(x: $0.x - CanvasDocumentView.origin.x, y: $0.y - CanvasDocumentView.origin.y, w: size.w, h: size.h) }
        let object = board.create(type: .terminal, props: .object(["cwd": .string(board.root.path), "command": .array([])]), frame: frame)
        DispatchQueue.main.async { [weak self] in
            (self?.tiles[object.id]?.content as? TerminalTile)?.focus()
        }
    }

    func createNote(at point: NSPoint) {
        let size = Board.defaultSize(.note)
        let frame = Frame(x: point.x - CanvasDocumentView.origin.x, y: point.y - CanvasDocumentView.origin.y, w: size.w, h: size.h)
        let note = board.create(type: .note, props: .object(["markdown": .string("")]), frame: frame)
        setSelection([note.id])
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
        menu.addItem(MenuAction.item("Group Selection", enabled: expandedSelection().count >= 2) { [weak self] in self?.groupSelection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(count > 1 ? "Copy Object IDs" : "Copy Object ID") { [weak self] in self?.copyIDs() })
        return menu
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

    func centerOnContent() {
        let frames = tiles.values.map(\.frame)
        let target = frames.isEmpty ? NSRect(origin: CanvasDocumentView.origin, size: .zero) : frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let visible = documentVisibleRect
        scroll(to: NSPoint(x: target.midX - visible.width / 2, y: target.minY - 40))
    }

    private func scroll(to origin: NSPoint) {
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        scheduleLiveness()
    }

    /// Centers a document rect in the viewport; a rect too big to fit shows its top-left corner.
    private func center(on rect: NSRect) {
        let visible = contentView.bounds.size
        let x = rect.width > visible.width ? rect.minX - 20 : rect.midX - visible.width / 2
        let y = rect.height > visible.height ? rect.minY - 20 : rect.midY - visible.height / 2
        scroll(to: NSPoint(x: x, y: y))
    }

    func zoom(to scale: CGFloat) {
        let visible = documentVisibleRect
        setMagnification(min(maxMagnification, max(minMagnification, scale)), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        scheduleLiveness()
    }

    /// Zooms (at most to 100%) so a document rect fills the viewport, centered.
    func fit(_ rect: NSRect) {
        let padded = rect.insetBy(dx: -60, dy: -60)
        let size = contentView.frame.size
        magnification = min(maxMagnification, max(minMagnification, min(size.width / padded.width, size.height / padded.height)))
        let visible = contentView.bounds.size
        scroll(to: NSPoint(x: padded.midX - visible.width / 2, y: padded.midY - visible.height / 2))
    }

    func zoomToFit() {
        let rects = selectableRects().map(\.rect) + groups.values.filter { !$0.isHidden }.map(\.frame)
        guard let first = rects.first else { return }
        fit(rects.dropFirst().reduce(first) { $0.union($1) })
    }

    /// "Zoom in" on the canvas: this tile at 100%, centered, selected, and focused if it types.
    func focus(tile id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        magnification = 1
        center(on: rect)
        setSelection([id])
        (tiles[id]?.content as? TerminalTile)?.focus()
    }

    /// Scrolls an object into the middle of the viewport at the current zoom.
    func reveal(_ id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        center(on: rect)
    }

    // MARK: Attention

    /// An agent's marker on an object: a pulsing ring and message, plus an edge chevron while the
    /// object is offscreen. Cleared by selecting it, focusing it, or looking at it for a while.
    func raiseAttention(_ id: ObjectID, message: String?) {
        guard board.objects[id] != nil else { return }
        if let marker = markers[id] {
            marker.message = message
        } else {
            let marker = AttentionMarker(objectID: id, message: message)
            marker.scale = magnification
            marker.onClick = { [weak self] in
                self?.clearAttention(id)
                self?.select(id, extend: false)
            }
            document.addSubview(marker, positioned: .below, relativeTo: overlay)
            markers[id] = marker
        }
        layoutMarkers()
        scheduleLiveness()
    }

    func clearAttention(_ id: ObjectID) {
        guard let marker = markers.removeValue(forKey: id) else { return }
        marker.removeFromSuperview()
        scheduleLiveness()
    }

    private func layoutMarkers() {
        for marker in markers.values {
            guard let rect = docFrame(marker.objectID) else { continue }
            marker.place(around: rect)
        }
    }

    private func updateEdges() {
        let visible = documentVisibleRect
        let pointers = markers.values.compactMap { marker -> AttentionEdgeView.Pointer? in
            guard let rect = docFrame(marker.objectID), !rect.intersects(visible) else { return nil }
            return .init(id: marker.objectID, message: marker.message, target: edges.convert(NSPoint(x: rect.midX, y: rect.midY), from: document))
        }
        edges.show(pointers.sorted { $0.id < $1.id })
    }

    // MARK: Seen

    /// Keyboard focus in a terminal counts as seeing it (the controller also marks the board).
    func terminalFocused(_ id: ObjectID) {
        seenLocally.insert(id)
        clearAttention(id)
        scheduleLiveness()
    }

    private func lifecycleChanged(_ terminal: CanvasObject) {
        // A new `working` report starts a new unseen stretch (Board resets its seen set too).
        if terminal.props["lifecycle"]?["state"]?.string == LifecycleState.working.rawValue,
           terminal.props["lifecycle"]?["seen"]?.bool != true {
            seenLocally.remove(terminal.id)
        }
        scheduleLiveness()
    }

    private func didSee(_ id: ObjectID) {
        if tiles[id]?.content is TerminalTile {
            seenLocally.insert(id)
            board.markSeen(id)
        }
        clearAttention(id)
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

    // MARK: Scene pass (zoom LOD, offscreen culling, chrome scale, chevrons, seen)

    @objc private func boundsChanged() {
        scheduleLiveness()
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

    private func updateScene() {
        if geometryDirty {
            geometryDirty = false
            objectsMoved()
        }
        // Mid-pinch, LOD flips and chrome rescaling wait for the gesture to end.
        if !magnifying {
            let scale = magnification
            let readable = scale >= Self.liveThreshold
            let visible = documentVisibleRect.insetBy(dx: -300, dy: -300)
            for tile in tiles.values {
                tile.setLive(readable && tile.frame.intersects(visible))
            }
            if scale != appliedScale {
                appliedScale = scale
                // Grid spacing and dot size depend on the zoom.
                document.needsDisplay = true
                overlay.scale = scale
                for group in groups.values { group.scale = scale }
                for marker in markers.values { marker.scale = scale }
                refreshGroups()
                layoutMarkers()
                refreshFocusHoles()
            }
        }
        updateEdges()
        updateSeen()
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
