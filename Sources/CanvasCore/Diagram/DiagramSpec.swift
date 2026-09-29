import Foundation

/// What a diagram tile draws, computed from the code (`type: diagram`, `props.kind`). Each kind
/// has its own builder that fills a `DiagramGraph`; the tile, layout, freshness, mentions, and
/// arrow ends are shared.
public enum DiagramKind: String, CaseIterable, Codable, Sendable {
    /// The callers and callees of one function (LSP call hierarchy).
    case calls
}

/// Which side of the root a call graph grows: its callers, its callees, or both.
public enum CallDirection: String, CaseIterable, Codable, Sendable {
    case incoming, outgoing, both

    var includesIncoming: Bool { self != .outgoing }
    var includesOutgoing: Bool { self != .incoming }
}

/// A diagram tile's props (schema `DiagramProps`).
public struct DiagramSpec: Equatable, Sendable {
    public static let defaultDepth = 2
    public static let maxDepth = 4

    public var kind: DiagramKind
    /// The file declaring the root symbol: board-relative or absolute; nil to find `symbol`'s file.
    public var path: String?
    /// The root symbol, `Type.member` or a bare name (a function's parameter labels optional).
    public var symbol: String?
    /// 1-based line of the root's declaration (or inside its body) when there is no `symbol`.
    public var line: Int?
    public var direction: CallDirection
    /// Levels each side of the root shows unasked.
    public var depth: Int
    /// Nodes (`DiagramNode.id`) opened one more level than `depth` shows.
    public var expanded: [String]

    public init(kind: DiagramKind = .calls, path: String? = nil, symbol: String? = nil, line: Int? = nil, direction: CallDirection = .incoming,
                depth: Int = defaultDepth, expanded: [String] = []) {
        self.kind = kind
        self.path = path
        self.symbol = symbol
        self.line = line
        self.direction = direction
        self.depth = depth
        self.expanded = expanded
    }

    /// Lenient: what `validate` would reject reads as the default.
    public init(_ props: JSONValue) {
        func nonEmpty(_ key: String) -> String? { props[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(kind: props["kind"]?.string.flatMap(DiagramKind.init) ?? .calls, path: nonEmpty("path"), symbol: nonEmpty("symbol"),
                  line: props["line"]?.int.flatMap { $0 >= 1 ? $0 : nil },
                  direction: props["direction"]?.string.flatMap(CallDirection.init) ?? .incoming,
                  depth: min(max(props["depth"]?.int ?? Self.defaultDepth, 1), Self.maxDepth),
                  expanded: props["expanded"]?.array?.compactMap(\.string) ?? [])
    }

    /// The graph's subject: a graph computed for another aim is not this tile's past (no stale
    /// nodes carry over from it). Depth and expansions only change how much of it shows.
    public var aim: DiagramAim { DiagramAim(kind: kind, path: path, symbol: symbol, line: line, direction: direction) }

    /// The tile's title without `props.title`: `Callers of SocketServer.start`, naming the
    /// root as the props do (or as the graph resolved it).
    public static func title(_ props: JSONValue) -> String {
        if let title = props["title"]?.string, !title.isEmpty { return title }
        let spec = DiagramSpec(props)
        let graph = DiagramGraph(props["graph"])
        let root = spec.symbol ?? graph?.root.flatMap { graph?.node($0)?.qualifiedName } ?? spec.path.map { "\(PathLabel.short($0)):\(spec.line ?? 1)" } ?? "?"
        switch spec.direction {
        case .incoming: return "Callers of \(root)"
        case .outgoing: return "Calls from \(root)"
        case .both: return "Calls around \(root)"
        }
    }

    /// Why a diagram's props (as they will be after a create or update) can't be drawn: nil when
    /// they can.
    public static func problem(_ props: JSONValue) -> String? {
        if let kind = props["kind"], kind.string.flatMap(DiagramKind.init) == nil {
            return "diagram kind must be one of \(DiagramKind.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if let direction = props["direction"], direction.string.flatMap(CallDirection.init) == nil {
            return "direction must be one of \(CallDirection.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        if let depth = props["depth"], !(depth.int.map { (1...maxDepth).contains($0) } ?? false) {
            return "depth must be an integer from 1 to \(maxDepth)"
        }
        if let line = props["line"], !(line.int.map { $0 >= 1 } ?? false) { return "line is 1-based: an integer of at least 1" }
        if let expanded = props["expanded"], expanded.array?.allSatisfy({ $0.string != nil }) != true { return "expanded is an array of node ids" }
        let spec = DiagramSpec(props)
        if spec.symbol == nil, spec.path == nil { return "a calls diagram needs props.symbol (e.g. \"SocketServer.start\"), or props.path with a line or symbol" }
        if spec.symbol == nil, spec.line == nil { return "a calls diagram needs props.symbol or props.line to name its root function in \(spec.path ?? "the file")" }
        return nil
    }
}

/// What a diagram is of (`DiagramSpec.aim`), recorded with the graph computed for it.
public struct DiagramAim: Codable, Equatable, Sendable {
    public var kind: DiagramKind
    public var path: String?
    public var symbol: String?
    public var line: Int?
    public var direction: CallDirection
}
