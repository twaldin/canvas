import CoreGraphics
import Foundation

/// Spatial structure a drawn object carries: what it encloses and the arrows drawn inside it.
/// Shared by `object.get --as graph` and the mention context so both describe the same thing.
extension Board {
    /// Objects (other than arrows and `object` itself) lying wholly inside `object`'s frame.
    public func enclosed(by object: CanvasObject) -> [CanvasObject] {
        objects.values
            .filter { $0.id != object.id && $0.type != .arrow && object.frame.contains($0.frame) }
            .sorted { $0.id < $1.id }
    }

    /// Arrows drawn inside `object`: each end is either a free point inside its frame or bound to
    /// an object it encloses. Arrows bound to `object` itself are its own in/out arrows, not these.
    public func arrows(enclosedBy object: CanvasObject) -> [(arrow: CanvasObject, spec: ArrowSpec)] {
        let inside = Set(enclosed(by: object).map(\.id))
        let region = object.frame.rect
        func within(_ binding: ArrowBinding) -> Bool {
            switch binding {
            case .object(let id, _, _): inside.contains(id)
            case .point(let point): region.contains(point)
            }
        }
        return objects.values
            .filter { $0.type == .arrow && $0.id != object.id }
            .compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
            .filter { within($0.spec.from) && within($0.spec.to) }
            .sorted { $0.arrow.id < $1.arrow.id }
    }

    /// Before `id` is deleted, every arrow bound to it gets a free end where it last attached, so
    /// the arrow keeps its drawn direction (also after a reload) and its other end keeps routing.
    /// The rewrite is a cascade of the delete, credited to whoever deleted.
    func detachArrows(from id: ObjectID, actor: ActivityActor, caller: ObjectID?) {
        // Without the app's drawn routes, route from frames, once, and only when an arrow needs it.
        var computed: [ObjectID: [CGPoint]]?
        for arrow in objects.values.sorted(by: { $0.id < $1.id }) where arrow.type == .arrow && arrow.id != id {
            guard var spec = ArrowSpec(arrow.props), spec.from.objectID == id || spec.to.objectID == id else { continue }
            var drawn = arrowRoute?(arrow.id)
            if drawn == nil {
                if computed == nil { computed = routes() }
                drawn = computed?[arrow.id].map { (start: $0[0], end: $0[$0.count - 1]) }
            }
            guard let route = drawn else { continue }
            if spec.from.objectID == id { spec.from = .point(route.start) }
            if spec.to.objectID == id { spec.to = .point(route.end) }
            _ = try? write(arrow.id, rev: nil, frame: nil, z: nil, props: .object(["from": spec.from.json, "to": spec.to.json]),
                           caller: caller, actor: actor, cause: "bound object \(id) deleted", refitting: [])
        }
    }

    /// Whether arrows route around this object and count as crossing it: tiles, text, and filled
    /// shapes. Unfilled rects and ellipses are regions drawn around things; ink, arrows, and
    /// groups never block.
    public static func blocksRoutes(_ object: CanvasObject) -> Bool {
        switch object.type {
        case .terminal, .browser, .code, .note, .html: return true
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return false }
            return spec.kind == .text || (spec.kind != .ink && spec.fill != .none)
        case .arrow, .group: return false
        }
    }

    /// Every arrow's routed polyline from object frames alone (the app routes the same way from
    /// what it draws): parallel arrows offset apart, `avoid` routes around blocking objects, an
    /// end bound to `lines` of a code tile at that line's row (`CodeMetrics.lineY`, freshly
    /// aimed; `rows` gives a tile's visual rows when known, else one row per line).
    public func routes(rows: [ObjectID: CodeRows] = [:]) -> [ObjectID: [CGPoint]] {
        let arrows = objects.values.filter { $0.type == .arrow }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        let blockers = objects.values.filter(Self.blocksRoutes)
        var result: [ObjectID: [CGPoint]] = [:]
        for (arrow, spec) in arrows {
            guard let from = arrowEnd(spec.from, rows: rows), let to = arrowEnd(spec.to, rows: rows) else { continue }
            let ends = Set([spec.from.objectID, spec.to.objectID].compactMap { $0 })
            let obstacles = spec.route == .avoid ? blockers.filter { !ends.contains($0.id) }.map(\.frame.rect) : []
            result[arrow.id] = DrawingGeometry.path(from: from, to: to, style: spec.route, offset: offsets[arrow.id] ?? 0, obstacles: obstacles)
        }
        return result
    }

    /// What a binding attaches to: a point, an object's frame (an ellipse's curve), or the row
    /// of the first of `lines` on a code tile. Nil when the object is gone.
    func arrowEnd(_ binding: ArrowBinding, rows: [ObjectID: CodeRows]) -> DrawingGeometry.ArrowEnd? {
        switch binding {
        case .point(let point): return .point(point)
        case .object(let id, let lines, _):
            guard let object = objects[id] else { return nil }
            if let lines, object.type == .code {
                return .row(object.frame.rect, y: CodeMetrics.lineY(line: lines.start, frame: object.frame, props: object.props, rows: rows[id]))
            }
            let isEllipse = object.type == .shape && ShapeSpec(object.props)?.kind == .ellipse
            return .bound(isEllipse ? .ellipse(object.frame.rect) : .rect(object.frame.rect))
        }
    }

    /// Where each captioned arrow's label sits along `routes`, as the drawing layer places it
    /// (`DrawingStyle.arrowLabel`, `DrawingGeometry.labelRect`): beside the route, clear of
    /// blocking objects where it can be.
    public func labelRects(routes: [ObjectID: [CGPoint]]) -> [ObjectID: CGRect] {
        let arrows = objects.values.filter { $0.type == .arrow }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        let blockers = objects.values.filter(Self.blocksRoutes).map(\.frame.rect)
        var result: [ObjectID: CGRect] = [:]
        for (arrow, spec) in arrows {
            guard let path = routes[arrow.id], let label = DrawingStyle.arrowLabel(spec) else { continue }
            result[arrow.id] = DrawingGeometry.labelRect(along: path, size: label.size, side: offsets[arrow.id] ?? 0, obstacles: blockers)
        }
        return result
    }
}
