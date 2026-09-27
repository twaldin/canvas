import CanvasCore
import Darwin
import Foundation

/// What runs in the foreground of a terminal tile's zmx session, read from the process table
/// (libproc, sysctl): no process is started once the session's shell is known.
enum ForegroundProgram {
    enum State: Equatable {
        /// The session's shell is gone (the session ended or was replaced).
        case gone
        /// The shell's prompt: nothing runs in the foreground.
        case prompt
        /// The foreground job's argv.
        case running([String])
    }

    /// The pid of the session's shell (`zmx list`'s `pid=`); nil when zmx or the session is
    /// missing. Blocks until zmx exits: call it off the main actor.
    nonisolated static func shellPid(session: String) -> pid_t? {
        guard let zmx = AppPaths.zmx else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard fields.first?.drop(while: { $0 == " " || $0 == "*" }) == "name=\(session)" else { continue }
            return fields.lazy.compactMap { $0.hasPrefix("pid=") ? pid_t($0.dropFirst(4)) : nil }.first
        }
        return nil
    }

    /// The foreground job of the terminal `shell` runs in: the leader of the terminal's
    /// foreground process group. While that is the shell itself, the command a `-c` shell runs
    /// without job control (a tile's `zsh -l -c '<command>; exec zsh -l'`: its child in the same
    /// group), else its prompt (an interactive shell's own children, like a prompt's `git`
    /// status, aren't jobs). A few syscalls; fine on the main actor.
    static func state(shell: pid_t) -> State {
        guard let info = bsdInfo(shell) else { return .gone }
        let group = pid_t(bitPattern: info.e_tpgid)
        guard group > 0 else { return .prompt }
        var leader = group
        if leader == shell {
            guard arguments(shell)?.contains("-c") == true else { return .prompt }
            let child = members(of: group).filter { $0 != shell }.compactMap { pid in bsdInfo(pid).map { (pid, $0) } }
                .filter { $0.1.pbi_ppid == UInt32(shell) }
                .max { ($0.1.pbi_start_tvsec, $0.1.pbi_start_tvusec) < ($1.1.pbi_start_tvsec, $1.1.pbi_start_tvusec) }
            guard let child else { return .prompt }
            leader = child.0
        } else if bsdInfo(leader) == nil {
            // The group's leader exited (the first stage of a pipeline): its oldest member.
            guard let member = members(of: group).min() else { return .prompt }
            leader = member
        }
        return arguments(leader).map(State.running) ?? .prompt
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func members(of group: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return bytes > 0 ? Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }) : []
    }

    /// `KERN_PROCARGS2`: argc, the executable path, padding, then argc NUL-terminated arguments.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // executable path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var argv: [String] = []
        while argv.count < argc, index < size {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            argv.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return argv.isEmpty ? nil : argv
    }
}
