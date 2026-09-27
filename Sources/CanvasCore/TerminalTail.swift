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

    public let limit: Int
    private var lines: [String] = []
    private var positions: [Int] = []
    /// Lines read so far: the position of the next one.
    private var count = 0
    /// Blank lines since the last non-blank one; they only matter once content follows.
    private var blanks = 0
    /// Bytes after the last newline. Split on raw bytes: 0x0A never occurs inside a UTF-8 sequence.
    private var partial = Data()

    public init(limit: Int) {
        self.limit = max(1, limit)
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
        return Tail(rows: Array(lines.suffix(limit)), positions: Array(positions.suffix(limit)))
    }

    private mutating func add(_ bytes: Data) {
        let position = count
        count += 1
        var line = String(decoding: bytes, as: UTF8.self)
        guard let last = line.lastIndex(where: { !$0.isWhitespace }) else {
            blanks += 1
            return
        }
        line = String(line[...last])
        if line.unicodeScalars.contains(Self.placeholder) {
            line = Self.replacingImages(in: line)
            // The rows under one image each hold a run of placeholders.
            if blanks == 0, line.trimmingCharacters(in: .whitespaces) == Self.image, lines.last == line { return }
        }
        if blanks > 0 {
            let kept = min(blanks, limit)
            lines.append(contentsOf: repeatElement("", count: kept))
            positions.append(contentsOf: (position - kept)..<position)
            blanks = 0
        }
        lines.append(line)
        positions.append(position)
        // Amortized trim: drop the excess once it reaches `limit`, not on every line.
        if lines.count >= 2 * limit {
            lines.removeFirst(lines.count - limit)
            positions.removeFirst(positions.count - limit)
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
