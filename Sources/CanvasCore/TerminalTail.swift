import Foundation

/// The last `limit` lines of a terminal's text, fed chunk by chunk so a long scrollback is never
/// held whole. Lines lose trailing whitespace (terminals pad rows) and trailing blank lines are
/// dropped (the empty screen rows below the cursor).
public struct TerminalTail: Sendable {
    public let limit: Int
    private var lines: [String] = []
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

    /// The tail as text (at most `limit` lines, ending with the last non-blank line) and its line count.
    public mutating func finish() -> (text: String, lines: Int) {
        if !partial.isEmpty {
            add(partial)
            partial.removeAll()
        }
        let tail = lines.suffix(limit)
        return (tail.joined(separator: "\n"), tail.count)
    }

    private mutating func add(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self)
        guard let last = line.lastIndex(where: { !$0.isWhitespace }) else {
            blanks += 1
            return
        }
        if blanks > 0 {
            lines.append(contentsOf: repeatElement("", count: min(blanks, limit)))
            blanks = 0
        }
        lines.append(String(line[...last]))
        // Amortized trim: drop the excess once it reaches `limit`, not on every line.
        if lines.count >= 2 * limit { lines.removeFirst(lines.count - limit) }
    }
}
