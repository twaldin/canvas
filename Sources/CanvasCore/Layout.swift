import CoreGraphics
import Foundation

/// Placement math for `layout.*`: pure functions over sizes and rects, applied to the board by
/// the `Board` extension below in one undo step and one revision.
public enum Layout {
    public enum Side: String, Sendable, CaseIterable { case right, left, above, below }
    public enum Align: String, Sendable, CaseIterable { case start, center, end }
    public enum Direction: String, Sendable, CaseIterable { case row, column }

    public static let defaultGap = 40.0

    /// Origin for a `size` box `gap` away from `anchor` on `side`, aligned along that side
    /// (start: top or left edges line up; end: bottom or right edges).
    public static func place(_ size: CGSize, near anchor: CGRect, side: Side, gap: CGFloat, align: Align) -> CGPoint {
        func along(_ start: CGFloat, _ length: CGFloat, _ extent: CGFloat) -> CGFloat {
            switch align {
            case .start: start
            case .center: start + (length - extent) / 2
            case .end: start + length - extent
            }
        }
        switch side {
        case .right: return CGPoint(x: anchor.maxX + gap, y: along(anchor.minY, anchor.height, size.height))
        case .left: return CGPoint(x: anchor.minX - gap - size.width, y: along(anchor.minY, anchor.height, size.height))
        case .below: return CGPoint(x: along(anchor.minX, anchor.width, size.width), y: anchor.maxY + gap)
        case .above: return CGPoint(x: along(anchor.minX, anchor.width, size.width), y: anchor.minY - gap - size.height)
        }
    }

    /// Origins for boxes laid one after another from `origin`: a row runs right, a column runs
    /// down, `gap` apart. With `wrapAt`, a line that would grow longer than `wrapAt` points
    /// starts a new line (below a row, right of a column) `gap` past the previous line's
    /// thickest box. `align` places each box across its line.
    public static func stack(_ sizes: [CGSize], from origin: CGPoint, direction: Direction, gap: CGFloat, wrapAt: CGFloat? = nil, align: Align = .start) -> [CGPoint] {
        let row = direction == .row
        func main(_ size: CGSize) -> CGFloat { row ? size.width : size.height }
        func cross(_ size: CGSize) -> CGFloat { row ? size.height : size.width }
        // Break into lines first: alignment needs each line's thickness.
        var lines: [[Int]] = [[]]
        var length: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let grown = lines[lines.count - 1].isEmpty ? main(size) : length + gap + main(size)
            if let wrapAt, !lines[lines.count - 1].isEmpty, grown > wrapAt {
                lines.append([index])
                length = main(size)
            } else {
                lines[lines.count - 1].append(index)
                length = grown
            }
        }
        var origins = [CGPoint](repeating: origin, count: sizes.count)
        var crossOffset: CGFloat = 0
        for line in lines where !line.isEmpty {
            let thickness = line.map { cross(sizes[$0]) }.max() ?? 0
            var mainOffset: CGFloat = 0
            for index in line {
                let size = sizes[index]
                let slack = thickness - cross(size)
                let shift = align == .start ? 0 : align == .center ? slack / 2 : slack
                origins[index] = row
                    ? CGPoint(x: origin.x + mainOffset, y: origin.y + crossOffset + shift)
                    : CGPoint(x: origin.x + crossOffset + shift, y: origin.y + mainOffset)
                mainOffset += main(size) + gap
            }
            crossOffset += thickness + gap
        }
        return origins
    }
}

extension Board {
    /// Moves `id` `gap` beside `anchor`; one undo step. Groups move their members.
    @discardableResult
    public func place(_ id: ObjectID, near anchor: ObjectID, side: Layout.Side, gap: Double = Layout.defaultGap, align: Layout.Align = .start, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        let moving = try object(id)
        let target = try object(anchor)
        guard id != anchor else { throw BoardError.invalidParams("an object can't be placed beside itself") }
        let origin = Layout.place(moving.frame.rect.size, near: target.frame.rect, side: side, gap: CGFloat(gap), align: align)
        return try atomically {
            try move(id, to: origin, caller: caller)
            return [id: try object(id).frame]
        }
    }

