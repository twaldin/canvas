import CryptoKit
import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// Languages with a bundled tree-sitter grammar; anything else renders plain.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, typescript, tsx, javascript, python, json, bash, go, rust

    public init?(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": self = .swift
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "py", "pyi": self = .python
        case "json": self = .json
        case "sh", "bash", "zsh": self = .bash
        case "go": self = .go
        case "rs": self = .rust
        default:
            guard [".bashrc", ".zshrc", ".profile", ".bash_profile"].contains(name) else { return nil }
            self = .bash
        }
    }
}

public enum SyntaxStyle: String, Sendable, CaseIterable {
    case keyword, string, comment, number, type, function, property, variable, builtin, tag, punctuation
}

/// A styled UTF-16 range of the analyzed text.
public struct SyntaxSpan: Sendable, Equatable {
    public var range: NSRange
    public var style: SyntaxStyle
}

/// A declaration and the 1-based lines it spans; `name` is qualified by its enclosing
/// declarations (`Board.follow`).
public struct SyntaxSymbol: Sendable, Equatable {
    public var name: String
    public var lines: ClosedRange<Int>
    /// What it declares, from its node: class, function, method, interface, enum, struct, …
    public var kind: String = "symbol"
    /// How an outline lists it when that says more than its name: `IntoIterator for Batch` for
    /// a Rust trait impl, whose name (and its members' qualifier) is the type, `Batch`.
    public var title: String?

    /// The kind a declaration node makes (`class_declaration` is a class).
    static func kind(ofNode type: String?) -> String {
        guard let type else { return "symbol" }
        // Whole node names where a part would match others: `definition` holds `init`.
        for (part, kind) in [("protocol_function", "method"), ("method", "method"), ("deinit", "deinitializer"), ("init_declaration", "initializer"), ("protocol", "protocol"), ("interface", "interface"),
                             ("class", "class"), ("enum", "enum"), ("struct", "struct"), ("union", "union"), ("trait", "trait"), ("impl", "impl"), ("mod", "module"),
                             ("macro_definition", "macro"), ("const_item", "constant"), ("static_item", "static"), ("type_item", "type"),
                             ("type_spec", "type"), ("variable_declarator", "function"), ("function", "function")] where type.contains(part) {
            return kind
        }
        return "symbol"
    }
}

public struct SyntaxAnalysis: Sendable {
    /// Ordered so that applying them in turn leaves the most specific style on each character.
    public var spans: [SyntaxSpan]
    public var symbols: [SyntaxSymbol]

    public static let empty = SyntaxAnalysis(spans: [], symbols: [])
}

extension Sequence<SyntaxSymbol> {
    /// The innermost declaration holding every one of `lines`: a range spanning several
    /// declarations (a whole file's excerpt) names none of them, only one they all sit in.
    public func innermost(around lines: LineRange) -> String? {
        filter { $0.lines.contains(lines.start) && $0.lines.contains(lines.end) }.min { $0.lines.count < $1.lines.count }?.name
    }
}

/// Tree-sitter parsing for code tiles: highlight spans and enclosing symbols. Thread-safe;
/// queries compile once per language, and results are cached per (language, content hash).
public enum Syntax {
    public static func analyze(_ text: String, language: SyntaxLanguage) -> SyntaxAnalysis {
        let key = CacheKey(language: language, content: Data(SHA256.hash(data: Data(text.utf8))))
        if let cached = cache.value(key) { return cached }
        guard let grammar = Grammar.load(language), let tree = grammar.parse(text), let root = tree.rootNode else { return .empty }
        let source = text as NSString
        let analysis = SyntaxAnalysis(spans: spans(root, tree: tree, grammar: grammar, text: text), symbols: symbols(root, tree: tree, grammar: grammar, source: source))
        cache.insert(analysis, for: key)
        return analysis
    }

