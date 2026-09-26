import Foundation

/// A gutter sign for one change against the tile's diff base, as in nvim's gitsigns: a green bar
/// on added lines, a blue bar on modified lines, a red wedge between lines where lines were
/// deleted.
public struct GitSign: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, modified, deleted
    }

    public var kind: Kind
    /// Displayed lines the bar marks (1-based, end-exclusive). A deletion marks none: its wedge
    /// sits on the top edge of line `lines.lowerBound`, which is `lineCount + 1` (below the last
    /// line) for deletions at the end of the file.
    public var lines: Range<Int>
    /// Base lines the change replaced or removed; empty for additions.
    public var old: Range<Int>

    public init(kind: Kind, lines: Range<Int>, old: Range<Int>) {
        self.kind = kind
        self.lines = lines
        self.old = old
    }

    /// Whether clicking the sign can show base lines.
    public var peekable: Bool { !old.isEmpty }

    /// One sign per change record of the diff.
    public static func signs(_ mappings: [LineRangeMapping]) -> [GitSign] {
        mappings.map { mapping in
            let kind: Kind = mapping.original.isEmpty ? .added : mapping.modified.isEmpty ? .deleted : .modified
            return GitSign(kind: kind, lines: mapping.modified, old: mapping.original)
        }
    }
}

/// The rows a code tile shows: every line of the displayed text, plus, for each peeked sign, the
/// base lines it replaced or removed, inline above the lines that replaced them (or at the
/// deletion's wedge). Peeks are few, so rows are computed rather than stored.
public struct CodeRows: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        /// A 1-based line of the displayed text.
        case line(Int)
        /// A 1-based base line shown by peeking sign `sign`.
        case peek(old: Int, sign: Int)
    }

    struct Peek: Equatable, Sendable {
        var sign: Int
        /// The displayed line the peek rows sit above.
        var at: Int
        var old: Range<Int>
    }

    public let lineCount: Int
    let peeks: [Peek]

    public init(lineCount: Int, signs: [GitSign] = [], peeked: Set<Int> = []) {
        self.lineCount = lineCount
        peeks = peeked.sorted().compactMap { index in
            guard signs.indices.contains(index), signs[index].peekable else { return nil }
            return Peek(sign: index, at: min(signs[index].lines.lowerBound, lineCount + 1), old: signs[index].old)
        }.sorted { ($0.at, $0.sign) < ($1.at, $1.sign) }
    }

    public var count: Int { lineCount + peeks.reduce(0) { $0 + $1.old.count } }

    public func row(_ index: Int) -> Row? {
        guard index >= 0 else { return nil }
        var inserted = 0
        for peek in peeks {
            let start = peek.at - 1 + inserted
            if index < start { break }
            if index < start + peek.old.count { return .peek(old: peek.old.lowerBound + index - start, sign: peek.sign) }
            inserted += peek.old.count
        }
        let line = index - inserted + 1
        return line <= lineCount ? .line(line) : nil
    }

    /// Row of a displayed line (clamped to the text).
    public func index(ofLine line: Int) -> Int {
        let line = min(max(1, line), max(1, lineCount))
        return line - 1 + peeks.reduce(0) { $0 + ($1.at <= line ? $1.old.count : 0) }
    }

    /// Row of a base line shown by a peek.
    public func index(ofPeek sign: Int, old line: Int) -> Int? {
        var inserted = 0
        for peek in peeks {
            if peek.sign == sign {
                guard peek.old.contains(line) else { return nil }
                return peek.at - 1 + inserted + (line - peek.old.lowerBound)
            }
            inserted += peek.old.count
        }
        return nil
    }

    public var peekedSigns: Set<Int> { Set(peeks.map(\.sign)) }
}

/// Highlight runs grouped by line: what the renderer needs for one row, without the whole-file
/// span list or an attributed string. Overlapping spans are flattened (the last applied wins).
public struct SyntaxLines: Sendable, Equatable {
    /// UTF-16 offsets within the line.
    public struct Run: Sendable, Equatable {
        public var start: Int32
        public var end: Int32
        public var style: SyntaxStyle
    }

    private let runs: [Run]
    /// Index into `runs` of each line's first run; one more entry than lines.
    private let firsts: [Int32]

