import Foundation

/// A freehand selection outline (closed implicitly from the last point back to the first).
/// Selection is by containment: a frame is selected only when it lies wholly inside.
public struct Lasso: Sendable {
    public var points: [(x: Double, y: Double)]

    public init(points: [(x: Double, y: Double)]) {
        self.points = points
    }

    /// Even-odd ray casting; points exactly on an edge count as inside or outside arbitrarily.
    public func contains(x: Double, y: Double) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// All four corners inside and no lasso edge crossing into the frame, so a concave lasso
    /// that dips between two corners does not select what it cuts through.
    public func contains(_ frame: Frame) -> Bool {
        let corners = [(frame.x, frame.y), (frame.maxX, frame.y), (frame.maxX, frame.maxY), (frame.x, frame.maxY)]
        guard corners.allSatisfy({ contains(x: $0.0, y: $0.1) }) else { return false }
        var j = points.count - 1
        for i in points.indices {
            if Self.segment(points[j], points[i], crosses: frame) { return false }
            j = i
        }
        return true
    }

    /// Whether segment a–b passes through the frame's interior.
    static func segment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), crosses frame: Frame) -> Bool {
        // Liang–Barsky clip against the open rectangle.
        var t0 = 0.0, t1 = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - frame.x), (dx, frame.maxX - a.x), (-dy, a.y - frame.y), (dy, frame.maxY - a.y)] {
            if p == 0 {
                if q <= 0 { return false }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 >= t1 { return false }
            }
        }
        return true
    }
}
