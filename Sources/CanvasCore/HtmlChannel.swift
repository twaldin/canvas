import Foundation

/// Carries out validated HTML tile messages against the board. The only native capabilities a
/// page has: read board files as excerpts, open code tiles, and keep its own `props.state`.
@MainActor
public enum HtmlChannel {
    public static let maxStateBytes = 256 * 1024

    /// A page's paths resolve against its tile's link root (`Board.linkRoot`). `tile` need only
    /// be on `board` for state messages: a page measured before its tile exists
    /// (`HtmlTile.measure`, on a scratch board rooted at the page's link root) reads excerpts
    /// against the board's root.
    public static func handle(_ message: HtmlMessage, tile: ObjectID, board: Board) async throws -> JSONValue {
        let root = board.objects[tile].map(board.linkRoot(of:)) ?? board.root
        switch message {
        case .excerpt(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: root)
            let excerpt = await offMain { SourceExcerpt.load(url: file.url, path: file.relative, lines: lines, symbol: symbol) }
            try Task.checkCancellation()
            return try JSONValue.encode(excerpt)

        case .openCode(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: root)
            var range = lines
            if range == nil, let symbol {
                range = await offMain { () -> LineRange? in
                    let excerpt = SourceExcerpt.load(url: file.url, path: file.relative, lines: nil, symbol: symbol)
                    return excerpt.stale ? nil : LineRange(start: excerpt.start, end: excerpt.end)
                }
                try Task.checkCancellation()
            }
            guard FileManager.default.fileExists(atPath: file.url.path) else { throw HtmlError.notFound(file.relative) }
            return openCode(path: board.boardPath(file.relative, linkRoot: root), range: range, symbol: symbol, beside: tile, on: board)

        case .getState(let key):
            return state(try board.object(tile).props, key: key)

        case .setState(let key, let value):
            var state = try board.object(tile).props["state"]?.object ?? [:]
            if value == .null { state.removeValue(forKey: key) } else { state[key] = value }
            let size = (try? JSONEncoder().encode(state).count) ?? Int.max
            guard size <= maxStateBytes else { throw HtmlError.tooLarge(size, limit: maxStateBytes) }
            try board.update(tile, props: .object(["state": .object(state)]))
            return .object([:])

        case .rendered:
            return .object([:])
        }
    }

    /// The `state.get` reply for a tile with `props`: one key's value, or the whole state.
    public static func state(_ props: JSONValue, key: String?) -> JSONValue {
        let state = props["state"] ?? .object([:])
        return .object(["value": key.map { state[$0] ?? .null } ?? state])
    }

    /// File reads run off the main actor and stop early when the requesting page goes away.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The user's navigation to code from the HTML tile (`Board.openForNavigation`): a plain
    /// code tile in view showing `path` re-aimed, else a new one to the right of the HTML tile.
    static func openCode(path: String, range: LineRange?, symbol: String?, beside tile: ObjectID, on board: Board) -> JSONValue {
        let opened = board.openForNavigation(CodeAim(path: path, range: range, symbol: symbol), from: tile)
        return .object(["tile": .string(opened.id), "created": .bool(opened.created)])
    }
}