    /// Lays `ids` out in a row or column starting where the first one is (or at `origin`); one
    /// undo step. Groups move their members.
    @discardableResult
    public func stack(_ ids: [ObjectID], direction: Layout.Direction, gap: Double = Layout.defaultGap, wrapAt: Double? = nil, align: Layout.Align = .start, origin: CGPoint? = nil, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        guard !ids.isEmpty else { return [:] }
        guard Set(ids).count == ids.count else { throw BoardError.invalidParams("ids repeat") }
        let frames = try ids.map { try object($0).frame.rect }
        let start = origin ?? frames[0].origin
        let origins = Layout.stack(frames.map(\.size), from: start, direction: direction, gap: CGFloat(gap), wrapAt: wrapAt.map { CGFloat($0) }, align: align)
        return try atomically {
            for (id, origin) in zip(ids, origins) { try move(id, to: origin, caller: caller) }
            return try Dictionary(uniqueKeysWithValues: ids.map { ($0, try object($0).frame) })
        }
    }

    /// Moves an object's frame origin to `origin`: a group moves its members (its frame
    /// follows), an arrow carries its free ends.
    public func move(_ id: ObjectID, to origin: CGPoint, caller: ObjectID? = nil) throws {
        let current = try object(id)
        try translate(id, dx: origin.x - current.frame.x, dy: origin.y - current.frame.y, caller: caller)
    }

    public func translate(_ id: ObjectID, dx: Double, dy: Double, caller: ObjectID? = nil) throws {
        guard dx != 0 || dy != 0 else { return }
        let current = try object(id)
        switch current.type {
        case .group:
            try transaction {
                for member in leafMembers(of: id) { try translate(member, dx: dx, dy: dy, caller: caller) }
            }
        case .arrow:
            var frame = current.frame
            frame.x += dx
            frame.y += dy
            try update(id, frame: frame, props: ArrowSpec(current.props)?.translated(dx: dx, dy: dy).props, caller: caller)
        default:
            var frame = current.frame
            frame.x += dx
            frame.y += dy
            try update(id, frame: frame, caller: caller)
        }
    }
}

extension ArrowSpec {
    /// Free ends moved by (dx, dy); bound ends follow their objects anyway.
    public func translated(dx: Double, dy: Double) -> ArrowSpec {
        func moved(_ binding: ArrowBinding) -> ArrowBinding {
            guard case .point(let point) = binding else { return binding }
            return .point(CGPoint(x: point.x + dx, y: point.y + dy))
        }
        var spec = self
        spec.from = moved(from)
        spec.to = moved(to)
        return spec
    }
}

// MARK: Checks

extension Board {
    public struct LayoutReport: Equatable, Sendable {
        /// Pairs (sorted ids) whose frames overlap by accident.
        public var overlaps: [[ObjectID]]
        /// Arrows whose route runs through objects other than their own ends.
        public var crossings: [Crossing]
        /// Arrows whose label lies on a tile, text, or filled shape (their own ends included), or
        /// on another arrow's label.
        public var labelOverlaps: [LabelOverlap]
    }

    public struct Crossing: Equatable, Sendable {
        public var arrow: ObjectID
        public var crosses: [ObjectID]
    }

    public struct LabelOverlap: Equatable, Sendable {
        public var arrow: ObjectID
        /// Objects under the label; an arrow id means that arrow's label.
        public var overlaps: [ObjectID]
    }

