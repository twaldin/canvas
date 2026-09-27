import Foundation

/// A board's authored order, such as a walkthrough's stops: arrows with `relation: "next_step"`
/// from one object to the next. ⌥⌘→ follows the selected object's outgoing one and ⌥⌘← its
/// incoming one, before the nearest tile that way (`Layout.neighbor`), so an agent can lay a
/// walkthrough out however reads best and still have it stepped in order.
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
        var next: [CanvasObject] = [], previous: [CanvasObject] = []
        for arrow in objects.values where arrow.type == .arrow && arrow.props["relation"]?.string == relation {
            guard let from = arrow.props["from"].flatMap(ArrowBinding.init)?.objectID,
                  let to = arrow.props["to"].flatMap(ArrowBinding.init)?.objectID, from != to,
                  let source = objects[from], let target = objects[to] else { continue }
            if from == id { next.append(target) }
            if to == id { previous.append(source) }
        }
        let candidates = forward ? next : previous
        if let first = candidates.min(by: { ($0.frame.y, $0.frame.x, $0.id) < ($1.frame.y, $1.frame.x, $1.id) }) { return .to(first.id) }
        return next.isEmpty && previous.isEmpty ? .none : .end
    }
}
