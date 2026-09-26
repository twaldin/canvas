import Darwin
import Foundation
import Testing
import CanvasCore

/// Drives the real SocketServer + ApiRouter over a Unix socket, the way clients do.
@MainActor
final class ApiRouterTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    var submitted: [String] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        router.submitToTerminal = { [unowned self] _, _, text in
            submitted.append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func connect() throws -> LineClient { try LineClient(path: dir.appendingPathComponent("s").path) }

    func terminal() -> ObjectID {
        board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
    }

    @Test func waitAfterPromptIgnoresThePrePromptIdle() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()

        client.send(#"{"id":"p","method":"agent.prompt","params":{"target":"\#(tile)","text":"explain the repo"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(submitted == ["explain the repo"])

        // The agent is still idle from before the prompt; the wait must not resolve from that.
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        client.send(#"{"id":"ping1","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping1"))

        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 2, source: "canvas-omp")
        client.send(#"{"id":"ping2","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping2"))

        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 3, source: "canvas-omp")
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"), "idle after work, unseen, is done")
    }

    @Test func waitWithoutPromptAnswersFromCurrentState() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .blocked, message: "approve bash", seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        let reply = try await client.next()
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("blocked"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["message"] == .string("approve bash"))
    }

    @Test func waitTimesOutWithTimeoutCode() async throws {
        let tile = terminal()
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"],"timeoutMs":30}}"#)
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"]?["code"] == .string("timeout"))
    }

    @Test func waitFailsWhenTheTerminalCloses() async throws {
        let tile = terminal()
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"]}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"))
        try board.delete(tile)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["error"]?["code"] == .string("not_found"))
    }

    @Test func promptFailsWhenTheSurfaceIsNotAttached() async throws {
        let tile = terminal()
        router.submitToTerminal = { _, _, _ in false }
        let client = try connect()
        client.send(#"{"id":"p","method":"agent.prompt","params":{"target":"\#(tile)","text":"hi"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unavailable"))
    }

    @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("a")]))
        let client = try connect()
        var batch = ""
        for index in 0..<20 {
            batch += #"{"id":"u\#(index)","method":"object.update","params":{"id":"\#(note.id)","props":{"markdown":"v\#(index)"}}}"# + "\n"
        }
        batch += #"{"id":"g","method":"object.get","params":{"id":"\#(note.id)"}}"# + "\n"
        client.sendRaw(batch)
        for index in 0..<20 {
            #expect(try await client.next()["id"] == .string("u\(index)"))
        }
        let get = try await client.next()
        #expect(get["id"] == .string("g"))
        #expect(get["result"]?["object"]?["props"]?["markdown"] == .string("v19"))
    }
}

/// Minimal blocking NDJSON client; reads happen off the main actor so the server can answer.
final class LineClient: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    deinit { close(fd) }

    func send(_ line: String) { sendRaw(line + "\n") }

    func sendRaw(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Next response line, failing after `timeout` seconds. Generous because every suite shares
    /// the main actor, and on a loaded machine the suites' setup (git lookups per board) can hold
    /// it for seconds; the timeout only detects hangs.
    func next(timeout: Double = 30) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await nextLine(timeout: timeout))
    }

    /// Next response line as text, for protocols that answer some commands outside JSON.
    func nextText(timeout: Double = 30) async throws -> String {
        String(decoding: try await nextLine(timeout: timeout), as: UTF8.self)
    }

    private func nextLine(timeout: Double) async throws -> Data {
        try await Task.detached { try self.readLine(timeout: timeout) }.value
    }

    private func readLine(timeout: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0, poll(&poller, 1, remaining) > 0 else { throw POSIXError(.ETIMEDOUT) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