    /// Overlaps, arrow crossings, and label overlaps involving `scope` (every object when nil).
    /// Not overlaps: a group and its (nested) members, and an unfilled rect/ellipse around what
    /// it contains (a drawn region). Arrow routes and labels are computed as drawn (parallel
    /// offsets, `avoid`, line-bound ends with `rows`, labels placed by `labelRect`); an arrow
    /// never crosses its own ends or what contains them.
    public func layoutCheck(scope: Set<ObjectID>? = nil, rows: [ObjectID: CodeRows] = [:]) -> LayoutReport {
        let solid = objects.values.filter { object in
            switch object.type {
            case .arrow: return false
            case .shape: return ShapeSpec(object.props)?.kind != .ink
            default: return true
            }
        }.sorted { $0.id < $1.id }
        func isRegion(_ object: CanvasObject) -> Bool {
            guard object.type == .shape, let spec = ShapeSpec(object.props) else { return false }
            return (spec.kind == .rect || spec.kind == .ellipse) && spec.fill == .none
        }
        var groupMembers: [ObjectID: Set<ObjectID>] = [:]
        func members(of group: CanvasObject) -> Set<ObjectID> {
            if let cached = groupMembers[group.id] { return cached }
            var all = Set(leafMembers(of: group.id))
            var queue = [group.id]
            while let next = queue.popLast() {
                for member in GroupSpec(objects[next]?.props ?? .null)?.members ?? [] where objects[member]?.type == .group && !all.contains(member) {
                    all.insert(member)
                    queue.append(member)
                }
            }
            groupMembers[group.id] = all
            return all
        }
        var overlaps: [[ObjectID]] = []
        for (index, a) in solid.enumerated() {
            for b in solid[(index + 1)...] {
                guard scope == nil || scope!.contains(a.id) || scope!.contains(b.id), a.frame.intersects(b.frame) else { continue }
                if a.type == .group, members(of: a).contains(b.id) { continue }
                if b.type == .group, members(of: b).contains(a.id) { continue }
                if isRegion(a) && a.frame.contains(b.frame) || isRegion(b) && b.frame.contains(a.frame) { continue }
                overlaps.append([a.id, b.id])
            }
        }
        let routes = routes(rows: rows)
        let blockers = objects.values.filter(Self.blocksRoutes).sorted { $0.id < $1.id }
        var crossings: [Crossing] = []
        for (arrowID, path) in routes.sorted(by: { $0.key < $1.key }) where scope == nil || scope!.contains(arrowID) {
            guard let spec = objects[arrowID].flatMap({ ArrowSpec($0.props) }) else { continue }
            var endRects: [CGRect] = []
            var endIDs: Set<ObjectID> = []
            for binding in [spec.from, spec.to] {
                switch binding {
                case .object(let id, _, _):
                    endIDs.insert(id)
                    if let frame = objects[id]?.frame.rect { endRects.append(frame) }
                case .point(let point):
                    endRects.append(CGRect(origin: point, size: .zero))
                }
            }
            let crossed = blockers.filter { blocker in
                let rect = blocker.frame.rect
                guard !endIDs.contains(blocker.id), !endRects.contains(where: { $0.size == .zero ? rect.contains($0.origin) : rect.contains($0) }) else { return false }
                return DrawingGeometry.path(path, crosses: rect)
            }.map(\.id)
            if !crossed.isEmpty { crossings.append(Crossing(arrow: arrowID, crosses: crossed)) }
        }
        let labels = labelRects(routes: routes)
        var labelOverlaps: [LabelOverlap] = []
        for (arrowID, label) in labels.sorted(by: { $0.key < $1.key }) where scope == nil || scope!.contains(arrowID) {
            let inner = label.insetBy(dx: 0.5, dy: 0.5)
            let under = blockers.filter { $0.frame.rect.intersects(inner) }.map(\.id)
                + labels.filter { $0.key != arrowID && $0.value.intersects(inner) }.map(\.key).sorted()
            if !under.isEmpty { labelOverlaps.append(LabelOverlap(arrow: arrowID, overlaps: under)) }
        }
        return LayoutReport(overlaps: overlaps, crossings: crossings, labelOverlaps: labelOverlaps)
    }
}
