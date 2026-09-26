import Foundation

/// Where a fence's anchor lands in the current source text. Pure: callers supply the lines.
///
/// Anchors prefer symbols; line ranges are re-found by content when lines move, using the fence's
/// `anchor="…"` text or, failing that, the content captured when the range was first resolved.
public enum NoteAnchor {
    public enum Status: Equatable, Sendable {
        case exact
        /// The range's content moved; `from` is the start line written in the fence.
        case relocated(from: Int)
        case stale(String)
    }

    public struct Resolution: Equatable, Sendable {
        public var range: LineRange?
        public var status: Status
    }

    /// Longest excerpt a symbol expands to; past this the declaration is shown truncated.
    static let maxSymbolLines = 400

    /// `body` is the fence's own text: a proposal's new code, or code an agent pasted into an
    /// excerpt fence. Without an `anchor` or captured text it re-finds a moved range by content.
    public static func resolve(_ fence: NoteFence, in source: [String], captured: [String]?, body: [String] = []) -> Resolution {
        if let symbol = fence.symbol {
            if let range = symbolRange(symbol, in: source) { return Resolution(range: range, status: .exact) }
            if fence.lines == nil { return Resolution(range: nil, status: .stale("symbol \(symbol) not found")) }
        }
        guard let lines = fence.lines else {
            // A whole-file excerpt.
            return Resolution(range: LineRange(start: 1, end: max(1, source.count)), status: .exact)
        }
        let length = lines.end - lines.start
        let expected = fence.anchor.map { [$0] } ?? captured ?? []
        guard let (offset, key) = expected.enumerated().first(where: { !normalized($0.element).isEmpty }).map({ ($0.offset, normalized($0.element)) }) else {
            guard let moved = placement(of: body, in: source, near: lines.start - 1, length: length + 1) else {
                guard lines.start <= source.count else {
                    return Resolution(range: nil, status: .stale("lines \(lines.start)-\(lines.end) are past the end of the file (\(source.count) lines)"))
                }
                return Resolution(range: LineRange(start: lines.start, end: min(lines.end, source.count)), status: .exact)
            }
            return Resolution(range: LineRange(start: moved + 1, end: min(moved + 1 + length, source.count)), status: .relocated(from: lines.start))
        }
        let wanted = lines.start - 1 + offset
        if wanted < source.count, normalized(source[wanted]) == key {
            return Resolution(range: LineRange(start: lines.start, end: min(lines.end, source.count)), status: .exact)
        }
        // Every line matching the key is a candidate; more matching neighbours (from the captured
        // text) wins, then nearness to where the range used to be.
        var best: (index: Int, score: Int, distance: Int)?
        for index in source.indices where normalized(source[index]) == key {
            let start = index - offset
            guard start >= 0 else { continue }
            var score = 0
            for (k, line) in expected.enumerated() where k != offset && start + k < source.count && normalized(source[start + k]) == normalized(line) {
                score += 1
            }
            let distance = abs(start - (lines.start - 1))
            if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                best = (start, score, distance)
            }
        }
        guard let best else {
            return Resolution(range: nil, status: .stale("lines \(lines.start)-\(lines.end) no longer contain \"\(clip(key))\""))
        }
        let start = best.index + 1
        return Resolution(range: LineRange(start: start, end: min(start + length, source.count)), status: .relocated(from: lines.start))
    }

    /// 0-based start where `body` sits in `source` when that differs from `written`. Every body
    /// line found in the source nominates the start it implies; each nominee is scored by how many
    /// lines a diff of its window against the body keeps (so a proposal's inserted lines don't
    /// skew it). The winner must beat the written start and keep at least two lines (one, for a
    /// one-line body), so a lone `}` moves nothing.
    static func placement(of body: [String], in source: [String], near written: Int, length: Int) -> Int? {
        let wanted = body.enumerated().filter { !normalized($0.element).isEmpty }.map { ($0.offset, normalized($0.element)) }
        guard !wanted.isEmpty else { return nil }
        let keys = Set(wanted.map(\.1))
        var positions: [String: [Int]] = [:]
        for (index, line) in source.enumerated() {
            let key = normalized(line)
            if keys.contains(key) { positions[key, default: []].append(index) }
        }
        var nominees = Set<Int>()
        for (offset, key) in wanted {
            for index in positions[key] ?? [] where index >= offset { nominees.insert(index - offset) }
        }
        let normalizedBody = body.map(normalized)
        func kept(_ start: Int) -> Int {
            guard start < source.count else { return 0 }
            let window = source[start..<min(source.count, start + length)].map(normalized)
            return NoteDiff.lines(window, normalizedBody).filter { if case .same = $0 { true } else { false } }.count
        }
        var best: (start: Int, kept: Int)?
        for start in nominees.sorted(by: { abs($0 - written) < abs($1 - written) }) {
            let score = kept(start)
            if best == nil || score > best!.kept { best = (start, score) }
        }
        guard let best, best.start != written, best.kept > kept(written), best.kept >= min(2, wanted.count) else { return nil }
        return best.start
    }

    // MARK: Symbols

    /// Best-effort, language-agnostic declaration search. `Outer.inner` finds `inner` inside the
    /// extent of `Outer`. The range runs from the declaration line to the end of its body (braces,
    /// else indentation).
    public static func symbolRange(_ symbol: String, in source: [String]) -> LineRange? {
        var scope = 0..<source.count
        var found: LineRange?
        for name in symbol.split(separator: ".").map(String.init) where !name.isEmpty {
            // The container's own declaration line can't declare its member.
            let searchFrom = found.map { $0.start } ?? scope.lowerBound
            guard searchFrom <= scope.upperBound, let line = declarationLine(name, in: source, within: searchFrom..<scope.upperBound) else { return nil }
            let end = extentEnd(from: line, in: source)
            found = LineRange(start: line + 1, end: end + 1)
            scope = line..<(end + 1)
        }
        return found
    }

    static let declarationKeywords = "func|function|def|class|struct|enum|protocol|interface|type|typealias|trait|impl|fn|fun|mod|module|extension|actor|record|object|namespace|macro|union|package"

    /// Declaration patterns for `name`, strongest first. `%@` is the escaped name.
    static let declarationPatterns = [
        // `func name`, `export async function name`, `class Name`, `func (r *T) Name` (Go), `def name`
        #"(?:^|[^\w.$])(?:"# + declarationKeywords + #")\s+(?:\([^)]*\)\s*)?\*?\s*%@(?![\w$])"#,
        // `const name =`, `let name:`, `var name =`
        #"(?:^|[^\w.$])(?:const|let|var|val)\s+%@\s*[:=]"#,
        // `name = (…) =>`, `name: function`, object and class methods `async name(…) {`
        #"^\s*(?:(?:export|public|private|protected|static|async|override|default)\s+)*%@\s*(?:[:=]\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*(?::[^=]*)?=>|\w+\s*=>)|\([^)]*\)?\s*(?::[^{]*)?\{\s*$)"#,
        // C-like definitions: `static int name(…) {` (a call ends in `;`, a definition doesn't;
        // `return name(…)` in semicolon-free languages is a call too)
        #"^\s*(?!(?:return|else|if|while|for|switch|case|await|throw|new|yield|print)\b)[A-Za-z_][\w<>,:*&\s\[\]]*[\s*&]%@\s*\([^;]*$"#,
    ]

    static func declarationLine(_ name: String, in source: [String], within scope: Range<Int>) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        for template in declarationPatterns {
            guard let regex = try? NSRegularExpression(pattern: template.replacingOccurrences(of: "%@", with: escaped)) else { continue }
            for index in scope {
                let line = source[index]
                if regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { return index }
            }
        }
        return nil
    }

    /// Last line (0-based) of the declaration starting at `start`: the line closing its first brace
    /// block if one opens within a few lines, else the indented block below it (plus a closing
    /// `end` at the same indent for Ruby/Lua-style languages).
    static func extentEnd(from start: Int, in source: [String]) -> Int {
        let limit = min(source.count, start + maxSymbolLines)
        var depth = 0
        var opened = false
        for index in start..<limit {
            for character in stripped(source[index]) {
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth <= 0 { return index }
            if !opened {
                let trimmed = source[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(";") { return index }
                if index - start >= 3 || trimmed.hasSuffix(":") { break }
            }
        }
        if opened { return limit - 1 }
        let base = indent(source[start])
        var end = start
        var index = start + 1
        while index < limit {
            let line = source[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if indent(line) > base {
                end = index
            } else {
                if indent(line) == base, line.trimmingCharacters(in: .whitespaces).hasPrefix("end"), end > start { end = index }
                break
            }
            index += 1
        }
        return end
    }

    /// The line with string literals and `//` comments removed, so braces in them don't count.
    static func stripped(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        var previous: Character?
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "/", previous == "/" {
                out.removeLast()
                break
            } else {
                out.append(character)
            }
            previous = character
        }
        return out
    }

    static func indent(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    static func clip(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}
