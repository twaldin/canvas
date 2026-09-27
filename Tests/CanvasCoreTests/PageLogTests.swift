import Foundation
import JavaScriptCore
import Testing
@testable import CanvasCore

/// The page-side recorder (`PageCapture.source`) runs here in JavaScriptCore with a stand-in
/// window (event listeners, timers, fetch, the message handler), then its record goes through
/// `PageLog` as `object.get` and the tile's error list read it.
@MainActor
struct PageLogTests {
    static let window = """
    var listeners = {};
    globalThis.addEventListener = (type, listener) => { (listeners[type] = listeners[type] || []).push(listener); };
    globalThis.dispatch = (type, event) => (listeners[type] || []).forEach((listener) => listener(event));
    var timers = [];
    globalThis.setTimeout = (callback) => { timers.push(callback); return timers.length; };
    globalThis.flushTimers = () => timers.splice(0).forEach((callback) => callback());
    var posted = [];
    globalThis.webkit = { messageHandlers: { canvasPageLog: { postMessage: (message) => posted.push(message) } } };
    var printed = [];
    globalThis.console = {};
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) console[level] = (...args) => printed.push(level);
    globalThis.location = { href: 'http://localhost:8000/' };
    globalThis.fetch = (input) => {
      const url = String(input);
      if (url.includes('offline')) return Promise.reject(new TypeError('Load failed'));
      const status = url.includes('missing') ? 404 : 200;
      const headers = { get: (name) => name === 'content-type' ? 'application/json' : null, forEach: (each) => each('application/json', 'content-type') };
      return Promise.resolve({ url, status, statusText: status === 404 ? 'Not Found' : 'OK', headers,
        clone: () => ({ body: null, text: async () => JSON.stringify({ ok: status === 200, pad: 'x'.repeat(70000) }) }) });
    };
    """

    let context: JSContext

    init() {
        context = JSContext()!
        context.evaluateScript(Self.window)
        context.evaluateScript(PageCapture.source)
    }

    @discardableResult
    func run(_ script: String) -> JSValue { context.evaluateScript(script) }

    func log() throws -> PageLog {
        let text = try #require(run("globalThis.__canvasPageLog.read()").toString())
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try #require(PageLog(json: json))
    }

