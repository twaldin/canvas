import Foundation

/// A `path:line` reference in terminal output (an agent's answer, a compiler error, a stack
/// trace): `src/foo.ts:42`, `src/foo.ts:42:7`, `src/foo.ts:42-50`, `foo.rs#L10-20`,
/// `/abs/path.swift:3`, `~/x.py:9`. ⌘-click opens it as a code tile beside the terminal.
public struct TerminalReference: Equatable, Sendable {
    /// UTF-16 range of the whole reference in the searched text.
    public var range: NSRange
    public var path: String
    public var lines: LineRange

    public init(range: NSRange, path: String, lines: LineRange) {
        self.range = range
        self.path = path
        self.lines = lines
    }
}

public enum TerminalReferences {
    // The path: optional `~`/`.`/`..` root, directories, a name. It needs a slash or a file
    // extension (checked after matching), so `localhost:3000` and `12:30` never match; the
    // lookbehind keeps `https://example.com:443` out. Then `:line`, `:line:col`, `:start-end`,
    // or `#Lstart`, `#Lstart-end`, `#Lstart-Lend`.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?<![\w./@:~-])((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*)(?::(\d+)(?:-(\d+)|:\d+)?|#L(\d+)(?:-L?(\d+))?)(?![\w/])"#)

    public static func find(in text: String) -> [TerminalReference] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let path = ns.substring(with: match.range(at: 1))
            guard path.contains("/") || hasExtension(path) else { return nil }
            func number(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let start = number(2) ?? number(4), start >= 1 else { return nil }
            let end = max(start, number(3) ?? number(5) ?? start)
            return TerminalReference(range: match.range, path: path, lines: LineRange(start: start, end: end))
        }
    }

    /// The reference covering UTF-16 offset `offset` of `text`.
    public static func reference(in text: String, at offset: Int) -> TerminalReference? {
        find(in: text).first { NSLocationInRange(offset, $0.range) }
    }

    /// `name.ext` with an extension starting with a letter (`v1.2` is a version, not a file).
    private static func hasExtension(_ path: String) -> Bool {
        let name = path.split(separator: "/").last ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return ext.first?.isLetter == true && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The existing file `path` names: absolute and `~/` paths as they are, relative ones against
    /// `directories` in order (the terminal's reported cwd, its `props.cwd`, the board root).
    /// Diff prefixes (`a/`, `b/`) are tried without the prefix too. When no directory has it, a
    /// relative path is looked up among the board root's `listed` files as a file name or a
    /// trailing part of a path (`core.py`, `click/core.py:10`, as agents write before they know
    /// better): one match is it; of several, the one nearest `cwd` (fewest directories up and
    /// down), unless two are equally near. Nil when nothing resolves.
    public static func resolve(_ path: String, directories: [String], home: String, isFile: (String) -> Bool,
                               listed: (root: String, files: FileIndex)? = nil, near cwd: String? = nil) -> String? {
        func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        if path.hasPrefix("~/") {
            let candidate = standard(home + path.dropFirst())
            return isFile(candidate) ? candidate : nil
        }
        if path.hasPrefix("/") {
            let candidate = standard(path)
            return isFile(candidate) ? candidate : nil
        }
        var relatives = [path]
        if path.hasPrefix("a/") || path.hasPrefix("b/") { relatives.append(String(path.dropFirst(2))) }
        for relative in relatives {
            for directory in directories where !directory.isEmpty {
                let candidate = standard((directory as NSString).appendingPathComponent(relative))
                if isFile(candidate) { return candidate }
            }
        }
        guard let listed else { return nil }
        var matches: [String] = []
        // A diff's `a/` or `b/` prefix is dropped only when the path as written matches nothing.
        for relative in relatives where matches.isEmpty {
            var suffix = Substring(relative)
            while suffix.hasPrefix("./") { suffix = suffix.dropFirst(2) }
            guard !suffix.split(separator: "/").contains("..") else { continue }
            for match in listed.files.paths(endingWith: String(suffix)) {
                let candidate = standard((listed.root as NSString).appendingPathComponent(match))
                if !matches.contains(candidate), isFile(candidate) { matches.append(candidate) }
            }
        }
        guard matches.count > 1 else { return matches.first }
        guard let cwd else { return nil }
        // /tmp and /private/tmp are one directory; a shell may report either.
        func real(_ path: String) -> [Substring] { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.split(separator: "/") }
        let here = real(cwd)
        func distance(_ file: String) -> Int {
            let folder = real(file).dropLast()
            let shared = zip(here, folder).prefix { $0 == $1 }.count
            return (here.count - shared) + (folder.count - shared)
        }
        let ranked = matches.map { ($0, distance($0)) }.sorted { $0.1 < $1.1 }
        return ranked[0].1 < ranked[1].1 ? ranked[0].0 : nil
    }

    /// True for an existing regular file (or a symlink to one).
    public static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
}

extension Board {
    /// A reference the user ⌘-clicked in terminal `tile`: selects the code tile already showing
    /// `path` at `lines` (follow tiles excluded: they belong to their agent), else creates one
    /// beside the terminal (`place(near:)`). `path` is absolute; it is stored board-relative when
    /// it lives under the root.
    @discardableResult
    public func openCode(path: String, lines: LineRange, beside tile: ObjectID) -> (id: ObjectID, created: Bool) {
        let stored = relativePath(path)
        let range: JSONValue = .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))])
        if let existing = objects.values
            .filter({ $0.type == .code && $0.props["followOf"] == nil && $0.props["path"]?.string == stored && $0.props["range"] == range })
            .max(by: { $0.z < $1.z }) {
            return (existing.id, false)
        }
        let size = Board.defaultSize(.code)
        let created = create(type: .code, props: .object(["path": .string(stored), "range": range]), frame: place(width: size.w, height: size.h, near: tile))
        return (created.id, true)
    }

    /// A code location the user opened from a tile (an HTML page's link, a changes tile's line):
    /// re-aims the topmost code tile already showing `path` (follow tiles excluded: they belong
    /// to their agent), else creates one beside `tile` with `extra` props (e.g. the diff base).
    @discardableResult
    public func showCode(path: String, range: LineRange?, symbol: String? = nil, beside tile: ObjectID, extra: [String: JSONValue] = [:]) throws -> (id: ObjectID, created: Bool) {
        let rangeValue: JSONValue = range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        let existing = objects.values
            .filter { $0.type == .code && $0.props["path"]?.string == path && $0.props["followOf"] == nil }
            .max { $0.z < $1.z }
        if let existing {
            try update(existing.id, props: .object(["range": rangeValue, "symbol": symbol.map(JSONValue.string) ?? .null]))
            return (existing.id, false)
        }
        var props = extra.merging(["path": .string(path), "range": rangeValue]) { $1 }
        if let symbol { props["symbol"] = .string(symbol) }
        let size = Board.defaultSize(.code)
        let created = create(type: .code, props: .object(props.filter { $0.value != .null }), frame: place(width: size.w, height: size.h, near: tile))
        return (created.id, true)
    }
}

/// How a terminal whose session is gone (after a reboot) resumes the agent it recorded
/// (`props.agent`: `kind` and `sessionId`, from `agent.report_session`).
public enum AgentResume {
    public static func argv(kind: String, sessionId: String) -> [String]? {
        switch kind {
        case "omp": ["omp", "--resume=\(sessionId)"]
        case "claude": ["claude", "--resume", sessionId]
        case "codex": ["codex", "resume", sessionId]
        default: nil
        }
    }
}