    public static let empty = SyntaxLines(runs: [], firsts: [0])

    private init(runs: [Run], firsts: [Int32]) {
        self.runs = runs
        self.firsts = firsts
    }

    public init(_ spans: [SyntaxSpan], text: SideText) {
        guard !spans.isEmpty, text.utf16Count > 0 else {
            self = .empty
            return
        }
        let styles = SyntaxStyle.allCases
        let none = UInt8.max
        var paint = [UInt8](repeating: none, count: text.utf16Count)
        for span in spans {
            let start = max(0, span.range.location), end = min(text.utf16Count, span.range.location + span.range.length)
            guard start < end, let code = styles.firstIndex(of: span.style) else { continue }
            for offset in start..<end { paint[offset] = UInt8(code) }
        }
        var runs: [Run] = []
        var firsts: [Int32] = []
        firsts.reserveCapacity(text.lineCount + 1)
        for line in 0..<text.lineCount {
            firsts.append(Int32(runs.count))
            let base = text.lineStarts[line]
            var offset = base
            let end = text.lineEnds[line]
            while offset < end {
                let code = paint[offset]
                var stop = offset + 1
                while stop < end, paint[stop] == code { stop += 1 }
                if code != none {
                    runs.append(Run(start: Int32(offset - base), end: Int32(stop - base), style: styles[Int(code)]))
                }
                offset = stop
            }
        }
        firsts.append(Int32(runs.count))
        self.runs = runs
        self.firsts = firsts
    }

    /// Runs of a 1-based line, in order.
    public func runs(line: Int) -> ArraySlice<Run> {
        guard line >= 1, line < firsts.count else { return [] }
        return runs[Int(firsts[line - 1])..<Int(firsts[line])]
    }
}

/// Everything a code tile draws for one load of its file: the text (the working tree, or the
/// base version of a deleted file), gitsigns against the diff base, per-line highlighting for
/// both sides, and the header's status and warning. Built off the main thread.
public struct CodeDocument: Sendable {
    public let path: String
    public let diff: FileDiff
    /// Which side of the diff the rows show: the base version only for deleted files.
    public let side: DiffSide
    public let signs: [GitSign]
    public let syntax: SyntaxLines
    /// The base side, for peek rows.
    public let oldSyntax: SyntaxLines
    public let symbols: [SyntaxSymbol]
    public let oldSymbols: [SyntaxSymbol]
    /// Widest line in columns (tabs expanded).
    public let longestLine: Int
    /// Shown instead of rows when there is no text (binary, missing, too large…).
    public let notice: String?
    /// Why the tile shows plain source or a read-only base version.
    public let warning: String?
    public let status: String

    public var text: SideText { side == .old ? diff.old : diff.new }

    public init(path: String, diff: FileDiff) {
        self.path = path
        self.diff = diff
        side = diff.state == .deleted ? .old : .new
        let showsSigns = diff.state == .modified || diff.state == .added
        signs = showsSigns ? GitSign.signs(diff.mappings) : []
        let text = side == .old ? diff.old : diff.new
        let language = SyntaxLanguage(path: path)
        let analysis = language.map { Syntax.analyze(text.text, language: $0) } ?? .empty
        syntax = SyntaxLines(analysis.spans, text: text)
        symbols = analysis.symbols
        if diff.state == .modified, let language {
            let old = Syntax.analyze(diff.old.text, language: language)
            oldSyntax = SyntaxLines(old.spans, text: diff.old)
            oldSymbols = old.symbols
        } else {
            oldSyntax = .empty
            oldSymbols = side == .old ? symbols : []
        }
        let source = text.text as NSString
        longestLine = (0..<text.lineCount).reduce(0) { widest, index in
            let range = NSRange(location: text.lineStarts[index], length: text.lineEnds[index] - text.lineStarts[index])
            // Columns can't be fewer than UTF-16 units; only lines with tabs need counting.
            guard range.length * CodeMetrics.tabWidth > widest else { return widest }
            return max(widest, CodeMetrics.columns(source.substring(with: range)))
        }
        let base = diff.base.map { " · \(diff.baseLabel ?? "base") \($0.prefix(7))" } ?? ""
        var notice: String?
        var warning: String?
        let status: String
        switch diff.state {
        case .modified: status = "+\(diff.addedCount) −\(diff.removedCount)\(base)"
        case .unchanged: status = "no changes\(base)"
        case .added: status = "new file · +\(diff.addedCount)\(base)"
        case .deleted:
            status = "−\(diff.removedCount)\(base)"
            warning = "deleted — base version, read-only"
        case .noBase:
            status = ""
            warning = "\(diff.baseLabel ?? "no base") — showing source"
        case .diffTooLarge:
            status = base.isEmpty ? "" : String(base.dropFirst(3))
            warning = "diff too large — showing source"
        case .notRepository: status = "not in a git repository"
        case .binary:
            status = String(base.dropFirst(3))
            notice = "binary file"
        case .missing:
            status = ""
            notice = "file not found: \(path)"
        case .tooLarge:
            status = ""
            notice = "file too large to show (over \(GitDiffEngine.maxFileSize >> 20) MiB)"
        case .submodule:
            status = ""
            notice = "submodule (not a text file)"
        case .unstable:
            status = ""
            notice = "file kept changing while diffing; waiting for the next write"
        }
        self.notice = notice
        self.warning = warning
        self.status = status
    }