    private static func spans(_ root: Node, tree: MutableTree, grammar: Grammar, text: String) -> [SyntaxSpan] {
        struct Styled {
            var range: NSRange
            var pattern: Int
            var style: SyntaxStyle
        }
        var styled: [Styled] = []
        let cursor = grammar.highlights.execute(node: root, in: tree)
        for match in cursor.resolve(with: Predicate.Context(string: text)) {
            for capture in match.captures {
                guard let name = capture.name, let style = style(forCapture: name), capture.range.length > 0 else { continue }
                styled.append(Styled(range: capture.range, pattern: match.patternIndex, style: style))
            }
        }
        // Outer ranges first so nested ones paint over them; for the same range the earliest
        // pattern wins, as in tree-sitter's own highlighter.
        styled.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            return lhs.pattern > rhs.pattern
        }
        return styled.map { SyntaxSpan(range: $0.range, style: $0.style) }
    }

    static func style(forCapture name: String) -> SyntaxStyle? {
        let parts = name.split(separator: ".")
        switch parts.first {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": return .keyword
        case "string", "escape", "character": return .string
        case "comment": return .comment
        case "number", "float", "boolean": return .number
        case "constant": return parts.dropFirst().first == "builtin" ? .builtin : .number
        case "type", "constructor": return .type
        case "function", "method": return parts.dropFirst().first == "builtin" ? .builtin : .function
        case "property", "attribute", "field", "label": return .property
        case "variable": return parts.dropFirst().first == "builtin" ? .builtin : nil
        case "tag": return .tag
        case "punctuation", "operator": return .punctuation
        default: return nil
        }
    }

    private static func symbols(_ root: Node, tree: MutableTree, grammar: Grammar, source: NSString) -> [SyntaxSymbol] {
        guard let query = grammar.symbols else { return [] }
        var found: [(name: String, title: String?, range: NSRange, lines: ClosedRange<Int>, kind: String)] = []
        for match in query.execute(node: root, in: tree) {
            guard let declaration = match.captures.first(where: { $0.name == "symbol" })?.node,
                  let name = match.captures.first(where: { $0.name == "name" }).map({ source.substring(with: $0.node.range) }) else { continue }
            let title = match.captures.first(where: { $0.name == "trait" }).map { "\(source.substring(with: $0.node.range)) for \(name)" }
            let lines = Int(declaration.pointRange.lowerBound.row) + 1...Int(declaration.pointRange.upperBound.row) + 1
            found.append((name, title, declaration.range, lines, SyntaxSymbol.kind(ofNode: declaration.nodeType)))
        }
        found.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        // Qualify each name with the declarations enclosing it.
        var stack: [(name: String, end: Int)] = []
        return found.map { symbol in
            while let last = stack.last, last.end <= symbol.range.location { stack.removeLast() }
            let qualified = (stack.map(\.name) + [symbol.name]).joined(separator: ".")
            stack.append((symbol.name, symbol.range.location + symbol.range.length))
            return SyntaxSymbol(name: qualified, lines: symbol.lines, kind: symbol.kind, title: symbol.title)
        }
    }

    // MARK: Cache

    private struct CacheKey: Hashable {
        var language: SyntaxLanguage
        var content: Data
    }

    private static let cache = AnalysisCache()

    private final class AnalysisCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: SyntaxAnalysis] = [:]
        private var order: [CacheKey] = []

        func value(_ key: CacheKey) -> SyntaxAnalysis? {
            lock.withLock { entries[key] }
        }

        func insert(_ analysis: SyntaxAnalysis, for key: CacheKey) {
            lock.withLock {
                if entries.updateValue(analysis, forKey: key) == nil {
                    order.append(key)
                    if order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
                }
            }
        }
    }
}

/// A compiled grammar: its language, highlight query, and declaration query. Queries come from
/// the grammar packages' own `queries` resources; TypeScript and TSX extend JavaScript's.
private final class Grammar: @unchecked Sendable {
    let language: Language
    let highlights: Query
    let symbols: Query?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [SyntaxLanguage: Grammar?] = [:]

    private init(language: Language, highlights: Query, symbols: Query?) {
        self.language = language
        self.highlights = highlights
        self.symbols = symbols
    }

    static func load(_ language: SyntaxLanguage) -> Grammar? {
        lock.withLock {
            if let known = loaded[language] { return known }
            let grammar = make(language)
            loaded[language] = grammar
            return grammar
        }
    }

    /// Parsers are cheap and not thread-safe, so each parse gets its own.
    func parse(_ text: String) -> MutableTree? {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else { return nil }
        return parser.parse(text)
    }

    private static func make(_ syntax: SyntaxLanguage) -> Grammar? {
        let (pointer, sources) = definition(syntax)
        let language = Language(pointer)
        let highlightSource = sources.compactMap(queryText).joined(separator: "\n")
        guard let highlights = try? Query(language: language, data: Data(highlightSource.utf8)) else { return nil }
        let symbols = symbolQuery(syntax).flatMap { try? Query(language: language, data: Data($0.utf8)) }
        return Grammar(language: language, highlights: highlights, symbols: symbols)
    }

