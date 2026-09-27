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
    /// Diff prefixes (`a/`, `b/`) are tried without the prefix too. Nil when no candidate is a file.
    public static func resolve(_ path: String, directories: [String], home: String, isFile: (String) -> Bool) -> String? {
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
        return nil
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
