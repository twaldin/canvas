import CoreGraphics
import Foundation

/// Pure geometry for the shape layer: arrow routing between bound outlines and hit testing that
/// only counts strokes, text, and fills (an unfilled shape's interior never blocks what's beneath).
public enum DrawingGeometry {
    public static let strokeWidth: CGFloat = 2
    /// Diameter of an ink stroke at half pressure.
    public static let inkSize: CGFloat = 6
    /// Space between an arrow tip and the outline it's bound to.
    public static let arrowGap: CGFloat = 6
    /// Rough strokes wander up to this far from the ideal outline.
    static let jitterAllowance: CGFloat = 2

    /// What a bound arrow end attaches to.
    public enum Outline: Equatable, Sendable {
        case rect(CGRect)
        case ellipse(CGRect)

        public var bounds: CGRect {
            switch self {
            case .rect(let rect), .ellipse(let rect): rect
            }
        }
    }

    public enum ArrowEnd: Equatable, Sendable {
        case point(CGPoint)
        case bound(Outline)

        /// What the other end aims at: the outline's bounds, or the point.
        public var aim: CGRect {
            switch self {
            case .point(let point): CGRect(origin: point, size: .zero)
            case .bound(let outline): outline.bounds
            }
        }
    }

    // MARK: Arrow routing

    /// Straight route between two ends. A bound end leaves from the side of its outline that faces
    /// the other end: when the two sit side by side (or stacked) with overlapping extents the arrow
    /// runs orthogonally through the middle of the overlap, otherwise it aims center to center.
    /// `offset` moves the whole route sideways (positive: left of travel), staying within the
    /// overlap for orthogonal runs.
    public static func route(from: ArrowEnd, to: ArrowEnd, gap: CGFloat = arrowGap, offset: CGFloat = 0) -> (start: CGPoint, end: CGPoint) {
        var shift = CGPoint.zero
        if offset != 0 {
            let a = from.aim
            let b = to.aim
            let d = CGPoint(x: b.midX - a.midX, y: b.midY - a.midY)
            let length = hypot(d.x, d.y)
            if length > 0 { shift = CGPoint(x: d.y / length * offset, y: -d.x / length * offset) }
        }
        return (attach(from, toward: to.aim, gap: gap, shift: shift), attach(to, toward: from.aim, gap: gap, shift: shift))
    }

    static func attach(_ end: ArrowEnd, toward other: CGRect, gap: CGFloat, shift: CGPoint = .zero) -> CGPoint {
        let outline: Outline
        switch end {
        case .point(let point): return point
        case .bound(let bound): outline = bound
        }
        let rect = outline.bounds
        let yRange = (max(rect.minY, other.minY), min(rect.maxY, other.maxY))
        let xRange = (max(rect.minX, other.minX), min(rect.maxX, other.maxX))
        if yRange.0 <= yRange.1, other.minX >= rect.maxX || other.maxX <= rect.minX {
            let right = other.minX >= rect.maxX
            let y = clamp((yRange.0 + yRange.1) / 2 + shift.y, yRange.0 + 2, yRange.1 - 2)
            let edge = boundary(outline, from: CGPoint(x: rect.midX, y: y), direction: CGPoint(x: right ? 1 : -1, y: 0))
            return CGPoint(x: edge.x + (right ? gap : -gap), y: y)
        }
        if xRange.0 <= xRange.1, other.minY >= rect.maxY || other.maxY <= rect.minY {
            let down = other.minY >= rect.maxY
            let x = clamp((xRange.0 + xRange.1) / 2 + shift.x, xRange.0 + 2, xRange.1 - 2)
            let edge = boundary(outline, from: CGPoint(x: x, y: rect.midY), direction: CGPoint(x: 0, y: down ? 1 : -1))
            return CGPoint(x: x, y: edge.y + (down ? gap : -gap))
        }
        let center = CGPoint(x: clamp(rect.midX + shift.x, rect.minX + 2, rect.maxX - 2), y: clamp(rect.midY + shift.y, rect.minY + 2, rect.maxY - 2))
        var direction = CGPoint(x: other.midX + shift.x - center.x, y: other.midY + shift.y - center.y)
        let length = hypot(direction.x, direction.y)
        direction = length > 0 ? CGPoint(x: direction.x / length, y: direction.y / length) : CGPoint(x: 0, y: -1)
        let edge = boundary(outline, from: center, direction: direction)
        return CGPoint(x: edge.x + direction.x * gap, y: edge.y + direction.y * gap)
    }

    /// Midpoint of the overlap of two closed intervals, nil when they don't overlap.
    static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat? {
        let low = max(a0, b0)
        let high = min(a1, b1)
        return low <= high ? (low + high) / 2 : nil
    }

