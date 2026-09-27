import Foundation

/// A command a terminal tile's shell ran, as Ghostty's shell integration reports it when the
/// command finishes (OSC 133 D: the exit status; Ghostty measures the duration from the
/// command's start, OSC 133 C). `command` is the command line when Canvas saw it: the title the
/// integration sets while it runs, or for an older block the prompt row above its output.
public struct TerminalCommand: Codable, Equatable, Sendable {
    public var command: String?
    public var exit: Int?
    public var durationMs: Int?

    public init(command: String? = nil, exit: Int? = nil, durationMs: Int? = nil) {
        self.command = command
        self.exit = exit
        self.durationMs = durationMs
    }

    /// A command that ran at least this long raises a marker when it finishes while nobody looks.
    public static let noticeAfterMs = 30_000
    /// A successful command shows its duration in the tile's header from this long.
    public static let showAfterMs = 10_000

    /// `exit 1 · 42 s`: what the header shows after a command that failed or ran long; nil after a
    /// quick success, so a terminal that works stays quiet.
    public var status: String? {
        let failed = (exit ?? 0) != 0
        let long = (durationMs ?? 0) >= Self.showAfterMs
        guard failed || long else { return nil }
        var parts: [String] = []
        if failed, let exit { parts.append("exit \(exit)") }
        if let durationMs, long || durationMs >= 1000 { parts.append(Self.duration(durationMs)) }
        return parts.joined(separator: " · ")
    }

    /// The attention marker's text: `go test ./... exited 1 · 42 s`, `make finished · 3 min 2 s`.
    public var noticeMessage: String {
        let name = command.map { TerminalExcerpt.clip($0, 60) } ?? "Command"
        let outcome = switch exit {
        case 0?: "finished"
        case let code?: "exited \(code)"
        case nil: "finished"
        }
        return ([ "\(name) \(outcome)" ] + (durationMs.map { [Self.duration($0)] } ?? [])).joined(separator: " · ")
    }

    /// `0.4 s`, `42 s`, `3 min 2 s`, `1 h 5 min`.
    public static func duration(_ ms: Int) -> String {
        if ms < 10_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    /// As the API reports it (`agent.list`, `object.get` `lastCommand`).
    public func json(finishedAt: Date? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let command { fields["command"] = .string(command) }
        fields["exit"] = exit.map { .number(Double($0)) } ?? .null
        if let durationMs { fields["durationMs"] = .number(Double(durationMs)) }
        if let finishedAt { fields["finishedAt"] = .string(finishedAt.formatted(.iso8601)) }
        return .object(fields)
    }
}

/// Which command a terminal is running, from what its shell tells the terminal: Ghostty's shell
/// integration titles the terminal with the command line when it starts (preexec) and with the
/// directory at each prompt. A prompt framework may title it too while it draws the prompt, and
/// the program may retitle it while it runs; so the command is the first title that arrives well
/// after a prompt was drawn (the user pressed Return) and isn't one of that prompt's titles.
public struct TerminalCommandTracker: Sendable {
    /// Titles within this long after a prompt belong to the prompt.
    public static let promptWindow: TimeInterval = 0.3

    private var promptAt: Date?
    private var promptTitles: Set<String> = []
    private var command: String?
    private var program: String?

    public init() {}

    /// The shell drew a prompt: it reported its directory (OSC 7), or a command finished.
    public mutating func prompt(at date: Date) {
        if promptAt.map({ date.timeIntervalSince($0) > Self.promptWindow }) ?? true { promptTitles = [] }
        promptAt = date
    }

    /// The terminal's title changed. `promptTitle`: the title the integration gives a prompt in
    /// the directory the shell reported (`~/src/app`).
    public mutating func title(_ title: String, at date: Date, promptTitle: String?) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        if let promptAt, date.timeIntervalSince(promptAt) <= Self.promptWindow {
            promptTitles.insert(title)
            return
        }
        guard command == nil, title != promptTitle, !promptTitles.contains(title) else { return }
        command = title
    }

    /// The program seen running in the foreground (`TerminalName.program`), for a command whose
    /// title never came (the user turned the integration's `title` feature off).
    public mutating func running(program: String?) {
        if let program { self.program = program }
    }

    /// A command finished; the tracker starts over for the next one.
    public mutating func finished(exit: Int?, durationNanos: UInt64, at date: Date) -> TerminalCommand {
        let finished = TerminalCommand(command: command ?? program, exit: exit, durationMs: Int(durationNanos / 1_000_000))
        command = nil
        program = nil
        prompt(at: date)
        return finished
    }

    /// The title Ghostty's integration gives a prompt in `cwd`: zsh's `%~`, the home directory as `~`.
    public static func promptTitle(cwd: String?, home: String) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }
}

