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

    /// The object an export of the selection is named after: the one selected object; else the
    /// one outermost group of what the export draws (`export`) that holds everything else it
    /// draws, drawings (`drawn`: shapes and arrows, which a marquee takes along) aside. Nil when
    /// the selection spans several groups or loose tiles.
    public static func namesake(selection: Set<ObjectID>, groups: [Group], drawn: Set<ObjectID>) -> ObjectID? {
        if selection.count == 1 { return selection.first }
        let scope = export(selection: selection, groups: groups)
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func contents(_ group: Group) -> Set<ObjectID> {
            var found: Set<ObjectID> = [], queue = group.members
            while let next = queue.popLast() {
                guard found.insert(next).inserted else { continue }
                queue += byID[next]?.members ?? []
            }
            return found
        }
        let chosen = groups.filter { scope.contains($0.id) }
        let inner = Set(chosen.flatMap(contents))
        let outer = chosen.filter { !inner.contains($0.id) }
        guard outer.count == 1, let group = outer.first else { return nil }
        let inside = contents(group).union([group.id])
        return scope.subtracting(drawn).allSatisfy(inside.contains) ? group.id : nil
    }
}
