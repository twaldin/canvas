import CoreGraphics
import Foundation

/// How an arrow travels between its ends (`ArrowProps.route`).
public enum ArrowRouteStyle: String, Sendable, CaseIterable {
    /// One segment between the facing sides.
    case straight
    /// Horizontal and vertical segments with one jog between the facing sides.
    case orthogonal
    /// Horizontal and vertical segments around every tile in the way.
    case avoid
}

extension DrawingGeometry {
    /// Distance between arrows drawn between the same two objects.
    public static let parallelSpacing: CGFloat = 20
    /// Clearance an `avoid` route keeps from the tiles it passes.
    public static let avoidMargin: CGFloat = 18
    /// Space between an arrow and its label.
    public static let labelClearance: CGFloat = 6

    /// A routed arrow's polyline (at least two points), from `from` to `to`. `offset` moves the
    /// route sideways (perpendicular to from → to, positive to the left of travel in flipped
    /// coordinates) so parallel arrows between the same objects draw apart; `obstacles` are the
    /// rects an `avoid` route goes around (the ends' own outlines are added here).
    public static func path(from: ArrowEnd, to: ArrowEnd, style: ArrowRouteStyle, offset: CGFloat = 0, obstacles: [CGRect] = [], gap: CGFloat = arrowGap) -> [CGPoint] {
        switch style {
        case .straight:
            let route = route(from: from, to: to, gap: gap, offset: offset)
            return [route.start, route.end]
        case .orthogonal:
            return orthogonal(from: from, to: to, offset: offset, gap: gap)
        case .avoid:
            return avoid(from: from, to: to, offset: offset, obstacles: obstacles, gap: gap) ?? orthogonal(from: from, to: to, offset: offset, gap: gap)
        }
    }

    /// Signed sideways offsets for arrows whose two ends are bound to the same pair of objects
    /// (either direction), so none draws on top of another; lone arrows get 0. Offsets are
    /// relative to each arrow's own direction, so opposite arrows land on opposite sides.
    public static func parallelOffsets(_ arrows: [(id: ObjectID, from: ObjectID?, to: ObjectID?)]) -> [ObjectID: CGFloat] {
        var pairs: [String: [(id: ObjectID, canonical: Bool)]] = [:]
        for arrow in arrows {
            guard let from = arrow.from, let to = arrow.to, from != to else { continue }
            pairs[min(from, to) + "|" + max(from, to), default: []].append((arrow.id, from < to))
        }
        var offsets: [ObjectID: CGFloat] = [:]
        for members in pairs.values where members.count > 1 {
            let sorted = members.sorted { $0.id < $1.id }
            for (index, member) in sorted.enumerated() {
                let shift = (CGFloat(index) - CGFloat(sorted.count - 1) / 2) * parallelSpacing
                offsets[member.id] = member.canonical ? shift : -shift
            }
        }
        return offsets
    }

    // MARK: Orthogonal

    /// Leaves the facing side, jogs once halfway, and enters the other's facing side; runs
    /// straight when the sides line up. A row end (a bound line) always leaves sideways: when
    /// the two overlap horizontally the route loops around their right edges.
    static func orthogonal(from: ArrowEnd, to: ArrowEnd, offset: CGFloat, gap: CGFloat) -> [CGPoint] {
        let a = from.box ?? from.aim
        let b = to.box ?? to.aim
        let gapX = max(b.minX - a.maxX, a.minX - b.maxX)
        let gapY = max(b.minY - a.maxY, a.minY - b.maxY)
        guard gapX > 0 || gapY > 0 else { return path(from: from, to: to, style: .straight, offset: offset, gap: gap) }
        let rows = from.isRow || to.isRow
        if rows, gapX <= 0 {
            let start = port(from, horizontal: true, toward: true, across: -offset, other: to.aim, gap: gap)
            let end = port(to, horizontal: true, toward: true, across: -offset, other: from.aim, gap: gap)
            let x = max(a.maxX, b.maxX) + gap + 24 + offset
            return simplified([start, CGPoint(x: x, y: start.y), CGPoint(x: x, y: end.y), end])
        }
        let horizontal = rows || gapX >= gapY
        // Offsets are perpendicular to travel; along a horizontal run that is -y when heading right.
        let forward = horizontal ? b.midX >= a.midX : b.midY >= a.midY
        let across = horizontal ? (forward ? -offset : offset) : (forward ? offset : -offset)
        let start = port(from, horizontal: horizontal, toward: forward, across: across, other: to.aim, gap: gap)
        let end = port(to, horizontal: horizontal, toward: !forward, across: across, other: from.aim, gap: gap)
        if horizontal {
            let jog = (start.x + end.x) / 2 + (forward ? offset : -offset)
            return simplified([start, CGPoint(x: jog, y: start.y), CGPoint(x: jog, y: end.y), end])
        }
        let jog = (start.y + end.y) / 2 + (forward ? -offset : offset)
        return simplified([start, CGPoint(x: start.x, y: jog), CGPoint(x: end.x, y: jog), end])
    }

