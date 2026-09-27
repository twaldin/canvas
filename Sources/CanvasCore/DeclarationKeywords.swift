import Foundation

/// The words that introduce a named declaration across the languages agents write in, and the
/// kind of thing each declares: one list behind the text outline and definitions
/// (`TextNavigation`), note and HTML anchors (`NoteAnchor`, `NoteSource`, `HtmlExcerpt`), the
/// keyboard's subject (`CodeSubject`) and the server outline's labels. A reader that leaves some
/// out says which and why with the sets below.
public enum DeclarationKeywords {
    static let kinds: [String: String] = [
        "function": "function", "function*": "function", "def": "function", "func": "function", "fun": "function", "fn": "function",
        "class": "class", "record": "record", "object": "object", "interface": "interface", "protocol": "protocol", "trait": "trait",
        "type": "type", "typealias": "type", "enum": "enum", "struct": "struct", "union": "union", "actor": "actor",
        "module": "module", "namespace": "module", "mod": "module", "package": "package", "extension": "extension",
        "macro": "macro", "macro_rules!": "macro", "impl": "impl",
        "const": "constant", "let": "variable", "var": "variable", "val": "variable",
    ]

    /// Bindings: weaker evidence of a declaration than the rest, so anchors try them last.
    static let bindings: Set<String> = ["const", "let", "var", "val"]

    /// Words that don't declare the name after them: `impl Foo` implements a type declared
    /// elsewhere (or a trait for one), `package main` names the file's package. Anchors search
    /// inside them; the text outline and definitions leave them out.
    static let notDeclaring: Set<String> = ["impl", "package"]

    /// Words as common as plain identifiers (`module.exports`, `object.props`, `actor: .user`):
    /// the keyboard's subject doesn't skip them.
    static let commonNames: Set<String> = ["object", "record", "module", "namespace", "macro", "actor", "union"]

    /// `words` as a regex alternation, longest first so `function*` is tried before `function`.
    static func alternation(_ words: some Sequence<String>) -> String {
        words.sorted { ($0.count, $0) > ($1.count, $1) }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    private static let first = try! NSRegularExpression(pattern: #"(?<![\w$.])("# + alternation(kinds.keys) + #")(?![\w$])"#)

    /// The kind the first declaration keyword on `line` declares (`pub trait Foo` → `trait`,
    /// `impl<T> Display for X` → `impl`); nil when it has none.
    public static func kind(declaredBy line: String) -> String? {
        guard let match = first.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return kinds[(line as NSString).substring(with: match.range(at: 1))]
    }
}