    @Test func recordsConsoleUncaughtErrorsAndRejectionsWithTheirSources() throws {
        run("""
        console.log('hello %s, %d%% done%c', 'world', 42.7, 'color: red');
        console.warn('careful', { retries: 3, cause: { deep: true } }, [1, 2]);
        console.error(new Error('boom'));
        dispatch('error', { message: 'TypeError: x is undefined', filename: 'http://localhost:8000/static/app.js', lineno: 12, colno: 5,
          error: { name: 'TypeError', message: 'x is undefined', stack: 'render@http://localhost:8000/static/app.js:12:5' } });
        dispatch('unhandledrejection', { reason: new Error('nope') });
        """)
        let log = try log()
        #expect(log.entries.map(\.text) == [
            "hello world, 42% done",
            "careful {retries: 3, cause: {…}} [1, 2]",
            "Error: boom",
            "TypeError: x is undefined",
            "Unhandled Promise Rejection: Error: nope",
        ])
        #expect(log.entries.map(\.kind) == [.console, .console, .console, .exception, .exception])
        #expect(log.entries.map(\.level) == ["log", "warn", "error", "error", "error"])
        #expect((log.errors, log.warnings) == (3, 1))
        let thrown = log.entries[3]
        #expect(thrown.source == "http://localhost:8000/static/app.js:12:5")
        #expect(thrown.shortSource == "app.js:12")
        #expect(thrown.stack == "render@http://localhost:8000/static/app.js:12:5")
        #expect(log.problems.map(\.text).first == "Unhandled Promise Rejection: Error: nope", "the list shows the newest error first")
        #expect(run("printed.join(',')").toString() == "log,warn,error", "the page's console still prints everything")
    }

    @Test func aWarningOrErrorNamesTheCodeThatLoggedIt() throws {
        context.evaluateScript("function save() { console.error('save failed') }\nsave()", withSourceURL: URL(string: "http://localhost:8000/static/cart.js"))
        let entry = try #require(try log().entries.last)
        #expect(entry.source?.hasPrefix("http://localhost:8000/static/cart.js:1:") == true, "the caller, not Canvas's hook: \(entry.source ?? "none")")
        #expect(entry.shortSource == "cart.js:1")
        context.evaluateScript("console.warn('inline')", withSourceURL: URL(string: "http://localhost:8000/"))
        #expect(try log().entries.last?.shortSource == "localhost:8000/:1", "a page's inline script is named by its page")
    }

    @Test func tellsTheTileTheErrorCountOncePerBurst() throws {
        #expect(run("JSON.stringify(posted)").toString() == "[0]", "a new document starts at zero")
        run("console.error('a'); console.error('b'); console.warn('c')")
        #expect(run("JSON.stringify(posted)").toString() == "[0]", "nothing until the burst settles")
        run("flushTimers()")
        #expect(run("JSON.stringify(posted)").toString() == "[0,2]")
        run("console.log('fine'); flushTimers()")
        #expect(run("JSON.stringify(posted)").toString() == "[0,2]", "logs and warnings never wake the tile")
    }

    @Test func failedRequestsAreErrorsAndOmpsResponseLogCoversPageLoad() throws {
        run("""
        var rejected = null;
        fetch('http://localhost:8000/missing.json');
        fetch('http://localhost:8000/ok.json');
        fetch('http://offline.test/x').catch((error) => { rejected = error.message; });
        """)
        let log = try log()
        #expect(log.entries.map(\.text) == ["GET http://localhost:8000/missing.json → 404 Not Found", "GET http://offline.test/x failed: Load failed"])
        #expect(log.entries.map(\.status) == [404, nil])
        #expect(log.entries.allSatisfy { $0.kind == .request && $0.resource == "fetch" && $0.method == "GET" })
        #expect(log.errors == 2)
        #expect(run("rejected").toString() == "Load failed", "the page's own fetch still rejects")

        let records = try #require(run("JSON.stringify(globalThis.__ompCmuxResponses)").toString())
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(records.utf8))
        #expect(json["nextId"]?.int == 4)
        let saved = try #require(json["records"]?.array)
        // The fetch that never got an answer is a record too, as the page log counts it (confirm6 F2).
        #expect(saved.map { $0["status"]?.int } == [0, 404, 200])
        #expect(saved.first?["url"]?.string == "http://offline.test/x" && saved.first?["statusText"]?.string == "Load failed")
        let answered = Array(saved.dropFirst())
        #expect(answered.allSatisfy { $0["method"]?.string == "GET" && $0["resourceType"]?.string == "fetch" && $0["headers"]?["content-type"]?.string == "application/json" })
        #expect(answered.first?["body"]?.string?.count == 65536, "bodies are capped")
    }

    @Test func aChattyPageNeverPushesOutItsErrors() throws {
        run("console.error('the one that matters'); for (let i = 0; i < 450; i++) console.log('tick ' + i)")
        let log = try log()
        #expect(log.entries.first?.text == "the one that matters")
        #expect(log.entries.count == 201)
        #expect(log.entries.last?.text == "tick 449")
        #expect(log.dropped == 250)
        #expect(log.errors == 1)
        let shown = log.json()
        #expect(shown["entries"]?.array?.count == PageLog.returnedEntries)
        #expect(shown["omitted"]?.int == 101)
    }

    @Test func ompsConsoleCaptureSeesLoadTimeMessagesInItsOwnShape() throws {
        run("""
        const loop = { name: 'loop' }; loop.self = loop;
        console.warn('__loadtime_warn__', loop);
        dispatch('error', { message: 'Error: kaboom', filename: 'http://localhost:8000/a.js', lineno: 3, colno: 1, error: new Error('kaboom') });
        """)
        let text = try #require(run("JSON.stringify(globalThis.__ompConsoleCapture)").toString())
        let capture = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let entries = try #require(capture["entries"]?.array)
        #expect(entries.map { $0["type"]?.string } == ["console", "pageerror"])
        #expect(entries.map { $0["seq"]?.int } == [1, 2])
        #expect(entries[0]["level"]?.string == "warn")
        #expect(entries[0]["text"]?.string == "__loadtime_warn__ [object Object]")
        #expect(entries[0]["args"]?.array?.first?.string == "__loadtime_warn__")
        #expect(entries[1]["location"]?.string == "http://localhost:8000/a.js:3:1")
        #expect(capture["nextSeq"]?.int == 3)
        #expect(run("JSON.stringify(Object.keys(globalThis).filter((key) => key.startsWith('__canvas') || key.startsWith('__omp')))").toString() == "[]",
                "the globals stay out of the page's own enumeration")
    }

    @Test func aCursorReadsOnlyWhatCameAfterItUntilThePageReloads() throws {
        run("console.error('before')")
        let first = try log()
        let cursor = try #require(PageLog.Cursor(first.cursor))
        run("console.error('after')")
        let second = try log()
        #expect(second.entries(after: cursor).entries.map(\.text) == ["after"])
        #expect(second.json(since: cursor)["reloaded"] == nil)

        let reloaded = PageLog(document: "another", url: second.url, entries: second.entries, errors: 2, warnings: 0)
        #expect(reloaded.entries(after: cursor).entries.map(\.text) == ["before", "after"])
        #expect(reloaded.json(since: cursor)["reloaded"]?.bool == true)

        #expect(PageLog.Cursor("nonsense") == nil)
        #expect(PageLog.Cursor(":3") == nil)
        #expect(PageLog.Cursor("171:-1") == nil)
    }

    @Test func aReleasedPageKeepsItsLogAndACursorFromBeforeTheReleaseCarriesOn() throws {
        run("console.error('brick.center is undefined')")
        let old = try log()
        let seen = try #require(PageLog.Cursor(old.cursor))
        run("console.warn('late')")
        let released = PageReport.Released(log: try log(), at: Date(timeIntervalSince1970: 1_790_000_000))

        // Released: nothing loaded, the old log under `previous`, and a cursor to carry on with.
        let gone = PageReport(visibility: .released, log: nil, previous: released).json()
        #expect(gone["loaded"]?.bool == false)
        #expect(gone["visibility"]?.string == "released")
        #expect(gone["previous"]?["errors"]?.int == 1)
        #expect(gone["previous"]?["entries"]?.array?.map { $0["text"]?.string } == ["brick.center is undefined", "late"])
        #expect(gone["previous"]?["releasedAt"]?.string == "2026-09-21T14:13:20.000Z")
        #expect(gone["cursor"]?.string == released.log.cursor)
        let sinceSeen = PageReport(visibility: .released, log: nil, previous: released).json(since: seen)
        #expect(sinceSeen["previous"]?["entries"]?.array?.map { $0["text"]?.string } == ["late"], "a cursor from before the release reads what came after it")

        // Loaded again: the new document's log, and the old one until the caller reads past it.
        let fresh = PageLog(document: "rebuilt", url: old.url, entries: [], errors: 0, warnings: 0)
        let back = PageReport(visibility: .visible, log: fresh, previous: released)
        let afterRelease = back.json(since: PageLog.Cursor(released.log.cursor))
        #expect(afterRelease["loaded"]?.bool == true)
        #expect(afterRelease["reloaded"]?.bool == true)
        #expect(afterRelease["previous"]?["entries"]?.array?.isEmpty == true, "the released page's entries were all read")
        #expect(afterRelease["cursor"]?.string == fresh.cursor)
        #expect(back.json()["previous"]?["errors"]?.int == 1)
        #expect(back.json(since: PageLog.Cursor(fresh.cursor))["previous"] == nil, "read past the reload: the released page is old news")
        #expect(PageReport(visibility: .hidden, log: fresh).json()["previous"] == nil)
    }

    @Test func aPageSourceOpensTheRepoFileItWasServedFrom() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)").path
        for file in ["game.js", "index.html", "public/static/app.js", "src/main.ts", "a/util.js", "b/util.js"] {
            let path = (root as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let listed = FileIndex(paths: ["game.js", "index.html", "public/static/app.js", "src/main.ts", "a/util.js", "b/util.js"])
        func file(_ text: String) -> String? {
            PageSource.location(text).flatMap { PageSource.file(for: $0.url, root: root, listed: listed) }.map { String($0.dropFirst(root.count + 1)) }
        }

        #expect(PageSource.location("update@http://localhost:8000/game.js:238:19") == .init(url: URL(string: "http://localhost:8000/game.js")!, line: 238, column: 19))
        #expect(PageSource.location("global code@http://localhost:8000/game.js:4")?.line == 4)
        #expect(PageSource.location("    at step (http://localhost:5173/src/main.ts?t=17:12:3)")?.url.absoluteString == "http://localhost:5173/src/main.ts?t=17")
        #expect(PageSource.location("[native code]") == nil)
        #expect(PageSource.location("game.js:238") == nil, "a URL, not a bare path")

        #expect(file("http://localhost:8000/game.js:238:19") == "game.js")
        #expect(file("http://localhost:5173/src/main.ts?t=1719:12:3") == "src/main.ts", "the query is the server's")
        #expect(file("http://localhost:8000/:12:5") == "index.html", "an inline script's line is the page's own file")
        #expect(file("http://localhost:3000/static/app.js:40") == "public/static/app.js", "a served path is found by its trailing part")
        #expect(file("http://localhost:3000/util.js:1") == nil, "two files end that way: none is guessed")
        #expect(file("http://localhost:3000/missing.js:1") == nil)
        #expect(file("http://localhost:3000/../../etc/hosts:1") == nil)
        #expect(file("http://localhost:5173/@fs\(root)/src/main.ts:3") == "src/main.ts")
        #expect(file("file://\(root)/game.js:7") == "game.js")
        #expect(file("file:///etc/hosts:1") == nil, "only files under the board root")
        #expect(file("https://cdn.example.com/lib/react.js:1") == nil)
    }

    @Test func vitalsWebKitDoesNotMeasureAreNullNeverZero() throws {
        let raw = JSONValue.object([
            "lcp": .number(86.24), "cls": .null, "longTasks": .null, "fcp": .number(40.06), "ttfb": .number(3), "domContentLoaded": .null,
            "load": .number(0), "unsupported": .array([.string("cls"), .string("longTasks")]),
        ])
        let vitals = PageLog.vitals(raw)
        #expect(vitals["lcp"]?.number == 86.2)
        #expect(vitals["fcp"]?.number == 40.1)
        #expect(vitals["cls"] == .null)
        #expect(vitals["longTasks"] == .null)
        #expect(vitals["domContentLoaded"] == .null)
        #expect(vitals["unsupported"] == .array([.string("cls"), .string("longTasks")]))
        let page = try log().json()["vitals"]
        #expect(page?["unsupported"] == .array([.string("lcp"), .string("cls"), .string("longTasks")]), "no PerformanceObserver here: nothing is claimed")
        #expect(page?["lcp"] == .null)
    }

    @Test func anHTTPErrorOnThePageItselfIsItsFirstProblem() throws {
        run("console.error('later')")
        var log = try log()
        log.add(documentFailure: PageLog.documentFailure(url: "http://localhost:8000/gone", status: 404))
        #expect(log.errors == 2)
        #expect(log.entries.first?.text.hasPrefix("http://localhost:8000/gone → 404") == true)
        #expect(log.entries.first?.resource == "document")
        #expect(log.problems.map(\.resource) == [nil, "document"])
    }

    @Test func aConsoleMentionCarriesTheMessageSourceAndStack() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = Board(id: "brd_test", root: root)
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost:8000/"), "title": .string("Shop")]))
        let entry = PageLogEntry(seq: 4, time: "2026-09-27T14:03:05.000Z", kind: .exception, level: "error", text: "TypeError: x is undefined",
                                 source: "http://localhost:8000/static/app.js:12:5",
                                 stack: "hook@canvas-page-log.js:1:2\nrecord@user-script:3:132:47\nrender@http://localhost:8000/static/app.js:12:5\nmain@http://localhost:8000/static/app.js:40:1")
        let target = MentionTarget.console(object: page.id, url: "http://localhost:8000/", entry: entry)
        let decoded = try JSONDecoder().decode(MentionTarget.self, from: JSONEncoder().encode(target))
        #expect(decoded == target)
        let mention = try board.stage(target)
        #expect(mention.label == "error \"TypeError: x is undefined\" · app.js:12")
        let context = await board.drain().context
        #expect(context.contains("[1] page error · browser tile \(page.id) \"Shop\" · page http://localhost:8000/ · at "))
        #expect(context.contains("\n    TypeError: x is undefined\n    source: http://localhost:8000/static/app.js:12:5\n    stack:\n      render@http://localhost:8000/static/app.js:12:5\n      main@"))
        #expect(!context.contains("canvas-page-log.js") && !context.contains("user-script"), "Canvas's own frames stay out")
    }
}
