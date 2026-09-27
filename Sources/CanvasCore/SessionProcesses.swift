/// What runs in a terminal's session, for the close sheet to name what closing ends: the
/// foreground program (`omp`) and the processes the shell or that program started that keep
/// running beside it (a dev server an agent started: `next dev`).
public struct SessionProcesses: Equatable, Sendable {
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        public var argv: [String]

        public init(pid: Int32, parent: Int32, argv: [String]) {
            self.pid = pid
            self.parent = parent
            self.argv = argv
        }
    }

    public var shell: Int32
    /// The foreground job's leader; nil at the shell's prompt.
    public var foreground: Int32?
    /// Every descendant of the shell.
    public var processes: [Process]

    public init(shell: Int32, foreground: Int32?, processes: [Process]) {
        self.shell = shell
        self.foreground = foreground
        self.processes = processes
    }

    /// Shells only wrap what they run (`bash -c 'pnpm dev'`): what they run is named instead.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "login"]

    /// The foreground program's name (`TerminalName.program`); nil at the prompt.
    public var program: String? {
        foreground.flatMap { pid in processes.first { $0.pid == pid } }.flatMap { TerminalName.program(argv: $0.argv) }
    }

    /// The other processes by name, in start (pid) order: the topmost descendants of the shell
    /// that aren't the foreground program or a shell wrapping something (a server's own workers
    /// count with it: `pnpm exec next dev` and the node it starts are one).
    public var background: [String] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func named(_ process: Process) -> Bool {
            process.pid != foreground && !(process.argv.first.map { Self.shells.contains(Self.base($0)) } ?? true)
        }
        return processes.sorted { $0.pid < $1.pid }.filter { process in
            guard named(process) else { return false }
            var parent = byPid[process.parent]
            while let current = parent {
                if named(current) { return false }
                parent = byPid[current.parent]
            }
            return true
        }.compactMap { TerminalName.program(argv: $0.argv) }
    }

    /// Descendants of `root` in a process table of (pid, parent) pairs.
    public static func descendants(of root: Int32, in table: [(pid: Int32, parent: Int32)]) -> [(pid: Int32, parent: Int32)] {
        var children: [Int32: [Int32]] = [:]
        for entry in table where entry.pid != entry.parent { children[entry.parent, default: []].append(entry.pid) }
        var found: [(pid: Int32, parent: Int32)] = []
        var queue = [root]
        var seen: Set<Int32> = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where seen.insert(child).inserted {
                found.append((child, next))
                queue.append(child)
            }
        }
        return found
    }

    /// The close sheet's text for these sessions (nil: not known, the shell not found yet):
    /// "Closing it ends omp and 1 background process (next dev)."
    public static func closingText(_ sessions: [SessionProcesses?]) -> String {
        let one = sessions.count == 1
        var parts: [String] = []
        var idle = 0, unknown = 0
        var background: [String] = []
        for session in sessions {
            guard let session else {
                unknown += 1
                continue
            }
            if let program = session.program { parts.append(program) } else { idle += 1 }
            background += session.background
        }
        if idle > 0 { parts.append(one ? "its shell" : idle == 1 ? "1 idle shell" : "\(idle) idle shells") }
        if !background.isEmpty {
            var names: [String] = []
            for name in background where !names.contains(name) { names.append(name) }
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
            parts.append("\(background.count) background process\(background.count == 1 ? "" : "es") (\(shown))")
        }
        let subject = one ? "it" : "them"
        if unknown > 0 { parts.append(one ? "anything running in it" : "anything running in the other\(unknown == 1 ? "" : "s")") }
        if one, idle == 1, background.isEmpty { return "Closing \(subject) ends its shell; nothing else is running in it." }
        return "Closing \(subject) ends \(list(parts))."
    }

    private static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return "nothing"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    private static func base(_ word: String) -> String {
        let name = word.split(separator: "/").last.map(String.init) ?? word
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
