import Foundation
import Testing
import CanvasCore

/// The cmux subset over a real Unix socket, framed the way omp's cmux socket client sends it.
@MainActor
final class CmuxRouterTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cx-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let board: Board
    var servers: [SocketServer] = []
    /// Commands that reached the WebKit side, with their surface.
    var performed: [(ObjectID, CmuxBrowserCommand)] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: dir.appendingPathComponent("root"))
    }

    deinit {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    func connect(password: String? = nil) throws -> LineClient {
        let router = CmuxRouter(registry: registry, password: password)
        router.perform = { [unowned self] _, object, command in
            performed.append((object.id, command))
            return .object(["value": .number(1)])
        }
        let path = dir.appendingPathComponent("c\(servers.count)").path
        let server = SocketServer(path: path, acceptsTextLines: true) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        servers.append(server)
        return try LineClient(path: path)
    }

    func terminal(at frame: Frame) -> CanvasObject {
        board.create(type: .terminal, props: .object([:]), frame: frame)
    }

    func browser() -> CanvasObject {
        board.create(type: .browser, props: .object(["url": .string("http://localhost:1/")]), frame: Frame(x: -2000, y: -2000, w: 400, h: 300))
    }

    @Test func openSplitPlacesTheBrowserBesideTheCallingTerminal() async throws {
        let caller = terminal(at: Frame(x: 100, y: 50, w: 820, h: 520))
        _ = board.create(type: .note, props: .object([:]), frame: Frame(x: 944, y: 50, w: 320, h: 200))
        let client = try connect()
        client.send(#"{"id":"o","method":"browser.open_split","params":{"url":"localhost:8000/form.html","focus":false,"workspace_id":"\#(board.id)","surface_id":"\#(caller.id)"}}"#)
        let reply = try await client.next()
        #expect(reply["id"] == .string("o"))
        let id = try #require(reply["result"]?["surface_id"]?.string)
        let tile = try board.object(id)
        #expect(tile.type == .browser)
        #expect(tile.createdBy == .agent(tile: caller.id))
        #expect(tile.props["url"] == .string("http://localhost:8000/form.html"), "bare host:port is loaded over http")
        #expect(reply["result"]?["url"] == .string("http://localhost:8000/form.html"))
        #expect(tile.frame.x == caller.frame.maxX + 24, "right of the caller")
        #expect(tile.frame.y == 50 + 200 + 24, "stacked below the note already beside the caller")
        #expect(reply["result"]?["workspace_id"] == .string(board.id))
    }

    @Test func openSplitWithoutACallerUsesTheWorkspaceViewport() async throws {
        board.viewportCenter = { (1000, 1000) }
        let client = try connect()
        client.send(#"{"id":1,"method":"browser.open_split","params":{"workspace_id":"\#(board.id)"}}"#)
        let reply = try await client.next()
        let tile = try board.object(try #require(reply["result"]?["surface_id"]?.string))
        #expect(tile.props["url"] == .string("about:blank"))
        #expect(tile.createdBy == .user)
        #expect(tile.frame.x + tile.frame.w / 2 == 1000)
        #expect(reply["result"]?["placement_strategy"] == .string("viewport"))
    }

    @Test func browserCommandsRunOnTheirSurfaceAndNameIt() async throws {
        let page = browser()
        let client = try connect()
        client.send(##"{"id":"w","method":"browser.wait","params":{"surface_id":"\##(page.id)","selector":"#done","timeout_ms":1500}}"##)
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(true))
        #expect(reply["result"]?["surface_id"] == .string(page.id), "omp rejects results for a different surface")
        #expect(performed.map(\.0) == [page.id])
        #expect(performed.map(\.1) == [.wait(.selector("#done"), timeoutMs: 1500)])

        client.send(#"{"id":"f","method":"browser.fill","params":{"surface_id":"\#(page.id)","selector":"@e4","text":""}}"#)
        #expect(try await client.next()["ok"] == .bool(true), "filling with empty text clears a field")
        #expect(performed.last?.1 == .fill(selector: "@e4", text: ""))
    }

    @Test func requestErrorsUseCmuxErrorShapeAndEchoTheId() async throws {
        let page = browser()
        let shell = terminal(at: Frame(x: 0, y: 0, w: 100, h: 100))
        let client = try connect()
        let cases: [(String, String)] = [
            (#"{"id":"a","method":"browser.tabs.new","params":{}}"#, "method_not_found"),
            (#"{"id":"b","method":"browser.click","params":{"surface_id":"obj_missing","selector":"a"}}"#, "not_found"),
            (#"{"id":"c","method":"browser.click","params":{"surface_id":"\#(shell.id)","selector":"a"}}"#, "invalid_params"),
            (#"{"id":"d","method":"browser.click","params":{"surface_id":"\#(page.id)"}}"#, "invalid_params"),
            (#"{"id":"e","method":"browser.wait","params":{"surface_id":"\#(page.id)","selector":"a","url_contains":"x"}}"#, "invalid_params"),
            (#"{"id":"f","method":"browser.wait","params":{"surface_id":"\#(page.id)","load_state":"networkidle"}}"#, "invalid_params"),
            (#"{"id":"g","method":"browser.navigate","params":{"surface_id":"\#(page.id)","url":"not a url"}}"#, "invalid_params"),
            (#"{"id":"h","method":"browser.scroll","params":{"surface_id":"\#(page.id)","dy":"down"}}"#, "invalid_params"),
            (#"{"id":"i","method":"surface.close","params":{"surface_id":"\#(shell.id)"}}"#, "invalid_params"),
            (#"{"id":"j","method":"browser.wait","params":{"surface_id":"obj_missing","selector":"a","timeout_ms":-1}}"#, "invalid_params"),
            (#"{"id":"k","method":"browser.snapshot","params":{"surface_id":"\#(page.id)","max_depth":-3}}"#, "invalid_params"),
        ]
        for (request, code) in cases {
            client.send(request)
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(false), "\(request)")
            #expect(reply["error"]?["code"] == .string(code), "\(request)")
            #expect(reply["error"]?["message"]?.string?.isEmpty == false)
            #expect(reply["id"] == (request.firstMatch(of: /"id":"(\w)"/).map { .string(String($0.1)) }))
        }
        #expect(performed.isEmpty, "invalid requests never reach a page")
        #expect(board.objects[shell.id] != nil, "the cmux socket never closes terminals")
    }

    @Test func hugeNumbersAreClampedNotFatal() async throws {
        let page = browser()
        let client = try connect()
        client.send(#"{"id":"w","method":"browser.wait","params":{"surface_id":"\#(page.id)","load_state":"complete","timeout_ms":1e100}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        client.send(#"{"id":"s","method":"browser.snapshot","params":{"surface_id":"\#(page.id)","max_depth":1e300}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(performed.map(\.1) == [.wait(.loadState(.complete), timeoutMs: 600_000), .snapshot(interactive: false, maxDepth: 1_000)])
    }

    @Test func closedSurfacesLeaveTheBoardAndTheList() async throws {
        let shell = terminal(at: Frame(x: 0, y: 0, w: 100, h: 100))
        let page = browser()
        let client = try connect()
        client.send(#"{"id":"l","method":"surface.list","params":{"surface_id":"\#(shell.id)"}}"#)
        let listed = try await client.next()["result"]
        #expect(listed?["workspace_id"] == .string(board.id))
        #expect(listed?["surfaces"]?.array?.compactMap { $0["id"]?.string } == [shell.id, page.id])
        #expect(listed?["surfaces"]?.array?.last?["type"] == .string("browser"))

        client.send(#"{"id":"x","method":"surface.close","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(board.objects[page.id] == nil)
        client.send(#"{"id":"u","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))
    }

    @Test func passwordGatesRequestsUntilAuth() async throws {
        let page = browser()
        let client = try connect(password: "s3cret")
        client.send(#"{"id":"early","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unauthorized"))

        client.send("auth wrong")
        #expect(try await client.nextText().hasPrefix("ERROR:"))
        client.send("auth s3cret")
        #expect(try await !client.nextText().hasPrefix("ERROR:"))
        client.send(#"{"id":"late","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(performed.map(\.1) == [.urlGet])
    }

    @Test func authWithoutAPasswordIsAccepted() async throws {
        let client = try connect()
        client.send("auth anything")
        #expect(try await !client.nextText().hasPrefix("ERROR:"), "omp sends auth whenever CMUX_SOCKET_PASSWORD is set")
        client.send("frobnicate")
        #expect(try await client.nextText().hasPrefix("ERROR: Unknown command"))
    }
}

struct BrowserURLTests {
    @Test func addressesBecomeLoadableURLs() {
        #expect(BrowserURL.normalize("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(BrowserURL.normalize("example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(BrowserURL.normalize("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserURL.normalize("127.0.0.1:8000/x")?.absoluteString == "http://127.0.0.1:8000/x")
        #expect(BrowserURL.normalize("devbox:8080")?.absoluteString == "http://devbox:8080")
        #expect(BrowserURL.normalize(" about:blank ")?.absoluteString == "about:blank")
        #expect(BrowserURL.normalize("file:///tmp/a.html")?.absoluteString == "file:///tmp/a.html")
    }

    @Test func textThatIsNotAnAddressIsRejected() {
        #expect(BrowserURL.normalize("how do forms work") == nil)
        #expect(BrowserURL.normalize("intranet") == nil)
        #expect(BrowserURL.normalize("javascript:alert(1)") == nil)
        #expect(BrowserURL.normalize("") == nil)
    }
}
