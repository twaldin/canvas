import CoreGraphics
import Foundation

/// A board's authored order, such as a walkthrough's stops: arrows with `relation: "next_step"`
/// from one object to the next. ⌥⌘→ follows the selected object's outgoing one and ⌥⌘← its
/// incoming one, before the nearest tile that way (`Layout.neighbor`), so an agent can lay a
/// walkthrough out however reads best and still have it stepped in order. ⌥⌘→ from a group
/// holding stops, or with nothing selected, starts a walkthrough at its first stop (`start`).
public enum StepOrder {
    public static let relation = "next_step"

    public enum Step: Equatable, Sendable {
        /// The next (or previous) stop.
        case to(ObjectID)
        /// The object is a stop, but the sequence ends there this way.
        case end
        /// The object is in no sequence: geometry decides.
        case none
    }

    /// Where a step from `id` goes: `forward` along its outgoing `next_step` arrows, else back
    /// along its incoming ones. With several, the stop that comes first in reading order (top to
    /// bottom, then left to right). Arrows with an end that is a free point or an object no
    /// longer on the board don't count, nor does one from an object to itself.
    public static func step(from id: ObjectID, forward: Bool, in objects: [ObjectID: CanvasObject]) -> Step {
        let links = links(in: objects)
        let next = links.filter { $0.from == id }.compactMap { objects[$0.to] }
        let previous = links.filter { $0.to == id }.compactMap { objects[$0.from] }
        if let first = (forward ? next : previous).min(by: readingOrder) { return .to(first.id) }
        return next.isEmpty && previous.isEmpty ? .none : .end
    }

    /// Where ⌥⌘→ starts a walkthrough when the step source isn't a stop itself. From a group
    /// (`id`) holding stops, directly or in nested groups (the walkthrough an agent grouped and
    /// marked "Start here"): its first stop. From nothing (`id` nil): the first stop of the
    /// walkthrough nearest `center` (the viewport's; zero distance inside the bounds of its
    /// stops, ties in reading order). A first stop is one no arrow steps to, the first in reading
    /// order; a sequence that is only a loop starts at its stop first in reading order. Nil when
    /// there is no such walkthrough: geometry decides.
    public static func start(from id: ObjectID?, center: CGPoint, in objects: [ObjectID: CanvasObject]) -> ObjectID? {
        let links = links(in: objects)
        var stops = Set(links.flatMap { [$0.from, $0.to] })
        if let id {
            guard objects[id]?.type == .group else { return nil }
            stops.formIntersection(members(of: id, in: objects))
        }
        // Each walkthrough: the stops linked to one another either way.
        var walkthroughs: [[ObjectID]] = [], placed = Set<ObjectID>()
        for stop in stops.sorted() where !placed.contains(stop) {
            var component: [ObjectID] = [], queue = [stop]
            placed.insert(stop)
            while let current = queue.popLast() {
                component.append(current)
                for link in links where link.from == current || link.to == current {
                    let other = link.from == current ? link.to : link.from
                    if stops.contains(other), placed.insert(other).inserted { queue.append(other) }
                }
            }
            walkthroughs.append(component)
        }
        func first(_ component: [ObjectID]) -> CanvasObject? {
            let members = Set(component)
            let stepped = Set(links.filter { members.contains($0.from) && members.contains($0.to) }.map(\.to))
            let stops = component.compactMap { objects[$0] }
            return stops.filter { !stepped.contains($0.id) }.min(by: readingOrder) ?? stops.min(by: readingOrder)
        }
        func distance(_ component: [ObjectID]) -> CGFloat {
            let rects = component.compactMap { objects[$0]?.frame.rect }
            guard let bounds = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return .infinity }
            return hypot(max(bounds.minX - center.x, 0, center.x - bounds.maxX), max(bounds.minY - center.y, 0, center.y - bounds.maxY))
        }
        let ranked = walkthroughs.compactMap { component in first(component).map { (stop: $0, distance: distance(component)) } }
        return ranked.min { ($0.distance, $0.stop.frame.y, $0.stop.frame.x, $0.stop.id) < ($1.distance, $1.stop.frame.y, $1.stop.frame.x, $1.stop.id) }?.stop.id
    }

    /// The `next_step` arrows between two different objects on the board.
    private static func links(in objects: [ObjectID: CanvasObject]) -> [(from: ObjectID, to: ObjectID)] {
        objects.values.compactMap { arrow in
            guard arrow.type == .arrow, arrow.props["relation"]?.string == relation,
                  let from = arrow.props["from"].flatMap(ArrowBinding.init)?.objectID,
                  let to = arrow.props["to"].flatMap(ArrowBinding.init)?.objectID, from != to,
                  objects[from] != nil, objects[to] != nil else { return nil }
            return (from, to)
        }
    }

    /// A group's members, and those of the groups among them.
    private static func members(of group: ObjectID, in objects: [ObjectID: CanvasObject]) -> Set<ObjectID> {
        var found = Set<ObjectID>(), queue = [group]
        while let id = queue.popLast() {
            guard let object = objects[id], object.type == .group, let spec = GroupSpec(object.props) else { continue }
            for member in spec.members where found.insert(member).inserted { queue.append(member) }
        }
        return found
    }

    private static func readingOrder(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
        (a.frame.y, a.frame.x, a.id) < (b.frame.y, b.frame.x, b.id)
    }
}
