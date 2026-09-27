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

    /// A grid cell: the box at `row`, `col` (any non-negative numbers; unused numbers take no space).
    public struct GridCell: Equatable, Sendable {
        public var row: Int
        public var col: Int
        public var size: CGSize

        public init(row: Int, col: Int, size: CGSize) {
            self.row = row
            self.col = col
            self.size = size
        }
    }

    /// One column (x, width) or row (y, height) of a grid.
    public struct Track: Equatable, Sendable {
        public var index: Int
        public var start: CGFloat
        public var length: CGFloat

        public init(index: Int, start: CGFloat, length: CGFloat) {
            self.index = index
            self.start = start
            self.length = length
        }
    }

    public struct Grid: Equatable, Sendable {
        /// Each cell's origin, in the order the cells were given.
        public var origins: [CGPoint]
        /// Used columns and rows, ascending.
        public var columns: [Track]
        public var rows: [Track]
    }

    /// Cells in shared columns and rows from `origin`: a column is as wide as its widest cell and
    /// a row as tall as its tallest, `colGap`/`rowGap` apart, so a column lines up across every
    /// row whatever else sits in them. `colAlign` places a cell across its column's width (start:
    /// left edges), `rowAlign` down its row's height (start: top edges).
    public static func grid(_ cells: [GridCell], origin: CGPoint, colGap: CGFloat, rowGap: CGFloat, colAlign: Align = .start, rowAlign: Align = .start) -> Grid {
        func tracks(_ index: (GridCell) -> Int, _ extent: (GridCell) -> CGFloat, from start: CGFloat, gap: CGFloat) -> [Track] {
            var lengths: [Int: CGFloat] = [:]
            for cell in cells { lengths[index(cell)] = max(lengths[index(cell)] ?? 0, extent(cell)) }
            var position = start
            return lengths.keys.sorted().map { key in
                defer { position += lengths[key]! + gap }
                return Track(index: key, start: position, length: lengths[key]!)
            }
        }
        func offset(_ slack: CGFloat, _ align: Align) -> CGFloat {
            align == .start ? 0 : align == .center ? slack / 2 : slack
        }
        let columns = tracks(\.col, \.size.width, from: origin.x, gap: colGap)
        let rows = tracks(\.row, \.size.height, from: origin.y, gap: rowGap)
        let columnAt = Dictionary(uniqueKeysWithValues: columns.map { ($0.index, $0) })
        let rowAt = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
        let origins = cells.map { cell -> CGPoint in
            let column = columnAt[cell.col]!, row = rowAt[cell.row]!
            return CGPoint(x: column.start + offset(column.length - cell.size.width, colAlign),
                           y: row.start + offset(row.length - cell.size.height, rowAlign))
        }
        return Grid(origins: origins, columns: columns, rows: rows)
    }

    /// Objects within this many points of each other belong to one cluster for Zoom to Fit.
    public static let clusterMargin: CGFloat = 1500

    /// Groups `frames` into clusters: frames at most `margin` apart (edge to edge) join, and
    /// clusters are transitive. Each cluster lists frame indices ascending; clusters are ordered
    /// by their first index.
    public static func clusters(_ frames: [CGRect], margin: CGFloat = clusterMargin) -> [[Int]] {
        var parent = Array(frames.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        // Each frame grows by half the margin, so two frames `margin` apart just touch. Sweep in
        // x order: a frame only meets later frames that start before it ends.
        let grown = frames.map { $0.insetBy(dx: -margin / 2, dy: -margin / 2) }
        let order = grown.indices.sorted { grown[$0].minX < grown[$1].minX }
        for (position, index) in order.enumerated() {
            let rect = grown[index]
            for other in order[(position + 1)...] {
                let candidate = grown[other]
                if candidate.minX > rect.maxX { break }
                if candidate.minY <= rect.maxY, rect.minY <= candidate.maxY {
                    parent[root(other)] = root(index)
                }
            }
        }
        var members: [Int: [Int]] = [:]
        for index in frames.indices { members[root(index), default: []].append(index) }
        return members.values.sorted { $0[0] < $1[0] }
    }

    /// What Zoom to Fit shows: all of `frames` when their bounds, `padding` added on every side,
    /// fit `viewport` at `minZoom` or closer; otherwise the bounds of the largest cluster (most
    /// frames, then most total area), so a few far-off strays don't shrink the board to nothing.
    /// Nil without frames.
    public static func fitTarget(_ frames: [CGRect], viewport: CGSize, padding: CGFloat, minZoom: CGFloat, margin: CGFloat = clusterMargin) -> CGRect? {
        func bounds(_ indices: some Sequence<Int>) -> CGRect? {
            indices.reduce(nil) { union, index in union?.union(frames[index]) ?? frames[index] }
        }
        guard let all = bounds(frames.indices) else { return nil }
        let zoom = min(viewport.width / (all.width + 2 * padding), viewport.height / (all.height + 2 * padding))
        if zoom >= minZoom { return all }
        func area(_ cluster: [Int]) -> CGFloat { cluster.reduce(0) { $0 + frames[$1].width * frames[$1].height } }
        let largest = clusters(frames, margin: margin).max { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : area(lhs) < area(rhs)
        }
        return largest.flatMap { bounds($0) }
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
        return try shift([(id, origin.x - moving.frame.x, origin.y - moving.frame.y)], caller: caller)
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
        return try shift(zip(ids, zip(frames, origins)).map { (id: $0, dx: Double($1.1.x - $1.0.minX), dy: Double($1.1.y - $1.0.minY)) }, caller: caller)
    }

    /// Moves `ids` by (dx, dy) in one undo step. Groups move their members (a member listed
    /// beside its group moves once); arrows carry their free ends, and bound ends follow.
    @discardableResult
    public func translate(_ ids: [ObjectID], dx: Double, dy: Double, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        guard !ids.isEmpty else { return [:] }
        return try shift(ids.map { ($0, dx, dy) }, caller: caller)
    }

    /// Places `cells` in shared columns and rows (`Layout.grid`, sized by the cells' current
    /// frames) from `origin`, default the cells' current top-left; one undo step. Groups move
    /// their members.
    public func grid(_ cells: [(id: ObjectID, row: Int, col: Int)], colGap: Double = Layout.defaultGap, rowGap: Double = Layout.defaultGap, colAlign: Layout.Align = .start,
                     rowAlign: Layout.Align = .start, origin: CGPoint? = nil, caller: ObjectID? = nil) throws -> (frames: [ObjectID: Frame], grid: Layout.Grid) {
        guard !cells.isEmpty else { throw BoardError.invalidParams("cells must not be empty") }
        guard Set(cells.map(\.id)).count == cells.count else { throw BoardError.invalidParams("cell ids repeat") }
        var taken: Set<[Int]> = []
        for cell in cells {
            guard cell.row >= 0, cell.col >= 0 else { throw BoardError.invalidParams("cell \(cell.id): row and col must be non-negative") }
            guard taken.insert([cell.row, cell.col]).inserted else { throw BoardError.invalidParams("two cells at row \(cell.row), col \(cell.col)") }
        }
        let frames = try cells.map { try object($0.id).frame.rect }
        let start = origin ?? CGPoint(x: frames.map(\.minX).min()!, y: frames.map(\.minY).min()!)
        let grid = Layout.grid(zip(cells, frames).map { Layout.GridCell(row: $0.row, col: $0.col, size: $1.size) }, origin: start,
                               colGap: CGFloat(colGap), rowGap: CGFloat(rowGap), colAlign: colAlign, rowAlign: rowAlign)
        let moves = zip(cells, zip(frames, grid.origins)).map { (id: $0.id, dx: Double($1.1.x - $1.0.minX), dy: Double($1.1.y - $1.0.minY)) }
        return (try shift(moves, caller: caller), grid)
    }

    /// Moves each object by its offset as one undo step and one revision, then returns the
    /// objects' frames. A group moves its members (nested groups' too) and is re-fit once, after
    /// every member moved; an object reached twice with the same offset (a member listed beside
    /// its group) moves once, with different offsets it is an error. Arrows carry free ends.
    private func shift(_ moves: [(id: ObjectID, dx: Double, dy: Double)], caller: ObjectID?) throws -> [ObjectID: Frame] {
        var offsets: [ObjectID: (dx: Double, dy: Double)] = [:]
        var order: [ObjectID] = []
        for move in moves {
            let object = try object(move.id)
            for target in object.type == .group ? BoardGeometry.leafMembers(of: move.id, in: objects) : [move.id] {
                if let earlier = offsets[target] {
                    guard earlier == (move.dx, move.dy) else {
                        throw BoardError.invalidParams("\(target) would move twice: \(move.id) and a group containing it are both listed")
                    }
                    continue
                }
                offsets[target] = (move.dx, move.dy)
                order.append(target)
            }
        }
        return try atomically {
            try deferringRefits {
                for target in order {
                    let (dx, dy) = offsets[target]!
                    guard dx != 0 || dy != 0 else { continue }
                    let current = try object(target)
                    var frame = current.frame
                    frame.x += dx
                    frame.y += dy
                    let props = current.type == .arrow ? ArrowSpec(current.props)?.translated(dx: dx, dy: dy).props : nil
                    try update(target, frame: frame, props: props, caller: caller)
                }
            }
            return try Dictionary(moves.map { ($0.id, try object($0.id).frame) }, uniquingKeysWith: { first, _ in first })
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

extension BoardGeometry {
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
    /// Not overlaps: a group and its (nested) members, and anything with an unfilled rect or
    /// ellipse (an annotation drawn over or around things, like ink). Arrow routes and labels
    /// are computed as drawn (parallel offsets, `avoid`, line-bound ends with `rows`, labels
    /// placed by `labelRect`); an arrow never crosses its own ends or what contains them.
    public func layoutCheck(scope: Set<ObjectID>? = nil, rows: [ObjectID: CodeRows] = [:]) -> LayoutReport {
        let solid = objects.values.filter { object in
            switch object.type {
            case .arrow: return false
            case .shape:
                guard let spec = ShapeSpec(object.props) else { return true }
                return spec.kind != .ink && !((spec.kind == .rect || spec.kind == .ellipse) && spec.fill == .none)
            default: return true
            }
        }.sorted { $0.id < $1.id }
        var groupMembers: [ObjectID: Set<ObjectID>] = [:]
        func members(of group: CanvasObject) -> Set<ObjectID> {
            if let cached = groupMembers[group.id] { return cached }
            var all = Set(Self.leafMembers(of: group.id, in: objects))
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
