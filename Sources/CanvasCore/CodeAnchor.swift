import Foundation

/// A code tile's range kept on the code it showed (docs/contracts.md "Code tiles"): it resolves
/// through `NoteAnchor` exactly as a note fence's line range does, by `props.anchor` (the range's
/// first line, which the tile writes back) and the text the tile last saw there.
public enum CodeAnchor {
    /// The fence a code tile's range resolves as; nil for a tile that doesn't anchor: a follow
    /// tile (it re-aims itself), one pinned to a commit (its text never changes), or one without
    /// a range.
    public static func fence(_ props: JSONValue) -> NoteFence? {
        guard props["followOf"]?.string == nil, props["pinnedCommit"]?.string.map(\.isEmpty) ?? true,
              let path = props["path"]?.string, !path.isEmpty, let start = props["range"]?["start"]?.int else { return nil }
        let end = max(start, props["range"]?["end"]?.int ?? start)
        return NoteFence(path: path, lines: LineRange(start: start, end: end), anchor: props["anchor"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The anchor written back for `range` of `source`: its first line, trimmed; nil when blank.
    public static func anchor(of range: LineRange, in source: [String]) -> String? {
        guard range.start >= 1, range.start <= source.count else { return nil }
        let text = source[range.start - 1].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
