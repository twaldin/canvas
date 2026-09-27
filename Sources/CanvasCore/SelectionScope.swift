/// What a marquee selects beyond the tiles and drawings it encloses, and what Export Selection
/// draws beyond the selection, so a diagram (tiles in titled groups, joined by arrows) comes
/// along whole.
public enum SelectionScope {
    public struct Group: Sendable {
        public var id: ObjectID
        public var members: [ObjectID]
        /// The marquee (box or lasso) encloses the group's whole region, title band included.
        public var enclosed: Bool

        public init(id: ObjectID, members: [ObjectID], enclosed: Bool = false) {
            self.id = id
            self.members = members
            self.enclosed = enclosed
        }
    }

    public struct Arrow: Sendable {
        public var id: ObjectID
        /// The objects its two ends are bound to; nil for an end at a point.
        public var from: ObjectID?
        public var to: ObjectID?

        public init(id: ObjectID, from: ObjectID?, to: ObjectID?) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    /// A marquee's selection: the tiles and drawn objects it encloses (`enclosed`), the groups
    /// whose region it encloses, and the arrows whose two ends are both bound to something
    /// selected (an enclosed object, a selected group, or one of its members), however their
    /// route bends outside the marquee.
    public static func marquee(enclosed: Set<ObjectID>, groups: [Group], arrows: [Arrow]) -> Set<ObjectID> {
        var selected = enclosed
        for group in groups where group.enclosed && !group.members.isEmpty { selected.insert(group.id) }
        let covered = selected.union(groups.filter { selected.contains($0.id) }.flatMap(\.members))
        for arrow in arrows {
            guard let from = arrow.from, let to = arrow.to, covered.contains(from), covered.contains(to) else { continue }
            selected.insert(arrow.id)
        }
        return selected
    }

    /// What Export Selection draws: the selection plus each group all of whose members are in it
    /// (or are such groups themselves), so the picture keeps their titles and borders.
    public static func export(selection: Set<ObjectID>, groups: [Group]) -> Set<ObjectID> {
        var result = selection
        var changed = true
        while changed {
            changed = false
            for group in groups where !result.contains(group.id) && !group.members.isEmpty && group.members.allSatisfy(result.contains) {
                result.insert(group.id)
                changed = true
            }
        }
        return result
    }
}
