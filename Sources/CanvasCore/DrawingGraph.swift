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
    func detachArrows(from id: ObjectID) {
        let computed = arrowRoute == nil ? routes() : [:]
        for arrow in objects.values.sorted(by: { $0.id < $1.id }) where arrow.type == .arrow && arrow.id != id {
            guard var spec = ArrowSpec(arrow.props), spec.from.objectID == id || spec.to.objectID == id else { continue }
            let drawn = arrowRoute?(arrow.id) ?? computed[arrow.id].map { (start: $0[0], end: $0[$0.count - 1]) }
            guard let route = drawn else { continue }
            if spec.from.objectID == id { spec.from = .point(route.start) }
            if spec.to.objectID == id { spec.to = .point(route.end) }
            _ = try? update(arrow.id, props: .object(["from": spec.from.json, "to": spec.to.json]))
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
    /// what it draws): parallel arrows offset apart, `avoid` routes around blocking objects.
    public func routes() -> [ObjectID: [CGPoint]] {
        let arrows = objects.values.filter { $0.type == .arrow }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        let blockers = objects.values.filter(Self.blocksRoutes)
        var result: [ObjectID: [CGPoint]] = [:]
        for (arrow, spec) in arrows {
            func end(_ binding: ArrowBinding) -> DrawingGeometry.ArrowEnd? {
                switch binding {
                case .point(let point): return .point(point)
                case .object(let id, _, _):
                    guard let object = objects[id] else { return nil }
                    let isEllipse = object.type == .shape && ShapeSpec(object.props)?.kind == .ellipse
                    return .bound(isEllipse ? .ellipse(object.frame.rect) : .rect(object.frame.rect))
                }
            }
            guard let from = end(spec.from), let to = end(spec.to) else { continue }
            let ends = Set([spec.from.objectID, spec.to.objectID].compactMap { $0 })
            let obstacles = spec.route == .avoid ? blockers.filter { !ends.contains($0.id) }.map(\.frame.rect) : []
            result[arrow.id] = DrawingGeometry.path(from: from, to: to, style: spec.route, offset: offsets[arrow.id] ?? 0, obstacles: obstacles)
        }
        return result
    }
}
