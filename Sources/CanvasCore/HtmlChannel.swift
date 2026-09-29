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
    /// A page with a `ref` reads its excerpts where the ref is now (`Board.linkSource`): the live
    /// worktree, else git objects at the ref's commit.
    public static func handle(_ message: HtmlMessage, tile: ObjectID, board: Board) async throws -> JSONValue {
        let object = board.objects[tile]
        let reading = if let object, RefSource.ref(of: object.props) != nil { await board.linkSource(of: object) } else { LinkReading(root: object.map(board.linkRoot(of:)) ?? board.root) }
        let root = reading.root
        switch message {
        case .excerpt(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: root)
            let excerpt: SourceExcerpt
            if let commit = reading.commit {
                do {
                    let text = try await reading.read(file.relative)
                    excerpt = await offMain { SourceExcerpt.resolve(text: text, path: file.relative, lines: lines, symbol: symbol) }
                } catch {
                    let reason = reading.failure?.reason ?? "\(file.relative) not found at \(commit.prefix(7))"
                    excerpt = SourceExcerpt(path: file.relative, start: 0, end: 0, lines: [], symbol: symbol, language: SourceExcerpt.language(for: file.relative), stale: true, reason: reason, truncated: false)
                }
            } else {
                excerpt = await offMain { SourceExcerpt.load(url: file.url, path: file.relative, lines: lines, symbol: symbol) }
            }
            try Task.checkCancellation()
            return try JSONValue.encode(excerpt)

        case .openCode(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: root)
            let ref = object.flatMap { RefSource.ref(of: $0.props) }
            if ref != nil, reading.commit != nil {
                // The ref's objects: the code tile opens at the same ref and finds the symbol itself.
                return openCode(path: board.boardPath(file.relative, linkRoot: root), range: lines, symbol: symbol, ref: ref, beside: tile, on: board)
            }
            var range = lines
            if range == nil, let symbol {
                range = await offMain { () -> LineRange? in
                    let excerpt = SourceExcerpt.load(url: file.url, path: file.relative, lines: nil, symbol: symbol)
                    return excerpt.stale ? nil : LineRange(start: excerpt.start, end: excerpt.end)
                }
                try Task.checkCancellation()
            }
            guard FileManager.default.fileExists(atPath: file.url.path) else { throw HtmlError.notFound(file.relative) }
            return openCode(path: board.boardPath(file.relative, linkRoot: root), range: range, symbol: symbol, ref: ref, beside: tile, on: board)

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

    /// The user's navigation to code from the HTML tile (`Board.openForNavigation`): a tile
    /// already showing the lines anywhere (`existing`, a walkthrough's stop), else a plain code
    /// tile in view showing `path` re-aimed, else a new one to the right of the HTML tile.
    static func openCode(path: String, range: LineRange?, symbol: String?, ref: String?, beside tile: ObjectID, on board: Board) -> JSONValue {
        let opened = board.openForNavigation(CodeAim(path: path, range: range, symbol: symbol, ref: ref), from: tile)
        return .object(["tile": .string(opened.id), "created": .bool(opened.created), "existing": .bool(opened.existing)])
    }
}
