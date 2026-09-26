import AppKit
import CanvasCore

/// Pointer and keyboard handling for the drawing tools.
extension ShapeLayer {
    static let minimumDrag: CGFloat = 6
    static let defaultShapeSize = NSSize(width: 160, height: 100)

    // MARK: Keyboard

    /// Tool shortcuts only when the canvas itself has the keyboard, never while a terminal, text
    /// view, or other tile content is first responder.
    var canvasHasKeyboard: Bool {
        guard let window else { return false }
        let responder = window.firstResponder
        if responder == nil || responder === window || responder === self { return true }
        return responder === canvas || responder === canvas.contentView || responder === canvas.document
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, canvasHasKeyboard, editor == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {  // Escape
            cancelGesture()
            tool = .select
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), let match = Tool.allCases.first(where: { $0.key == key }) else { return false }
        tool = match
        return true
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: point), let item = items[handle.id] {
            gesture = .resize(id: handle.id, anchor: handle.anchor, frame: item.frame)
            return
        }
        switch tool {
        case .select:
            guard let item = item(at: point) else { return }
            if event.clickCount >= 2 {
                beginEditing(item.object)
            } else {
                canvas.select(item.object.id, extend: event.modifierFlags.contains(.shift))
            }
        case .rect, .ellipse:
            gesture = .box(tool: tool, start: point, current: point)
        case .arrow:
            gesture = .arrow(from: binding(at: point), start: point, current: point)
        case .ink:
            let pressured = event.subtype == .tabletPoint
            gesture = .ink(points: [inkPoint(point, event, pressured)], pressured: pressured)
        case .text:
            beginText(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let current = gesture else { return }
        let before = gestureBounds
        switch current {
        case .box(let tool, let start, _):
            gesture = .box(tool: tool, start: start, current: point)
        case .arrow(let from, let start, _):
            gesture = .arrow(from: from, start: start, current: point)
        case .ink(var points, let pressured):
            points.append(inkPoint(point, event, pressured))
            gesture = .ink(points: points, pressured: pressured)
        case .resize(let id, let anchor, _):
            let resized = Self.rect(anchor, point)
            gesture = .resize(id: id, anchor: anchor, frame: resized)
            if let object = board.objects[id] {
                refresh(object, frameOverride: resized)
                reroute(boundTo: id)
            }
        }
        invalidate(before.union(gestureBounds))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let finished = gesture else { return }
        invalidate(gestureBounds)
        gesture = nil
        switch finished {
        case .box(let tool, let start, _):
            var rect = Self.rect(start, point)
            if rect.width < Self.minimumDrag && rect.height < Self.minimumDrag {
                rect = NSRect(x: start.x - Self.defaultShapeSize.width / 2, y: start.y - Self.defaultShapeSize.height / 2,
                              width: Self.defaultShapeSize.width, height: Self.defaultShapeSize.height)
            }
            let spec = ShapeSpec(kind: tool == .rect ? .rect : .ellipse, color: color, fill: fill)
            created(board.create(type: .shape, props: spec.props, frame: Self.canvasFrame(rect)))
        case .arrow(let from, let start, _):
            let to = binding(at: point)
            let distinctObjects = from.objectID != nil && to.objectID != nil && from.objectID != to.objectID
            guard hypot(point.x - start.x, point.y - start.y) >= Self.minimumDrag * 2 || distinctObjects else { return }
            createArrow(ArrowSpec(from: from, to: to, color: color))
        case .ink(let points, _):
            createInk(points)
        case .resize(let id, _, let frame):
            if frame.width >= 4, frame.height >= 4, board.objects[id] != nil {
                _ = try? board.update(id, frame: Self.canvasFrame(frame))
            } else if let object = board.objects[id] {
                refresh(object)
                reroute(boundTo: id)
            }
        }
    }

    func cancelGesture() {
        guard gesture != nil else { return }
        invalidate(gestureBounds)
        if case .resize(let id, _, _) = gesture, let object = board.objects[id] {
            gesture = nil
            refresh(object)
            reroute(boundTo: id)
        }
        gesture = nil
    }

    private func inkPoint(_ point: NSPoint, _ event: NSEvent, _ pressured: Bool) -> InkPoint {
        InkPoint(x: point.x, y: point.y, pressure: pressured ? Double(event.pressure) : nil)
    }

    static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// What an arrow end dropped at a document point binds to: the topmost drawn shape whose
    /// frame contains it, else the topmost tile, else the point itself.
    func binding(at point: NSPoint) -> ArrowBinding {
        let shape = items.values
            .filter { $0.shape != nil && $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            .max { $0.object.z < $1.object.z }
        if let shape { return .object(shape.object.id) }
        let document = canvas.document
        let tile = canvas.tiles.values.filter { $0.frame.contains(point) }.max { lhs, rhs in
            (document.subviews.firstIndex(of: lhs) ?? 0) < (document.subviews.firstIndex(of: rhs) ?? 0)
        }
        if let tile { return .object(tile.objectID) }
        return .point(Self.canvasPoint(point))
    }

    // MARK: Creation

    private func created(_ object: CanvasObject) {
        tool = .select
        canvas.select(object.id, extend: false)
    }

    private func createArrow(_ spec: ArrowSpec) {
        let route = DrawingGeometry.route(from: arrowEnd(spec.from), to: arrowEnd(spec.to))
        let rect = Self.rect(route.start, route.end)
        created(board.create(type: .arrow, props: spec.props, frame: Self.canvasFrame(rect)))
    }

    private func arrowEnd(_ binding: ArrowBinding) -> DrawingGeometry.ArrowEnd {
        switch binding {
        case .point(let point): .point(Self.docPoint(point))
        case .object(let id, _, _): outline(of: id).map { .bound($0) } ?? .point(.zero)
        }
    }

    /// Ink keeps its points object-local; the frame is the stroke's painted bounds.
    private func createInk(_ points: [InkPoint]) {
        guard !points.isEmpty else { return }
        let outline = DrawingInk.outline(points)
        let xs = outline.map(\.x) + points.map { CGFloat($0.x) }
        let ys = outline.map(\.y) + points.map { CGFloat($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let bounds = NSRect(x: floor(minX), y: floor(minY), width: ceil(maxX - floor(minX)), height: ceil(maxY - floor(minY)))
        let local = points.map { point in
            InkPoint(x: (point.x - bounds.minX).rounded(toPlaces: 2), y: (point.y - bounds.minY).rounded(toPlaces: 2), pressure: point.pressure.map { $0.rounded(toPlaces: 3) })
        }
        board.create(type: .shape, props: ShapeSpec(kind: .ink, points: local, color: color).props, frame: Self.canvasFrame(bounds))
    }

    // MARK: Gesture preview

    var gestureBounds: NSRect {
        switch gesture {
        case .box(_, let start, let current):
            return Self.rect(start, current).insetBy(dx: -12, dy: -12)
        case .arrow(_, let start, let current):
            return Self.rect(start, current).insetBy(dx: -20, dy: -20)
        case .ink(let points, _):
            let xs = points.map { CGFloat($0.x) }
            let ys = points.map { CGFloat($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -DrawingGeometry.inkSize * 2, dy: -DrawingGeometry.inkSize * 2)
        case .resize(_, _, let frame):
            return frame.insetBy(dx: -handleSize * 2, dy: -handleSize * 2)
        case nil:
            return .zero
        }
    }

    func drawGesture(in context: CGContext) {
        let ink = DrawingStyle.color(color)
        switch gesture {
        case .box(let tool, let start, let current):
            let rect = Self.rect(start, current)
            context.setStrokeColor(ink.cgColor)
            if tool == .rect { context.addRect(rect) } else { context.addEllipse(in: rect) }
            context.strokePath()
        case .arrow(_, let start, let current):
            let target = binding(at: current)
            if let id = target.objectID, let outline = outline(of: id) {
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
                context.addRect(outline.bounds.insetBy(dx: -3, dy: -3))
                context.strokePath()
            }
            let (left, right) = DrawingGeometry.arrowhead(start: start, end: current)
            context.setStrokeColor(ink.cgColor)
            context.move(to: start)
            context.addLine(to: current)
            context.move(to: left)
            context.addLine(to: current)
            context.addLine(to: right)
            context.strokePath()
        case .ink(let points, _):
            if let path = DrawnItem.smoothPolygon(DrawingInk.outline(points, options: {
                var options = DrawingInk.options(for: points)
                options.complete = false
                return options
            }())) {
                context.setFillColor(ink.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        case .resize, nil:
            break
        }
    }

    // MARK: Editing

    func beginText(at point: NSPoint) {
        editor?.commit()
        let editor = ShapeTextEditor(layer: self, origin: point, editing: nil, text: "")
        attach(editor)
    }

    /// Double-click: text shapes and shape labels edit in place; arrows edit label and relation.
    func beginEditing(_ object: CanvasObject) {
        editor?.commit()
        switch object.type {
        case .arrow:
            guard let item = items[object.id], let arrow = item.arrow else { return }
            attach(ArrowLabelEditor(layer: self, arrow: object, spec: arrow.spec, at: NSPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)))
        case .shape:
            guard let spec = ShapeSpec(object.props), spec.kind != .ink else { return }
            let frame = Self.docRect(object.frame)
            attach(ShapeTextEditor(layer: self, origin: frame.origin, editing: object, text: spec.text ?? ""))
        default:
            break
        }
    }

    private func attach(_ editor: ShapeEditing) {
        self.editor = editor
        editor.begin()
        if let id = editor.editing, let item = items[id] { invalidate(item.bounds) }
    }

    /// Called by an editor after it committed or cancelled.
    func editorEnded(_ editor: ShapeEditing) {
        guard self.editor === editor else { return }
        self.editor = nil
        if let id = editor.editing, let item = items[id] { invalidate(item.bounds) }
        if tool == .text { tool = .select }
    }
}

private extension Double {
    /// Ink points are stored in props; two decimals is well below a device pixel.
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