    /// Where a ray from `origin` (inside the outline) along a unit `direction` leaves the outline.
    static func boundary(_ outline: Outline, from origin: CGPoint, direction: CGPoint) -> CGPoint {
        switch outline {
        case .rect(let rect):
            let tx = direction.x > 0 ? (rect.maxX - origin.x) / direction.x : direction.x < 0 ? (rect.minX - origin.x) / direction.x : .infinity
            let ty = direction.y > 0 ? (rect.maxY - origin.y) / direction.y : direction.y < 0 ? (rect.minY - origin.y) / direction.y : .infinity
            let t = max(0, min(tx, ty))
            return CGPoint(x: origin.x + direction.x * t, y: origin.y + direction.y * t)
        case .ellipse(let rect):
            // Solve |((o + t·d) - c) / r|² = 1 for the positive root.
            let rx = max(rect.width / 2, 0.0001)
            let ry = max(rect.height / 2, 0.0001)
            let ox = (origin.x - rect.midX) / rx
            let oy = (origin.y - rect.midY) / ry
            let dx = direction.x / rx
            let dy = direction.y / ry
            let a = dx * dx + dy * dy
            let b = 2 * (ox * dx + oy * dy)
            let c = ox * ox + oy * oy - 1
            let t = a > 0 ? max(0, (-b + (b * b - 4 * a * c).squareRoot()) / (2 * a)) : 0
            return CGPoint(x: origin.x + direction.x * t, y: origin.y + direction.y * t)
        }
    }

    /// Two short strokes forming the arrowhead at `end`, pointing along start → end.
    public static func arrowhead(start: CGPoint, end: CGPoint, length: CGFloat = 12) -> (CGPoint, CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 7
        let size = min(length, hypot(end.x - start.x, end.y - start.y) / 2)
        return (CGPoint(x: end.x - size * cos(angle - spread), y: end.y - size * sin(angle - spread)),
                CGPoint(x: end.x - size * cos(angle + spread), y: end.y - size * sin(angle + spread)))
    }

    // MARK: Hit testing

    /// Whether `point` (same coordinates as `frame`) hits the drawn shape: its stroke within
    /// `tolerance`, its text, or its fill. `labelRect` is the laid-out label of a rect/ellipse;
    /// `inkOutline` is the painted outline polygon of an ink stroke (`DrawingInk.outline`).
    public static func hits(_ shape: ShapeSpec, frame: CGRect, at point: CGPoint, tolerance: CGFloat, labelRect: CGRect? = nil, inkOutline: [CGPoint] = []) -> Bool {
        if let labelRect, labelRect.contains(point) { return true }
        let reach = tolerance + strokeWidth / 2 + jitterAllowance
        switch shape.kind {
        case .text:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rect:
            if shape.fill != .none, frame.contains(point) { return true }
            return distanceToRectBorder(point, frame) <= reach
        case .ellipse:
            if shape.fill != .none, ellipseContains(frame, point) { return true }
            return distanceToEllipse(point, frame) <= reach
        case .ink:
            return polygonContains(inkOutline, point) || distanceToPolygon(point, inkOutline) <= tolerance
        }
    }

    /// Nonzero winding: the stroke outline can cross itself where the ink loops.
    static func polygonContains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var winding = 0
        var a = polygon[polygon.count - 1]
        for b in polygon {
            let side = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
            if a.y <= p.y {
                if b.y > p.y, side > 0 { winding += 1 }
            } else if b.y <= p.y, side < 0 {
                winding -= 1
            }
            a = b
        }
        return winding != 0
    }

    static func distanceToPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> CGFloat {
        guard var a = polygon.last else { return .infinity }
        var best = CGFloat.infinity
        for b in polygon {
            best = min(best, distanceToSegment(p, a, b))
            a = b
        }
        return best
    }

    public static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distanceToRectBorder(_ p: CGPoint, _ rect: CGRect) -> CGFloat {
        if rect.contains(p) {
            return min(p.x - rect.minX, rect.maxX - p.x, p.y - rect.minY, rect.maxY - p.y)
        }
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return hypot(dx, dy)
    }

    static func ellipseContains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        let rx = rect.width / 2
        let ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (p.x - rect.midX) / rx
        let ny = (p.y - rect.midY) / ry
        return nx * nx + ny * ny <= 1
    }

    /// Distance to the ellipse outline measured along the ray from its center (exact on the axes,
    /// close enough elsewhere for a pointer tolerance).
    static func distanceToEllipse(_ p: CGPoint, _ rect: CGRect) -> CGFloat {
        let rx = max(rect.width / 2, 0.0001)
        let ry = max(rect.height / 2, 0.0001)
        let dx = p.x - rect.midX
        let dy = p.y - rect.midY
        let radius = hypot(dx, dy)
        guard radius > 0 else { return min(rx, ry) }
        let normalized = hypot(dx / rx, dy / ry)
        return abs(radius - radius / normalized)
    }
}
