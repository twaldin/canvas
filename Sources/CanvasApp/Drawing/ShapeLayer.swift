import AppKit
import CanvasCore

/// The hand-drawn layer: renders `.shape` and `.arrow` objects in document coordinates above the
/// tiles and below the Hyper outline. Only strokes, text, and fills take the mouse (plus the whole
/// canvas while a drawing tool is active); everything else passes through to the tiles beneath.
/// All changes go through `board.create`/`board.update` as the user, so undo and persistence apply.
@MainActor
final class ShapeLayer: NSView {
    enum Tool: String, CaseIterable {
        case select, rect, ellipse, arrow, text, ink

        var key: String {
            switch self {
            case .select: "v"
            case .rect: "r"
            case .ellipse: "o"
            case .arrow: "a"
            case .text: "t"
            case .ink: "p"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .rect: "rectangle"
            case .ellipse: "circle"
            case .arrow: "arrow.up.right"
            case .text: "textformat"
            case .ink: "scribble"
            }
        }

        var title: String {
            switch self {
            case .select: "Select"
            case .rect: "Rectangle"
            case .ellipse: "Ellipse"
            case .arrow: "Arrow"
            case .text: "Text"
            case .ink: "Draw"
            }
        }
    }

    unowned let canvas: CanvasView
    var board: Board { canvas.board }

    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            cancelGesture()
            // Resize handles show only with the select tool.
            for item in resizable { invalidate(item.frame.insetBy(dx: -handleSize, dy: -handleSize)) }
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    /// Palette name for new objects; nil is the default ink.
    var color: String? { didSet { onToolChange?() } }
    var fill: ShapeSpec.Fill = .none { didSet { onToolChange?() } }
    var onToolChange: (() -> Void)?

    private(set) var items: [ObjectID: DrawnItem] = [:]
    /// Item ids in paint order (ascending z); rebuilt lazily after inserts and z changes.
    private var paintOrder: [ObjectID] = []
    private var paintOrderStale = true
    /// Arrows bound to each object, so a move re-routes only those.
    private var arrowsBound: [ObjectID: Set<ObjectID>] = [:]
    /// Selection-drag preview from the scene: these drawn objects are painted offset.
    private var dragPreview: (ids: Set<ObjectID>, offset: NSSize) = ([], .zero)
    /// Hides selection handles while rendering an object image.
    var exporting = false

    var gesture: Gesture?
    var editor: ShapeEditing?

    enum Gesture {
        case box(tool: Tool, start: NSPoint, current: NSPoint)
        case arrow(from: ArrowBinding, start: NSPoint, current: NSPoint)
        case ink(points: [InkPoint], pressured: Bool)
        case resize(id: ObjectID, anchor: NSPoint, frame: NSRect)
    }

    // MARK: Install

