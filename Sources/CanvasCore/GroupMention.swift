import CoreGraphics
import Foundation

/// A titled group as one mention: what a Hyper-click on its title or empty interior stages,
/// and ⇧⌘M with the group selected. Its members, named by its title.
public enum GroupMention {
    /// How far (window points) the pointer moves before a Hyper press on the canvas away from
    /// tiles and drawings is a marquee drag, not a click on the group under it.
    public static let dragThreshold: CGFloat = 4

    /// A group's region as the canvas shows it now.
    public struct Region: Sendable {
        public var id: ObjectID
        public var frame: CGRect

        public init(id: ObjectID, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    /// The innermost region holding `point`: the smallest, as a nested group's region lies
    /// inside its parent's.
    public static func innermost(at point: CGPoint, in regions: [Region]) -> ObjectID? {
        regions.filter { $0.frame.contains(point) }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    /// The mention of a group: its members, named by its title (unnamed without one). Nil for
    /// anything but a group with members.
    @MainActor public static func target(_ group: ObjectID, on board: Board) -> MentionTarget? {
        guard let object = board.objects[group], object.type == .group, let spec = GroupSpec(object.props), !spec.members.isEmpty else { return nil }
        return .group(objects: spec.members, name: spec.title.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A Hyper press on the canvas away from any tile or drawing: released where it began (within
    /// `dragThreshold`) it is a click on the group under it; moved further, a marquee.
    public struct Press: Sendable {
        /// Where it began, in document coordinates.
        public let start: CGPoint
        /// The innermost group under the start; nil on bare canvas.
        public let group: ObjectID?
        private let origin: CGPoint
        public private(set) var dragging = false

        /// `window`: the start in window coordinates, where the threshold is measured.
        public init(start: CGPoint, window: CGPoint, group: ObjectID?) {
            self.start = start
            self.origin = window
            self.group = group
        }

        public enum Outcome: Equatable, Sendable {
            case group(ObjectID)
            /// The dragged box, document coordinates.
            case marquee(CGRect)
            case nothing
        }

        /// The pointer moved to `window`; once past the threshold the press stays a drag.
        public mutating func move(window: CGPoint) {
            if !dragging, hypot(window.x - origin.x, window.y - origin.y) >= GroupMention.dragThreshold { dragging = true }
        }

        /// Released at `point` (document) / `window`.
        public mutating func release(at point: CGPoint, window: CGPoint) -> Outcome {
            move(window: window)
            if dragging {
                return .marquee(CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y)))
            }
            return group.map(Outcome.group) ?? .nothing
        }
    }
}
