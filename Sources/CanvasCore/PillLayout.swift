import CoreGraphics

/// Where the canvas's screen-sized "needs you" pills go, in window space (points, y down): a
/// marker's bubble beside its object on screen, and an edge pill at the rim of the area the
/// chrome leaves clear for each offscreen object that needs the user (a marker, a blocked
/// agent). No pill covers another; a bubble sits above its object when that covers no other
/// tile, else on the object's own title bar, else as near to either as the other pills allow;
/// edge pills slide along their edge. Everything stays inside `clear` (between the toolbar and
/// the tray), so no pill sits under the chrome.
public enum PillLayout {
    /// Room kept between two pills, and between a bubble and the ring around its object.
    public static let spacing: CGFloat = 6
    /// A bubble's and edge pill's distance from the clear area's left and right sides.
    public static let bubbleMargin: CGFloat = 10
    public static let edgeMargin: CGFloat = 16
    /// A bubble is never wider than this, nor wider than its ring when the ring is wider than
    /// `minBubbleWidth` (its text truncates, the whole message is its tooltip).
    public static let maxBubbleWidth: CGFloat = 480
    public static let minBubbleWidth: CGFloat = 240

    public struct Marker: Sendable {
        public var id: String
        /// The object's rect on screen.
        public var target: CGRect
        /// The ring's distance outside `target`.
        public var ringInset: CGFloat
        /// The bubble's size.
        public var size: CGSize
        /// Height of the object's title bar on screen; 0 for objects without one.
        public var titleBar: CGFloat

        public init(id: String, target: CGRect, ringInset: CGFloat, size: CGSize, titleBar: CGFloat) {
            self.id = id
            self.target = target
            self.ringInset = ringInset
            self.size = size
            self.titleBar = titleBar
        }
    }

    public struct Edge: Sendable {
        public var id: String
        /// The offscreen object's center.
        public var target: CGPoint
        public var size: CGSize

        public init(id: String, target: CGPoint, size: CGSize) {
            self.id = id
            self.target = target
            self.size = size
        }
    }

    public struct Placement: Equatable, Sendable {
        public var bubbles: [String: CGRect]
        public var edges: [String: CGRect]
    }

    /// A bubble's width for a message `natural` points wide on an object `ringWidth` wide on screen.
    public static func bubbleWidth(natural: CGFloat, ringWidth: CGFloat) -> CGFloat {
        min(natural, maxBubbleWidth, max(minBubbleWidth, ringWidth))
    }

    /// `tiles`: every tile's rect on screen (a bubble avoids covering tiles other than its own).
    /// Bubbles are placed first, top to bottom, then edge pills, which also keep clear of them.
    public static func place(markers: [Marker], edges: [Edge], tiles: [(id: String, rect: CGRect)], clear: CGRect) -> Placement {
        var placed: [CGRect] = []
        var bubbles: [String: CGRect] = [:]
        let ordered = markers.sorted { ($0.target.minY, $0.target.minX, $0.id) < ($1.target.minY, $1.target.minX, $1.id) }
        for marker in ordered {
            let rect = bubble(marker, placed: placed, tiles: tiles, clear: clear)
            bubbles[marker.id] = rect
            placed.append(rect)
        }
        var pills: [String: CGRect] = [:]
        for edge in edges.sorted(by: { $0.id < $1.id }) {
            let rect = edgePill(edge, placed: placed, clear: clear)
            pills[edge.id] = rect
            placed.append(rect)
        }
        return Placement(bubbles: bubbles, edges: pills)
    }

    /// Inside `clear`, `margin` from its sides.
    private static func clamp(_ rect: CGRect, into clear: CGRect, margin: CGFloat) -> CGRect {
        var rect = rect
        rect.origin.x = max(min(rect.minX, clear.maxX - margin - rect.width), clear.minX + margin)
        rect.origin.y = max(min(rect.minY, clear.maxY - rect.height), clear.minY)
        return rect
    }

    private static func overlapsPill(_ rect: CGRect, _ placed: [CGRect]) -> Bool {
        let room = spacing - 0.5
        return placed.contains { $0.insetBy(dx: -room, dy: -room).intersects(rect) }
    }

    /// Origins that sit `spacing` beside each placed pill, on either side, along one axis.
    private static func escapes(_ base: CGFloat, length: CGFloat, placed: [CGRect], axis: KeyPath<CGRect, CGFloat>, far: KeyPath<CGRect, CGFloat>) -> [CGFloat] {
        [base] + placed.flatMap { [$0[keyPath: far] + spacing, $0[keyPath: axis] - spacing - length] }
    }