    /// Displayed line range a line range of the object's `range` covers, clamped to the text.
    public func lines(for range: LineRange) -> ClosedRange<Int>? {
        guard text.lineCount > 0 else { return nil }
        let start = min(max(1, range.start), text.lineCount)
        return start...min(max(start, range.end), text.lineCount)
    }

    /// The commit mentions of this tile's lines name: the diff base while the tile shows changes
    /// against it, or the base a deleted file's rows come from.
    public var mentionCommit: String? {
        signs.isEmpty && side == .new ? nil : diff.base
    }

    public func enclosingSymbol(line: Int, side: DiffSide) -> String? {
        let symbols = side == self.side ? symbols : oldSymbols
        return symbols.filter { $0.lines.contains(line) }.min { $0.lines.count < $1.lines.count }?.name
    }

    /// The sign whose bar covers `line`, or whose wedge sits on its top edge.
    public func sign(at line: Int) -> Int? {
        signs.firstIndex { $0.lines.contains(line) } ?? signs.firstIndex { $0.kind == .deleted && $0.lines.lowerBound == line }
    }

    /// First displayed line of the change after (or before) `line`, wrapping around; for
    /// header ↑/↓.
    public func changeLine(after line: Int, forward: Bool) -> Int? {
        let starts = signs.map { min($0.lines.lowerBound, max(1, text.lineCount)) }
        guard !starts.isEmpty else { return nil }
        return forward ? starts.first { $0 > line } ?? starts.first : starts.last { $0 < line } ?? starts.last
    }
}

/// Which lines of a file one write changed, from the text before and after it.
public enum CodeEdits {
    /// Beyond this many differing lines the whole differing span counts as changed.
    static let diffLimit = 4000

    /// Lines of `new` that an edit inserted or replaced (1-based, end-exclusive, ascending) and
    /// the first line it touched (a pure deletion touches the line after it). Nil when the
    /// texts have the same lines.
    public static func changes(from old: SideText, to new: SideText) -> (lines: [Range<Int>], first: Int)? {
        let before = (0..<old.lineCount).map { old.line($0 + 1) }
        let after = (0..<new.lineCount).map { new.line($0 + 1) }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        guard prefix < before.count || prefix < after.count else { return nil }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let removed = before[prefix..<(before.count - suffix)]
        let added = after[prefix..<(after.count - suffix)]
        let first = min(prefix + 1, max(1, new.lineCount))
        guard !added.isEmpty else { return ([], first) }
        guard removed.count + added.count <= diffLimit, !removed.isEmpty else {
            return ([(prefix + 1)..<(prefix + added.count + 1)], first)
        }
        var inserted: [Int] = []
        for change in added.difference(from: removed) {
            if case .insert(let offset, _, _) = change { inserted.append(offset) }
        }
        var lines: [Range<Int>] = []
        for offset in inserted.sorted() {
            let line = prefix + offset + 1
            if let last = lines.last, last.upperBound == line {
                lines[lines.count - 1] = last.lowerBound..<(line + 1)
            } else {
                lines.append(line..<(line + 1))
            }
        }
        return (lines, first)
    }
}
