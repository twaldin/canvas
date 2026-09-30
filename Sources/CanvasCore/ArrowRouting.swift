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

    /// A routed arrow's polyline (at least two points), from `from` to `to`. `offset` moves a
    /// straight or orthogonal route sideways (perpendicular to from → to, positive to the left of
    /// travel in flipped coordinates) so parallel arrows between the same objects draw apart;
    /// `obstacles` are the rects an `avoid` route goes around (the ends' own outlines are added
    /// here). An `avoid` route alone; a board routes its `avoid` arrows together
    /// (`ConnectorRouter`), which spreads arrows sharing a side or a channel.
    public static func path(from: ArrowEnd, to: ArrowEnd, style: ArrowRouteStyle, offset: CGFloat = 0, obstacles: [CGRect] = [], gap: CGFloat = arrowGap) -> [CGPoint] {
        switch style {
        case .straight:
            let route = route(from: from, to: to, gap: gap, offset: offset)
            return [route.start, route.end]
        case .orthogonal:
            return orthogonal(from: from, to: to, offset: offset, gap: gap)
        case .avoid:
            let router = ConnectorRouter(connectors: [.init(id: "", from: from, to: to)],
                                         obstacles: obstacles.enumerated().map { .init(id: "obstacle.\($0.offset)", rect: $0.element) })
            return router.route().paths[""] ?? orthogonal(from: from, to: to, offset: offset, gap: gap)
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

    // MARK: Labels

    /// Where one arrow's label of `size` goes along `path`, alone: beside its longest segment
    /// from the middle outward, clear of `obstacles` and `titles` where it can be, else a short
    /// leader away (`ConnectorRouter.placeLabels`, which a board's routing runs for all its arrows).
    public static func label(along path: [CGPoint], size: CGSize, obstacles: [CGRect], titles: [CGRect] = []) -> ConnectorRouter.Label {
        let connector = ConnectorRouter.Connector(id: "", from: .point(path.first ?? .zero), to: .point(path.last ?? .zero), label: size, path: path)
        return ConnectorRouter.placeLabels(connectors: [connector], routes: [path], obstacles: obstacles, titles: titles)[""]
            ?? ConnectorRouter.Label(rect: CGRect(origin: path.first ?? .zero, size: size))
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
