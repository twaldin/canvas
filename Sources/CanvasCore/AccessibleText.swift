import Foundation

/// What a tile gives VoiceOver as a read-only text area (a code tile's lines, a terminal's
/// screen), with the lookups AppKit's text-area attributes ask for: characters by range, the
/// line a character is on, and a line's range. Offsets and lengths are UTF-16, as AppKit counts.
public struct AccessibleText: Sendable, Equatable {
    public let text: String
    /// UTF-16 offset where each line starts; the first is 0.
    private let lineStarts: [Int]

    public init(_ text: String) {
        self.text = text
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        lineStarts = starts
    }

    /// Code lines, each after its line number ("1321  def f():"), so a line number an agent
    /// names (`core.py:1321`) is found by listening.
    public init(numbered lines: [(number: Int, text: String)]) {
        self.init(lines.map { "\($0.number)  \($0.text)" }.joined(separator: "\n"))
    }

    public var length: Int { text.utf16.count }

    /// The line (0-based) the character at `index` is on; past the end, the last line.
    public func line(at index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Line `line`'s characters with its line break; empty past the last line.
    public func range(ofLine line: Int) -> NSRange {
        guard lineStarts.indices.contains(line) else { return NSRange(location: length, length: 0) }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// The characters in `range`, clamped to the text.
    public func string(in range: NSRange) -> String {
        let whole = text as NSString
        let start = min(max(0, range.location), whole.length)
        return whole.substring(with: NSRange(location: start, length: min(max(0, range.length), whole.length - start)))
    }
}
