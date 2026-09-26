import CoreGraphics
import Foundation

/// Typed view of `GroupProps`. A group is a region: its frame is always its members' bounds
/// plus `padding`, with a title band on top, recomputed whenever a member moves, resizes, or
/// goes away, so `encloses` and hit tests see what is drawn.
public struct GroupSpec: Equatable, Sendable {
    public static let defaultPadding = 24.0
    /// Band above the members holding the title (the group's drag handle).
    public static let titleHeight = 32.0

    public var members: [ObjectID]
    public var title: String?
    /// Palette name or #rrggbb, as ShapeProps.color; nil draws a neutral region.
    public var color: String?
    public var padding: Double

    public init?(_ props: JSONValue) {
        guard let members = props["members"]?.array else { return nil }
        self.members = members.compactMap(\.string)
        title = props["title"]?.string
        color = props["color"]?.string
        padding = max(0, props["padding"]?.number ?? Self.defaultPadding)
    }

    /// The region around member rects (any coordinates): their union, `padding` on every side,
    /// and the title band on top. Nil without members.
    public func frame(around rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let inset = CGFloat(padding)
        return CGRect(x: union.minX - inset, y: union.minY - inset - Self.titleHeight,
                      width: union.width + 2 * inset, height: union.height + 2 * inset + Self.titleHeight)
    }
}

extension Board {
    /// The frame a group has for its current members: arrows (whose frames don't follow their
    /// routes) and missing members don't count. Nil when no member is left.
    func fittedFrame(ofGroup group: CanvasObject) -> Frame? {
        guard group.type == .group, let spec = GroupSpec(group.props) else { return nil }
        let rects = spec.members.compactMap { objects[$0] }.filter { $0.type != .arrow && $0.id != group.id }.map(\.frame.rect)
        return spec.frame(around: rects).map(Frame.init)
    }

    /// Re-bounds every group that lists `id`, recursively for nested groups, as part of the
    /// caller's change (and so its undo step). Undo/redo restore recorded frames instead.
    func refitGroups(containing id: ObjectID, visited: Set<ObjectID> = []) {
        guard !history.replaying else { return }
        let parents = objects.values
            .filter { $0.type == .group && !visited.contains($0.id) && GroupSpec($0.props)?.members.contains(id) == true }
            .sorted { $0.id < $1.id }
        for group in parents {
            guard let frame = fittedFrame(ofGroup: group), frame != group.frame else { continue }
            _ = try? write(group.id, rev: nil, frame: frame, z: nil, props: nil, caller: nil, refitting: visited.union([id]))
        }
    }

    /// Groups (transitively) listing `id`.
    public func groups(containing id: ObjectID) -> [ObjectID] {
        var found: [ObjectID] = []
        var queue = [id]
        while let next = queue.popLast() {
            for group in objects.values where group.type == .group && !found.contains(group.id) && GroupSpec(group.props)?.members.contains(next) == true {
                found.append(group.id)
                queue.append(group.id)
            }
        }
        return found.sorted()
    }

    /// Members of a group, nested groups expanded, without the groups themselves.
    public func leafMembers(of id: ObjectID) -> [ObjectID] {
        var seen: Set<ObjectID> = [id]
        var result: [ObjectID] = []
        var queue = [id]
        while let next = queue.popLast() {
            guard let group = objects[next], let spec = GroupSpec(group.props) else { continue }
            for member in spec.members where !seen.contains(member) {
                seen.insert(member)
                guard let object = objects[member] else { continue }
                if object.type == .group { queue.append(member) } else { result.append(member) }
            }
        }
        return result
    }
}
