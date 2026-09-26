import Foundation

/// Carries out validated HTML tile messages against the board. The only native capabilities a
/// page has: read board files as excerpts, open code tiles, and keep its own `props.state`.
@MainActor
public enum HtmlChannel {
    public static let maxStateBytes = 256 * 1024

    public static func handle(_ message: HtmlMessage, tile: ObjectID, board: Board) async throws -> JSONValue {
        let object = try board.object(tile)
        switch message {
        case .excerpt(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: board.root)
            let excerpt = await offMain { SourceExcerpt.load(url: file.url, path: file.relative, lines: lines, symbol: symbol) }
            try Task.checkCancellation()
            return try JSONValue.encode(excerpt)

        case .openCode(let path, let lines, let symbol):
            let file = try HtmlKit.boardFile(path, root: board.root)
            var range = lines
            if range == nil, let symbol {
                range = await offMain { () -> LineRange? in
                    let excerpt = SourceExcerpt.load(url: file.url, path: file.relative, lines: nil, symbol: symbol)
                    return excerpt.stale ? nil : LineRange(start: excerpt.start, end: excerpt.end)
                }
                try Task.checkCancellation()
            }
            guard FileManager.default.fileExists(atPath: file.url.path) else { throw HtmlError.notFound(file.relative) }
            return try openCode(path: file.relative, range: range, symbol: symbol, beside: tile, on: board)

        case .getState(let key):
            let state = object.props["state"] ?? .object([:])
            return .object(["value": key.map { state[$0] ?? .null } ?? state])

        case .setState(let key, let value):
            var state = object.props["state"]?.object ?? [:]
            if value == .null { state.removeValue(forKey: key) } else { state[key] = value }
            let size = (try? JSONEncoder().encode(state).count) ?? Int.max
            guard size <= maxStateBytes else { throw HtmlError.tooLarge(size, limit: maxStateBytes) }
            try board.update(tile, props: .object(["state": .object(state)]))
            return .object([:])

        case .rendered:
            return .object([:])
        }
    }

    /// File reads run off the main actor and stop early when the requesting page goes away.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Re-aims the topmost code tile already showing `path` (follow tiles excluded: they belong
    /// to their agent), else creates one to the right of the HTML tile. The click is the user's.
    static func openCode(path: String, range: LineRange?, symbol: String?, beside tile: ObjectID, on board: Board) throws -> JSONValue {
        let rangeValue: JSONValue = range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        let existing = board.objects.values
            .filter { $0.type == .code && $0.props["path"]?.string == path && $0.props["followOf"] == nil }
            .max { $0.z < $1.z }
        if let existing {
            try board.update(existing.id, props: .object(["range": rangeValue, "symbol": symbol.map(JSONValue.string) ?? .null]))
            return .object(["tile": .string(existing.id), "created": .bool(false)])
        }
        var props: [String: JSONValue] = ["path": .string(path), "mode": .string("source"), "range": rangeValue]
        if let symbol { props["symbol"] = .string(symbol) }
        let size = Board.defaultSize(.code)
        let created = board.create(type: .code, props: .object(props.filter { $0.value != .null }), frame: board.place(width: size.w, height: size.h, near: tile))
        return .object(["tile": .string(created.id), "created": .bool(true)])
    }
}
