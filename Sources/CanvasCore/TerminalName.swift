import Foundation

/// What a terminal tile is called where it's listed (its header, ⌘P, the tray): its name (the
/// user's or an agent's `props.name`, else the program running in it) next to the live title the
/// program set (OSC 0/2).
public enum TerminalName {
    /// Interpreters whose first operand is the program being run (`node …/bin/gemini` is gemini).
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl", "php", "sh", "bash", "zsh", "dash", "fish"]
    static let maxWords = 3

    /// A process's argv as the name a person would give what runs: the program's file name and
    /// the leading words that pick what it does (`cargo test`, `npm run dev`), up to the first
    /// option (`opencode -m …` is `opencode`); for an interpreter, the script it runs
    /// (`node --no-warnings /opt/homebrew/bin/gemini` is `gemini`). Paths shorten to their last
    /// component. Nil for an empty argv.
    public static func program(argv: [String]) -> String? {
        guard let first = argv.first.map(lastComponent), !first.isEmpty else { return nil }
        var words = Array(argv.dropFirst())
        var name = first
        // `python3.12`, `node18` run scripts too, and so does macOS's framework `Python`.
        if interpreters.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))) {
            words = Array(words.drop { $0.hasPrefix("-") })
            if let script = words.first, script.contains("/") || script.contains(".") {
                name = lastComponent(script)
                words.removeFirst()
            }
        }
        let leading = words.prefix { !$0.hasPrefix("-") && !$0.isEmpty }.prefix(maxWords - 1).map(lastComponent)
        return ([name] + leading).joined(separator: " ")
    }

    /// The header text: `name · title`, just the title when it already says the name (Claude
    /// Code's "✳ Claude Code") or there is no name, just the name when there is no title.
    public static func label(name: String?, title: String?) -> String? {
        let name = name.flatMap(nonEmpty)
        guard let title = title.flatMap(nonEmpty) else { return name }
        guard let name, title.range(of: name, options: .caseInsensitive) == nil else { return title }
        return "\(name) · \(title)"
    }

    private static func lastComponent(_ word: String) -> String {
        word.contains("/") ? (word.split(separator: "/").last.map(String.init) ?? word) : word
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
