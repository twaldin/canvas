import Foundation

/// One side of a diff: the full text and where each line starts (UTF-16 offsets), so lines and
/// syntax spans can be sliced without copying the text per line.
public struct SideText: Sendable, Equatable {
    public let text: String
    /// UTF-16 offset of each line's first character; `lineStarts.count` is the line count.
    public let lineStarts: [Int]
    /// UTF-16 offset where each line's content ends, before `\n` or `\r\n`.
    public let lineEnds: [Int]
    public let utf16Count: Int

    public init(_ text: String) {
        self.text = text
        var starts: [Int] = []
        var ends: [Int] = []
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if starts.count == ends.count { starts.append(offset) }
            if unit == 0x0A { ends.append(previous == 0x0D ? offset - 1 : offset) }
            previous = unit
            offset += 1
        }
        if starts.count > ends.count { ends.append(offset) }
        lineStarts = starts
        lineEnds = ends
        utf16Count = offset
    }

    public var lineCount: Int { lineStarts.count }

    /// UTF-16 range of a 1-based line, without its line break.
    public func range(ofLine line: Int) -> NSRange {
        NSRange(location: lineStarts[line - 1], length: lineEnds[line - 1] - lineStarts[line - 1])
    }

    public func line(_ line: Int) -> String {
        (text as NSString).substring(with: range(ofLine: line))
    }

    /// 1-based line containing a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}

/// VS Code-style change: 1-based, end-exclusive line ranges on each side. An empty range sits
/// before the line where the other side's lines were inserted or removed.
public struct LineRangeMapping: Equatable, Sendable {
    public var original: Range<Int>
    public var modified: Range<Int>

    public init(original: Range<Int>, modified: Range<Int>) {
        self.original = original
        self.modified = modified
    }
}

/// Changes close enough that `git diff -U3` would print them as one hunk.
public struct DiffHunk: Equatable, Sendable {
    public var mappings: [LineRangeMapping]

    public var original: Range<Int> { mappings.first!.original.lowerBound..<mappings.last!.original.upperBound }
    public var modified: Range<Int> { mappings.first!.modified.lowerBound..<mappings.last!.modified.upperBound }

    /// Lines a mention of the whole hunk refers to: the new side, or the old side when the hunk
    /// only removes lines.
    public var mentionLines: (side: DiffSide, lines: LineRange) {
        if modified.isEmpty {
            return (.old, LineRange(start: original.lowerBound, end: max(original.lowerBound, original.upperBound - 1)))
        }
        return (.new, LineRange(start: modified.lowerBound, end: modified.upperBound - 1))
    }

    public var header: String {
        func span(_ range: Range<Int>) -> String {
            range.count == 1 ? "\(range.lowerBound)" : "\(range.isEmpty ? range.lowerBound - 1 : range.lowerBound),\(range.count)"
        }
        return "@@ -\(span(original)) +\(span(modified)) @@"
    }
}

public enum DiffSide: String, Sendable, Codable {
    case old, new
}

/// What the tile shows for a file: its diff against a resolved base, or why there is none.
public struct FileDiff: Sendable, Equatable {
    public enum State: Equatable, Sendable {
        /// Differs from the base (including files deleted from the working tree).
        case modified
        case unchanged
        /// Untracked, or new since the base: every line is added.
        case added
        case deleted
        case binary
        /// Neither on disk nor in the base.
        case missing
        /// Outside any git repository; `new` holds the file as source.
        case notRepository
        case tooLarge
    }

    public var state: State
    /// Full SHA of the commit diffed against; nil when there is no base.
    public var base: String?
    /// How the base was chosen, e.g. `merge-base with origin/main`.
    public var baseLabel: String?
    public var old: SideText
    public var new: SideText
    public var hunks: [DiffHunk]

    public init(state: State, base: String?, baseLabel: String?, old: SideText, new: SideText, hunks: [DiffHunk]) {
        self.state = state
        self.base = base
        self.baseLabel = baseLabel
        self.old = old
        self.new = new
        self.hunks = hunks
    }

    public var mappings: [LineRangeMapping] { hunks.flatMap(\.mappings) }
    public var addedCount: Int { mappings.reduce(0) { $0 + $1.modified.count } }
    public var removedCount: Int { mappings.reduce(0) { $0 + $1.original.count } }
}

/// Parses `git diff -U0` output for one file.
public enum UnifiedDiff {
    public struct Parsed: Equatable, Sendable {
        public var mappings: [LineRangeMapping]
        /// Removed lines keyed by old line number, the only old-side text the patch carries.
        public var removed: [Int: Substring]
        public var binary: Bool
    }

    public static func parse(_ patch: String) -> Parsed {
        var parsed = Parsed(mappings: [], removed: [:], binary: false)
        var oldLine = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                guard let mapping = mapping(fromHeader: line) else { continue }
                parsed.mappings.append(mapping)
                oldLine = mapping.original.lowerBound
            } else if line.hasPrefix("-"), !parsed.mappings.isEmpty {
                // Inside hunks every `-` line is a removal, even one whose text starts with `--`.
                parsed.removed[oldLine] = line.dropFirst()
                oldLine += 1
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                parsed.binary = true
            }
        }
        return parsed
    }

    /// `@@ -a[,b] +c[,d] @@`: a zero count means the range is empty and sits after line a/c.
    static func mapping(fromHeader header: Substring) -> LineRangeMapping? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
              let original = range(fields[1].dropFirst()), let modified = range(fields[2].dropFirst()) else { return nil }
        return LineRangeMapping(original: original, modified: modified)
    }

    private static func range(_ field: Substring) -> Range<Int>? {
        let parts = field.split(separator: ",")
        guard let start = Int(parts[0]) else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let lower = count == 0 ? start + 1 : start
        return lower..<(lower + count)
    }

    /// git merges changes into one hunk when at most 2 × 3 context lines separate them.
    public static func hunks(_ mappings: [LineRangeMapping], context: Int = 3) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        for mapping in mappings {
            if let last = hunks.last?.mappings.last, mapping.modified.lowerBound - last.modified.upperBound <= 2 * context {
                hunks[hunks.count - 1].mappings.append(mapping)
            } else {
                hunks.append(DiffHunk(mappings: [mapping]))
            }
        }
        return hunks
    }

    /// The base version of the file: the new lines with each change's removed lines put back.
    /// Unchanged runs are copied as whole spans, not line by line.
    public static func reconstructOld(new: SideText, mappings: [LineRangeMapping], removed: [Int: Substring]) -> SideText {
        let source = new.text as NSString
        let out = NSMutableString(capacity: new.utf16Count)
        func copyLines(_ lines: Range<Int>) {
            let lines = lines.clamped(to: 1..<(new.lineCount + 1))
            guard !lines.isEmpty else { return }
            let start = new.lineStarts[lines.lowerBound - 1]
            let end = lines.upperBound <= new.lineCount ? new.lineStarts[lines.upperBound - 1] : new.utf16Count
            out.append(source.substring(with: NSRange(location: start, length: end - start)))
            if lines.upperBound > new.lineCount, new.lineEnds[new.lineCount - 1] == new.utf16Count { out.append("\n") }
        }
        var next = 1
        for mapping in mappings {
            copyLines(next..<mapping.modified.lowerBound)
            for old in mapping.original {
                out.append(String(removed[old] ?? ""))
                out.append("\n")
            }
            next = mapping.modified.upperBound
        }
        copyLines(next..<(new.lineCount + 1))
        return SideText(out as String)
    }
}
