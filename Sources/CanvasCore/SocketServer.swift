import Darwin
import Foundation

/// Newline-delimited JSON over a Unix domain socket (mode 0600). One request per line;
/// the handler returns a response line, or nil for connections turned into event streams.
public final class SocketServer: @unchecked Sendable {
    public final class Connection: @unchecked Sendable {
        public let fd: Int32
        fileprivate var buffer = Data()
        fileprivate var source: DispatchSourceRead?
        /// Requests in arrival order; one consumer task handles them sequentially so pipelined
        /// calls (update then get) are answered in order.
        fileprivate let requests: AsyncStream<JSONValue>.Continuation
        fileprivate let stream: AsyncStream<JSONValue>
        public fileprivate(set) var isOpen = true
        private let writeLock = NSLock()

        init(fd: Int32) {
            self.fd = fd
            (stream, requests) = AsyncStream.makeStream(of: JSONValue.self)
        }

        /// Stops further writes; the fd itself is closed by the read source's cancel handler.
        fileprivate func markClosed() -> Bool {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard isOpen else { return false }
            isOpen = false
            return true
        }

        /// Writes one JSON line. Safe from any thread; returns false once the peer is gone.
        @discardableResult
        public func send(_ value: JSONValue) -> Bool {
            guard var data = try? JSONEncoder().encode(value) else { return false }
            data.append(0x0A)
            writeLock.lock()
            defer { writeLock.unlock() }
            guard isOpen else { return false }
            return data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
        }
    }

    public typealias Handler = @Sendable (_ request: JSONValue, _ connection: Connection) async -> JSONValue?

    public let path: String
    private let queue = DispatchQueue(label: "canvas.socket.\(UUID().uuidString)")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    /// Reused for every read; only touched on `queue`.
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private let handler: Handler

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for connection in connections.values { closeConnection(connection) }
            connections.removeAll()
            listenFD = -1
        }
        unlink(path)
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, connection] in self?.read(connection) }
        source.setCancelHandler { close(fd) }
        connection.source = source
        connections[fd] = connection
        let handler = self.handler
        Task {
            for await request in connection.stream {
                if let response = await handler(request, connection) { connection.send(response) }
            }
        }
        source.resume()
    }

    private func read(_ connection: Connection) {
        let count = readBuffer.withUnsafeMutableBytes { Darwin.read(connection.fd, $0.baseAddress, $0.count) }
        guard count > 0 else {
            closeConnection(connection)
            connections.removeValue(forKey: connection.fd)
            return
        }
        connection.buffer.append(contentsOf: readBuffer[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            let request: JSONValue
            do {
                request = try JSONDecoder().decode(JSONValue.self, from: line)
            } catch {
                connection.send(.object(["ok": .bool(false), "error": .object(["code": .string("invalid_params"), "message": .string("malformed JSON line")])]))
                continue
            }
            connection.requests.yield(request)
        }
    }

    private func closeConnection(_ connection: Connection) {
        guard connection.markClosed() else { return }
        connection.requests.finish()
        connection.source?.cancel()
    }
}
