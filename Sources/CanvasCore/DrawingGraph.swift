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
                if computed == nil { computed = BoardGeometry(objects: objects, labelSizes: [:]).routes() }
                drawn = computed?[arrow.id].map { (start: $0[0], end: $0[$0.count - 1]) }
            }
            guard let route = drawn else { continue }
            if spec.from.objectID == id { spec.from = .point(route.start) }
            if spec.to.objectID == id { spec.to = .point(route.end) }
            _ = try? write(arrow.id, rev: nil, frame: nil, z: nil, props: .object(["from": spec.from.json, "to": spec.to.json]),
                           caller: caller, actor: actor, cause: "bound object \(id) deleted", refitting: [])
        }
    }
}
