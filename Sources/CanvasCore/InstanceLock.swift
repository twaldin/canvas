import Darwin
import Foundation

/// One app instance per support directory: the first takes an exclusive `flock` on a file there
/// and holds it until it exits (the kernel drops it with the process, even after a crash). A second
/// instance on the same directory would take over its sockets, so it hands its work to the holder
/// instead (`forward`) and exits.
public struct InstanceLock {
    let fd: Int32

    /// Takes the lock at `path` and records this process's pid in the file; nil when another
    /// process (or another open of the file in this one) holds it.
    public static func acquire(at path: String) -> InstanceLock? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return InstanceLock(fd: fd)
    }

    /// The pid the holder recorded, if it has written one yet. Read it only while the lock is
    /// taken, and check the process before acting on it: between taking the lock and writing its
    /// own, a new holder leaves the previous one's pid there, which may have been reused since.
    public static func holder(at path: String) -> pid_t? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Asks the instance listening on `socket` to open `root`'s board and show it. The holder may
    /// still be starting, so a socket that isn't there yet, or not yet listening (a crashed
    /// instance's file), is retried until `timeout`; its reply may take until it has finished
    /// launching (opening its boards), up to `replyTimeout`.
    public static func forward(root: String, to socket: String, timeout: TimeInterval = 10, replyTimeout: TimeInterval = 30) throws -> JSONValue {
        let request: JSONValue = .object(["id": .number(1), "method": .string("board.open"), "params": .object(["root": .string(root), "select": .bool(true)])])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try send(request, to: socket, timeout: replyTimeout)
            } catch let error as POSIXError where [.ENOENT, .ECONNREFUSED].contains(error.code) && Date() < deadline {
                usleep(200_000)
            }
        }
    }

    /// One request line, one response line, blocking.
    static func send(_ request: JSONValue, to path: String, timeout: TimeInterval) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED) }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : .init(rawValue: errno) ?? .EIO) }
            response.append(contentsOf: chunk[..<count])
        }
        return try JSONDecoder().decode(JSONValue.self, from: response.prefix { $0 != 0x0A })
    }
}