    private static func bubble(_ marker: Marker, placed: [CGRect], tiles: [(id: String, rect: CGRect)], clear: CGRect) -> CGRect {
        let size = marker.size
        let ring = marker.target.insetBy(dx: -marker.ringInset, dy: -marker.ringInset)
        // Above the ring, left-aligned with it; then on the object's own title bar.
        let bases = [
            CGRect(x: ring.minX, y: ring.minY - spacing - size.height, width: size.width, height: size.height),
            CGRect(x: marker.target.minX + spacing, y: marker.target.minY + max(0, (marker.titleBar - size.height) / 2), width: size.width, height: size.height),
        ].map { clamp($0, into: clear, margin: bubbleMargin) }
        let others = tiles.filter { $0.id != marker.id }.map(\.rect)
        // Area of other tiles the rect covers.
        func covered(_ rect: CGRect) -> CGFloat {
            var area: CGFloat = 0
            for tile in others {
                let part = tile.intersection(rect)
                if !part.isNull { area += part.width * part.height }
            }
            return area
        }
        // Either spot as it is, when it covers neither a pill nor more than a sliver of a tile.
        if let clean = bases.first(where: { !overlapsPill($0, placed) && covered($0) < 100 }) { return clean }
        // Else, covering no pill, the spot with the least of other tiles covered plus distance
        // moved from either spot (covered area counts as the length of bubble it hides, so a
        // bubble never strays far from its object to spare a sliver); ties go to the preferred spot.
        var best: (rect: CGRect, cost: (Int, CGFloat, Int))?
        for (index, base) in bases.enumerated() {
            let xs = escapes(base.minX, length: size.width, placed: placed, axis: \.minX, far: \.maxX)
            let ys = escapes(base.minY, length: size.height, placed: placed, axis: \.minY, far: \.maxY)
            for x in xs {
                for y in ys {
                    let rect = clamp(CGRect(x: x, y: y, width: size.width, height: size.height), into: clear, margin: bubbleMargin)
                    let pill = overlapsPill(rect, placed) ? 1 : 0
                    if let best, pill > best.cost.0 { continue }
                    let distance = hypot(rect.minX - base.minX, rect.minY - base.minY)
                    let cost = (pill, (covered(rect) / size.height + distance).rounded(), index)
                    if best == nil || cost < best!.cost { best = (rect, cost) }
                }
            }
        }
        return best?.rect ?? bases[0]
    }

    private static func edgePill(_ edge: Edge, placed: [CGRect], clear: CGRect) -> CGRect {
        let size = edge.size
        let center = CGPoint(x: clear.midX, y: clear.midY)
        let dx = edge.target.x - center.x, dy = edge.target.y - center.y
        // Where the ray from the clear area's center to the target leaves it (inset).
        let halfW = clear.width / 2 - edgeMargin, halfH = clear.height / 2 - edgeMargin
        let t = min(dx == 0 ? .infinity : halfW / abs(dx), dy == 0 ? .infinity : halfH / abs(dy))
        let point = t.isFinite ? CGPoint(x: center.x + dx * t, y: center.y + dy * t) : center
        let ideal = clamp(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), into: clear, margin: edgeMargin)
        guard overlapsPill(ideal, placed) else { return ideal }
        // Along the edge it sits on first; stepping inward only when the edge is full.
        let horizontal = ideal.minY <= clear.minY + 0.5 || ideal.maxY >= clear.maxY - 0.5
        let xs = escapes(ideal.minX, length: size.width, placed: placed, axis: \.minX, far: \.maxX)
        let ys = escapes(ideal.minY, length: size.height, placed: placed, axis: \.minY, far: \.maxY)
        var best: (rect: CGRect, cost: (Int, Int, CGFloat))?
        for x in xs {
            for y in ys {
                let rect = clamp(CGRect(x: x, y: y, width: size.width, height: size.height), into: clear, margin: edgeMargin)
                let across = horizontal ? abs(rect.minY - ideal.minY) : abs(rect.minX - ideal.minX)
                let cost = (overlapsPill(rect, placed) ? 1 : 0, across > 0.5 ? 1 : 0, hypot(rect.minX - ideal.minX, rect.minY - ideal.minY).rounded())
                if best == nil || cost < best!.cost { best = (rect, cost) }
            }
        }
        return best?.rect ?? ideal
    }
}
