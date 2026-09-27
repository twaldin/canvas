import Foundation

/// The board root's files for Go to (⌘P): a fuzzy, case-insensitive subsequence match on the
/// repo-relative path, ranked the way quick-open pickers do (the file name over directories,
/// runs over scattered letters, word starts, then shorter paths).
public struct FileIndex: Sendable {
    struct Entry: Sendable {
        var path: String
        var lower: [UInt8]
        /// Where the file name starts in `lower`.
        var nameStart: Int
    }

    let entries: [Entry]
    /// Entry indices by file name (case-sensitive, as a reference spells it).
    private let byName: [Substring: [Int]]

    public init(paths: [String]) {
        entries = paths.map { path in
            let lower = Array(path.lowercased().utf8)
            let slash = lower.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
            return Entry(path: path, lower: lower, nameStart: slash)
        }
        var byName: [Substring: [Int]] = [:]
        for (index, path) in paths.enumerated() {
            byName[Self.name(path), default: []].append(index)
        }
        self.byName = byName
    }

    private static func name(_ path: String) -> Substring {
        path[(path.lastIndex(of: "/").map(path.index(after:)) ?? path.startIndex)...]
    }

    public var count: Int { entries.count }

    /// Every listed path, in listing order.
    public var paths: some Sequence<String> { entries.lazy.map(\.path) }

    /// Paths that are `suffix` or end with `/` + `suffix` (whole path components: `core.py`,
    /// `click/core.py`), in listing order.
    public func paths(endingWith suffix: String) -> [String] {
        let name = Self.name(suffix)
        guard !name.isEmpty, let indices = byName[name] else { return [] }
        return indices.map { entries[$0].path }.filter { $0 == suffix || $0.hasSuffix("/" + suffix) }
    }

    /// Paths `query` matches (whitespace ignored), best first, at most `limit`. An empty query
    /// matches nothing.
    public func search(_ query: String, limit: Int) -> [String] {
        let needle = Array(query.lowercased().utf8.filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") })
        guard !needle.isEmpty, limit > 0 else { return [] }
        var scored: [(score: Int, entry: Entry)] = []
        for entry in entries {
            if let score = Self.score(entry, needle) { scored.append((score, entry)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.lower.count != rhs.entry.lower.count { return lhs.entry.lower.count < rhs.entry.lower.count }
            return lhs.entry.path < rhs.entry.path
        }
        return scored.prefix(limit).map(\.entry.path)
    }

    /// Higher is better; nil when `needle` isn't a subsequence of the path.
    public static func score(_ path: String, query: String) -> Int? {
        FileIndex(paths: [path]).entries.first.flatMap { score($0, Array(query.lowercased().utf8)) }
    }

    static func score(_ entry: Entry, _ needle: [UInt8]) -> Int? {
        let hay = entry.lower
        guard needle.count <= hay.count else { return nil }
        // The rightmost alignment favors the file name, the leftmost a directory prefix
        // ("srcmain" → src/…/main.ts); take the better of the two.
        guard let right = align(needle, in: hay, fromEnd: true) else { return nil }
        let left = align(needle, in: hay, fromEnd: false) ?? right
        return max(rate(right, entry), rate(left, entry))
    }

    /// Indices of `needle` in `hay` matched greedily from the start or the end.
    private static func align(_ needle: [UInt8], in hay: [UInt8], fromEnd: Bool) -> [Int]? {
        var positions = [Int](repeating: 0, count: needle.count)
        if fromEnd {
            var h = hay.count - 1
            for n in stride(from: needle.count - 1, through: 0, by: -1) {
                while h >= 0, hay[h] != needle[n] { h -= 1 }
                guard h >= 0 else { return nil }
                positions[n] = h
                h -= 1
            }
        } else {
            var h = 0
            for n in needle.indices {
                while h < hay.count, hay[h] != needle[n] { h += 1 }
                guard h < hay.count else { return nil }
                positions[n] = h
                h += 1
            }
        }
        return positions
    }

    private static func rate(_ positions: [Int], _ entry: Entry) -> Int {
        let hay = entry.lower
        var score = 0
        for (index, position) in positions.enumerated() {
            if position >= entry.nameStart { score += 4 }
            if position == 0 || [UInt8(ascii: "/"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " ")].contains(hay[position - 1]) {
                score += 8
            }
            if index > 0 {
                let gap = position - positions[index - 1] - 1
                score += gap == 0 ? 6 : -min(gap, 8)
            }
        }
        // The whole query is the file name, or starts it.
        let name = hay[entry.nameStart...]
        if let first = positions.first, first == entry.nameStart, positions.last.map({ $0 - first + 1 }) == positions.count {
            score += name.count == positions.count ? 40 : 20
            if name.count > positions.count, name[entry.nameStart + positions.count] == UInt8(ascii: ".") { score += 15 }
        }
        return score
    }
}

/// What a Go to (⌘P) query asks for: text matched against objects and files, optionally with a
/// line (`core.py:1428`, `src/click/core.py:10-20`, `:10:5`, `core.py#L10-L20`, the forms
/// terminal references take), or a workspace symbol (`@resolve_command`).
public struct GoToQuery: Equatable, Sendable {
    /// The query without its line or `@`, whitespace trimmed.
    public var text: String
    public var lines: LineRange?
    /// `@name`: search the language servers' workspace symbols for `text`.
    public var symbol: Bool

    public init(text: String, lines: LineRange? = nil, symbol: Bool = false) {
        self.text = text
        self.lines = lines
        self.symbol = symbol
    }

    private static let linePattern = try! NSRegularExpression(pattern: #"^(.*?\S)\s*(?::(\d+)(?:-(\d+)|:\d+)?|#L(\d+)(?:-L?(\d+))?):?$"#)

    public static func parse(_ query: String) -> GoToQuery {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") {
            return GoToQuery(text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces), symbol: true)
        }
        let ns = trimmed as NSString
        guard let match = linePattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
            // Half-typed (`core.py:`, `core.py#L`): the file part alone.
            var text = Substring(trimmed)
            while text.hasSuffix(":") { text = text.dropLast() }
            if text.hasSuffix("#L") { text = text.dropLast(2) } else if text.hasSuffix("#") { text = text.dropLast() }
            return GoToQuery(text: text.trimmingCharacters(in: .whitespaces))
        }
        func number(_ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        guard let start = number(2) ?? number(4), start >= 1 else { return GoToQuery(text: trimmed) }
        let end = max(start, number(3) ?? number(5) ?? start)
        return GoToQuery(text: ns.substring(with: match.range(at: 1)), lines: LineRange(start: start, end: end))
    }
}
