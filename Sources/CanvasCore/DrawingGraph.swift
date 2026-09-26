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
}
