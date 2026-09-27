import CoreGraphics

/// Where the canvas's screen-sized "needs you" pills go, in window space (points, y down): a
/// bubble beside each object on screen that needs the user (an attention marker's, or a blocked
/// agent's terminal's), and an edge pill at the rim of the area the chrome leaves clear for each
/// offscreen one. No pill covers another, and no pill covers a blocked terminal other than its
/// own (its approval prompt is what the user must read) or the tile the user is typing in
/// (`focused`). A bubble sits outside its object: above it, else beside it (right, then left),
/// else below, wherever that covers no other tile; failing that, slid along one of those sides
/// to a free stretch, or as near to one of those or to the top of the object's body as the
/// other pills allow, weighing what it hides (other tiles' title bars count most). It never
/// covers the object's own header (a tile's title bar, a browser's address bar), whose controls
/// stay clickable. Edge pills are compact and slide along their edge off pills, blocked and
/// focused terminals, and tiles' title bars. Everything stays inside `clear` (between the
/// toolbar and the tray), so no pill sits under the chrome.
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
        /// Height of the object's header on screen (title bar, plus a browser's address bar),
        /// which its bubble never covers; 0 for objects without one.
        public var header: CGFloat
        /// A blocked agent's terminal rather than an attention marker: placed first, and never
        /// covered by another bubble.
        public var blocked: Bool

        public init(id: String, target: CGRect, ringInset: CGFloat, size: CGSize, header: CGFloat, blocked: Bool = false) {
            self.id = id
            self.target = target
            self.ringInset = ringInset
            self.size = size
            self.header = header
            self.blocked = blocked
        }
    }

    /// A tile on screen: its rect and the height of its header (title bar plus a content strip
    /// like a browser's address bar), whose controls a pill covers only as a last resort.
    public struct Tile: Sendable {
        public var id: String
        public var rect: CGRect
        public var header: CGFloat

        public init(id: String, rect: CGRect, header: CGFloat = 0) {
            self.id = id
            self.rect = rect
            self.header = header
        }

        var headerRect: CGRect { CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(header, rect.height)) }
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
        /// Attention markers' bubbles.
        public var bubbles: [String: CGRect]
        /// Blocked terminals' bubbles.
        public var blocked: [String: CGRect]
        public var edges: [String: CGRect]
    }

    /// A bubble's width for a message `natural` points wide on an object `ringWidth` wide on screen.
    public static func bubbleWidth(natural: CGFloat, ringWidth: CGFloat) -> CGFloat {
        min(natural, maxBubbleWidth, max(minBubbleWidth, ringWidth))
    }

    /// Hidden area of a tile's header counts this many times as much as its body: title bars and
    /// address bars hold the controls and the name that say what the tile is.
    static let headerWeight: CGFloat = 4

    /// `tiles`: every tile's rect on screen (a bubble avoids covering tiles other than its own).
    /// `focused`: the tile with the keyboard, which no pill covers when there is any other place,
    /// and `caret` the row being typed in there (a terminal's cursor line), which no pill covers
    /// unless pills fill the view. Blocked terminals' bubbles are placed first, then markers'
    /// (each group top to bottom), then edge pills, which also keep clear of them.
    public static func place(markers: [Marker], edges: [Edge], tiles: [Tile], focused: String? = nil, caret: CGRect? = nil, clear: CGRect) -> Placement {
        var placed: [CGRect] = caret.map { [$0] } ?? []
        var bubbles: [String: CGRect] = [:]
        var blocked: [String: CGRect] = [:]
        // What no bubble but a terminal's own may cover: each blocked terminal inside its ring,
        // and the tile the user is typing in.
        var prompts = markers.filter(\.blocked).map { (id: $0.id, rect: $0.target.insetBy(dx: -$0.ringInset, dy: -$0.ringInset)) }
        if let focused, !prompts.contains(where: { $0.id == focused }), let tile = tiles.first(where: { $0.id == focused }) {
            prompts.append((focused, tile.rect))
        }
        let ordered = markers.sorted { ($0.blocked ? 0 : 1, $0.target.minY, $0.target.minX, $0.id) < ($1.blocked ? 0 : 1, $1.target.minY, $1.target.minX, $1.id) }
        for marker in ordered {
            let rect = bubble(marker, placed: placed, keepOff: prompts.filter { $0.id != marker.id }.map(\.rect), tiles: tiles, clear: clear)
            if marker.blocked { blocked[marker.id] = rect } else { bubbles[marker.id] = rect }
            placed.append(rect)
        }
        var pills: [String: CGRect] = [:]
        let onScreenPrompts = prompts.map(\.rect)
        let headers = tiles.map(\.headerRect).filter { !$0.isEmpty && $0.intersects(clear) }
        for edge in edges.sorted(by: { $0.id < $1.id }) {
            let rect = edgePill(edge, placed: placed, keepOff: onScreenPrompts, headers: headers, clear: clear)
            pills[edge.id] = rect
            placed.append(rect)
        }
        return Placement(bubbles: bubbles, blocked: blocked, edges: pills)
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

    /// Origins that sit `spacing` beside each rect, on either side, along one axis, for rects
    /// that cross the band `band` (the other axis's span the pill would occupy).
    private static func slides(length: CGFloat, around rects: [CGRect], axis: KeyPath<CGRect, CGFloat>, far: KeyPath<CGRect, CGFloat>, crossing band: CGRect) -> [CGFloat] {
        rects.filter { $0.intersects(band) }.flatMap { [$0[keyPath: far] + spacing, $0[keyPath: axis] - spacing - length] }
    }

    /// `keepOff`: other blocked terminals (ring included) and the focused tile, which the bubble
    /// treats like pills.
    private static func bubble(_ marker: Marker, placed pills: [CGRect], keepOff: [CGRect], tiles: [Tile], clear: CGRect) -> CGRect {
        let placed = pills + keepOff
        let size = marker.size
        let target = marker.target
        let ring = target.insetBy(dx: -marker.ringInset, dy: -marker.ringInset)
        let header = CGRect(x: target.minX, y: target.minY, width: target.width, height: marker.header)
        // Outside the ring: above it (left-aligned), beside it on the right and the left
        // (top-aligned), below it (left-aligned).
        let outside = [
            CGRect(x: ring.minX, y: ring.minY - spacing - size.height, width: size.width, height: size.height),
            CGRect(x: ring.maxX + spacing, y: ring.minY, width: size.width, height: size.height),
            CGRect(x: ring.minX - spacing - size.width, y: ring.minY, width: size.width, height: size.height),
            CGRect(x: ring.minX, y: ring.maxY + spacing, width: size.width, height: size.height),
        ].map { clamp($0, into: clear, margin: bubbleMargin) }
        // When the object fills the view: on its body, just below its header.
        let inside = clamp(CGRect(x: target.minX + spacing, y: target.minY + marker.header + spacing, width: size.width, height: size.height),
                           into: clear, margin: bubbleMargin)
        let others = tiles.filter { $0.id != marker.id }
        let otherRects = others.map(\.rect)
        let otherHeaders = others.map(\.headerRect).filter { !$0.isEmpty }
        func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let part = a.intersection(b)
            return part.isNull ? 0 : part.width * part.height
        }
        // Area of other tiles the rect covers, their headers weighing more.
        func covered(_ rect: CGRect) -> CGFloat {
            otherRects.reduce(0) { $0 + area($1, rect) } + (headerWeight - 1) * otherHeaders.reduce(0) { $0 + area($1, rect) }
        }
        // A spot outside that the clear area holds without pushing it onto the ring, covering
        // neither a pill nor more than a sliver of a tile.
        if let clean = outside.first(where: { !$0.intersects(ring) && !overlapsPill($0, placed) && covered($0) < 100 }) { return clean }
        // Else, covering no pill and not the header, the spot with the least hidden (other
        // tiles, and its own object's body) plus distance moved from one of those spots (hidden
        // area counts as the length of bubble it hides, so a bubble never strays far from its
        // object to spare a sliver); ties go to the preferred spot. Above and below, a bubble
        // slides sideways along its side past the tiles there; beside, up and down.
        var best: (rect: CGRect, cost: (Int, Int, CGFloat, Int))?
        for (index, base) in (outside + [inside]).enumerated() {
            let alongX = index == 0 || index == 3
            let alongY = index == 1 || index == 2
            var xs = escapes(base.minX, length: size.width, placed: placed, axis: \.minX, far: \.maxX)
            var ys = escapes(base.minY, length: size.height, placed: placed, axis: \.minY, far: \.maxY)
            if alongX { xs += slides(length: size.width, around: otherRects, axis: \.minX, far: \.maxX, crossing: CGRect(x: clear.minX, y: base.minY, width: clear.width, height: size.height)) }
            if alongY { ys += slides(length: size.height, around: otherRects, axis: \.minY, far: \.maxY, crossing: CGRect(x: base.minX, y: clear.minY, width: size.width, height: clear.height)) }
            for x in xs {
                for y in ys {
                    let rect = clamp(CGRect(x: x, y: y, width: size.width, height: size.height), into: clear, margin: bubbleMargin)
                    let pill = overlapsPill(rect, placed) ? 1 : 0
                    if let best, pill > best.cost.0 { continue }
                    let chrome = rect.intersects(header) ? 1 : 0
                    let distance = hypot(rect.minX - base.minX, rect.minY - base.minY)
                    let cost = (pill, chrome, ((covered(rect) + area(rect, target)) / size.height + distance).rounded(), index)
                    if best == nil || cost < best!.cost { best = (rect, cost) }
                }
            }
        }
        return best?.rect ?? inside
    }

    /// `keepOff`: blocked terminals and the focused tile on screen, and `headers` tiles' title
    /// bars, which an edge pill slides off along its edge when the edge has room (it never leaves
    /// the edge for them).
    private static func edgePill(_ edge: Edge, placed: [CGRect], keepOff: [CGRect], headers: [CGRect], clear: CGRect) -> CGRect {
        let size = edge.size
        let center = CGPoint(x: clear.midX, y: clear.midY)
        let dx = edge.target.x - center.x, dy = edge.target.y - center.y
        // Where the ray from the clear area's center to the target leaves it (inset).
        let halfW = clear.width / 2 - edgeMargin, halfH = clear.height / 2 - edgeMargin
        let t = min(dx == 0 ? .infinity : halfW / abs(dx), dy == 0 ? .infinity : halfH / abs(dy))
        let point = t.isFinite ? CGPoint(x: center.x + dx * t, y: center.y + dy * t) : center
        let ideal = clamp(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), into: clear, margin: edgeMargin)
        guard overlapsPill(ideal, placed) || overlapsPill(ideal, keepOff) || overlapsPill(ideal, headers) else { return ideal }
        // Along the edge it sits on first, off blocked and focused terminals, then off title bars
        // where the edge allows; stepping inward only when the edge is full of pills.
        let horizontal = ideal.minY <= clear.minY + 0.5 || ideal.maxY >= clear.maxY - 0.5
        let obstacles = placed + keepOff + headers
        let xs = escapes(ideal.minX, length: size.width, placed: horizontal ? obstacles : placed, axis: \.minX, far: \.maxX)
        let ys = escapes(ideal.minY, length: size.height, placed: horizontal ? placed : obstacles, axis: \.minY, far: \.maxY)
        var best: (rect: CGRect, cost: (Int, Int, Int, Int, CGFloat))?
        for x in xs {
            for y in ys {
                let rect = clamp(CGRect(x: x, y: y, width: size.width, height: size.height), into: clear, margin: edgeMargin)
                let across = horizontal ? abs(rect.minY - ideal.minY) : abs(rect.minX - ideal.minX)
                let cost = (overlapsPill(rect, placed) ? 1 : 0, across > 0.5 ? 1 : 0, overlapsPill(rect, keepOff) ? 1 : 0, overlapsPill(rect, headers) ? 1 : 0,
                            hypot(rect.minX - ideal.minX, rect.minY - ideal.minY).rounded())
                if best == nil || cost < best!.cost { best = (rect, cost) }
            }
        }
        return best?.rect ?? ideal
    }
}
