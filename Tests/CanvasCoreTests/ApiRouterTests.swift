import CoreGraphics
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

    @Test func shapeGraphDescribesEnclosureOverlapsAndArrows() async throws {
        let box = board.create(type: .shape, props: .object(["kind": .string("rect"), "text": .string("auth path?")]), frame: Frame(x: 0, y: 0, w: 1000, h: 800))
        let a = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 50, y: 50, w: 300, h: 200))
        let b = board.create(type: .code, props: .object(["path": .string("a.swift")]), frame: Frame(x: 500, y: 50, w: 300, h: 200))
        let outside = board.create(type: .note, props: .object([:]), frame: Frame(x: 2000, y: 0, w: 300, h: 200))
        let straddling = board.create(type: .note, props: .object([:]), frame: Frame(x: 900, y: 600, w: 300, h: 200))
        let inner = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id), relation: "calls").props)
        let scribble = board.create(type: .arrow, props: ArrowSpec(from: .point(CGPoint(x: 100, y: 500)), to: .object(b.id)).props)
        let out = board.create(type: .arrow, props: ArrowSpec(from: .object(box.id), to: .object(outside.id), relation: "hypothesis_about").props)
        // Leaves the box: not drawn inside it, so not part of its structure.
        _ = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(outside.id)).props)

        let client = try connect()
        client.send(#"{"id":"g","method":"object.get","params":{"id":"\#(box.id)","as":"graph"}}"#)
        let graph = try #require(try await client.next()["result"]?["graph"])
        #expect(graph["encloses"] == .array([a.id, b.id].sorted().map(JSONValue.string)))
        #expect(graph["overlaps"] == .array([.string(straddling.id)]))
        #expect(graph["arrowsOut"]?.array?.first?["to"] == .string(outside.id))
        #expect(graph["arrowsOut"]?.array?.first?["relation"] == .string("hypothesis_about"))
        let arrows = graph["arrows"]?.array ?? []
        #expect(arrows.compactMap { $0["arrow"]?.string } == [inner.id, scribble.id].sorted())
        let calls = arrows.first { $0["arrow"] == .string(inner.id) }
        #expect(calls?["from"]?["object"] == .string(a.id))
        #expect(calls?["to"]?["object"] == .string(b.id))
        #expect(calls?["relation"] == .string("calls"))

        client.send(#"{"id":"r","method":"object.get","params":{"id":"\#(out.id)","as":"graph"}}"#)
        let arrowGraph = try #require(try await client.next()["result"]?["graph"])
        #expect(arrowGraph["from"]?["object"] == .string(box.id))
        #expect(arrowGraph["to"]?["object"] == .string(outside.id))

        // The prompt context says the same thing in one line.
        try board.stage(.object(box.id))
        let context = board.drain().context
        #expect(context.contains("encloses \([a.id, b.id].sorted().joined(separator: ", "))"))
        #expect(context.contains("inner arrow \(a.id) → \(b.id) (calls)"))
        #expect(context.contains("arrow → \(outside.id) (hypothesis_about)"))
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

    /// Next response line, failing after `timeout` seconds.
    func next(timeout: Double = 5) async throws -> JSONValue {
        try await Task.detached { try self.readLine(timeout: timeout) }.value
    }

    private func readLine(timeout: Double) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return try JSONDecoder().decode(JSONValue.self, from: Data(line))
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
