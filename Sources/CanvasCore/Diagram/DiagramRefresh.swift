import Foundation

/// Computes a diagram tile's graph from the code and writes it back as `props.graph`
/// (bookkeeping: no rev, no undo step), for the tile (on creation, a file change, a click that
/// expands a node) and for `object.reload`.
@MainActor
public enum DiagramRefresh {
    /// The graph written, or nil when the object is gone or was re-aimed, re-expanded, or
    /// re-scoped while this ran (the refresh that change started writes instead).
    public static func run(_ id: ObjectID, on board: Board, languages: LanguageService) async throws -> DiagramGraph? {
        guard let object = board.objects[id], object.type == .diagram else { return nil }
        let spec = DiagramSpec(object.props)
        let previous = DiagramGraph(object.props["graph"])
        let graph: DiagramGraph
        switch spec.kind {
        case .calls: graph = try await CallGraphBuilder.build(spec, boardRoot: board.root, scope: scope(of: object, on: board), previous: previous, languages: languages)
        }
        guard let now = board.objects[id], DiagramSpec(now.props) == spec else { return nil }
        try board.writeBookkeeping(id, props: .object(["graph": graph.json]))
        return graph
    }

    /// The checkout a diagram is of (`CallGraphBuilder.build`'s `scope`): the one its root's file
    /// lies in (`path`, else the root node it last found), else the checkout of the agent that
    /// made it, else the one the user opened the board from (`Board.workingRoot`).
    static func scope(of diagram: CanvasObject, on board: Board) -> URL {
        let spec = DiagramSpec(diagram.props)
        let graph = DiagramGraph(diagram.props["graph"])
        if let path = spec.path ?? graph?.root.flatMap({ graph?.node($0)?.path }) { return board.checkoutRoot(of: path) }
        if case .agent(let tile) = diagram.createdBy, let checkout = board.callerCheckout(for: tile) { return URL(fileURLWithPath: checkout) }
        return board.workingRoot
    }

    /// What `object.reload` answers for a diagram: counts, not the graph (`object.get` has it).
    public static func summary(_ id: ObjectID, graph: DiagramGraph?, computed: Bool) -> JSONValue {
        var result: [String: JSONValue] = ["id": .string(id), "loaded": .bool(computed)]
        if let graph {
            result["nodes"] = .number(Double(graph.nodes.count))
            result["edges"] = .number(Double(graph.edges.count))
            result["stale"] = .array(graph.nodes.filter(\.isStale).map { .string($0.id) })
            if let root = graph.root { result["root"] = .string(root) }
            if let error = graph.error { result["error"] = .string(error) }
        }
        return .object(result)
    }
}