    /// Language pointer and highlight files (resource bundle target, file) in precedence order.
    private static func definition(_ syntax: SyntaxLanguage) -> (OpaquePointer, [(String, String)]) {
        switch syntax {
        case .swift: (tree_sitter_swift(), [("TreeSitterSwift", "highlights.scm")])
        case .typescript: (tree_sitter_typescript(), [("TreeSitterTypeScript", "highlights.scm"), ("TreeSitterJavaScript", "highlights.scm")])
        case .tsx: (tree_sitter_tsx(), [("TreeSitterTSX", "highlights.scm"), ("TreeSitterJavaScript", "highlights.scm"), ("TreeSitterJavaScript", "highlights-jsx.scm")])
        case .javascript: (tree_sitter_javascript(), [("TreeSitterJavaScript", "highlights.scm"), ("TreeSitterJavaScript", "highlights-jsx.scm")])
        case .python: (tree_sitter_python(), [("TreeSitterPython", "highlights.scm")])
        case .json: (tree_sitter_json(), [("TreeSitterJSON", "highlights.scm")])
        case .bash: (tree_sitter_bash(), [("TreeSitterBash", "highlights.scm")])
        case .go: (tree_sitter_go(), [("TreeSitterGo", "highlights.scm")])
        case .rust: (tree_sitter_rust(), [("TreeSitterRust", "highlights.scm")])
        }
    }

    /// Declarations that name an enclosing symbol: `@symbol` is the declaration, `@name` its name.
    private static func symbolQuery(_ syntax: SyntaxLanguage) -> String? {
        switch syntax {
        case .swift:
            return """
            (class_declaration name: (_) @name) @symbol
            (protocol_declaration name: (_) @name) @symbol
            (function_declaration name: (_) @name) @symbol
            (protocol_function_declaration name: (_) @name) @symbol
            (init_declaration "init" @name) @symbol
            (deinit_declaration "deinit" @name) @symbol
            """
        case .typescript, .tsx:
            return scriptSymbols + """
            (interface_declaration name: (_) @name) @symbol
            (abstract_class_declaration name: (_) @name) @symbol
            (enum_declaration name: (_) @name) @symbol
            (internal_module name: (_) @name) @symbol
            (function_signature name: (_) @name) @symbol
            """
        case .javascript:
            return scriptSymbols
        case .python:
            return """
            (function_definition name: (_) @name) @symbol
            (class_definition name: (_) @name) @symbol
            """
        case .go:
            return """
            (function_declaration name: (_) @name) @symbol
            (method_declaration name: (_) @name) @symbol
            (type_spec name: (_) @name) @symbol
            """
        case .rust:
            // A trait impl is named by its type, like an inherent one, so its members qualify
            // as `Batch.into_iter`; the trait is its `@trait` (`SyntaxSymbol.title`).
            return """
            (function_item name: (_) @name) @symbol
            (impl_item trait: (_)? @trait type: (_) @name) @symbol
            (struct_item name: (_) @name) @symbol
            (enum_item name: (_) @name) @symbol
            (union_item name: (_) @name) @symbol
            (trait_item name: (_) @name) @symbol
            (mod_item name: (_) @name) @symbol
            (macro_definition name: (_) @name) @symbol
            (const_item name: (_) @name) @symbol
            (static_item name: (_) @name) @symbol
            (type_item name: (_) @name) @symbol
            """
        case .bash:
            return "(function_definition name: (_) @name) @symbol"
        case .json:
            return nil
        }
    }

    private static let scriptSymbols = """
    (function_declaration name: (_) @name) @symbol
    (generator_function_declaration name: (_) @name) @symbol
    (class_declaration name: (_) @name) @symbol
    (method_definition name: (_) @name) @symbol
    (variable_declarator name: (identifier) @name value: [(arrow_function) (function_expression)]) @symbol

    """

    /// A query file from a grammar package's resource bundle, next to the executable in a
    /// `swift run` build and in Contents/Resources in the app bundle.
    private static func queryText(_ source: (target: String, file: String)) -> String? {
        let fileManager = FileManager.default
        let containers = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for container in containers {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: container.path) else { continue }
            for entry in entries where entry.hasSuffix("_\(source.target).bundle") {
                let bundle = container.appendingPathComponent(entry)
                for queries in [bundle.appendingPathComponent("Contents/Resources/queries"), bundle.appendingPathComponent("queries")] {
                    if let text = try? String(contentsOf: queries.appendingPathComponent(source.file), encoding: .utf8) { return text }
                }
            }
        }
        return nil
    }
}
