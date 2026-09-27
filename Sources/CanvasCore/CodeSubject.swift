import Foundation

/// What Go to Definition and Find References act on from the keyboard (the menu bar), where no
/// pointer names a symbol: the first name on a line that isn't a declaration keyword, so a tile
/// aimed at `def write_usage(self, …)` or `public func neighbor(of:…)` means that symbol.
public enum CodeSubject {
    static let keywords: Set<String> = [
        "def", "class", "async", "await", "func", "fn", "function", "let", "var", "const", "pub", "public", "private",
        "fileprivate", "internal", "open", "static", "final", "override", "mutating", "nonisolated", "export", "default",
        "struct", "enum", "interface", "type", "protocol", "extension", "impl", "trait", "mod", "package", "import",
        "from", "return", "abstract", "readonly", "declare", "unsafe", "extern", "virtual", "inline", "void", "self",
    ]

    /// The UTF-16 offset of the first non-keyword identifier in `line`; nil when it has none.
    public static func firstName(in line: String) -> Int? {
        let units = Array(line.utf16)
        func isStart(_ unit: UInt16) -> Bool {
            unit == 0x5F || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit > 0x7F
        }
        func isPart(_ unit: UInt16) -> Bool { isStart(unit) || (0x30...0x39).contains(unit) }
        var index = 0
        while index < units.count {
            // A comment ends the search: nothing after `#` or `//` is code.
            if units[index] == 0x23 || (units[index] == 0x2F && index + 1 < units.count && units[index + 1] == 0x2F) { return nil }
            guard isStart(units[index]), index == 0 || !isPart(units[index - 1]) else {
                index += 1
                continue
            }
            var end = index
            while end < units.count, isPart(units[end]) { end += 1 }
            let word = String(decoding: units[index..<end], as: UTF16.self)
            let decorated = index > 0 && units[index - 1] == 0x40
            if !decorated, !keywords.contains(word) { return index }
            index = end
        }
        return nil
    }
}
