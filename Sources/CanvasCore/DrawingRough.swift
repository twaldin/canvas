import CoreGraphics
import Foundation

/// Hand-drawn strokes in the style of rough.js (MIT; the technique, not its code): every line is
/// drawn twice as a slightly bowed cubic with jittered ends, and ellipses are fitted through
/// jittered points with a small overlap. Randomness is seeded by the object id, so a shape looks
/// the same on every redraw and after relaunch.
public enum DrawingRough {
    /// One continuous stroke: a start point followed by cubic Bézier segments.
    public struct Stroke: Equatable, Sendable {
        public struct Cubic: Equatable, Sendable {
            public var control1: CGPoint
            public var control2: CGPoint
            public var end: CGPoint
        }

        public var start: CGPoint
        public var curves: [Cubic]
    }

    /// Deterministic generator (Park–Miller minimal standard) so strokes are reproducible.
    public struct Random: Sendable {
        var state: UInt64

        public init(seed: UInt32) {
            state = UInt64(seed % 2_147_483_646) + 1
        }

        /// Uniform in [0, 1).
        public mutating func next() -> CGFloat {
            state = (state * 48271) % 2_147_483_647
            return CGFloat(state - 1) / 2_147_483_646
        }
    }

    /// FNV-1a over the UTF-8 bytes: stable across launches, unlike `hashValue`.
    public static func seed(_ id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    public static let roughness: CGFloat = 1
    static let maxOffset: CGFloat = 2
    static let bowing: CGFloat = 1

    public static func line(from a: CGPoint, to b: CGPoint, random: inout Random) -> [Stroke] {
        [bowedLine(a, b, random: &random, overlay: false), bowedLine(a, b, random: &random, overlay: true)]
    }

    public static func rectangle(_ rect: CGRect, random: inout Random) -> [Stroke] {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return (0..<4).flatMap { index in line(from: corners[index], to: corners[(index + 1) % 4], random: &random) }
    }

    public static func ellipse(_ rect: CGRect, random: inout Random) -> [Stroke] {
        let rx = rect.width / 2
        let ry = rect.height / 2
        let perimeterish = (2 * .pi * ((rx * rx + ry * ry) / 2).squareRoot()).squareRoot()
        let steps = max(9, (9 / CGFloat(200).squareRoot() * perimeterish).rounded(.up))
        let increment = 2 * .pi / steps
        let fit: CGFloat = 0.05
        let jitteredRX = rx + offset(rx * fit, &random)
        let jitteredRY = ry + offset(ry * fit, &random)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let overlapScale = between(0.4, 1, &random)
        let overlap = increment * between(0.1, overlapScale, &random)
        return [
            ellipseStroke(center, jitteredRX, jitteredRY, increment: increment, overlap: overlap, jitter: 1, random: &random),
            ellipseStroke(center, jitteredRX, jitteredRY, increment: increment, overlap: overlap, jitter: 1.5, random: &random),
        ]
    }

    /// Random value in [-range, range], scaled by roughness and a gain that calms long lines.
    static func offset(_ range: CGFloat, _ random: inout Random, gain: CGFloat = 1) -> CGFloat {
        between(-range, range, &random) * gain
    }

    static func between(_ low: CGFloat, _ high: CGFloat, _ random: inout Random) -> CGFloat {
        roughness * (random.next() * (high - low) + low)
    }

    static func bowedLine(_ a: CGPoint, _ b: CGPoint, random: inout Random, overlay: Bool) -> Stroke {
        let length = hypot(b.x - a.x, b.y - a.y)
        let gain: CGFloat = length < 200 ? 1 : length > 500 ? 0.4 : -0.0016668 * length + 1.233334
        var spread = maxOffset
        if spread * spread * 100 > length * length { spread = length / 10 }
        let half = spread / 2
        let diverge = 0.2 + random.next() * 0.2
        let midX = offset(bowing * maxOffset * (b.y - a.y) / 200, &random, gain: gain)
        let midY = offset(bowing * maxOffset * (a.x - b.x) / 200, &random, gain: gain)
        let range = overlay ? half : spread
        func jitter() -> CGFloat { offset(range, &random, gain: gain) }
        let start = CGPoint(x: a.x + jitter(), y: a.y + jitter())
        let control1 = CGPoint(x: midX + a.x + (b.x - a.x) * diverge + jitter(), y: midY + a.y + (b.y - a.y) * diverge + jitter())
        let control2 = CGPoint(x: midX + a.x + 2 * (b.x - a.x) * diverge + jitter(), y: midY + a.y + 2 * (b.y - a.y) * diverge + jitter())
        let end = CGPoint(x: b.x + jitter(), y: b.y + jitter())
        return Stroke(start: start, curves: [.init(control1: control1, control2: control2, end: end)])
    }

    static func ellipseStroke(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, increment: CGFloat, overlap: CGFloat, jitter: CGFloat, random: inout Random) -> Stroke {
        let startAngle = offset(0.5, &random) - .pi / 2
        func point(_ angle: CGFloat, _ scale: CGFloat) -> CGPoint {
            CGPoint(x: offset(jitter, &random) + c.x + scale * rx * cos(angle), y: offset(jitter, &random) + c.y + scale * ry * sin(angle))
        }
        var points = [point(startAngle - increment, 0.9)]
        var angle = startAngle
        while angle < startAngle + 2 * .pi - 0.01 {
            points.append(point(angle, 1))
            angle += increment
        }
        points.append(point(startAngle + 2 * .pi + overlap * 0.5, 1))
        points.append(point(startAngle + overlap, 0.98))
        points.append(point(startAngle + overlap * 0.5, 0.9))
        return catmullRom(points)
    }

    /// Curve through points[1]…points[n-2], using the outer points only as tangents.
    static func catmullRom(_ points: [CGPoint]) -> Stroke {
        var curves: [Stroke.Cubic] = []
        for i in 1..<(points.count - 2) {
            let p0 = points[i - 1], p1 = points[i], p2 = points[i + 1], p3 = points[i + 2]
            curves.append(.init(control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                                end: p2))
        }
        return Stroke(start: points[1], curves: curves)
    }
}