    /// Adds the layer to `canvas` (above its tiles), its toolbar to `container`, and sets the
    /// canvas' drawn-object seams.
    @discardableResult
    static func install(on canvas: CanvasView, toolbarIn container: NSView) -> ShapeLayer {
        let layer = ShapeLayer(canvas: canvas)
        canvas.installShapeLayer(layer)
        canvas.shapeHitTest = { [unowned layer] point in layer.item(at: point)?.object.id }
        canvas.shapeOutline = { [unowned layer] id in layer.outlineRect(id) }
        canvas.drawingOwnsPoint = { [unowned layer] point in layer.ownsPoint(point) }
        canvas.onSelectionChange = { [unowned layer] in layer.selectionChanged() }
        canvas.onSelectionDrag = { [unowned layer] ids, offset in layer.previewDrag(ids, offset: offset) }
        canvas.moveProps = { object, dx, dy in ShapeLayer.moveProps(object, dx: dx, dy: dy) }
        let toolbar = DrawingToolbar(layer: layer)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            toolbar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return layer
    }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.document.bounds)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for object in board.snapshot.objects { refresh(object) }
        // Tiles move live while dragged but commit their frame only on drop; follow them live.
        NotificationCenter.default.addObserver(self, selector: #selector(viewFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func viewFrameChanged(_ note: Notification) {
        guard let tile = note.object as? TileFrameView, tile.superview === canvas.document else { return }
        reroute(boundTo: tile.objectID)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Coordinates

    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height)
    }

    static func docPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x + CanvasDocumentView.origin.x, y: point.y + CanvasDocumentView.origin.y)
    }

    static func canvasPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x - CanvasDocumentView.origin.x, y: point.y - CanvasDocumentView.origin.y)
    }

    /// A few screen points, in document points at the current zoom.
    var tolerance: CGFloat { 6 / max(canvas.magnification, 0.1) }

    // MARK: Board events

    func apply(_ event: BoardEvent) {
        switch event {
        case .objectCreated(let object), .objectUpdated(let object):
            refresh(object)
            reroute(boundTo: object.id)
        case .objectDeleted(let id):
            if let item = items.removeValue(forKey: id) {
                invalidate(item)
                paintOrderStale = true
                if let spec = item.arrow?.spec { unbind(arrow: id, spec) }
            }
            // Arrows bound to a deleted object keep their last route; undo re-binds them.
        default:
            break
        }
    }

    /// Rebuild one drawn object's geometry from its latest revision.
    func refresh(_ object: CanvasObject, frameOverride: NSRect? = nil) {
        let old = items[object.id]
        switch object.type {
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return }
            items[object.id] = DrawnItem.shape(object, spec, frame: frameOverride ?? Self.docRect(object.frame))
        case .arrow:
            guard let spec = ArrowSpec(object.props) else { return }
            if let oldSpec = old?.arrow?.spec { unbind(arrow: object.id, oldSpec) }
            for id in [spec.from.objectID, spec.to.objectID].compactMap({ $0 }) { arrowsBound[id, default: []].insert(object.id) }
            items[object.id] = routed(object, spec, previous: old)
        default:
            return
        }
        if let old { invalidate(old) }
        if old?.object.z != object.z || old == nil { paintOrderStale = true }
        if let item = items[object.id] { invalidate(item) }
    }

    private func unbind(arrow id: ObjectID, _ spec: ArrowSpec) {
        for bound in [spec.from.objectID, spec.to.objectID].compactMap({ $0 }) {
            arrowsBound[bound]?.remove(id)
            if arrowsBound[bound]?.isEmpty == true { arrowsBound.removeValue(forKey: bound) }
        }
    }

    func reroute(boundTo id: ObjectID) {
        guard let arrows = arrowsBound[id] else { return }
        for arrowID in arrows {
            guard let old = items[arrowID], let spec = old.arrow?.spec else { continue }
            let item = routed(old.object, spec, previous: old)
            guard item.arrow?.start != old.arrow?.start || item.arrow?.end != old.arrow?.end else { continue }
            invalidate(old)
            items[arrowID] = item
            invalidate(item)
        }
    }

    private func routed(_ object: CanvasObject, _ spec: ArrowSpec, previous: DrawnItem?) -> DrawnItem {
        let shift = dragPreview.ids.contains(object.id) ? dragPreview.offset : .zero
        func end(_ binding: ArrowBinding) -> DrawingGeometry.ArrowEnd? {
            switch binding {
            case .point(let point):
                let doc = Self.docPoint(point)
                return .point(CGPoint(x: doc.x + shift.width, y: doc.y + shift.height))
            case .object(let id, _, _):
                return outline(of: id).map { .bound($0) }
            }
        }
        if let from = end(spec.from), let to = end(spec.to) {
            let route = DrawingGeometry.route(from: from, to: to)
            return DrawnItem.arrow(object, spec, start: route.start, end: route.end)
        }
        // A bound object is gone (deleted, possibly about to be restored by undo): keep the last
        // route, or fall back to the arrow's recorded frame.
        if let previous = previous?.arrow {
            return DrawnItem.arrow(object, spec, start: previous.start, end: previous.end)
        }
        let rect = Self.docRect(object.frame)
        return DrawnItem.arrow(object, spec, start: NSPoint(x: rect.minX, y: rect.minY), end: NSPoint(x: rect.maxX, y: rect.maxY))
    }

    /// Where an arrow bound to `id` attaches, as currently shown (tiles mid-drag included).
    func outline(of id: ObjectID) -> DrawingGeometry.Outline? {
        if let tile = canvas.tiles[id] { return .rect(tile.frame) }
        if let item = items[id], item.shape != nil {
            let offset = dragPreview.ids.contains(id) ? dragPreview.offset : .zero
            let frame = item.frame.offsetBy(dx: offset.width, dy: offset.height)
            return item.shape?.kind == .ellipse ? .ellipse(frame) : .rect(frame)
        }
        guard let object = board.objects[id], object.type != .arrow else { return nil }
        return .rect(Self.docRect(object.frame))
    }

    // MARK: Painting

    private func invalidate(_ item: DrawnItem) {
        invalidate(item.bounds)
        if dragPreview.ids.contains(item.object.id) {
            invalidate(item.bounds.offsetBy(dx: dragPreview.offset.width, dy: dragPreview.offset.height))
        }
        if canvas.selection.contains(item.object.id) { invalidate(item.frame.insetBy(dx: -handleSize, dy: -handleSize)) }
    }

    func invalidate(_ rect: NSRect) {
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    }

    private var ordered: [ObjectID] {
        if paintOrderStale {
            paintOrder = items.values.sorted { ($0.object.z, $0.object.id) < ($1.object.z, $1.object.id) }.map(\.object.id)
            paintOrderStale = false
        }
        return paintOrder
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(DrawingGeometry.strokeWidth)
        for id in ordered {
            guard let item = items[id], editor?.editing != id else { continue }
            let offset = dragPreview.ids.contains(id) && item.shape != nil ? dragPreview.offset : .zero
            guard item.bounds.offsetBy(dx: offset.width, dy: offset.height).intersects(dirtyRect) else { continue }
            if offset != .zero {
                context.saveGState()
                context.translateBy(x: offset.width, y: offset.height)
                item.draw(in: context)
                context.restoreGState()
            } else {
                item.draw(in: context)
            }
        }
        drawGesture(in: context)
        if !exporting { drawHandles(in: context, dirtyRect: dirtyRect) }
    }

    // MARK: Hit testing

    /// Topmost drawn object whose stroke, text, or fill is at a document point.
    func item(at point: NSPoint) -> DrawnItem? {
        let tolerance = self.tolerance
        for id in ordered.reversed() {
            guard let item = items[id], item.bounds.contains(point), item.hits(point, tolerance: tolerance) else { continue }
            return item
        }
        return nil
    }

    func outlineRect(_ id: ObjectID) -> NSRect? {
        guard let item = items[id] else { return nil }
        if item.arrow != nil {
            let union = item.labelRect.map { item.frame.union($0) } ?? item.frame
            return union.insetBy(dx: -4, dy: -4)
        }
        return item.frame
    }

    func ownsPoint(_ point: NSPoint) -> Bool {
        tool != .select || gesture != nil || handle(at: point) != nil || editor?.frame.contains(point) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if tool != .select || handle(at: local) != nil { return self }
        return item(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(visibleRect, cursor: tool == .text ? .iBeam : .crosshair) }
    }

    // MARK: Selection

    let handleSize: CGFloat = 12

    /// Selected rect/ellipse shapes get corner handles for resizing (the scene draws the selection).
    private var resizable: [DrawnItem] {
        canvas.selection.compactMap { items[$0] }.filter { [.rect, .ellipse].contains($0.shape?.kind) }
    }

    private func handleRects(_ frame: NSRect) -> [(corner: NSPoint, opposite: NSPoint, rect: NSRect)] {
        let size = handleSize / max(canvas.magnification, 0.1)
        let corners = [NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.minY),
                       NSPoint(x: frame.maxX, y: frame.maxY), NSPoint(x: frame.minX, y: frame.maxY)]
        return corners.indices.map { index in
            let corner = corners[index]
            return (corner, corners[(index + 2) % 4], NSRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size))
        }
    }

    /// The resize handle under a document point: which shape, and the corner that stays put.
    func handle(at point: NSPoint) -> (id: ObjectID, anchor: NSPoint)? {
        guard tool == .select else { return nil }
        for item in resizable {
            if let handle = handleRects(item.frame).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
                return (item.object.id, handle.opposite)
            }
        }
        return nil
    }

    private func drawHandles(in context: CGContext, dirtyRect: NSRect) {
        guard tool == .select else { return }
        for item in resizable {
            var frame = item.frame
            if case .resize(let id, _, let resized) = gesture, id == item.object.id { frame = resized }
            for handle in handleRects(frame) where handle.rect.intersects(dirtyRect) {
                context.setFillColor(NSColor.white.cgColor)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.5 / max(canvas.magnification, 0.1))
                context.addRect(handle.rect)
                context.drawPath(using: .fillStroke)
            }
        }
        context.setLineWidth(DrawingGeometry.strokeWidth)
    }

    private var selectionShown: Set<ObjectID> = []

    func selectionChanged() {
        let current = Set(canvas.selection.filter { items[$0] != nil })
        for id in current.symmetricDifference(selectionShown) {
            if let item = items[id] { invalidate(item.frame.insetBy(dx: -handleSize, dy: -handleSize)) }
        }
        selectionShown = current
    }

    // MARK: Scene seams

    func previewDrag(_ ids: Set<ObjectID>, offset: NSSize) {
        let drawn = ids.filter { items[$0] != nil }
        let before = dragPreview
        for id in before.ids { if let item = items[id] { invalidate(item) } }
        dragPreview = (drawn, offset)
        for id in drawn { if let item = items[id] { invalidate(item) } }
        // Arrows follow the shapes they are bound to; tiles report their own frame changes.
        for id in before.ids.union(drawn) where items[id]?.shape != nil { reroute(boundTo: id) }
        for id in before.ids.union(drawn) where items[id]?.arrow != nil {
            if let item = items[id], let spec = item.arrow?.spec {
                invalidate(item)
                items[id] = routed(item.object, spec, previous: item)
                invalidate(items[id]!)
            }
        }
    }

    /// A moved arrow carries its free ends along; bound ends follow their objects.
    static func moveProps(_ object: CanvasObject, dx: Double, dy: Double) -> JSONValue? {
        guard object.type == .arrow, var spec = ArrowSpec(object.props) else { return nil }
        func moved(_ binding: ArrowBinding) -> ArrowBinding {
            guard case .point(let point) = binding else { return binding }
            return .point(CGPoint(x: point.x + dx, y: point.y + dy))
        }
        spec.from = moved(spec.from)
        spec.to = moved(spec.to)
        return .object(["from": spec.from.json, "to": spec.to.json])
    }
}
