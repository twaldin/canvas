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
        for arrow in objects.values.sorted(by: { $0.id < $1.id }) where arrow.type == .arrow && arrow.id != id {
            guard var spec = ArrowSpec(arrow.props), spec.from.objectID == id || spec.to.objectID == id,
                  let route = arrowRoute?(arrow.id) ?? route(of: spec) else { continue }
            if spec.from.objectID == id { spec.from = .point(route.start) }
            if spec.to.objectID == id { spec.to = .point(route.end) }
            _ = try? update(arrow.id, props: .object(["from": spec.from.json, "to": spec.to.json]))
        }
    }

    /// An arrow's route from object frames alone (no app to ask for what is drawn).
    func route(of spec: ArrowSpec) -> (start: CGPoint, end: CGPoint)? {
        func end(_ binding: ArrowBinding) -> DrawingGeometry.ArrowEnd? {
            switch binding {
            case .point(let point): return .point(point)
            case .object(let id, _, _):
                guard let object = objects[id] else { return nil }
                let isEllipse = object.type == .shape && ShapeSpec(object.props)?.kind == .ellipse
                return .bound(isEllipse ? .ellipse(object.frame.rect) : .rect(object.frame.rect))
            }
        }
        guard let from = end(spec.from), let to = end(spec.to) else { return nil }
        return DrawingGeometry.route(from: from, to: to)
    }
}