/// Terminal text as mentions and `agent.read` hand it to an agent.
public enum TerminalExcerpt {
    /// Lines of terminal text: trailing blanks trimmed off each line (terminals pad rows), blank
    /// lines at either end dropped.
    public static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
    }

    /// `lines` whole when they fit in `head + tail` lines (one more would only replace the
    /// marker), else the first `head`, a line saying how many were left out, and the last `tail`:
    /// a test run's failures are at its end, what it ran at its start.
    public static func trim(_ lines: [String], head: Int, tail: Int) -> [String] {
        guard lines.count > head + tail + 1 else { return lines }
        let omitted = lines.count - head - tail
        return Array(lines.prefix(head)) + ["… \(omitted) lines omitted …"] + Array(lines.suffix(tail))
    }

    /// The rows around row `index` of `rows` (a terminal's screen): up to `before` rows above and
    /// `after` below, blank rows at either end dropped, the clicked row marked `>` and the others
    /// indented to match.
    public static func around(_ rows: [String], index: Int, before: Int, after: Int) -> [String] {
        guard rows.indices.contains(index) else { return [] }
        let trimmed = rows.map { String($0.reversed().drop { $0 == " " }.reversed()) }
        var from = max(0, index - before), to = min(trimmed.count - 1, index + after)
        while from < index, trimmed[from].isEmpty { from += 1 }
        while to > index, trimmed[to].isEmpty { to -= 1 }
        return (from...to).map { ($0 == index ? "> " : "  ") + trimmed[$0] }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

/// A command's block on a terminal's screen, as Ghostty's shell integration marks it: the
/// command's output and the prompt row just above it.
public enum TerminalBlocks {
    /// How many rows `text` covers in a terminal `columns` wide (each line at least one row, a
    /// long one wrapped).
    public static func rows(of text: String, columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let width = line.reduce(0) { $0 + TerminalStyledTail.cellWidth($1) }
            return total + max(1, (width + columns - 1) / columns)
        }
    }

    /// The most rows a prompt takes between the last command's output and the cursor (a
    /// two-line prompt, a blank line before it).
    public static let promptRows = 4

    /// `output` without what precedes its command's own line. A block Ghostty found no prompt
    /// above (the first command after Canvas reattached to the session: the prompt it ran from
    /// came back as plain text, without its mark) starts at the top of the scrollback, so the
    /// command's line, `❯ go test ./...`, is inside it: its output starts after that line.
    public static func output(_ output: String, after command: String?) -> String {
        guard let command = command?.trimmingCharacters(in: .whitespaces), !command.isEmpty else { return output }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let line = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(command) }) else { return output }
        return lines[(line + 1)...].joined(separator: "\n")
    }

    /// What a block's output ending on screen row `outputEnd` ran: the shell's `last` command
    /// when this is its block (the shell is back at its prompt, `cursorRow` just below the output,
    /// and the prompt row above the output ends with that command), else just the command line
    /// shown in `promptRow`, without exit status or duration.
    public static func command(promptRow: String?, outputEnd: Int, cursorRow: Int?, atPrompt: Bool, last: TerminalCommand?) -> TerminalCommand? {
        let shown = promptRow.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        if let last, atPrompt, let cursorRow, cursorRow > outputEnd, cursorRow - outputEnd <= promptRows {
            let matches = last.command.map { command in shown.map { $0.hasSuffix(command) } ?? true } ?? true
            if matches {
                var block = last
                if block.command == nil { block.command = shown }
                return block
            }
        }
        return shown.map { TerminalCommand(command: $0) }
    }
}

/// Where the shell integration tiles load comes from (docs/contracts.md "Terminal tile
/// environment"): Ghostty's own `shell-integration-features` stay Ghostty's (`GHOSTTY_SHELL_FEATURES`).
public enum TerminalShellIntegration {
    /// The directory holding Ghostty's `zsh/` and `bash/` integration for tiles to load, from the
    /// user's `shell-integration` setting: `none` turns it off, like in Ghostty; anything else
    /// (`detect`, a shell's name, unset) loads it. Nil when off or not shipped.
    public static func directory(setting: String?, resources: URL?, isDirectory: (String) -> Bool) -> String? {
        guard setting?.trimmingCharacters(in: .whitespaces) != "none", let resources else { return nil }
        let directory = resources.appendingPathComponent("shell-integration").path
        return isDirectory(directory) ? directory : nil
    }
}

/// A pytest node id in test output (`tests/test_cli.py::test_help`,
/// `tests/test_cli.py::TestGroup::test_help[param-1]`): the file and the names in it.
public enum PytestNode {
    /// The line of the last name's `def` (or `class`), inside the classes the names before it
    /// open, by indentation; nil when the file has no such definition.
    public static func line(of names: [String], in source: String) -> Int? {
        guard !names.isEmpty else { return nil }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        /// Only definitions indented deeper than this belong to the class found so far.
        var outer = -1
        var found: Int?
        for (position, name) in names.enumerated() {
            let last = position == names.count - 1
            found = nil
            while index < lines.count {
                let line = lines[index]
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                let body = line.dropFirst(indent)
                index += 1
                if !body.isEmpty, indent <= outer, !body.hasPrefix("#"), !body.hasPrefix(")"), outer >= 0 { return nil }
                // The first name is the module's own; the next ones are members of the class before.
                guard position == 0 ? indent == 0 : indent > outer else { continue }
                let keywords = last ? ["def ", "async def ", "class "] : ["class "]
                guard let keyword = keywords.first(where: { body.hasPrefix($0) }) else { continue }
                let rest = body.dropFirst(keyword.count)
                guard rest.hasPrefix(name), let next = rest.dropFirst(name.count).first, next == "(" || next == ":" else { continue }
                found = index
                outer = indent
                break
            }
            if found == nil { return nil }
        }
        return found
    }
}

/// What a terminal tile knows about itself now (`agent.list`, `agent.read`, `object.get`).
public struct TerminalStatus: Sendable {
    /// The title the program set (OSC 0/2).
    public var title: String?
    /// What runs in the foreground (`TerminalName.program`); nil at the prompt.
    public var program: String?
    /// The last command the shell finished, and when.
    public var lastCommand: (command: TerminalCommand, finishedAt: Date)?

    public init(title: String? = nil, program: String? = nil, lastCommand: (command: TerminalCommand, finishedAt: Date)? = nil) {
        self.title = title
        self.program = program
        self.lastCommand = lastCommand
    }
}
