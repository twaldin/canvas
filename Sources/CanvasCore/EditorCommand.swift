import Foundation

/// The command "Edit Here" runs in a terminal tile: the user's editor (`$VISUAL`, else `$EDITOR`)
/// on a file, at a line for editors known to take `+line`.
public enum EditorCommand {
    /// Editors that open at `+<line>` given before the file.
    public static let plusLine: Set<String> = ["vi", "vim", "nvim", "gvim", "mvim", "view", "nano", "pico", "emacs", "emacsclient",
                                               "micro", "kak", "joe", "jed", "mg", "ne", "mcedit"]
    /// Of those, the ones that take `--` to end options (a path starting with `-` stays a path).
    static let endsOptions: Set<String> = ["vi", "vim", "nvim", "gvim", "mvim", "view"]

    /// `editor` is the variable's value, words split on whitespace (`code -w`); empty or nil
    /// uses `fallback` (nvim when installed, else vi).
    public static func argv(editor: String?, fallback: String, line: Int, path: String) -> [String] {
        var words = (editor ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { words = [fallback] }
        let name = URL(fileURLWithPath: words[0]).lastPathComponent
        guard plusLine.contains(name) else { return words + [path] }
        return words + ["+\(max(1, line))"] + (endsOptions.contains(name) ? ["--"] : []) + [path]
    }
}
