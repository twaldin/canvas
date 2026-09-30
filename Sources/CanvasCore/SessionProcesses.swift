import Darwin

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

    /// Whether `argv0` runs a shell (a login shell's `-zsh` too). Shells only wrap what they run
    /// (`bash -c 'pnpm dev'`, `login`): what they run is named instead.
    public static func isShell(_ argv0: String) -> Bool {
        let name = argv0.split(separator: "/").last.map(String.init) ?? argv0
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "login"]

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
            process.pid != foreground && !(process.argv.first.map(Self.isShell) ?? true)
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

    /// The current directory of process `pid` (libproc; the path as the kernel names it, symlinks
    /// resolved: `/private/tmp/…`); nil when the process is gone or not the user's.
    public static func directory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// The close sheet's text for these sessions (nil: not known, the shell not found yet):
    /// "Closing it ends omp and 1 background process (next dev)."
    public static func closingText(_ sessions: [SessionProcesses?]) -> String {
        let one = sessions.count == 1
        let tally = Tally(sessions)
        var parts = tally.programs
        if tally.idle > 0 { parts.append(one ? "its shell" : tally.idle == 1 ? "1 idle shell" : "\(tally.idle) idle shells") }
        if let background = tally.backgroundPart { parts.append(background) }
        let subject = one ? "it" : "them"
        if tally.unknown > 0 { parts.append(one ? "anything running in it" : "anything running in the other\(tally.unknown == 1 ? "" : "s")") }
        if one, tally.idle == 1, tally.background.isEmpty { return "Closing \(subject) ends its shell; nothing else is running in it." }
        return "Closing \(subject) ends \(list(parts))."
    }

    /// What keeps running when a board's tab or window closes with these sessions:
    /// "omp, codex and 1 idle shell keep running", "omp keeps running".
    public static func keepRunningText(_ sessions: [SessionProcesses?]) -> String {
        let tally = Tally(sessions)
        var parts = tally.programs
        if tally.idle > 0 { parts.append(tally.idle == 1 ? "1 idle shell" : "\(tally.idle) idle shells") }
        if let background = tally.backgroundPart { parts.append(background) }
        if tally.unknown > 0 { parts.append(tally.unknown == 1 ? "1 terminal" : "\(tally.unknown) terminals") }
        let count = tally.programs.count + tally.idle + tally.background.count + tally.unknown
        return "\(list(parts)) \(count == 1 ? "keeps" : "keep") running"
    }

    /// The sessions' foreground programs, idle shells, background processes, and unknowns.
    private struct Tally {
        var programs: [String] = []
        var idle = 0, unknown = 0
        var background: [String] = []

        init(_ sessions: [SessionProcesses?]) {
            for session in sessions {
                guard let session else {
                    unknown += 1
                    continue
                }
                if let program = session.program { programs.append(program) } else { idle += 1 }
                background += session.background
            }
        }

        /// "2 background processes (next dev, vite)", the first three names.
        var backgroundPart: String? {
            guard !background.isEmpty else { return nil }
            var names: [String] = []
            for name in background where !names.contains(name) { names.append(name) }
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
            return "\(background.count) background process\(background.count == 1 ? "" : "es") (\(shown))"
        }
    }

    private static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return "nothing"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
