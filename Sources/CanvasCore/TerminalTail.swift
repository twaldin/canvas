import Foundation

/// The last `limit` lines of a terminal's text, fed chunk by chunk so a long scrollback is never
/// held whole. Lines lose trailing whitespace (terminals pad rows) and trailing blank lines are
/// dropped (the empty screen rows below the cursor). Inline images (kitty graphics Unicode
/// placeholders: U+10EEEE cells carrying combining diacritics, what omp prints for an image)
/// read as `[image]`, one line for all of an image's rows.
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
            lines.append(contentsOf: repeatElement("", count: min(blanks, limit)))
            blanks = 0
        }
        lines.append(line)
        // Amortized trim: drop the excess once it reaches `limit`, not on every line.
        if lines.count >= 2 * limit { lines.removeFirst(lines.count - limit) }
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
