import Foundation

/// Zero-based line and UTF-16 column, as LSP counts them.
public struct LSPPosition: Sendable, Hashable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    var json: JSONValue { .object(["line": .number(Double(line)), "character": .number(Double(character))]) }

    init?(_ json: JSONValue?) {
        guard let line = json?["line"]?.int, let character = json?["character"]?.int else { return nil }
        self.init(line: line, character: character)
    }
}

public struct LSPRange: Sendable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    /// Half-open, as LSP ranges are: the end position is just past the last character.
    public func contains(_ position: LSPPosition) -> Bool {
        (start.line, start.character) <= (position.line, position.character) && (position.line, position.character) < (end.line, end.character)
    }

    /// The 1-based inclusive lines the range covers, as board `range` props store them. A
    /// multi-line range ending at column 0 stops on the line before.
    public var lines: LineRange {
        let first = start.line + 1
        let last = end.character == 0 && end.line > start.line ? end.line : end.line + 1
        return LineRange(start: first, end: max(first, last))
    }

    init?(_ json: JSONValue?) {
        guard let start = LSPPosition(json?["start"]), let end = LSPPosition(json?["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

public struct LSPLocation: Sendable, Hashable {
    /// Absolute file URL (the server's spelling, symlinks resolved by most servers).
    public var url: URL
    public var range: LSPRange

    public init(url: URL, range: LSPRange) {
        self.url = url
        self.range = range
    }

    /// Location, LocationLink (target side), or nil for non-file URIs.
    init?(_ json: JSONValue) {
        let uri = json["uri"]?.string ?? json["targetUri"]?.string
        guard let uri, let url = URL(string: uri), url.isFileURL,
              let range = LSPRange(json["targetSelectionRange"] ?? json["range"]) else { return nil }
        self.init(url: url, range: range)
    }

    /// Definition and references answer with one location, an array of them, or null.
    static func list(_ result: JSONValue) -> [LSPLocation] {
        switch result {
        case .array(let items): items.compactMap(LSPLocation.init)
        case .object: LSPLocation(result).map { [$0] } ?? []
        default: []
        }
    }
}

public struct LSPHover: Sendable, Hashable {
    /// Hover contents normalized to markdown (plain text and MarkedString included).
    public var markdown: String
    /// The span the hover describes, when the server says.
    public var range: LSPRange?

    init?(_ result: JSONValue) {
        let markdown = Self.markdown(result["contents"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        self.markdown = markdown
        range = LSPRange(result["range"])
    }

    private static func markdown(_ contents: JSONValue?) -> String {
        switch contents {
        case .string(let text)?: return text
        case .array(let parts)?: return parts.map { markdown($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
        case .object(let object)?:
            let value = object["value"]?.string ?? ""
            // MarkedString {language, value} is a code block; MarkupContent carries its kind.
            if let language = object["language"]?.string { return "```\(language)\n\(value)\n```" }
            if object["kind"]?.string == "plaintext" { return "```\n\(value)\n```" }
            return value
        default: return ""
        }
    }
}

public struct LSPSymbol: Sendable, Hashable {
    public var name: String
    public var detail: String?
    /// LSP SymbolKind (1 File … 26 TypeParameter).
    public var kind: Int
    /// Where the symbol's name is; what "reveal" jumps to.
    public var selectionRange: LSPRange
    public var children: [LSPSymbol]

    /// DocumentSymbol (hierarchical) or SymbolInformation (flat, location-based).
    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string, let kind = json["kind"]?.int,
              let range = LSPRange(json["selectionRange"]) ?? LSPRange(json["location"]?["range"]) else { return nil }
        self.name = name
        self.kind = kind
        detail = json["detail"]?.string
        selectionRange = range
        children = (json["children"]?.array ?? []).compactMap(LSPSymbol.init)
    }

    public var kindName: String {
        let names = ["file", "module", "namespace", "package", "class", "method", "property", "field", "constructor", "enum",
                     "interface", "function", "variable", "constant", "string", "number", "boolean", "array", "object", "key",
                     "null", "enum member", "struct", "event", "operator", "type parameter"]
        return (1...names.count).contains(kind) ? names[kind - 1] : "symbol"
    }

    /// Depth-first flattening for outline lists, each level in source order (servers may answer
    /// alphabetically, e.g. typescript-language-server).
    public static func flatten(_ symbols: [LSPSymbol], depth: Int = 0) -> [(symbol: LSPSymbol, depth: Int)] {
        symbols.sorted { ($0.selectionRange.start.line, $0.selectionRange.start.character) < ($1.selectionRange.start.line, $1.selectionRange.start.character) }
            .flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
    }
}

public enum LanguageServerStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(pid: Int32)
    /// Exited without being asked to; the next request starts it again.
    case crashed(String)
}

public enum LSPError: Error, Equatable, LocalizedError {
    case unsupportedLanguage(String)
    /// The server binary isn't installed (not on the login shell's PATH).
    case unavailable(String)
    case startFailed(String)
    case unreadable(String)
    /// The server exited while the request was outstanding.
    case serverExited(String)
    case response(code: Int, message: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let what): "No language server for \(what)"
        case .unavailable(let what): what
        case .startFailed(let why): "Language server failed to start: \(why)"
        case .unreadable(let path): "Cannot read \(path)"
        case .serverExited(let why): "\(why). It restarts on the next request."
        case .response(_, let message): message
        case .timedOut(let method): "Language server did not answer \(method) in time"
        }
    }
}
