import Foundation

/// A `path:line` reference in terminal output (an agent's answer, a compiler error, a stack
/// trace): `src/foo.ts:42`, `src/foo.ts:42:7`, `src/foo.ts:42-50` (also with an en or em dash,
/// as Gemini writes ranges), `foo.rs#L10-20`, `/abs/path.swift:3`, `~/x.py:9`; or a pytest node id
/// (`tests/test_x.py::TestA::test_b[1]`), whose line is its `def`'s, found when it opens.
/// ⌘-click opens it as a code tile beside the terminal.
public struct TerminalReference: Equatable, Sendable {
    /// UTF-16 range of the whole reference in the searched text.
    public var range: NSRange
    public var path: String
    public var lines: LineRange
    /// A pytest node id's names after the file (`["TestA", "test_b"]`); `lines` is then 1-1.
    public var test: [String]?

    public init(range: NSRange, path: String, lines: LineRange, test: [String]? = nil) {
        self.range = range
        self.path = path
        self.lines = lines
        self.test = test
    }
}

public enum TerminalReferences {
    // The path: optional `~`/`.`/`..` root, directories, a name. It needs a slash or a file
    // extension (checked after matching), so `localhost:3000` and `12:30` never match; the
    // lookbehind keeps `https://example.com:443` out. Then `:line`, `:line:col`, `:start-end`,
    // or `#Lstart`, `#Lstart-end`, `#Lstart-Lend`; a range's dash may be `-`, `–` or `—`.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?<![\w./@:~-])((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*)(?::(\d+)(?:[-–—](\d+)|:\d+)?|#L(\d+)(?:[-–—]L?(\d+))?)(?![\w/])"#)
    /// A pytest node id: a `.py` path, `::` and names, maybe a parameter set in brackets.
    private static let nodePattern = try! NSRegularExpression(pattern:
        #"(?<![\w./@:~-])((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*\.py)((?:::[A-Za-z_]\w*)+)(?:\[[^\]\s]*\])?"#)

    public static func find(in text: String) -> [TerminalReference] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let located: [TerminalReference] = pattern.matches(in: text, range: whole).compactMap { match in
            let path = ns.substring(with: match.range(at: 1))
            guard path.contains("/") || hasExtension(path) else { return nil }
            func number(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let start = number(2) ?? number(4), start >= 1 else { return nil }
            let end = max(start, number(3) ?? number(5) ?? start)
            return TerminalReference(range: match.range, path: path, lines: LineRange(start: start, end: end))
        }
        let nodes = nodePattern.matches(in: text, range: whole).map { match in
            TerminalReference(range: match.range, path: ns.substring(with: match.range(at: 1)), lines: LineRange(start: 1, end: 1),
                              test: ns.substring(with: match.range(at: 2)).components(separatedBy: "::").filter { !$0.isEmpty })
        }
        return (located + nodes).sorted { $0.range.location < $1.range.location }
    }

    /// The reference covering UTF-16 offset `offset` of `text`.
    public static func reference(in text: String, at offset: Int) -> TerminalReference? {
        find(in: text).first { NSLocationInRange(offset, $0.range) }
    }

    /// `name.ext` with an extension starting with a letter (`v1.2` is a version, not a file).
    private static func hasExtension(_ path: String) -> Bool {
        let name = path.split(separator: "/").last ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return ext.first?.isLetter == true && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The existing file `path` names: absolute and `~/` paths as they are, relative ones against
    /// `directories` in order (the terminal's reported cwd, its `props.cwd`, the board root).
    /// Diff prefixes (`a/`, `b/`) are tried without the prefix too. When no directory has it, a
    /// relative path is looked up among the board root's `listed` files as a file name or a
    /// trailing part of a path (`core.py`, `click/core.py:10`, as agents write before they know
    /// better): one match is it; of several, the one nearest `cwd` (fewest directories up and
    /// down), unless two are equally near. Nil when nothing resolves.
    public static func resolve(_ path: String, directories: [String], home: String, isFile: (String) -> Bool,
                               listed: (root: String, files: FileIndex)? = nil, near cwd: String? = nil) -> String? {
        func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        if path.hasPrefix("~/") {
            let candidate = standard(home + path.dropFirst())
            return isFile(candidate) ? candidate : nil
        }
        if path.hasPrefix("/") {
            let candidate = standard(path)
            return isFile(candidate) ? candidate : nil
        }
        var relatives = [path]
        if path.hasPrefix("a/") || path.hasPrefix("b/") { relatives.append(String(path.dropFirst(2))) }
        for relative in relatives {
            for directory in directories where !directory.isEmpty {
                let candidate = standard((directory as NSString).appendingPathComponent(relative))
                if isFile(candidate) { return candidate }
            }
        }
        guard let listed else { return nil }
        var matches: [String] = []
        // A diff's `a/` or `b/` prefix is dropped only when the path as written matches nothing.
        for relative in relatives where matches.isEmpty {
            var suffix = Substring(relative)
            while suffix.hasPrefix("./") { suffix = suffix.dropFirst(2) }
            guard !suffix.split(separator: "/").contains("..") else { continue }
            for match in listed.files.paths(endingWith: String(suffix)) {
                let candidate = standard((listed.root as NSString).appendingPathComponent(match))
                if !matches.contains(candidate), isFile(candidate) { matches.append(candidate) }
            }
        }
        guard matches.count > 1 else { return matches.first }
        guard let cwd else { return nil }
        // /tmp and /private/tmp are one directory; a shell may report either.
        func real(_ path: String) -> [Substring] { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.split(separator: "/") }
        let here = real(cwd)
        func distance(_ file: String) -> Int {
            let folder = real(file).dropLast()
            let shared = zip(here, folder).prefix { $0 == $1 }.count
            return (here.count - shared) + (folder.count - shared)
        }
        let ranked = matches.map { ($0, distance($0)) }.sorted { $0.1 < $1.1 }
        return ranked[0].1 < ranked[1].1 ? ranked[0].0 : nil
    }

    /// True for an existing regular file (or a symlink to one).
    public static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
}

extension TerminalReferences {
    /// A reference drawn in a terminal's viewport, resolved to a file.
    public struct Hit: Equatable, Sendable {
        public var file: String
        public var lines: LineRange
        /// Where it is drawn: one run per viewport row it covers.
        public var runs: [TerminalTextRows.Run]
        /// A pytest node id's names (`TerminalReference.test`): the line is its `def`'s.
        public var test: [String]?

        public init(file: String, lines: LineRange, runs: [TerminalTextRows.Run], test: [String]? = nil) {
            self.file = file
            self.lines = lines
            self.runs = runs
            self.test = test
        }
    }

    /// How many rows above and below the clicked one a reference is followed onto.
    static let joinedRows = 2

    /// The reference drawn in cell (`row`, `column`) of a viewport `columns` wide (`read` gives a
    /// row's text, nil past the screen) that `resolve` finds a file for. A reference may go on
    /// from one row to the next in two ways:
    /// - wrapped: the row fills the terminal to its last column (the terminal soft-wrapped it, or
    ///   a program's newline fell exactly there; the two read the same), so the next row
    ///   continues it directly;
    /// - broken by a TUI that wraps its own text with hard newlines inside its margins
    ///   (opencode's `src/dir_entry.` then `rs:100-103`): the row's text ends, before trailing
    ///   blanks and box-drawing borders, in an unfinished reference (`src/dir_entry.`,
    ///   `walk.rs:661-`, a bare word), and the next row continues it from its first non-blank.
    /// Joins are guesses (the word before a reference on the row above joins too), so the
    /// longest run of joined rows is tried first, then shorter ones around the row, down to the
    /// row alone: the first reference under the cell that resolves wins.
    public static func hit(row: Int, column: Int, columns: Int, read: (Int) -> String?, resolve: (String) -> String?) -> Hit? {
        var cache: [Int: String?] = [:]
        func line(_ index: Int) -> String? {
            if let cached = cache[index] { return cached }
            let text = index < 0 ? nil : read(index)
            cache[index] = text
            return text
        }
        guard line(row) != nil else { return nil }
        // joins[r]: how row r goes on into row r + 1.
        var joins: [Int: TerminalTextRows.Join] = [:]
        for upper in stride(from: row - 1, through: row - joinedRows, by: -1) {
            guard let text = line(upper), let next = line(upper + 1), let join = TerminalTextRows.join(text, next, columns: columns) else { break }
            joins[upper] = join
        }
        for upper in row..<(row + joinedRows) {
            guard let text = line(upper), let next = line(upper + 1), let join = TerminalTextRows.join(text, next, columns: columns) else { break }
            joins[upper] = join
        }
        var first = row, last = row
        while joins[first - 1] != nil { first -= 1 }
        while joins[last] != nil { last += 1 }
        let spans = (first...row).flatMap { top in (row...last).map { (top, $0) } }
            .sorted { ($0.1 - $0.0, $0.0) > ($1.1 - $1.0, $1.0) }
        for (top, bottom) in spans {
            let rows = TerminalTextRows((top...bottom).map { index in
                TerminalTextRows.Segment(row: index, text: line(index) ?? "",
                                         leading: index > top ? joins[index - 1]!.leading : 0,
                                         trailing: index < bottom ? joins[index]!.trailing : 0)
            })
            guard let offset = rows.offset(row: row, column: column),
                  let reference = reference(in: rows.text, at: offset),
                  let file = resolve(reference.path) else { continue }
            return Hit(file: file, lines: reference.lines, runs: rows.runs(reference.range), test: reference.test)
        }
        return nil
    }
}

/// Consecutive viewport rows of a terminal's text as one string, with each UTF-16 unit's cell,
/// so a reference that goes on from one row to the next is found whole and underlined per row.
public struct TerminalTextRows {
    public struct Run: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var width: Int

        public init(row: Int, column: Int, width: Int) {
            self.row = row
            self.column = column
            self.width = width
        }
    }

    /// One row's part of the text: all of `text` but `leading` characters at its start and
    /// `trailing` at its end (a TUI's margin and border around a broken reference).
    struct Segment {
        var row: Int
        var text: String
        var leading = 0
        var trailing = 0
    }

    /// How a row goes on into the next (`TerminalReferences.hit`): directly when it fills the
    /// terminal's width, else past the `trailing` blanks and border of the upper row and the
    /// `leading` ones of the lower (a TUI's margins).
    struct Join {
        var trailing = 0
        var leading = 0
    }

    public private(set) var text = ""
    /// Per UTF-16 unit of `text`: its viewport row and first cell column.
    private var cells: [(row: Int, column: Int, width: Int)] = []

    init(_ segments: [Segment]) {
        for segment in segments {
            var column = 0
            let characters = Array(segment.text)
            for (index, character) in characters.enumerated() {
                let width = TerminalStyledTail.cellWidth(character)
                defer { column += width }
                guard index >= segment.leading, index < characters.count - segment.trailing else { continue }
                for _ in character.utf16 { cells.append((segment.row, column, width)) }
                text.append(character)
            }
        }
    }

    /// The UTF-16 offset of the character drawn in cell (`row`, `column`).
    public func offset(row: Int, column: Int) -> Int? {
        cells.firstIndex { $0.row == row && column >= $0.column && column < $0.column + max($0.width, 1) }
    }

    /// The cells `range` covers, one run per row.
    public func runs(_ range: NSRange) -> [Run] {
        var runs: [Run] = []
        for index in range.location..<min(NSMaxRange(range), cells.count) {
            let cell = cells[index]
            if let last = runs.last, last.row == cell.row {
                runs[runs.count - 1].width = max(last.width, cell.column + max(cell.width, 1) - last.column)
            } else {
                runs.append(Run(row: cell.row, column: cell.column, width: max(cell.width, 1)))
            }
        }
        return runs
    }

    /// How `upper` goes on into `lower` in a terminal `columns` wide; nil when it doesn't. A row
    /// whose text reaches the last column goes on directly; one that ends in blanks or a border
    /// (a TUI's margin and scrollbar, even when they fill the row) only after an unfinished word,
    /// or inside a table cell: a reference that looks whole (`trade-ups.ts:1383-13` before the
    /// cell's `│`) goes on when the row below holds nothing in its cells but digits (`92`).
    static func join(_ upper: String, _ lower: String, columns: Int) -> Join? {
        let above = Array(upper), below = Array(lower)
        var end = above.count
        while end > 0, isMargin(above[end - 1]) { end -= 1 }
        if end == above.count, upper.reduce(0, { $0 + TerminalStyledTail.cellWidth($1) }) >= columns { return Join() }
        var start = end
        while start > 0, isPathCharacter(above[start - 1]) { start -= 1 }
        guard start < end else { return nil }
        var lead = 0
        while lead < below.count, isMargin(below[lead]) { lead += 1 }
        guard lead < below.count, isPathCharacter(below[lead]) else { return nil }
        if isUnfinished(String(above[start..<end])) { return Join(trailing: above.count - end, leading: lead) }
        let inCell = above[end...].contains(where: isBorder) && above[end - 1].isNumber
        let digits = below[lead...].prefix { $0.isNumber }
        guard inCell, !digits.isEmpty, below[(lead + digits.count)...].allSatisfy(isMargin) else { return nil }
        return Join(trailing: above.count - end, leading: lead)
    }

    /// A box-drawing character: a table's or a TUI's border.
    private static func isBorder(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// Blank cells and a TUI's borders and scrollbars (box drawing, block elements).
    private static func isMargin(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.allSatisfy { (0x2500...0x259F).contains($0.value) }
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_@.+-/~:#–—".contains(character)
    }

    /// A row's last word that isn't a whole reference by itself: `src/dir_entry.`, `walk.rs:661-`.
    private static func isUnfinished(_ word: String) -> Bool {
        let length = (word as NSString).length
        return !TerminalReferences.find(in: word).contains { NSMaxRange($0.range) == length }
    }
}

extension Board {
    /// A reference the user ⌘-clicked in terminal `tile`. `path` is absolute; it is stored
    /// board-relative when it lives under the root. Like an editor's preview tab, the terminal
    /// has one preview tile that each ⌘-click re-aims, so clicking down a list of hits doesn't
    /// pile up tiles:
    /// - a code tile already showing `path` at `lines` is selected (follow tiles excluded: they
    ///   belong to their agent);
    /// - else the tile the terminal's last ⌘-click opened is re-aimed, while nobody has changed
    ///   it since (moved, resized, re-based, re-aimed: its `rev`) and the user hasn't kept it
    ///   (`keepCode`: scrolled, clicked or selected in it, opened it in an editor);
    /// - else a new tile opens beside the terminal (`place(near:)`, shrunk down to
    ///   `followMinimumSize` to land wholly in view) and becomes the terminal's preview.
    /// `newTile` (⌥⌘-click) always opens a new tile, which the user keeps.
    @discardableResult
    public func openCode(path: String, lines: LineRange, beside tile: ObjectID, newTile: Bool = false) -> (id: ObjectID, created: Bool) {
        let stored = relativePath(path)
        let range: JSONValue = .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))])
        if !newTile {
            if let existing = objects.values
                .filter({ $0.type == .code && $0.props["followOf"] == nil && $0.props["path"]?.string == stored && $0.props["range"] == range })
                .max(by: { $0.z < $1.z }) {
                return (existing.id, false)
            }
            if let preview = codePreviews[tile], let object = objects[preview.tile], object.rev == preview.rev,
               let aimed = try? update(object.id, props: .object(["path": .string(stored), "range": range, "symbol": .null])) {
                codePreviews[tile] = (aimed.id, aimed.rev)
                return (aimed.id, false)
            }
        }
        let size = Board.defaultSize(.code)
        let created = create(type: .code, props: .object(["path": .string(stored), "range": range]),
                             frame: place(width: size.w, height: size.h, near: tile, shrinkingTo: Self.followMinimumSize))
        if !newTile { codePreviews[tile] = (created.id, created.rev) }
        return (created.id, true)
    }

    /// The user kept code tile `id` (scrolled, clicked or selected in it, opened it in an
    /// editor): no terminal's ⌘-click re-aims it any more.
    public func keepCode(_ id: ObjectID) {
        guard codePreviews.values.contains(where: { $0.tile == id }) else { return }
        codePreviews = codePreviews.filter { $0.value.tile != id }
    }

    /// A code location the user opened from a tile (an HTML page's link, a changes tile's line):
    /// re-aims the topmost code tile already showing `path` (follow tiles excluded: they belong
    /// to their agent), else creates one beside `tile` with `extra` props (e.g. the diff base),
    /// shrunk (down to a follow tile's minimum) to land wholly in view when `tile` is on screen.
    @discardableResult
    public func showCode(path: String, range: LineRange?, symbol: String? = nil, beside tile: ObjectID, extra: [String: JSONValue] = [:]) throws -> (id: ObjectID, created: Bool) {
        let rangeValue: JSONValue = range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        let existing = objects.values
            .filter { $0.type == .code && $0.props["path"]?.string == path && $0.props["followOf"] == nil }
            .max { $0.z < $1.z }
        if let existing {
            try update(existing.id, props: .object(["range": rangeValue, "symbol": symbol.map(JSONValue.string) ?? .null]))
            return (existing.id, false)
        }
        var props = extra.merging(["path": .string(path), "range": rangeValue]) { $1 }
        if let symbol { props["symbol"] = .string(symbol) }
        let size = Board.defaultSize(.code)
        let created = create(type: .code, props: .object(props.filter { $0.value != .null }), frame: place(width: size.w, height: size.h, near: tile, shrinkingTo: Board.followMinimumSize))
        return (created.id, true)
    }
}

/// How a terminal whose session is gone (after a reboot) resumes the agent it recorded
/// (`props.agent`: `kind` and `sessionId`, from `agent.report_session`).
public enum AgentResume {
    public static func argv(kind: String, sessionId: String) -> [String]? {
        switch kind {
        case "omp": ["omp", "--resume=\(sessionId)"]
        case "claude": ["claude", "--resume", sessionId]
        case "codex": ["codex", "resume", sessionId]
        case "gemini": ["gemini", "--resume", sessionId]
        case "opencode": ["opencode", "--session", sessionId]
        default: nil
        }
    }
}
