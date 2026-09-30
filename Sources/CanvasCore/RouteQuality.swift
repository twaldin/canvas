import CoreGraphics
import Foundation

/// How readable a board's arrows are: what `layout.check` reports and the router is judged by.
extension ConnectorRouter {
    /// Two arrows drawn on top of each other for `length` points (collinear segments closer than
    /// `overlapTolerance`), first at `at`.
    public struct Overlap: Equatable, Sendable {
        public var arrows: [ObjectID]
        public var length: CGFloat
        public var at: CGPoint
    }

    /// Two arrows whose lines cross `count` times, first at `at`.
    public struct Intersection: Equatable, Sendable {
        public var arrows: [ObjectID]
        public var count: Int
        public var at: CGPoint
    }

    /// Lines nearer than this read as one: a stroke is 2 points wide and wanders up to 2.
    public static let overlapTolerance: CGFloat = 3

    /// Pairs of arrows (ids sorted) that share length, sorted by ids; runs shorter than 2 points
    /// (a touch at a corner) don't count.
    public static func overlaps(_ paths: [ObjectID: [CGPoint]]) -> [Overlap] {
        let ids = paths.keys.sorted()
        let segments = ids.map { id in axisSegments(paths[id]!) }
        var result: [Overlap] = []
        for a in ids.indices {
            for b in ids.indices where b > a {
                var length: CGFloat = 0
                var at: CGPoint?
                for s in segments[a] {
                    for t in segments[b] where s.vertical == t.vertical && abs(s.coord - t.coord) < overlapTolerance {
                        let low = max(s.low, t.low)
                        let high = min(s.high, t.high)
                        guard high - low >= 2 else { continue }
                        length += high - low
                        if at == nil { at = s.vertical ? CGPoint(x: s.coord, y: (low + high) / 2) : CGPoint(x: (low + high) / 2, y: s.coord) }
                    }
                }
                if let at { result.append(Overlap(arrows: [ids[a], ids[b]], length: length, at: at)) }
            }
        }
        return result
    }

    /// Pairs of arrows (ids sorted) whose lines cross, sorted by ids.
    public static func intersections(_ paths: [ObjectID: [CGPoint]]) -> [Intersection] {
        let ids = paths.keys.sorted()
        var result: [Intersection] = []
        for a in ids.indices {
            let p = paths[ids[a]]!
            for b in ids.indices where b > a {
                let q = paths[ids[b]]!
                var count = 0
                var at: CGPoint?
                for (p0, p1) in zip(p, p.dropFirst()) {
                    for (q0, q1) in zip(q, q.dropFirst()) where properlyIntersect(p0, p1, q0, q1) {
                        count += 1
                        if at == nil { at = intersection(p0, p1, q0, q1) }
                    }
                }
                if let at { result.append(Intersection(arrows: [ids[a], ids[b]], count: count, at: at)) }
            }
        }
        return result
    }

    struct AxisSegment {
        var vertical: Bool
        var coord: CGFloat
        var low: CGFloat
        var high: CGFloat
    }

    static func axisSegments(_ path: [CGPoint]) -> [AxisSegment] {
        zip(path, path.dropFirst()).compactMap { a, b in
            if abs(a.x - b.x) < 0.01, abs(a.y - b.y) > 0.01 { return AxisSegment(vertical: true, coord: a.x, low: min(a.y, b.y), high: max(a.y, b.y)) }
            if abs(a.y - b.y) < 0.01, abs(a.x - b.x) > 0.01 { return AxisSegment(vertical: false, coord: a.y, low: min(a.x, b.x), high: max(a.x, b.x)) }
            return nil
        }
    }

    static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-9 else { return a }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        return CGPoint(x: a.x + t * r.x, y: a.y + t * r.y)
    }
}
