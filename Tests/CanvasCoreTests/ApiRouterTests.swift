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
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"],"timeoutMs":30}}"#)
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"]?["code"] == .string("timeout"))
    }

    @Test func waitFailsWhenTheTerminalCloses() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"]}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"))
        try board.delete(tile)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["error"]?["code"] == .string("not_found"))
    }

    @Test func terminalsWithoutAReportingAgentAreListedAndCantBeWaitedOn() async throws {
        let shell = terminal()
        let omp = terminal()
        try board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        let agents = try await call(client, "agent.list", [:])["result"]?["agents"]?.array ?? []
        let byTile = Dictionary(uniqueKeysWithValues: agents.compactMap { entry in entry["tile"]?.string.map { ($0, entry) } })
        #expect(Set(byTile.keys) == [shell, omp], "every terminal, reporting or not")
        #expect(byTile[shell]?["kind"] == .string("unknown"))
        #expect(byTile[shell]?["lifecycle"]?["state"] == .string("unknown"))
        #expect(byTile[omp]?["kind"] == .string("omp"))

        // Prompting works; the reply says a wait can't follow it, and a wait fails at once.
        let prompted = try await call(client, "agent.prompt", ["target": .string(shell), "text": "make test"])
        #expect(prompted["result"]?["waitable"] == .bool(false))
        let waited = try await call(client, "agent.wait", ["target": .string(shell), "timeoutMs": 60000])
        #expect(waited["error"]?["code"] == .string("unavailable"))
        #expect(waited["error"]?["message"]?.string?.contains("reports no agent lifecycle") == true)
        // Asking for `unknown` itself is answered.
        let unknown = try await call(client, "agent.wait", ["target": .string(shell), "until": ["unknown"]])
        #expect(unknown["result"]?["agent"]?["tile"] == .string(shell))
    }

    @Test func aWaitOnAnAgentThatExitsFailsInsteadOfHanging() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"))
        try board.releaseAgent(tile: tile)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["error"]?["code"] == .string("unavailable"))
    }

    @Test func promptSaysItCanBeWaitedOnForAnAgentThatReports() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        let prompted = try #require(try await call(client, "agent.prompt", ["target": .string(tile), "text": "go"])["result"])
        #expect(prompted["waitable"] == .bool(true))
        #expect(prompted["submittedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) } != nil)
    }

    /// The window's state with `target` as the terminal the tray shows.
    func showTray(to target: ObjectID?) {
        router.viewState = { _ in
            ViewState(viewport: Viewport(rect: Frame(x: 0, y: 0, w: 1000, h: 800), zoom: 1), promptTarget: target, focused: nil, selection: [], enteredGroup: nil, visible: true)
        }
    }

    @Test func onlyTheTerminalTheTrayShowsDrainsIt() async throws {
        let shown = terminal()
        let other = terminal()
        _ = try board.update(other, props: .object(["name": "fees"]))
        showTray(to: shown)
        try board.stage(.terminal(object: other, text: "npm test"))
        try board.stage(.object(shown))
        let client = try connect()

        let held = try #require(try await call(client, "tray.drain", ["caller": .string(other)])["result"])
        #expect(held["mentions"] == .array([]))
        #expect(held["context"] == .string(""))
        #expect(held["held"] == .number(2))
        #expect(held["target"] == .string(shown))
        #expect(board.tray.count == 2, "another terminal's prompt leaves the tray as it is")

        let peeked = try #require(try await call(client, "tray.drain", ["caller": .string(shown), "peek": .bool(true)])["result"])
        let context = try #require(peeked["context"]?.string)
        #expect(context.contains("[1] terminal tile \(other) \"fees\""), "another terminal is named")
        #expect(context.contains("[2] terminal \(shown) \"terminal\" (your terminal)"))
        #expect(board.tray.count == 2)

        // A script (no caller) drains whatever the tray shows.
        let drained = try #require(try await call(client, "tray.drain", [:])["result"])
        #expect(drained["mentions"]?.array?.count == 2)
        #expect(board.tray.isEmpty)
    }

    @Test func withNoTargetShownEveryCallerTerminalIsHeldBack() async throws {
        let a = terminal()
        _ = terminal()
        showTray(to: nil)
        try board.stage(.object(a))
        let client = try connect()
        let held = try #require(try await call(client, "tray.drain", ["caller": .string(a)])["result"])
        #expect(held["held"] == .number(1))
        #expect(held["target"] == nil)
        #expect(board.tray.count == 1)
    }

    @Test func arrowsReportTheBoundsOfTheirRouteNotAZeroSizePoint() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 400, y: 200, w: 100, h: 100))
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id)).props)
        #expect(arrow.frame.w == 0 && arrow.frame.h == 0, "the stored frame of a bound arrow is a placeholder")
        let route = try #require(board.geometry.routes()[arrow.id])
        let xs = route.map { Double($0.x) }, ys = route.map { Double($0.y) }
        let expected = Frame(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
        #expect(expected.w > 200 && expected.h > 100)
        let client = try connect()

        let objects = try await call(client, "board.get", [:])["result"]?["objects"]?.array ?? []
        let listed = try #require(objects.first { $0["id"] == .string(arrow.id) })
        #expect(try listed["frame"]?.decode(Frame.self) == expected)
        let got = try await call(client, "object.get", ["id": .string(arrow.id)])
        #expect(try got["result"]?["object"]?["frame"]?.decode(Frame.self) == expected)
        let history = try await call(client, "board.history", [:])["result"]?["entries"]?.array ?? []
        let created = history.compactMap { $0["summary"]?.string }.first { $0.hasPrefix("created arrow") }
        #expect(created?.hasSuffix(String(format: "at (%.0f, %.0f) %.0f×%.0f", expected.x, expected.y, expected.w, expected.h)) == true)

        // With a window, what is drawn (the app's routed line) is what is reported.
        board.arrowPath = { id in id == arrow.id ? [CGPoint(x: 110, y: 50), CGPoint(x: 250, y: 50), CGPoint(x: 250, y: 240), CGPoint(x: 390, y: 240)] : nil }
        let drawn = try await call(client, "object.get", ["id": .string(arrow.id)])
        #expect(try drawn["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 110, y: 50, w: 280, h: 190))
    }

    @Test func promptFailsWhenTheSurfaceIsNotAttached() async throws {
        let tile = terminal()
        router.submitToTerminal = { _, _, _ in false }
        let client = try connect()
        client.send(#"{"id":"p","method":"agent.prompt","params":{"target":"\#(tile)","text":"hi"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unavailable"))
    }

    @Test func boardGetSummarizesAFollowTilesHistoryAndObjectGetHasItWhole() async throws {
        let tile = terminal()
        // Follow shows only files that exist in the project.
        let source = dir.appendingPathComponent("root/src/a.ts")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
        for line in [10, 40, 90] {
            try board.follow(tile: tile, path: "src/a.ts", range: LineRange(start: line, end: line + 5), action: "read")
        }
        let follow = try #require(board.objects.values.first { $0.props["followOf"]?.string == tile })
        let client = try connect()
        client.send(#"{"id":"g","method":"board.get","params":{"board":"\#(board.id)"}}"#)
        let objects = try await client.next()["result"]?["objects"]?.array ?? []
        let listed = try #require(objects.first { $0["id"] == .string(follow.id) })
        #expect(listed["props"]?["history"]?.string?.contains("3") == true, "history is a short summary: \(listed["props"]?["history"] ?? .null)")
        #expect(listed["props"]?["range"]?["start"] == .number(90), "what the tile shows now stays whole")
        client.send(#"{"id":"o","method":"object.get","params":{"id":"\#(follow.id)"}}"#)
        #expect(try await client.next()["result"]?["object"]?["props"]?["history"]?.array?.count == 3)
    }

    @Test func boardOpenOpensADirectoryOnceAndRejectsBadRoots() async throws {
        let second = dir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var opened: [(String, Bool)] = []
        router.openBoard = { [unowned self] root, select in
            opened.append((root.path, select))
            return registry.open(root: root)
        }
        let client = try connect()
        client.send(#"{"id":"a","method":"board.open","params":{"root":"\#(second.path)"}}"#)
        let first = try await client.next()
        let id = try #require(first["result"]?["board"]?.string)
        #expect(id != board.id)
        #expect(registry.boards[id]?.root.path == second.path)
        // Opening it again (asking for its tab) is the same board.
        client.send(#"{"id":"b","method":"board.open","params":{"root":"\#(second.path)/","select":true}}"#)
        #expect(try await client.next()["result"]?["board"]?.string == id)
        #expect(opened.map(\.1) == [false, true])

        client.send(#"{"id":"c","method":"board.open","params":{"root":"relative/dir"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("invalid_params"))
        client.send(#"{"id":"d","method":"board.open","params":{"root":"\#(dir.path)/missing"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))
        #expect(opened.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aSubscriberThatStopsReadingDoesNotStallTheBoardOrOtherClients() async throws {
        let stalled = try connect()
        stalled.send(#"{"id":"s","method":"events.subscribe","params":{}}"#)
        #expect(try await stalled.next()["ok"] == .bool(true))
        // It never reads again, while the board emits far more than a socket buffer holds: the
        // broadcasts run on the main actor, which a blocking write would freeze for good.
        let text = String(repeating: "x", count: 4000)
        for index in 0..<400 { board.create(type: .note, props: .object(["markdown": .string("\(index) \(text)")])) }
        let other = try connect()
        other.send(#"{"id":"p","method":"system.ping","params":{}}"#)
        #expect(try await other.next()["id"] == .string("p"))
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
        let context = await board.drain().context
        #expect(context.contains("encloses \([a.id, b.id].sorted().joined(separator: ", "))"))
        #expect(context.contains("inner arrow \(a.id) → \(b.id) (calls)"))
        #expect(context.contains("arrow → \(outside.id) (hypothesis_about)"))
    }

    /// One request on `client`; the whole reply.
    func call(_ client: LineClient, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    @Test func deletingATerminalThroughTheApiEndsItsSessionUnlessTheBatchFails() async throws {
        var ended: [ObjectID] = []
        registry.onTerminalsEnded = { _, ids in ended += ids }
        let client = try connect()

        let deleted = terminal()
        #expect(try await call(client, "object.delete", ["id": .string(deleted)])["ok"] == .bool(true))
        #expect(ended == [deleted])
        // ⌘Z brings the tile back (it starts a new session); nothing more ends.
        #expect(board.undo())
        #expect(board.objects[deleted]?.type == .terminal)
        #expect(ended == [deleted])

        // A batch that fails puts its deleted terminal back: its session must survive.
        let kept = terminal()
        let failed = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(kept)])]),
            .object(["method": "object.update", "params": .object(["id": "obj_missing", "props": .object([:])])]),
        ])])
        #expect(failed["ok"] == .bool(false))
        #expect(board.objects[kept] != nil)
        #expect(ended == [deleted])

        // One that succeeds ends every terminal it deleted, once it has committed.
        let other = terminal()
        let batch = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(kept)])]),
            .object(["method": "object.delete", "params": .object(["id": .string(other)])]),
        ])])
        #expect(batch["ok"] == .bool(true))
        #expect(ended == [deleted, kept, other])
    }

    @Test func anAgentsNewMarkerClearsItsMarkersFromEarlierTurnsOnly() async throws {
        let agent = terminal(), other = terminal()
        let a = board.create(type: .note, props: .object(["markdown": .string("a")]))
        let b = board.create(type: .note, props: .object(["markdown": .string("b")]))
        let c = board.create(type: .note, props: .object(["markdown": .string("c")]))
        let d = board.create(type: .note, props: .object(["markdown": .string("d")]))
        let client = try connect()
        func raise(_ id: ObjectID, by caller: ObjectID?) async throws -> JSONValue {
            var params: [String: JSONValue] = ["id": .string(id), "message": .string("look")]
            if let caller { params["caller"] = .string(caller) }
            let reply = try await call(client, "view.attention", params)
            #expect(reply["result"]?["active"] == .bool(true), "\(reply)")
            return reply["result"] ?? .null
        }
        var seq = 0
        func report(_ tile: ObjectID, _ state: LifecycleState) throws {
            seq += 1
            try board.reportLifecycle(tile: tile, kind: "omp", state: state, message: nil, seq: seq, source: "canvas-omp")
        }

        try report(agent, .working)
        _ = try await raise(a.id, by: agent)
        _ = try await raise(b.id, by: agent)
        #expect(Set(board.attention.keys) == [a.id, b.id], "one answer may point at several things")
        try report(other, .working)
        _ = try await raise(c.id, by: other)
        _ = try await raise(d.id, by: nil)

        // Repeated working reports, and an approval answered (blocked → working), continue the turn.
        try report(agent, .working)
        #expect(try await raise(a.id, by: agent)["cleared"] == nil)
        try report(agent, .blocked)
        try report(agent, .working)
        #expect(try await raise(b.id, by: agent)["cleared"] == nil, "markers from before the approval belong to the same answer")
        #expect(Set(board.attention.keys) == [a.id, b.id, c.id, d.id])

        // The user's next prompt: idle, then working again.
        try report(agent, .idle)
        try report(agent, .working)
        try report(other, .idle)
        try report(other, .working)
        let next = try await raise(d.id, by: agent)
        #expect(next["cleared"] == .array([a.id, b.id].sorted().map(JSONValue.string)))
        #expect(Set(board.attention.keys) == [c.id, d.id], "another agent's marker and the new one stay")
        #expect(board.attention[d.id]?.raisedBy == agent, "raising on a marked object takes it over")

        // Clearing and deleting remove markers; the user seeing an object is the board's clear.
        #expect(try await call(client, "view.attention", ["id": .string(c.id), "clear": .bool(true)])["result"]?["active"] == .bool(false))
        try board.delete(d.id)
        #expect(board.attention.isEmpty)
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

    /// Next response line, failing after `timeout` seconds (the timeout only detects hangs).
    func next(timeout: Double = 30) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await nextLine(timeout: timeout))
    }

    /// Next response line as text, for protocols that answer some commands outside JSON.
    func nextText(timeout: Double = 30) async throws -> String {
        String(decoding: try await nextLine(timeout: timeout), as: UTF8.self)
    }

    /// The blocking read runs on a GCD thread, never on Swift's cooperative pool: suites run in
    /// parallel, and a pool full of threads parked in poll() starves the server tasks that would
    /// answer them.
    private func nextLine(timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try self.readLine(timeout: timeout) })
            }
        }
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
