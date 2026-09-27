import Foundation

/// The last `limit` lines of a terminal's text, fed chunk by chunk so a long scrollback is never
/// held whole. Lines lose trailing whitespace (terminals pad rows) and trailing blank lines are
/// dropped (the empty screen rows below the cursor). Inline images (kitty graphics Unicode
/// placeholders: U+10EEEE cells carrying combining diacritics, what omp prints for an image)
/// read as `[image]`, one line for all of an image's rows. Every kept line remembers its position
/// in the whole text, so two reads of one session can be compared line by line (`since`).
public struct TerminalTail: Sendable {
    /// A finished tail.
    public struct Tail: Sendable, Equatable {
        /// The kept lines, oldest first.
        public var rows: [String]
        /// Each row's position in the whole text: how many lines came before it (blank ones too).
        public var positions: [Int]

        public init(rows: [String], positions: [Int]) {
            self.rows = rows
            self.positions = positions
        }

        public var text: String { rows.joined(separator: "\n") }
        public var lines: Int { rows.count }
        /// Position just past the last row: where the next output lands.
        public var end: Int { positions.last.map { $0 + 1 } ?? 0 }

        /// Where the output that followed `before` (an earlier read of the same session) starts:
        /// the first line `before` showed that reads differently now (a shell's prompt line that
        /// got the command, an agent's input box its reply scrolled away), else `before.end`.
        /// Lines older than this tail reaches can't be compared and are skipped.
        public func boundary(after before: Tail) -> Int {
            let first = positions.first ?? end
            var now: [Int: String] = [:]
            for (position, row) in zip(positions, rows) { now[position] = row }
            for (position, row) in zip(before.positions, before.rows) where position >= first && now[position] != row { return position }
            return before.end
        }

        /// The rows at or after `position`.
        public func rows(from position: Int) -> Tail {
            let start = positions.firstIndex { $0 >= position } ?? rows.count
            return Tail(rows: Array(rows[start...]), positions: Array(positions[start...]))
        }

        /// The last `limit` rows.
        public func suffix(_ limit: Int) -> Tail {
            Tail(rows: Array(rows.suffix(limit)), positions: Array(positions.suffix(limit)))
        }
    }

    /// A row of the terminal's live screen as the terminal itself reads it: its text and whether
    /// the terminal soft-wrapped it into the next row (Ghostty's own wrap flag).
    public struct ScreenRow: Sendable, Equatable {
        public var text: String
        public var wraps: Bool

        public init(text: String, wraps: Bool) {
            self.text = text
            self.wraps = wraps
        }
    }

    public let limit: Int
    /// The terminal's width: a row that fills it goes on in the next (`joinsNext`), and the two
    /// read as one line. Nil when unknown: every row is a line.
    public let columns: Int?
    /// The live screen as the terminal reads it, when known: its rows join by the terminal's own
    /// wrap flags instead of the guess, once they're found at the end of the text.
    private let screen: [ScreenRow]
    private var lines: [String] = []
    private var positions: [Int] = []
    /// Per kept line, the position of the last row it holds (a joined line holds several).
    private var lastRows: [Int] = []
    /// The last rows read (trailing blanks trimmed) with their positions, while `screen` is set.
    private var recent: [(position: Int, text: String)] = []
    /// Lines read so far: the position of the next one.
    private var count = 0
    /// Blank lines since the last non-blank one; they only matter once content follows.
    private var blanks = 0
    /// The last kept line filled the terminal's width: the next row may continue it.
    private var wrapping = false
    /// Bytes after the last newline. Split on raw bytes: 0x0A never occurs inside a UTF-8 sequence.
    private var partial = Data()

    public init(limit: Int, columns: Int? = nil, screen: [ScreenRow] = []) {
        self.limit = max(1, limit)
        self.columns = columns.flatMap { $0 > 0 ? $0 : nil }
        self.screen = screen
    }

    /// Whether `row` (trailing blanks trimmed) is the first part of a line the terminal
    /// soft-wrapped at `columns` into `next`: it fills the width and ends in text (`fills`), and
    /// the next row doesn't start with a border (`continues`) nor the way `row` does (`startsAlike`:
    /// pytest's `FAILED …` rows, each cut at the width). A full-width box line, a TUI's frame
    /// (`│ … │`) or a separator a program padded to the width (`isRule`: pytest's
    /// `==== FAILURES ====`) stays its own row; a row that happens to end in text at the edge
    /// joins, which is how it reads. (zmx's history carries no wrap flag, so this is a guess; the
    /// live screen's rows join by the terminal's own flags, `ScreenRow`.)
    public static func joinsNext(_ row: String, _ next: String, columns: Int) -> Bool {
        fills(row, columns: columns) && continues(next) && !startsAlike(row, next)
    }

    static func fills(_ row: String, columns: Int) -> Bool {
        guard let last = row.last, !isEdge(last), !isRule(row) else { return false }
        return row.reduce(0) { $0 + TerminalStyledTail.cellWidth($1) } == columns
    }

    /// A separator row: it starts and ends with a run of one punctuation character (`=`, `-`,
    /// `_`, `!`, `*`, `#`, `~`, `+`, `.`), maybe with a title between (`==== 2 failed ====`,
    /// `!!!! stopping after 1 failures !!!!`, `____ test_x ____`). Box drawing is an edge anyway.
    static func isRule(_ row: String) -> Bool {
        let characters = Array(row.reversed().drop(while: \.isWhitespace).reversed())
        guard let mark = characters.first, "=-_!*#~+.".contains(mark), characters.count >= 6 else { return false }
        return characters.prefix(3).allSatisfy { $0 == mark } && characters.suffix(3).allSatisfy { $0 == mark }
    }

