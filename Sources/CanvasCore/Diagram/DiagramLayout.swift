import CoreGraphics
import Foundation

/// Where a diagram's nodes sit: a layered graph, one column per level (callers left of the
/// root, callees right), each column ordered by where its neighbours toward the root are
/// (fewer crossings) and centred on the tallest. Deterministic from the graph alone, so the
/// tile, `object.measure`, and arrows bound to a node (`BoardGeometry`) agree on every rect.
public struct DiagramLayout: Equatable, Sendable {
    public static let nodeWidth: CGFloat = 300
    public static let columnGap: CGFloat = 76
    public static let rowGap: CGFloat = 14
    /// Room around the columns: a call within one column loops out into it.
    public static let margin: CGFloat = 36
    /// The status strip above the graph (what it shows, when computed, why it failed).
    public static let headerHeight: CGFloat = 28
    public static let padding: CGFloat = 8
    public static let nameHeight: CGFloat = 18
    public static let placeHeight: CGFloat = 16
    public static let excerptLineHeight: CGFloat = 16
    /// The tile's body when there is no graph yet (computing, or it failed).
    public static let emptySize = CGSize(width: 520, height: 160)

    /// Each node's box in graph coordinates (origin at the graph's top-left, margins included).
    public var rects: [String: CGRect]
    /// The graph's extent, margins included; the header is not part of it.
    public var size: CGSize

    public init(_ graph: DiagramGraph) {
        var rects: [String: CGRect] = [:]
        let levels = Array(Set(graph.nodes.map(\.level))).sorted()
        guard !levels.isEmpty else {
            self.rects = [:]
            size = CGSize(width: Self.emptySize.width, height: Self.emptySize.height - Self.headerHeight)
            return
        }
        var neighbours: [String: [String]] = [:]
        for edge in graph.edges {
            neighbours[edge.from, default: []].append(edge.to)
            neighbours[edge.to, default: []].append(edge.from)
        }
        let levelOf = Dictionary(graph.nodes.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        var columns: [Int: [DiagramNode]] = Dictionary(grouping: graph.nodes, by: \.level)
        // Outward from the root: a column sorts by the mean position of its neighbours in the
        // column nearer the root, already placed.
        var position: [String: Double] = [:]
        for level in levels.sorted(by: { abs($0) < abs($1) || (abs($0) == abs($1) && $0 < $1) }) {
            let inward = level == 0 ? 0 : level > 0 ? level - 1 : level + 1
            let nodes = columns[level] ?? []
            func key(_ node: DiagramNode) -> Double {
                let placed = (neighbours[node.id] ?? []).filter { levelOf[$0] == inward }.compactMap { position[$0] }
                return placed.isEmpty ? .greatestFiniteMagnitude : placed.reduce(0, +) / Double(placed.count)
            }
            let sorted = nodes.enumerated().sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
            columns[level] = sorted
            for (index, node) in sorted.enumerated() { position[node.id] = Double(index) }
        }
        let heights = columns.mapValues { nodes in nodes.reduce(0) { $0 + Self.height(of: $1) } + CGFloat(max(0, nodes.count - 1)) * Self.rowGap }
        let tallest = heights.values.max() ?? 0
        for (column, level) in levels.enumerated() {
            let x = Self.margin + CGFloat(column) * (Self.nodeWidth + Self.columnGap)
            var y = Self.margin + (tallest - (heights[level] ?? 0)) / 2
            for node in columns[level] ?? [] {
                let height = Self.height(of: node)
                rects[node.id] = CGRect(x: x, y: y, width: Self.nodeWidth, height: height)
                y += height + Self.rowGap
            }
        }
        self.rects = rects
        size = CGSize(width: 2 * Self.margin + CGFloat(levels.count) * Self.nodeWidth + CGFloat(levels.count - 1) * Self.columnGap,
                      height: 2 * Self.margin + tallest)
    }

    public static func height(of node: DiagramNode) -> CGFloat {
        2 * padding + nameHeight + placeHeight + CGFloat(node.excerpt.count) * excerptLineHeight + (node.excerpt.isEmpty ? 0 : 4)
    }

    /// The body a tile needs to show the whole graph at full size.
    public var bodySize: CGSize { CGSize(width: max(size.width, Self.emptySize.width), height: Self.headerHeight + size.height) }

    /// How the graph is drawn in a body of `body` points: scaled down (never up) to fit below
    /// the header, centred.
    public func placement(in body: CGSize) -> (scale: CGFloat, origin: CGPoint) {
        let room = CGSize(width: body.width, height: max(1, body.height - Self.headerHeight))
        let scale = min(1, room.width / max(size.width, 1), room.height / max(size.height, 1))
        return (scale, CGPoint(x: (room.width - size.width * scale) / 2, y: Self.headerHeight + (room.height - size.height * scale) / 2))
    }

    /// `id`'s box in body points, as a tile of `body` draws it.
    public func rect(of id: String, in body: CGSize) -> CGRect? {
        guard let rect = rects[id] else { return nil }
        let (scale, origin) = placement(in: body)
        return CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// The excerpt row of `node` at graph-coordinate `y` inside its box (nil: its name or place).
    public static func excerptIndex(of node: DiagramNode, atY y: CGFloat, in rect: CGRect) -> Int? {
        let top = rect.minY + padding + nameHeight + placeHeight + 4
        guard y >= top else { return nil }
        let index = Int((y - top) / excerptLineHeight)
        return node.excerpt.indices.contains(index) ? index : nil
    }

    /// Where a diagram tile at `frame` with `props` draws node `id`, in canvas coordinates (title
    /// bar and `props.scale` included): what an arrow bound to the node attaches to.
    public static func canvasRect(of id: String, frame: Frame, props: JSONValue) -> CGRect? {
        guard let graph = DiagramGraph(props["graph"]) else { return nil }
        let scale = CGFloat(ObjectScale.of(props))
        let body = CGSize(width: CGFloat(frame.w) / scale, height: max(0, CGFloat(frame.h) / scale - CGFloat(RenderMath.tileTitleHeight)))
        guard let rect = DiagramLayout(graph).rect(of: id, in: body) else { return nil }
        return CGRect(x: CGFloat(frame.x) + scale * rect.minX, y: CGFloat(frame.y) + scale * (CGFloat(RenderMath.tileTitleHeight) + rect.minY),
                      width: scale * rect.width, height: scale * rect.height)
    }
}
