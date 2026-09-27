import Foundation

/// A declaration a line of source makes: the name it declares, what kind of thing that is, and
/// the UTF-16 column of the name.
public struct Declaration: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var column: Int
}

/// Code navigation without a language server: likely declarations by per-language patterns
/// (`function`, `class`, `def`, `const`, `type`, `interface`, `func`, `fn`, `struct`,
/// `macro_rules!`, …), and word matches over the files of a root (`git grep -w`), for when a
/// language's server is not installed or not running. Answers are labelled as text search
/// wherever they are shown.
public enum TextNavigation {
    /// Names a declaration keyword introduces, with the kind it makes.
    private static let keywordKinds: [String: String] = [
        "function": "function", "function*": "function", "def": "function", "func": "function", "fun": "function", "fn": "function",
        "class": "class", "interface": "interface", "protocol": "protocol", "trait": "trait",
        "type": "type", "typealias": "type", "enum": "enum", "struct": "struct", "union": "union", "actor": "actor",
        "const": "constant", "let": "variable", "var": "variable", "val": "variable",
        "module": "module", "namespace": "module", "mod": "module", "extension": "extension",
        "macro_rules!": "macro",
    ]

    private static let identifier = #"[A-Za-z_$][\w$]*"#

    /// `class Foo`, `export async function foo`, `pub fn foo`, `def foo`, `const foo`, `type Foo`,
    /// `macro_rules! foo`. The name is matched ahead, not taken, so `const fn foo` finds `fn foo` too.
    private static let keyword = try! NSRegularExpression(pattern: #"(?<![\w$.])(function\*?|def|func|fun|fn|class|interface|protocol|trait|type|typealias|enum|struct|union|actor|const|let|var|val|module|namespace|mod|extension|macro_rules!)\s+(?=("# + identifier + "))")
    /// A Rust static: `pub static mut COUNTER: u32` (`static` elsewhere is a modifier).
    private static let rustStatic = try! NSRegularExpression(pattern: #"^\s*(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?([A-Za-z_]\w*)\s*:"#)
    /// Go methods: `func (s *Server) Serve(`.
    private static let goMethod = try! NSRegularExpression(pattern: #"\bfunc\s*\([^)]*\)\s*([A-Za-z_]\w*)"#)
    /// `foo = async (a) =>`, `foo: function (`, `foo = x =>`.
    private static let assignedFunction = try! NSRegularExpression(pattern: "(?:^|[\\s,{(])(" + identifier + #")\s*[:=]\s*(?:async\s+)?(?:function\b|(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*(?::\s*[^=]+?)?=>)"#)
    /// A method definition line: `async resolve(ctx: Context): Promise<void> {`.
    private static let method = try! NSRegularExpression(pattern: #"^\s*(?:(?:public|private|protected|internal|static|async|readonly|override|abstract|get|set|pub|export|default|final|open)\s+)*("# + identifier + #")\s*(?:<[^<>()]*>)?\s*\([^()]*\)\s*(?:(?::|->)\s*[^={;]+)?\{\s*$"#)
    /// A module-level Python assignment: `DEFAULT_TIMEOUT = 30`, `app: Flask = Flask(…)`.
    private static let pythonAssignment = try! NSRegularExpression(pattern: #"^([A-Za-z_]\w*)\s*(?::[^=]+)?=(?!=)"#)
    /// Words the method pattern would take for a name: control flow and calls, not declarations.
    private static let notNames: Set<String> = ["if", "for", "while", "switch", "catch", "return", "function", "with", "elif", "else", "match", "guard", "when", "foreach", "until", "do", "try", "await", "typeof", "super", "this", "constructor"]

    /// The declarations a line of source makes (a line may make several: `const f = () =>`
    /// once). Comment lines and imports make none. `pathExtension` picks language-only rules
    /// (Python's module-level assignments, Rust's statics).
    public static func declarations(inLine line: String, pathExtension: String = "") -> [Declaration] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Comments, imports, and attributes (`#[derive]`) declare nothing.
        if ["//", "#", "/*", "*", "--", "import ", "from ", "use ", "using ", "@import"].contains(where: trimmed.hasPrefix) { return [] }
        let text = line as NSString
        let whole = NSRange(location: 0, length: text.length)
        var found: [Declaration] = []
        func add(_ name: String, _ kind: String, _ column: Int) {
            guard !notNames.contains(name), !keywordKinds.keys.contains(name), !found.contains(where: { $0.name == name }) else { return }
            found.append(Declaration(name: name, kind: kind, column: column))
        }
        for match in keyword.matches(in: line, range: whole) {
            let name = match.range(at: 2)
            add(text.substring(with: name), keywordKinds[text.substring(with: match.range(at: 1))] ?? "symbol", name.location)
        }
        for match in goMethod.matches(in: line, range: whole) {
            add(text.substring(with: match.range(at: 1)), "method", match.range(at: 1).location)
        }
        for match in assignedFunction.matches(in: line, range: whole) {
            add(text.substring(with: match.range(at: 1)), "function", match.range(at: 1).location)
        }
        if found.isEmpty, let match = method.firstMatch(in: line, range: whole) {
            add(text.substring(with: match.range(at: 1)), "method", match.range(at: 1).location)
        }
        if pathExtension == "py" || pathExtension == "pyi", found.isEmpty, let match = pythonAssignment.firstMatch(in: line, range: whole) {
            add(text.substring(with: match.range(at: 1)), "variable", match.range(at: 1).location)
        }
        if pathExtension == "rs", let match = rustStatic.firstMatch(in: line, range: whole) {
            add(text.substring(with: match.range(at: 1)), "static", match.range(at: 1).location)
        }
        return found
    }

    /// A file's top-level declarations (unindented lines), 1-based lines, in source order: an
    /// outline for files without a language server, beside the tree-sitter symbols.
    public static func topLevelDeclarations(in text: String, pathExtension: String) -> [(line: Int, declaration: Declaration)] {
        var result: [(Int, Declaration)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            for declaration in declarations(inLine: String(line), pathExtension: pathExtension) {
                result.append((index + 1, declaration))
            }
        }
        return result
    }

    /// One row of an outline made without a language server.
    public struct OutlineEntry: Equatable, Sendable {
        public var name: String
        public var kind: String
        /// 1-based.
        public var line: Int
        /// How many types it is nested in.
        public var depth: Int
    }

    /// Kinds whose members an outline lists (a function's locals it doesn't).
    private static let containers: Set<String> = ["class", "interface", "protocol", "enum", "struct", "trait", "impl", "module", "extension"]

    /// A file's outline without a language server, in source order: the tree-sitter declarations
    /// (types, their members, top-level functions; nothing declared inside a function), plus
    /// top-level declarations the grammar's query doesn't name (`const`, `type`, `interface`,
    /// module-level assignments in Python) by `declarations(inLine:)`, or only those for a
    /// language without a bundled grammar.
    public static func outline(of text: String, path: String) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        var stack: [(lines: ClosedRange<Int>, container: Bool)] = []
        let symbols = SyntaxLanguage(path: path).map { Syntax.analyze(text, language: $0).symbols } ?? []
        for symbol in symbols {
            while let last = stack.last, !(last.lines.lowerBound <= symbol.lines.lowerBound && symbol.lines.upperBound <= last.lines.upperBound) {
                stack.removeLast()
            }
            let local = stack.contains { !$0.container }
            let depth = stack.count
            stack.append((symbol.lines, containers.contains(symbol.kind)))
            guard !local else { continue }
            let name = symbol.title ?? symbol.name.split(separator: ".").last.map(String.init) ?? symbol.name
            entries.append(OutlineEntry(name: name, kind: symbol.kind, line: symbol.lines.lowerBound, depth: depth))
        }
        let named = Set(entries.map(\.line))
        for (line, declaration) in topLevelDeclarations(in: text, pathExtension: (path as NSString).pathExtension) where !named.contains(line) {
            entries.append(OutlineEntry(name: declaration.name, kind: declaration.kind, line: line, depth: 0))
        }
        return entries.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }

    /// A word match: a file (relative to the searched root), 1-based line and column, the line.
    public struct Match: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var column: Int
        public var text: String

        public init(path: String, line: Int, column: Int, text: String) {
            self.path = path
            self.line = line
            self.column = column
            self.text = text
        }
    }

    /// Parses `git grep -n -z --column` output: `path\0line\0column\0text` per line.
    public static func parse(_ output: String) -> [Match] {
        output.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let line = Int(parts[1]), let column = Int(parts[2]) else { return nil }
            return Match(path: String(parts[0]), line: line, column: column, text: String(parts[3]))
        }
    }

    /// Where a text search for `file` runs: the board root when the file is under it, else the
    /// repository (a directory holding `.git`) the file is in, else its directory.
    public static func searchRoot(for file: URL, boardRoot: URL) -> URL {
        let path = file.resolvingSymlinksInPath().path
        let root = boardRoot.resolvingSymlinksInPath()
        if path.hasPrefix(root.path + "/") { return root }
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// The most word matches a search lists.
    public static let maxMatches = 200
    /// Word matches taken from any one file.
    static let maxPerFile = 60

    /// Lines of the files under `root` containing `name` as a whole word, tracked or untracked
    /// but not ignored, binary files skipped, in path order; at most `maxMatches` (`truncated`
    /// says there were more). Runs git off the main thread.
    public static func wordMatches(_ name: String, in root: URL) async throws -> (matches: [Match], truncated: Bool) {
        let args = ["grep", "-n", "-z", "--column", "-w", "-I", "-F", "--max-count", "\(maxPerFile)", "-e", name]
        let output: Data
        do {
            output = try await GitRunner.shared.run(args + ["--untracked"], in: root, allowedStatus: [0, 1], maxOutput: 8 << 20, timeout: 20)
        } catch GitError.failed(let status, _) where status == 128 {
            // Not a repository: the directory's files, minus what .gitignore files exclude.
            output = try await GitRunner.shared.run(args + ["--no-index", "--exclude-standard"], in: root, allowedStatus: [0, 1], maxOutput: 8 << 20, timeout: 20)
        }
        let text = String(decoding: output, as: UTF8.self)
        let matches = await offPool { parse(text) }
        return (Array(matches.prefix(maxMatches)), matches.count > maxMatches)
    }

    /// The likely declarations of `name` under `root`: word matches whose line declares it
    /// (`declarations(inLine:)`), those in `file` (relative to `root`) first, then those in files
    /// of its language, then the rest, each in path and line order.
    public static func declarations(of name: String, in root: URL, preferring file: String) async throws -> [Match] {
        let args = ["grep", "-n", "-z", "--column", "-w", "-I", "-F", "-e", name]
        let output: Data
        do {
            output = try await GitRunner.shared.run(args + ["--untracked"], in: root, allowedStatus: [0, 1], maxOutput: 32 << 20, timeout: 20)
        } catch GitError.failed(let status, _) where status == 128 {
            output = try await GitRunner.shared.run(args + ["--no-index", "--exclude-standard"], in: root, allowedStatus: [0, 1], maxOutput: 32 << 20, timeout: 20)
        }
        let text = String(decoding: output, as: UTF8.self)
        return await offPool { rankDeclarations(of: name, among: parse(text), preferring: file) }
    }

    /// `declarations(of:in:preferring:)`'s filter and order over word matches.
    public static func rankDeclarations(of name: String, among matches: [Match], preferring file: String) -> [Match] {
        let language = family((file as NSString).pathExtension)
        let declared: [(Match, Int)] = matches.compactMap { match in
            let pathExtension = (match.path as NSString).pathExtension
            guard let declaration = declarations(inLine: match.text, pathExtension: pathExtension).first(where: { $0.name == name }) else { return nil }
            var located = match
            located.column = declaration.column + 1
            return (located, match.path == file ? 0 : family(pathExtension) == language ? 1 : 2)
        }
        return declared.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    /// Extensions of one language family: a `.tsx` component's declaration in a `.ts` file.
    private static func family(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs": "script"
        case "py", "pyi": "python"
        case "c", "h", "cc", "cpp", "hpp", "m", "mm": "c"
        default: pathExtension.lowercased()
        }
    }
}