    /// Where a route leaves `end` along an axis: the middle of its side (moved `across` along the
    /// side, and lined up with `other` when their extents overlap), `gap` off the outline. A row
    /// end leaves its left or right edge at its row.
    static func port(_ end: ArrowEnd, horizontal: Bool, toward positive: Bool, across: CGFloat, other: CGRect, gap: CGFloat) -> CGPoint {
        let outline: Outline
        switch end {
        case .point(let point): return point
        case .row(let rect, let y): return CGPoint(x: positive ? rect.maxX + gap : rect.minX - gap, y: y)
        case .bound(let bound): outline = bound
        }
        let rect = outline.bounds
        if horizontal {
            let shared = overlap(rect.minY, rect.maxY, other.minY, other.maxY)
            let y = clamp((shared ?? rect.midY) + across, rect.minY + 4, rect.maxY - 4)
            let edge = boundary(outline, from: CGPoint(x: rect.midX, y: y), direction: CGPoint(x: positive ? 1 : -1, y: 0))
            return CGPoint(x: edge.x + (positive ? gap : -gap), y: y)
        }
        let shared = overlap(rect.minX, rect.maxX, other.minX, other.maxX)
        let x = clamp((shared ?? rect.midX) + across, rect.minX + 4, rect.maxX - 4)
        let edge = boundary(outline, from: CGPoint(x: x, y: rect.midY), direction: CGPoint(x: 0, y: positive ? 1 : -1))
        return CGPoint(x: x, y: edge.y + (positive ? gap : -gap))
    }

    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low <= high ? min(max(value, low), high) : (low + high) / 2
    }

    /// Drops repeated points and middle points of straight runs.
    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, abs(last.x - point.x) < 0.01, abs(last.y - point.y) < 0.01 { continue }
            if result.count >= 2 {
                let a = result[result.count - 2]
                let b = result[result.count - 1]
                let cross = (b.x - a.x) * (point.y - b.y) - (b.y - a.y) * (point.x - b.x)
                if abs(cross) < 0.01 { result[result.count - 1] = point; continue }
            }
            result.append(point)
        }
        if result.count == 1 { result.append(result[0]) }
        return result
    }

    // MARK: Avoid

    /// The shortest orthogonal route (bends cost extra) from any side of `from` to any side of
    /// `to` that keeps `avoidMargin` clear of every obstacle and of both ends, searched on the
    /// grid of obstacle edges. Nil when every way is blocked.
    static func avoid(from: ArrowEnd, to: ArrowEnd, offset: CGFloat, obstacles: [CGRect], gap: CGFloat) -> [CGPoint]? {
        let margin = avoidMargin
        let ends = [from.aim, to.aim]
        let local = ends[0].union(ends[1]).insetBy(dx: -600, dy: -600)
        var blocks = obstacles
            .filter { rect in rect.intersects(local) && !ends.contains { rect.contains(CGPoint(x: $0.midX, y: $0.midY)) } }
            .map { $0.insetBy(dx: -margin, dy: -margin) }
        for box in [from.box, to.box].compactMap({ $0 }) { blocks.append(box.insetBy(dx: -margin, dy: -margin)) }

        let starts = ports(from, offset: offset, gap: gap, margin: margin)
        let goals = ports(to, offset: offset, gap: gap, margin: margin)
        var xs = Set<CGFloat>()
        var ys = Set<CGFloat>()
        for rect in blocks { xs.formUnion([rect.minX, rect.maxX]); ys.formUnion([rect.minY, rect.maxY]) }
        for port in starts + goals { xs.insert(port.stub.x); ys.insert(port.stub.y) }
        let gx = xs.sorted()
        let gy = ys.sorted()
        let nx = gx.count
        let ny = gy.count
        guard nx > 0, ny > 0, nx * ny <= 250_000 else { return nil }
        func index(_ values: [CGFloat], _ value: CGFloat) -> Int { values.firstIndex { abs($0 - value) < 0.001 } ?? 0 }
        // Grid points strictly inside a block, and grid segments running through one.
        var blockedNode = [Bool](repeating: false, count: nx * ny)
        var blockedRight = [Bool](repeating: false, count: nx * ny)
        var blockedDown = [Bool](repeating: false, count: nx * ny)
        for rect in blocks {
            let ix = gx.indices.filter { gx[$0] >= rect.minX - 0.001 && gx[$0] <= rect.maxX + 0.001 }
            let iy = gy.indices.filter { gy[$0] >= rect.minY - 0.001 && gy[$0] <= rect.maxY + 0.001 }
            for i in ix {
                for j in iy {
                    let insideX = gx[i] > rect.minX + 0.001 && gx[i] < rect.maxX - 0.001
                    let insideY = gy[j] > rect.minY + 0.001 && gy[j] < rect.maxY - 0.001
                    if insideX && insideY { blockedNode[j * nx + i] = true }
                    if insideY, i + 1 < nx, gx[i + 1] <= rect.maxX + 0.001 { blockedRight[j * nx + i] = true }
                    if insideX, j + 1 < ny, gy[j + 1] <= rect.maxY + 0.001 { blockedDown[j * nx + i] = true }
                }
            }
        }
        // States are (node, heading); a heading change costs a bend.
        let bend: CGFloat = 60
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        var best = [CGFloat](repeating: .infinity, count: nx * ny * 4)
        var parent = [Int](repeating: -1, count: nx * ny * 4)
        var heap = MinHeap()
        var goalAt: [Int: (port: Port, index: Int)] = [:]
        for (number, goal) in goals.enumerated() {
            let node = index(gy, goal.stub.y) * nx + index(gx, goal.stub.x)
            if !blockedNode[node] { goalAt[node] = (goal, number) }
        }
        guard !goalAt.isEmpty else { return nil }
        func estimate(_ node: Int) -> CGFloat {
            let p = CGPoint(x: gx[node % nx], y: gy[node / nx])
            return goals.map { abs($0.stub.x - p.x) + abs($0.stub.y - p.y) }.min() ?? 0
        }
        var startPort: [Int: Port] = [:]
        for start in starts {
            let node = index(gy, start.stub.y) * nx + index(gx, start.stub.x)
            guard !blockedNode[node] else { continue }
            let state = node * 4 + start.heading
            let cost = abs(start.point.x - start.stub.x) + abs(start.point.y - start.stub.y)
            guard cost < best[state] else { continue }
            best[state] = cost
            startPort[state] = start
            heap.push(state, cost + estimate(node))
        }
        var finish: (state: Int, cost: CGFloat, goal: Port)?
        while let (state, _) = heap.pop() {
            let cost = best[state]
            if let finish, cost >= finish.cost { break }
            let node = state / 4
            let heading = state % 4
            if let goal = goalAt[node] {
                // Arrive heading into the goal's side (opposite its outward direction).
                let turn: CGFloat = heading == (goal.port.heading + 2) % 4 ? 0 : bend
                let total = cost + turn + abs(goal.port.point.x - goal.port.stub.x) + abs(goal.port.point.y - goal.port.stub.y)
                if finish == nil || total < finish!.cost { finish = (state, total, goal.port) }
            }
            let i = node % nx
            let j = node / nx
            for (direction, step) in steps.enumerated() {
                let ni = i + step.0
                let nj = j + step.1
                guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                let next = nj * nx + ni
                guard !blockedNode[next] else { continue }
                let segmentBlocked: Bool
                switch direction {
                case 0: segmentBlocked = blockedRight[node]
                case 2: segmentBlocked = blockedRight[next]
                case 1: segmentBlocked = blockedDown[node]
                default: segmentBlocked = blockedDown[next]
                }
                guard !segmentBlocked, direction != (heading + 2) % 4 else { continue }
                let length = abs(gx[ni] - gx[i]) + abs(gy[nj] - gy[j])
                let nextCost = cost + length + (direction == heading ? 0 : bend)
                let nextState = next * 4 + direction
                guard nextCost < best[nextState] else { continue }
                best[nextState] = nextCost
                parent[nextState] = state
                heap.push(nextState, nextCost + estimate(next))
            }
        }
        guard let finish else { return nil }
        var states = [finish.state]
        while let last = states.last, parent[last] >= 0 { states.append(parent[last]) }
        guard let first = states.last, let start = startPort[first] else { return nil }
        let grid = states.reversed().map { CGPoint(x: gx[($0 / 4) % nx], y: gy[($0 / 4) / nx]) }
        return simplified([start.point] + grid + [finish.goal.point])
    }

    struct Port {
        /// On the outline (plus the arrow gap), where the arrow starts or ends.
        var point: CGPoint
        /// Just outside the end's margin: where the grid search starts or ends.
        var stub: CGPoint
        /// Outward direction: 0 right, 1 down, 2 left, 3 up.
        var heading: Int
    }

    /// The four side middles of a bound end, moved `offset` along each side so parallel arrows
    /// leave from distinct points; a row end's left and right edges at its row; a free point is
    /// its own port, left in any direction.
    static func ports(_ end: ArrowEnd, offset: CGFloat, gap: CGFloat, margin: CGFloat) -> [Port] {
        let outline: Outline
        switch end {
        case .point(let point):
            return (0..<4).map { Port(point: point, stub: point, heading: $0) }
        case .row(let rect, let y):
            let out = margin + 1
            return [Port(point: CGPoint(x: rect.maxX + gap, y: y), stub: CGPoint(x: rect.maxX + out, y: y), heading: 0),
                    Port(point: CGPoint(x: rect.minX - gap, y: y), stub: CGPoint(x: rect.minX - out, y: y), heading: 2)]
        case .bound(let bound): outline = bound
        }
        let rect = outline.bounds
        return (0..<4).map { heading in
            let horizontal = heading % 2 == 0
            let sign: CGFloat = heading < 2 ? 1 : -1
            let along = horizontal ? clamp(rect.midY + offset, rect.minY + 4, rect.maxY - 4) : clamp(rect.midX + offset, rect.minX + 4, rect.maxX - 4)
            let origin = horizontal ? CGPoint(x: rect.midX, y: along) : CGPoint(x: along, y: rect.midY)
            let direction = horizontal ? CGPoint(x: sign, y: 0) : CGPoint(x: 0, y: sign)
            let edge = boundary(outline, from: origin, direction: direction)
            let point = CGPoint(x: edge.x + direction.x * gap, y: edge.y + direction.y * gap)
            let out = margin + 1
            let stub = horizontal ? CGPoint(x: sign > 0 ? rect.maxX + out : rect.minX - out, y: along) : CGPoint(x: along, y: sign > 0 ? rect.maxY + out : rect.minY - out)
            return Port(point: point, stub: stub, heading: heading)
        }
    }

    // MARK: Labels

    /// Where an arrow's label of `size` goes: beside the route (never on it), at the first spot
    /// along it, from the middle outward, that stays clear of `obstacles`; `side` (the sign of
    /// the arrow's parallel offset) picks which side is tried first, so opposite arrows label
    /// their outer sides. Falls back to the middle when nothing is clear.
    public static func labelRect(along path: [CGPoint], size: CGSize, side: CGFloat, obstacles: [CGRect]) -> CGRect {
        let lengths = zip(path, path.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var candidates: [CGRect] = []
        for fraction in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8] as [CGFloat] {
            var remaining = total * fraction
            var segment = 0
            while segment < lengths.count - 1, remaining > lengths[segment] {
                remaining -= lengths[segment]
                segment += 1
            }
            guard segment < lengths.count else { continue }
            let a = path[segment]
            let b = path[segment + 1]
            let length = max(lengths[segment], 0.0001)
            let point = CGPoint(x: a.x + (b.x - a.x) * remaining / length, y: a.y + (b.y - a.y) * remaining / length)
            // Left of travel (flipped coordinates), then right; `side` flips the preference.
            var normal = CGPoint(x: (a.y - b.y) / length, y: (b.x - a.x) / length)
            if side > 0 || (side == 0 && normal.y > 0) { normal = CGPoint(x: -normal.x, y: -normal.y) }
            for sign in [1.0, -1.0] as [CGFloat] {
                let n = CGPoint(x: normal.x * sign, y: normal.y * sign)
                let lift = abs(n.x) * size.width / 2 + abs(n.y) * size.height / 2 + labelClearance
                let center = CGPoint(x: point.x + n.x * lift, y: point.y + n.y * lift)
                candidates.append(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
        }
        let clear = candidates.first { rect in
            !obstacles.contains { $0.intersects(rect) } && distance(fromPath: path, to: rect) >= labelClearance - 1
        }
        return clear ?? candidates.first ?? CGRect(origin: path.first ?? .zero, size: size)
    }

    // MARK: Path queries

    public static func distance(_ point: CGPoint, toPath path: [CGPoint]) -> CGFloat {
        guard path.count > 1 else { return path.first.map { hypot($0.x - point.x, $0.y - point.y) } ?? .infinity }
        return zip(path, path.dropFirst()).map { distanceToSegment(point, $0, $1) }.min() ?? .infinity
    }

    /// Smallest gap between the path and a rect (0 when they touch).
    static func distance(fromPath path: [CGPoint], to rect: CGRect) -> CGFloat {
        if zip(path, path.dropFirst()).contains(where: { segment($0, $1, intersects: rect) }) { return 0 }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        let fromCorners = corners.map { distance($0, toPath: path) }.min() ?? .infinity
        let fromPoints = path.map { distanceToRectBorder($0, rect) }.min() ?? .infinity
        return min(fromCorners, fromPoints)
    }

    /// Whether any segment of the path passes through the rect's interior.
    public static func path(_ path: [CGPoint], crosses rect: CGRect) -> Bool {
        let inner = rect.insetBy(dx: 0.5, dy: 0.5)
        guard !inner.isEmpty else { return false }
        return zip(path, path.dropFirst()).contains { segment($0, $1, intersects: inner) }
    }

    /// Liang–Barsky clip of segment a–b against a rect.
    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        var t0: CGFloat = 0
        var t1: CGFloat = 1
        let dx = b.x - a.x
        let dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
                continue
            }
            let r = q / p
            if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            if t0 > t1 { return false }
        }
        return true
    }

    public static func hitsArrow(path: [CGPoint], at point: CGPoint, tolerance: CGFloat) -> Bool {
        distance(point, toPath: path) <= tolerance + strokeWidth / 2 + jitterAllowance
    }
}

/// Binary min-heap of (state, priority) for the route search.
struct MinHeap {
    private var items: [(state: Int, priority: CGFloat)] = []

    mutating func push(_ state: Int, _ priority: CGFloat) {
        items.append((state, priority))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].priority < items[parent].priority else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Int, CGFloat)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (top.state, top.priority)
    }
}
