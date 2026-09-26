import AppKit
import CanvasCore

/// Flipped, very large document; canvas coordinates are offset so (0,0) sits in the middle.
final class CanvasDocumentView: NSView {
    static let extent: CGFloat = 200_000
    static let origin = NSPoint(x: extent / 2, y: extent / 2)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        // Dot grid every 40 points.
        let spacing: CGFloat = 40
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        var x = (dirtyRect.minX / spacing).rounded(.down) * spacing
        while x < dirtyRect.maxX {
            var y = (dirtyRect.minY / spacing).rounded(.down) * spacing
            while y < dirtyRect.maxY {
                NSRect(x: x - 1, y: y - 1, width: 2, height: 2).fill()
                y += spacing
            }
            x += spacing
        }
    }
}

/// Transparent overlay above the tiles for Hyper hover outlines; never takes clicks.
final class OutlineOverlay: NSView {
    var outline: NSRect? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let outline else { return }
        let path = NSBezierPath(roundedRect: outline.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        NSColor.systemPurple.setStroke()
        NSColor.systemPurple.withAlphaComponent(0.08).setFill()
        path.fill()
        path.stroke()
    }
}

/// The pan/zoom scene for one board: tiles are real NSViews positioned by object frames.
/// Zoom is capped at 100%; below `liveThreshold` tiles become cards and release resources.
@MainActor
final class CanvasView: NSScrollView {
    static let liveThreshold: CGFloat = 0.3

    let board: Board
    let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    let overlay = OutlineOverlay(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    private(set) var tiles: [ObjectID: TileFrameView] = [:]
    private(set) var selection: Set<ObjectID> = []
    private var livenessScheduled = false

    /// Last terminal that held keyboard focus: where the tray drains and Superwhisper pastes.
    var promptTarget: ObjectID? { didSet { onPromptTargetChange?() } }
    var onPromptTargetChange: (() -> Void)?

    init(board: Board) {
        self.board = board
        super.init(frame: .zero)
        documentView = document
        document.addSubview(overlay)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 1.0
        drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        board.viewportCenter = { [weak self] in self?.viewportCenter() ?? (0, 0) }
        for object in board.snapshot.objects { add(object) }
        DispatchQueue.main.async { [weak self] in self?.centerOnContent() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Coordinates

    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h + TileFrameView.titleHeight)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height - TileFrameView.titleHeight)
    }

    func viewportCenter() -> (x: Double, y: Double) {
        let visible = documentVisibleRect
        return (visible.midX - CanvasDocumentView.origin.x, visible.midY - CanvasDocumentView.origin.y)
    }

    func centerOnContent() {
        let frames = tiles.values.map(\.frame)
        let target = frames.isEmpty ? NSRect(origin: CanvasDocumentView.origin, size: .zero) : frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let visible = documentVisibleRect
        let point = NSPoint(x: target.midX - visible.width / 2, y: target.minY - 40)
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
        scheduleLiveness()
    }

    // MARK: Reconciliation

    func apply(_ event: BoardEvent) {
        switch event {
        case .objectCreated(let object): add(object)
        case .objectUpdated(let object):
            guard let tile = tiles[object.id] else { return add(object) }
            let rect = Self.docRect(object.frame)
            if tile.frame != rect { tile.frame = rect }
            tile.update(object)
        case .objectDeleted(let id):
            tiles.removeValue(forKey: id)?.removeFromSuperview()
            selection.remove(id)
        default: break
        }
    }

    private func add(_ object: CanvasObject) {
        guard tiles[object.id] == nil, TileFactory.hasTile(object.type) else { return }
        let content = TileFactory.make(object, board: board)
        if let terminal = content as? TerminalTile {
            terminal.onTitle = { [weak self] title in self?.tiles[object.id]?.setTitle(title) }
        }
        let tile = TileFrameView(object: object, content: content, frame: Self.docRect(object.frame))
        tile.onFrameCommit = { [weak self] rect in
            guard let self else { return }
            _ = try? self.board.update(object.id, frame: Self.canvasFrame(rect))
        }
        tile.onClose = { [weak self] in self?.close(object.id) }
        tile.onSelect = { [weak self] extend in self?.select(object.id, extend: extend) }
        document.addSubview(tile, positioned: .below, relativeTo: overlay)
        tiles[object.id] = tile
        scheduleLiveness()
    }

    func close(_ id: ObjectID) {
        guard let tile = tiles[id] else { return }
        if let terminal = tile.content as? TerminalTile {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "Its zmx session (and anything running in it) will be ended."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            terminal.killSession()
        }
        try? board.delete(id)
    }

    func select(_ id: ObjectID, extend: Bool) {
        if !extend {
            for other in selection where other != id { tiles[other]?.isSelected = false }
            selection = [id]
        } else if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        tiles[id]?.isSelected = selection.contains(id)
        if let tile = tiles[id], let terminal = tile.content as? TerminalTile {
            terminal.focus()
        }
    }

    // MARK: Liveness (zoom LOD + offscreen culling)

    @objc private func boundsChanged() {
        scheduleLiveness()
    }

    private func scheduleLiveness() {
        guard !livenessScheduled else { return }
        livenessScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.livenessScheduled = false
            self.updateLiveness()
        }
    }

    private func updateLiveness() {
        let readable = magnification >= Self.liveThreshold
        let visible = documentVisibleRect.insetBy(dx: -300, dy: -300)
        for tile in tiles.values {
            tile.setLive(readable && tile.frame.intersects(visible))
        }
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

    /// Tiles and drawn objects wholly inside a document rect.
    func objects(inDocRect rect: NSRect) -> [ObjectID] {
        board.objects.values.filter { object in
            let frame = tiles[object.id]?.frame ?? NSRect(x: object.frame.x + CanvasDocumentView.origin.x, y: object.frame.y + CanvasDocumentView.origin.y, width: object.frame.w, height: object.frame.h)
            return object.type != .group && rect.contains(frame)
        }.map(\.id).sorted()
    }

    // MARK: Drawn objects (installed by the drawing layer)

    /// The shape or arrow drawn at a document point. Only strokes, text, and fills hit, so an
    /// empty shape interior never blocks the tiles beneath; drawn objects sit above tiles.
    var shapeHitTest: ((NSPoint) -> ObjectID?)?
    /// Document-space outline of a drawn object, for hover highlights.
    var shapeOutline: ((ObjectID) -> NSRect?)?

    func shape(atWindowPoint point: NSPoint) -> ObjectID? {
        shapeHitTest?(document.convert(point, from: nil))
    }
}