    static func continues(_ next: String) -> Bool {
        guard let first = next.first else { return false }
        return first == " " || !isEdge(first)
    }

    /// Both rows start with the same word and a blank (`FAILED `, `error: `): two records of a
    /// list, not a line and its wrapped rest.
    static func startsAlike(_ row: String, _ next: String) -> Bool {
        guard let space = row.firstIndex(of: " "), row.distance(from: row.startIndex, to: space) >= 2, row.first?.isWhitespace == false else { return false }
        return next.hasPrefix(row[...space])
    }

    private static func isEdge(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.allSatisfy { (0x2500...0x259F).contains($0.value) }
    }

    public mutating func append(_ bytes: Data) {
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            if partial.isEmpty {
                add(bytes[start..<newline])
            } else {
                partial.append(bytes[start..<newline])
                add(partial)
                partial.removeAll(keepingCapacity: true)
            }
            start = bytes.index(after: newline)
        }
        partial.append(bytes[start...])
    }

    /// The tail: at most `limit` lines, ending with the last non-blank line.
    public mutating func finish() -> Tail {
        if !partial.isEmpty {
            add(partial)
            partial.removeAll()
        }
        rejoinScreen()
        return Tail(rows: Array(lines.suffix(limit)), positions: Array(positions.suffix(limit)))
    }

    private mutating func add(_ bytes: Data) {
        let position = count
        count += 1
        let line = String(decoding: bytes, as: UTF8.self)
        if !screen.isEmpty {
            recent.append((position, String(line.reversed().drop(while: \.isWhitespace).reversed())))
            if recent.count >= 4 * screen.count { recent.removeFirst(recent.count - 2 * screen.count) }
        }
        add(line, at: position, joins: nil)
    }

    /// Adds row `line` read at `position`; `joins` says whether the row before goes on into it,
    /// nil to guess (`joinsNext`).
    private mutating func add(_ row: String, at position: Int, joins known: Bool?) {
        guard let last = row.lastIndex(where: { !$0.isWhitespace }) else {
            blanks += 1
            wrapping = false
            return
        }
        var line = String(row[...last])
        if line.unicodeScalars.contains(Self.placeholder) {
            wrapping = false
            line = Self.replacingImages(in: line)
            // The rows under one image each hold a run of placeholders.
            if blanks == 0, line.trimmingCharacters(in: .whitespaces) == Self.image, lines.last == line {
                lastRows[lastRows.count - 1] = position
                return
            }
        } else if let columns {
            let joins = blanks == 0 && !lines.isEmpty && (known ?? (wrapping && Self.continues(line) && !Self.startsAlike(lines[lines.count - 1], line)))
            wrapping = Self.fills(line, columns: columns)
            if joins {
                lines[lines.count - 1] += line
                lastRows[lastRows.count - 1] = position
                return
            }
        }
        if blanks > 0 {
            let kept = min(blanks, limit)
            lines.append(contentsOf: repeatElement("", count: kept))
            positions.append(contentsOf: (position - kept)..<position)
            lastRows.append(contentsOf: (position - kept)..<position)
            blanks = 0
        }
        lines.append(line)
        positions.append(position)
        lastRows.append(position)
        // Amortized trim: drop the excess once it reaches `limit`, not on every line.
        if lines.count >= 2 * limit {
            lines.removeFirst(lines.count - limit)
            positions.removeFirst(positions.count - limit)
            lastRows.removeFirst(lastRows.count - limit)
        }
    }

    /// Joins the live screen's rows again by the terminal's own wrap flags (`screen`), once the
    /// text's last rows are found to read as the screen does (else the guesses stand: the
    /// session's screen moved on, or it is another size). A line that started above the screen
    /// keeps the rows it guessed.
    private mutating func rejoinScreen() {
        var shown = screen.map { String($0.text.reversed().drop(while: \.isWhitespace).reversed()) }
        while shown.last?.isEmpty == true { shown.removeLast() }
        var rows = recent
        while rows.last?.text.isEmpty == true { rows.removeLast() }
        guard columns != nil, !shown.isEmpty, rows.count >= shown.count,
              zip(rows.suffix(shown.count), shown).allSatisfy({ $0.0.text == $0.1 }) else { return }
        let top = rows[rows.count - shown.count].position
        while let position = positions.last, position >= top {
            lines.removeLast()
            positions.removeLast()
            lastRows.removeLast()
        }
        let from = max(top, (lastRows.last ?? -1) + 1)
        blanks = 0
        wrapping = false
        for row in rows where row.position >= from {
            let index = row.position - top
            add(row.text, at: row.position, joins: index > 0 && screen[index - 1].wraps)
        }
    }

    /// Kitty's image placeholder character; its row, column, and image-id diacritics are
    /// combining marks, so each cell is one `Character` starting with it.
    static let placeholder: Unicode.Scalar = "\u{10EEEE}"
    static let image = "[image]"

    /// `line` with each run of placeholder cells as `[image]`.
    static func replacingImages(in line: String) -> String {
        var result = ""
        var inRun = false
        for character in line {
            if character.unicodeScalars.first == placeholder {
                if !inRun { result += image }
                inRun = true
            } else {
                result.append(character)
                inRun = false
            }
        }
        return result
    }
}
