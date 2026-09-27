import Foundation

/// Where a fence's anchor lands in the current source text. Pure: callers supply the lines.
/// Note fences and code tiles' ranges (`props.anchor`) resolve here alike.
///
/// Anchors prefer symbols; line ranges are re-found by content when lines move, using the text
/// captured when the range was last resolved or, failing that, the `anchor="…"` first line.
/// Captured text also carries the range's end along when lines are inserted or removed inside it.
public enum NoteAnchor {
    public enum Status: Equatable, Sendable {
        case exact
        /// The range's content moved or changed length; `from` is the range as written.
        case relocated(from: LineRange)
        case stale(String)
    }

    public struct Resolution: Equatable, Sendable {
        public var range: LineRange?
        public var status: Status
    }

    /// Longest excerpt a symbol expands to; past this the declaration is shown truncated.
    static let maxSymbolLines = 400

    /// `captured` is the range's text when it last resolved (nil: unknown, e.g. after a restart).
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
        let written = lines.start - 1
        // The range from 0-based `start`: to where its content ends, else as long as written.
        func resolution(_ start: Int, tracking expected: [String]) -> Resolution {
            let fixed = min(start + length, source.count - 1)
            let end = expected.count > 1 ? trackedEnd(of: expected, in: source, from: start) ?? fixed : fixed
            let range = LineRange(start: start + 1, end: end + 1)
            return Resolution(range: range, status: start == written && end == fixed ? .exact : .relocated(from: lines))
        }
        let expected = expectedText(anchor: fence.anchor, captured: captured)
        guard let (offset, key) = firstKey(expected) else {
            guard let moved = placement(of: body, in: source, near: written, length: length + 1) else {
                guard lines.start <= source.count else {
                    return Resolution(range: nil, status: .stale("lines \(lines.start)-\(lines.end) are past the end of the file (\(source.count) lines)"))
                }
                return resolution(written, tracking: [])
            }
            return resolution(moved, tracking: [])
        }
        // Every line matching the key is a candidate, the written position included: more
        // matching neighbours (from the captured text) wins, nearness to where the range used to
        // be only breaks ties, so a common first line (`}`) left at the old spot can't hold the
        // range when the captured block sits elsewhere.
        var best: (index: Int, score: Int, distance: Int)?
        for index in source.indices where normalized(source[index]) == key {
            let start = index - offset
            guard start >= 0 else { continue }
            var score = 0
            for (k, line) in expected.prefix(maxPlacementLines).enumerated() where k != offset && start + k < source.count && normalized(source[start + k]) == normalized(line) {
                score += 1
            }
            let distance = abs(start - written)
            if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                best = (start, score, distance)
            }
        }
        if let best { return resolution(best.index, tracking: expected) }
        // The first line changed or went; most of the rest of the captured text may still stand.
        if expected.count > 1, let found = bestPlacement(of: expected, in: source, near: written, length: expected.count),
           found.kept >= 2, found.kept * 2 > expected.count {
            return resolution(found.start, tracking: expected)
        }
        return Resolution(range: nil, status: .stale("lines \(lines.start)-\(lines.end) no longer contain \"\(clip(key))\""))
    }

    /// The text a line range is re-found by: what it captured, when that opens with the anchor
    /// (or there is none); else the anchor alone, written since by an agent or kept from an
    /// earlier run.
    static func expectedText(anchor: String?, captured: [String]?) -> [String] {
        if let captured, let first = firstKey(captured), anchor.map({ first.offset == 0 && normalized($0) == first.key }) ?? true {
            return captured
        }
        return anchor.map { [$0] } ?? captured ?? []
    }

    /// The first non-blank line: its offset and normalized text.
    static func firstKey(_ lines: [String]) -> (offset: Int, key: String)? {
        lines.enumerated().first { !normalized($0.element).isEmpty }.map { ($0.offset, normalized($0.element)) }
    }

    /// Last line (0-based) of `captured`'s content in `source` when it starts at `start`: the
    /// shortest stretch keeping as much of it as a generous window does, so lines inserted or
    /// removed inside the range carry its end with them. Captured lines gone from the end leave
    /// the range shorter rather than taking in the next, unrelated line, unless that line reads
    /// like the one it replaced (`}` → `} // done`). Nil when most of the content is gone: the
    /// range then keeps its written length.
    static func trackedEnd(of captured: [String], in source: [String], from start: Int) -> Int? {
        guard captured.count <= maxPlacementLines, start < source.count else { return nil }
        let wanted = captured.map(normalized)
        let window = source[start..<min(source.count, start + captured.count + max(10, captured.count / 2))].map(normalized)
        let most = NoteDiff.keptCount(wanted, window)
        guard most * 2 > wanted.count else { return nil }
        var low = 1
        var high = window.count
        while low < high {
            let mid = (low + high) / 2
            if NoteDiff.keptCount(wanted, Array(window[..<mid])) >= most { high = mid } else { low = mid + 1 }
        }
        var end = start + low - 1
        let lastKept = NoteDiff.lines(wanted, Array(window[..<low])).reduce(-1) { last, line in
            if case .same(let old, _, _) = line { max(last, old) } else { last }
        }
        for replaced in wanted.dropFirst(lastKept + 1) {
            guard end + 1 < source.count, similar(replaced, normalized(source[end + 1])) else { break }
            end += 1
        }
        return end
    }

    /// Two non-blank lines where one begins the other, or that share at least half their length
    /// from the start: an edited line rather than another one.
    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared * 2 >= max(a.count, b.count)
    }

    /// Body relocation diffs a window per nominee; these keep it bounded on huge or repetitive files.
    static let maxPlacementLines = 400
    static let maxNominees = 32

    /// 0-based start where `body` sits in `source` when that differs from `written`
    /// (`bestPlacement`). The winner must beat the written start and keep at least two lines
    /// (one, for a one-line body), so a lone `}` moves nothing.
    static func placement(of body: [String], in source: [String], near written: Int, length: Int) -> Int? {
        guard let best = bestPlacement(of: body, in: source, near: written, length: length) else { return nil }
        let wanted = body.filter { !normalized($0).isEmpty }.count
        guard best.start != written, best.kept > kept(body, in: source, at: written, length: length), best.kept >= min(2, wanted) else { return nil }
        return best.start
    }

    /// Where `body` fits `source` best: every body line found in the source nominates the start
    /// it implies; each nominee (the nearest `maxNominees` to `written`) is scored by how many
    /// lines a diff of its `length`-line window against the body keeps, so inserted or changed
    /// lines don't skew it.
    static func bestPlacement(of body: [String], in source: [String], near written: Int, length: Int) -> (start: Int, kept: Int)? {
        guard body.count <= maxPlacementLines, length <= maxPlacementLines else { return nil }
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
        var best: (start: Int, kept: Int)?
        for start in nominees.sorted(by: { abs($0 - written) < abs($1 - written) }).prefix(maxNominees) {
            let score = kept(body, in: source, at: start, length: length)
            if best == nil || score > best!.kept { best = (start, score) }
        }
        return best
    }

    /// Lines of `body` a diff against the `length`-line window at `start` keeps.
    static func kept(_ body: [String], in source: [String], at start: Int, length: Int) -> Int {
        guard start >= 0, start < source.count else { return 0 }
        let window = source[start..<min(source.count, start + length)].map(normalized)
        return NoteDiff.keptCount(window, body.map(normalized))
    }

    /// Where `source` already reads a proposal's `body` (contiguously, nearest `near`, 0-based):
    /// the proposal is applied. Not while `original`, the range's text before the proposal,
    /// still stands whole around that spot: a proposal that only drops lines reads as part of
    /// its range until it is applied. `starts` (0-based) bounds where the body may begin: around
    /// the resolved range; nil (the anchor is lost) searches the file, for a body of two or more
    /// lines or one found once.
    public static func applied(_ body: [String], original: [String], in source: [String], starts: ClosedRange<Int>?, near: Int) -> LineRange? {
        let wanted = body.map(normalized)
        let substantive = wanted.filter { !$0.isEmpty }.count
        guard substantive > 0, wanted.count <= source.count, wanted.count <= maxPlacementLines else { return nil }
        func reads(_ lines: [String], at start: Int) -> Bool {
            start >= 0 && start + lines.count <= source.count && lines.indices.allSatisfy { normalized(source[start + $0]) == lines[$0] }
        }
        let lower = max(0, starts?.lowerBound ?? 0)
        let upper = min(source.count - wanted.count, starts?.upperBound ?? source.count)
        guard lower <= upper else { return nil }
        let found = (lower...upper).filter { reads(wanted, at: $0) }
        guard let start = found.min(by: { abs($0 - near) < abs($1 - near) }) else { return nil }
        if starts == nil, found.count > 1, substantive < 2 { return nil }
        let old = original.map(normalized)
        if old.count > wanted.count, (max(0, start + wanted.count - old.count)...start).contains(where: { reads(old, at: $0) }) { return nil }
        return LineRange(start: start + 1, end: start + wanted.count)
    }

    // MARK: Symbols

    /// Best-effort, language-agnostic declaration search. `Outer.inner` finds `inner` inside the
    /// whole extent of `Outer` (however long). The range runs from the declaration line to the
    /// end of its body (braces, else indentation), at most `maxSymbolLines` long.
    public static func symbolRange(_ symbol: String, in source: [String]) -> LineRange? {
        let names = symbol.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        var scope = 0..<source.count
        var found: LineRange?
        for (index, name) in names.enumerated() {
            // The container's own declaration line can't declare its member.
            let searchFrom = found.map { $0.start } ?? scope.lowerBound
            guard searchFrom <= scope.upperBound, let line = declarationLine(name, in: source, within: searchFrom..<scope.upperBound) else { return nil }
            let end = extentEnd(from: line, in: source, limit: index == names.count - 1 ? maxSymbolLines : nil)
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

    /// Last line (0-based) of the declaration starting at `start`, at most `limit` lines on (nil:
    /// the whole of it, for a container a member is searched in): the line closing its first
    /// brace block if one opens within a few lines of the signature's end (a parameter list may
    /// run over many lines first; braces inside it, `= {}` defaults or destructuring, open
    /// nothing), else the indented block below the signature's last line (Python's `) -> T:`
    /// sits at the declaration's own indent), plus a closing `end` at the same indent for
    /// Ruby/Lua-style languages.
    static func extentEnd(from start: Int, in source: [String], limit: Int? = maxSymbolLines) -> Int {
        let stop = limit.map { min(source.count, start + $0) } ?? source.count
        var depth = 0
        var opened = false
        var parens = 0
        var signatureEnd: Int?
        for index in start..<stop {
            for character in stripped(source[index]) {
                switch character {
                case "{" where opened || parens == 0:
                    depth += 1
                    opened = true
                case "}" where opened: depth -= 1
                case "(": parens += 1
                case ")": parens = max(0, parens - 1)
                default: break
                }
            }
            if opened, depth <= 0 { return index }
            // Inside a parameter list the body can't have started yet.
            if !opened, parens == 0 {
                if signatureEnd == nil { signatureEnd = index }
                let trimmed = source[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(";") { return index }
                if index - signatureEnd! >= 3 || trimmed.hasSuffix(":") { break }
            }
        }
        if opened { return stop - 1 }
        let base = indent(source[start])
        var end = signatureEnd ?? start
        var index = end + 1
        while index < stop {
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
