import Foundation

/// One line of code a node shows: its signature, or where it makes the call its edge draws.
public struct DiagramExcerptLine: Codable, Equatable, Sendable {
    /// 1-based, in the node's file.
    public var line: Int
    /// Trimmed.
    public var text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// A symbol in a diagram, identified by what it is (file, container, name), not where it is,
/// so it keeps its identity (expansions, arrows bound to it) when code above it moves.
public struct DiagramNode: Codable, Equatable, Sendable {
    /// `path#Container.name`; a second symbol with the same identity gets `@line` appended.
    public var id: String
    public var name: String
    /// The enclosing type or module, when the server says.
    public var container: String?
    /// LSP symbol kind as a word ("method", "function").
    public var kind: String
    /// Board-relative (absolute outside the board root).
    public var path: String
    /// 1-based line of the name.
    public var line: Int
    /// The whole declaration.
    public var lines: LineRange
    /// 1–3 lines: for a caller, the lines making its calls toward the root; else the signature.
    public var excerpt: [DiagramExcerptLine]
    /// Columns from the root (0): callers negative, callees positive.
    public var level: Int
    /// Its symbol is gone from the code: the node stays as it last was, badged, until the
    /// symbol is back or the diagram is aimed elsewhere.
    public var stale: Bool?
    /// Its next level hasn't been asked for (beyond `depth`): a click expands it.
    public var expandable: Bool?
    /// Opened past `depth` by a click (`props.expanded`).
    public var expanded: Bool?

    public init(id: String, name: String, container: String?, kind: String, path: String, line: Int, lines: LineRange, excerpt: [DiagramExcerptLine],
                level: Int, stale: Bool? = nil, expandable: Bool? = nil, expanded: Bool? = nil) {
        self.id = id
        self.name = name
        self.container = container
        self.kind = kind
        self.path = path
        self.line = line
        self.lines = lines
        self.excerpt = excerpt
        self.level = level
        self.stale = stale
        self.expandable = expandable
        self.expanded = expanded
    }

    public var isStale: Bool { stale == true }

    /// `Container.name`, what a mention names the symbol by.
    public var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }

    /// What a Hyper-click on the node in diagram tile `object` mentions: a code mention of its
    /// symbol, with its declaration's lines, or the one excerpt line clicked.
    public func mention(in object: ObjectID, excerptLine: Int? = nil) -> MentionTarget {
        .code(object: object, path: path, lines: excerptLine.map { LineRange(start: $0, end: $0) } ?? lines, symbol: qualifiedName)
    }
}

/// A call, from caller to callee.
public struct DiagramEdge: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    /// 1-based lines of the calls, in `from`'s file.
    public var lines: [Int]
    /// An edge kept from before, into or out of a stale node.
    public var stale: Bool?

    public init(from: String, to: String, lines: [Int], stale: Bool? = nil) {
        self.from = from
        self.to = to
        self.lines = lines
        self.stale = stale
    }
}

/// A diagram as last computed (`props.graph`, written by the app, never an undo step):
/// what the tile draws, `object.get` reports, and arrows bound to its nodes attach to.
public struct DiagramGraph: Codable, Equatable, Sendable {
    public var aim: DiagramAim
    public var root: String?
    public var nodes: [DiagramNode]
    public var edges: [DiagramEdge]
    /// Why the graph is empty or old: no language server, no such symbol, the server failed.
    public var error: String?
    /// Nodes left out past `CallGraphBuilder.maxNodes`.
    public var omitted: Int?
    /// ISO 8601, when the language server was last asked.
    public var computedAt: String

    public init(aim: DiagramAim, root: String? = nil, nodes: [DiagramNode] = [], edges: [DiagramEdge] = [], error: String? = nil, omitted: Int? = nil,
                computedAt: String = DiagramGraph.now()) {
        self.aim = aim
        self.root = root
        self.nodes = nodes
        self.edges = edges
        self.error = error
        self.omitted = omitted
        self.computedAt = computedAt
    }

    /// `props.graph` as stored; nil when absent or unreadable.
    public init?(_ json: JSONValue?) {
        guard let json, json.object != nil, let graph = try? json.decode(DiagramGraph.self) else { return nil }
        self = graph
    }

    public var json: JSONValue { (try? JSONValue.encode(self)) ?? .null }

    public static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    public func node(_ id: String) -> DiagramNode? { nodes.first { $0.id == id } }

    // MARK: Freshness

    /// `fresh` as the tile shows it after `previous` (the graph it showed): nodes of `previous`
    /// missing from `fresh` whose symbols are `vanished` stay, stale, where they were, with their
    /// edges to what is still there; the rest of the missing (no longer a caller, collapsed, past
    /// a smaller depth) are gone. A graph of another aim carries nothing over.
    public static func merged(fresh: DiagramGraph, previous: DiagramGraph?, vanished: Set<String>) -> DiagramGraph {
        guard let previous, previous.aim == fresh.aim else { return fresh }
        var result = fresh
        let present = Set(fresh.nodes.map(\.id))
        for var node in previous.nodes where !present.contains(node.id) && vanished.contains(node.id) {
            node.stale = true
            node.expandable = nil
            result.nodes.append(node)
        }
        let kept = Set(result.nodes.map(\.id))
        let stale = kept.subtracting(present)
        let drawn = Set(fresh.edges.map { [$0.from, $0.to] })
        for var edge in previous.edges where kept.contains(edge.from) && kept.contains(edge.to) && !drawn.contains([edge.from, edge.to]) {
            guard stale.contains(edge.from) || stale.contains(edge.to) else { continue }
            edge.stale = true
            result.edges.append(edge)
        }
        return result
    }

    /// `previous` kept whole when the root itself can't be resolved any more: every node as it
    /// was, the root badged stale, and why.
    public static func stalled(_ previous: DiagramGraph, reason: String) -> DiagramGraph {
        var graph = previous
        graph.error = reason
        graph.computedAt = now()
        if let root = graph.root, let index = graph.nodes.firstIndex(where: { $0.id == root }) {
            graph.nodes[index].stale = true
            graph.nodes[index].expandable = nil
        }
        return graph
    }
}
