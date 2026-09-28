import Foundation
import Testing
import CanvasCore

/// An agent's lifecycle across a Canvas quit and relaunch: each launch is a new registry, router
/// and socket on the same board store, as the app sets them up; what an integration said while
/// Canvas was away waits in the spool (`AgentReportSpool`, written by extensions/agent-hooks/report.ts).
@MainActor
final class AgentRelaunchTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    var root: URL { dir.appendingPathComponent("root") }
    var spool: URL { dir.appendingPathComponent("agent-reports") }
    var servers: [SocketServer] = []

    @MainActor
    struct Launch {
        let registry: BoardRegistry
        let board: Board
        let socket: String

        func quit() {
            registry.store.save(board)
        }
    }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    func launch() throws -> Launch {
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60), agentReports: spool)
        let board = registry.open(root: root)
        let router = ApiRouter(registry: registry)
        let socket = dir.appendingPathComponent("s\(servers.count)").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        servers.append(server)
        return Launch(registry: registry, board: board, socket: socket)
    }

    /// A report the integration couldn't deliver, as report.ts spools it.
    func spooled(_ tile: ObjectID, seq: Int, method: String = "agent.report", _ params: [String: JSONValue]) throws {
        let folder = spool.appendingPathComponent(tile, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var params = params
        params["tile"] = .string(tile)
        let entry: JSONValue = .object(["seq": .number(Double(seq)), "method": .string(method), "params": .object(params)])
        try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("\(seq)-1-\(UUID().uuidString.prefix(8)).json"))
    }

    func spoolIsEmpty(_ tile: ObjectID) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent(tile).path)) ?? []).isEmpty
    }

    /// Waits (up to 3 s) for the replay that opening the board started.
    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func call(_ launch: Launch, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let client = try LineClient(path: launch.socket)
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    @Test func anAgentThatFinishedWhileCanvasWasAwayComesBackDoneWithItsAnswer() async throws {
        let before = try launch()
        let codex = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: 100, source: "canvas-codex")
        before.quit()

        // Codex worked on and finished while Canvas was closed; its hooks spooled every report.
        // One from before the last applied report (it timed out as Canvas quit) is stale.
        try spooled(codex, seq: 50, ["kind": "codex", "state": "idle", "source": "canvas-codex", "final": "an older answer"])
        try spooled(codex, seq: 150, ["kind": "codex", "state": "working", "source": "canvas-codex", "call": "f0c82fec96cbd7c6"])
        try spooled(codex, seq: 200, ["kind": "codex", "state": "idle", "source": "canvas-codex", "final": "No blocking findings in d93c070."])

        let after = try launch()
        func lifecycle() -> JSONValue? { after.board.objects[codex]?.props["lifecycle"] }
        try await eventually { lifecycle()?["state"] == .string("done") }
        #expect(lifecycle()?["seen"] == .bool(false), "unseen: the user hasn't read it")
        #expect(NeedsYouItem.all(after.board.objects, attention: after.board.attention).map(\.id) == [codex], "⌘J goes to it")
        let waited = try await call(after, "agent.wait", ["target": .string(codex), "timeoutMs": 2000])
        #expect(waited["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"), "\(waited)")
        let final = try await call(after, "agent.read", ["target": .string(codex), "final": .bool(true)])
        #expect(final["result"]?["text"] == .string("No blocking findings in d93c070."), "\(final)")
        try await eventually { spoolIsEmpty(codex) }
    }

    @Test func theLastAnswerOutlastsARelaunchUntilTheNextTurn() async throws {
        let before = try launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp", final: "Committed d327349.")
        before.board.markSeen(omp)
        before.quit()

        let after = try launch()
        let final = try await call(after, "agent.read", ["target": .string(omp), "final": .bool(true)])
        #expect(final["result"]?["text"] == .string("Committed d327349."), "\(final)")
        // A report older than one applied before the quit is stale after it too.
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 2, source: "canvas-omp")
        #expect(after.board.objects[omp]?.props["lifecycle"]?["state"] == .string("idle"))
        // The next turn clears it.
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp")
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 4, source: "canvas-omp")
        #expect(try await call(after, "agent.read", ["target": .string(omp), "final": .bool(true)])["error"]?["code"] == .string("unavailable"))
    }

    @Test func anAgentThatExitedWhileCanvasWasAwayComesBackReleased() async throws {
        let before = try launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 100, source: "canvas-omp")
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 200, source: "canvas-omp")
        before.quit()

        // A release older than the last report applied (a new session had started) is stale.
        try spooled(omp, seq: 150, method: "agent.release", ["kind": "omp", "source": "canvas-omp"])
        let stale = try launch()
        try await eventually { spoolIsEmpty(omp) }
        #expect(stale.board.objects[omp]?.props["lifecycle"]?["state"] == .string("done"))
        stale.quit()

        try spooled(omp, seq: 300, method: "agent.release", ["kind": "omp", "source": "canvas-omp"])
        let after = try launch()
        try await eventually { after.board.objects[omp]?.props["agent"] == nil }
        #expect(after.board.objects[omp]?.props["lifecycle"] == nil, "a plain shell again")
    }
}
