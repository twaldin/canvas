import CoreGraphics
import Foundation
import Testing
import CanvasCore

private typealias G = DrawingGeometry

private func moved(_ frame: Frame, _ dx: Double, _ dy: Double) -> Frame {
    Frame(x: frame.x + dx, y: frame.y + dy, w: frame.w, h: frame.h)
}

// Literal params keep the request bodies below readable.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

/// Layout over the socket, as agents drive it: measure, fit, place/stack, batch, check.
@MainActor
final class LayoutApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-layout-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let server: SocketServer
    let board: Board
    let client: LineClient
    var sequence = 0

    init() throws {
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 100 lines; line 12 is a tab plus 60 x's (64 columns), line 50 is the longest in the file.
        var lines = (1...100).map { "line \($0)" }
        lines[11] = "\t" + String(repeating: "x", count: 60)
        lines[49] = String(repeating: "y", count: 120)
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("src.txt"), atomically: true, encoding: .utf8)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: root)
        let router = ApiRouter(registry: registry)
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        client = try LineClient(path: dir.appendingPathComponent("s").path)
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// One request; returns the whole reply (`ok`, `result` or `error`).
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        sequence += 1
        let request: JSONValue = .object(["id": .string("r\(sequence)"), "method": .string(method), "params": params])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func result(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let reply = try await call(method, params)
        #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
        return reply["result"] ?? .null
    }

    static func size(_ value: JSONValue?) -> CGSize {
        CGSize(width: value?["w"]?.number ?? -1, height: value?["h"]?.number ?? -1)
    }

    static func code(_ start: Int, _ end: Int, caption: String? = nil) -> JSONValue {
        var props: [String: JSONValue] = ["path": .string("src.txt"), "range": .object(["start": .number(Double(start)), "end": .number(Double(end))])]
        if let caption { props["caption"] = .string(caption) }
        return .object(props)
    }

    // MARK: Measure and fit

    @Test func codeMeasuresExactlyItsRangeWithTabsExpanded() async throws {
        let measured = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19)])))
        #expect(measured == CodeMetrics.size(lines: 10, longestLine: 64, caption: false))
        let captioned = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: "why")])))
        #expect(captioned.height == measured.height + CodeMetrics.captionHeight)
        // The file's longest line (50) is outside the range and doesn't widen it.
        let wide = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54)])))
        #expect(wide.width > measured.width)
    }

    @Test func unmeasurableContentSaysWhy() async throws {
        let html = try await call("object.measure", .object(["type": "html", "props": .object(["html": "<p>hi</p>"])]))
        #expect(html["error"]?["code"] == .string("unsupported"))
        let past = try await call("object.measure", .object(["type": "code", "props": Self.code(150, 160)]))
        #expect(past["error"]?["code"] == .string("unavailable"))
    }

    @Test func noteHeightFollowsItsWrapWidthAndResolvedFences() async throws {
        let prose: JSONValue = .object(["markdown": .string(String(repeating: "A sentence that wraps across the note. ", count: 12))])
        let narrow = Self.size(try await result("object.measure", .object(["type": "note", "props": prose, "width": 240])))
        let wide = Self.size(try await result("object.measure", .object(["type": "note", "props": prose, "width": 720])))
        #expect(narrow.width == 240 && wide.width == 720)
        #expect(narrow.height > wide.height * 2, "about three times the lines at a third of the width")
        let oneLine = Self.size(try await result("object.measure", .object(["type": "note", "props": .object(["markdown": "Short."]), "width": 720])))
        #expect(oneLine.height < wide.height)

        // A live excerpt renders the file's rows, so 30 rows measure taller than 3.
        func fence(_ end: Int) -> JSONValue { .object(["markdown": .string("Intro\n\n```txt file=src.txt#L1-\(end)\n```")]) }
        let short = Self.size(try await result("object.measure", .object(["type": "note", "props": fence(3), "width": 480])))
        let long = Self.size(try await result("object.measure", .object(["type": "note", "props": fence(30), "width": 480])))
        #expect(long.height - short.height > 27 * 12)
    }

    @Test func sizeFitCreatesAndRefitsAtTheGivenOrigin() async throws {
        let created = try await result("object.create", .object(["type": "code", "props": Self.code(1, 20), "frame": .object(["x": 100, "y": 200]), "size": "fit"]))
        let id = try #require(created["object"]?["id"]?.string)
        let expected = CodeMetrics.size(lines: 20, longestLine: 64, caption: false)
        #expect(created["object"]?["frame"] == .object(["x": 100, "y": 200, "w": .number(expected.width), "h": .number(expected.height)]))

        let refit = try await result("object.update", .object(["id": .string(id), "props": .object(["range": .object(["start": 1, "end": 5])]), "size": "fit"]))
        let frame = try #require(refit["object"]?["frame"]).decode(Frame.self)
        #expect(frame.x == 100 && frame.y == 200)
        #expect(frame.h == Double(CodeMetrics.size(lines: 5, longestLine: 7, caption: false).height))

        let note = try await result("object.create", .object(["type": "note", "props": .object(["markdown": "# Title\n\nBody"]), "frame": .object(["x": 0, "y": 0, "w": 400]), "size": "fit"]))
        #expect(note["object"]?["frame"]?["w"] == .number(400))
    }

    // MARK: Batch

    @Test func batchResolvesEarlierIdsAndUndoesAsOneStep() async throws {
        let before = board.revision
        let steps = board.history.undoSteps.count
        let reply = try await result("object.batch", .object(["ops": .array([
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "a"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])])]),
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "b"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])])]),
            .object(["method": "layout.place", "params": .object(["id": "$1", "near": "$0", "side": "right", "gap": 60])]),
            .object(["method": "object.create", "params": .object(["type": "arrow", "props": .object(["from": .object(["object": "$0"]), "to": .object(["object": "$1"])])])]),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$0", "$1"], "title": "Lane"])])]),
        ])]))
        let results = try #require(reply["results"]?.array)
        let a = try #require(results[0]["object"]?["id"]?.string)
        let b = try #require(results[1]["object"]?["id"]?.string)
        let arrow = try board.object(try #require(results[3]["object"]?["id"]?.string))
        #expect(arrow.props["from"]?["object"] == .string(a) && arrow.props["to"]?["object"] == .string(b))
        #expect(try board.object(b).frame.x == 260)
        #expect(board.revision == before + 1, "one revision for the whole batch")
        #expect(board.history.undoSteps.count == steps + 1)
        #expect(board.changed(since: before).count == 4)

        board.undo()
        #expect(board.objects.isEmpty)
    }

    @Test func aFailingOpRollsBackEverythingBeforeIt() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "keep"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let steps = board.history.undoSteps.count
        let reply = try await call("object.batch", .object(["ops": .array([
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "new"])])]),
            .object(["method": "object.update", "params": .object(["id": .string(note.id), "frame": .object(["x": 500, "y": 500, "w": 200, "h": 100])])]),
            .object(["method": "object.update", "params": .object(["id": .string(note.id), "rev": 1, "props": .object(["markdown": "stale"])])]),
        ])]))
        #expect(reply["error"]?["code"] == .string("conflict"))
        #expect(reply["error"]?["message"]?.string?.hasPrefix("op 2 (object.update)") == true)
        #expect(board.objects.count == 1, "the created note is gone")
        let restored = try board.object(note.id)
        #expect(restored.frame == note.frame && restored.props == note.props)
        #expect(board.history.undoSteps.count == steps, "nothing to undo")

        let forward = try await call("object.batch", .object(["ops": .array([
            .object(["method": "object.delete", "params": .object(["id": "$1"])]),
        ])]))
        #expect(forward["error"]?["code"] == .string("invalid_params"))
    }

    /// Build offscreen, then lay out: a batch creates tiles in two lanes and grids them by `$n`,
    /// so each column lines up across both lanes at its widest cell.
    @Test func gridInsideABatchAlignsColumnsAcrossGroups() async throws {
        func note(_ w: Int, _ h: Int) -> JSONValue {
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "n"]), "frame": .object(["x": 20000, "y": 0, "w": .number(Double(w)), "h": .number(Double(h))])])])
        }
        func cell(_ ref: String, _ row: Int, _ col: Int) -> JSONValue { .object(["id": .string(ref), "row": .number(Double(row)), "col": .number(Double(col))]) }
        let before = board.revision
        let reply = try await result("object.batch", .object(["ops": .array([
            note(300, 100), note(200, 150), note(250, 80), note(400, 120),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$0", "$1"]])])]),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$2", "$3"]])])]),
            .object(["method": "layout.grid", "params": .object(["cells": .array([cell("$0", 0, 0), cell("$1", 0, 1), cell("$2", 1, 0), cell("$3", 1, 1)]),
                                                                  "colGap": 50, "rowGap": 120, "origin": .object(["x": 0, "y": 0])])]),
        ])]))
        let results = try #require(reply["results"]?.array)
        let ids = try (0..<6).map { try #require(results[$0]["object"]?["id"]?.string) }
        let frames = try ids.map { try board.object($0).frame }
        // Column 0 is 300 wide (row 0's note), column 1 starts 50 past it; rows are 150 and 120 tall.
        #expect(frames[0...3].map(\.x) == [0, 350, 0, 350])
        #expect(frames[0...3].map(\.y) == [0, 0, 270, 270])
        #expect(results[6]["columns"] == .array([.object(["col": 0, "x": 0, "w": 300]), .object(["col": 1, "x": 350, "w": 400])]))
        #expect(results[6]["rows"] == .array([.object(["row": 0, "y": 0, "h": 150]), .object(["row": 1, "y": 270, "h": 120])]))
        // The lanes were re-fit to their members' new places before the batch returned.
        let top = GroupSpec.titleHeight, pad = GroupSpec.defaultPadding
        #expect(frames[4] == Frame(x: -pad, y: -pad - top, w: 550 + 2 * pad, h: 150 + 2 * pad + top))
        #expect(results[6]["frames"]?[ids[3]] == .object(["x": 350, "y": 270, "w": 400, "h": 120]))
        #expect(board.revision == before + 1)

        board.undo()
        #expect(board.objects.isEmpty, "the whole build is one step")
    }

    @Test func translateInABatchMovesGroupsAndArrowEnds() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let lane = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let free = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["point": [500, 50]])]))
        let reply = try await result("object.batch", .object(["ops": .array([
            .object(["method": "layout.translate", "params": .object(["ids": .array([.string(lane.id), .string(a.id), .string(free.id)]), "dx": -12000, "dy": 30])]),
        ])]))
        #expect(try board.object(a.id).frame == Frame(x: -12000, y: 30, w: 200, h: 100), "listed beside its group, it still moves once")
        #expect(reply["results"]?.array?.first?["frames"]?[lane.id] == (try JSONValue.encode(moved(lane.frame, -12000, 30))))
        let spec = try #require(ArrowSpec(try board.object(free.id).props))
        #expect(spec.to == .point(CGPoint(x: -11500, y: 80)) && spec.from == .object(a.id))
    }

    // MARK: Check

    @Test func checkReportsOverlapsCrossingsAndOverflow() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 200))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 400, y: 0, w: 200, h: 200))
        let c = board.create(type: .note, props: .object(["markdown": "c"]), frame: Frame(x: 800, y: 0, w: 200, h: 200))
        let stray = board.create(type: .note, props: .object(["markdown": "stray"]), frame: Frame(x: 150, y: 150, w: 200, h: 100))
        let region = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: -50, y: -100, w: 1100, h: 450))
        let group = board.create(type: .group, props: .object(["members": .array([.string(b.id), .string(c.id)])]))
        let through = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(c.id)])]))
        let around = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(c.id)]), "route": "avoid"]))
        let tiny = board.create(type: .code, props: Self.code(1, 30), frame: Frame(x: 0, y: 600, w: 300, h: 100))

        let report = try await result("layout.check", .object([:]))
        let overlaps = Set(report["overlaps"]?.array?.compactMap { $0.array?.compactMap(\.string) } ?? [])
        #expect(overlaps.contains([a.id, stray.id].sorted()))
        #expect(!overlaps.contains { $0.contains(region.id) }, "a drawn region around things isn't an overlap")
        #expect(!overlaps.contains([b.id, group.id].sorted()), "nor is a group around its members")
        #expect(overlaps.contains([a.id, group.id].sorted()) == false)
        let crossings = report["arrowCrossings"]?.array ?? []
        #expect(crossings.contains(.object(["arrow": .string(through.id), "crosses": .array([.string(b.id)])])))
        #expect(!crossings.contains { $0["arrow"] == .string(around.id) }, "an avoid route goes around b")
        let overflow = try #require(report["overflow"]?.array?.first { $0["id"] == .string(tiny.id) })
        #expect(overflow["y"]?.number == Double(CodeMetrics.size(lines: 30, longestLine: 64, caption: false).height) - 100)

        let scoped = try await result("layout.check", .object(["ids": .array([.string(c.id)])]))
        #expect(scoped["overlaps"] == .array([]) && scoped["arrowCrossings"] == .array([]))
    }
}

/// Board-level layout: place/stack math and steps, groups as regions, and arrow routing.
@MainActor
struct LayoutBoardTests {
    let board = Board(id: "brd_layout", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func note(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CanvasObject {
        board.create(type: .note, props: .object(["markdown": "n"]), frame: Frame(x: x, y: y, w: w, h: h))
    }

    @Test func placeAlignsOnEverySide() {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 100)
        let size = CGSize(width: 50, height: 40)
        #expect(Layout.place(size, near: anchor, side: .right, gap: 10, align: .start) == CGPoint(x: 310, y: 100))
        #expect(Layout.place(size, near: anchor, side: .right, gap: 10, align: .end) == CGPoint(x: 310, y: 160))
        #expect(Layout.place(size, near: anchor, side: .left, gap: 10, align: .center) == CGPoint(x: 40, y: 130))
        #expect(Layout.place(size, near: anchor, side: .below, gap: 10, align: .center) == CGPoint(x: 175, y: 210))
        #expect(Layout.place(size, near: anchor, side: .above, gap: 10, align: .end) == CGPoint(x: 250, y: 50))
    }

    @Test func stackWrapsLinesAndAlignsAcrossThem() {
        let sizes = [CGSize(width: 100, height: 50), CGSize(width: 100, height: 80), CGSize(width: 100, height: 30)]
        #expect(Layout.stack(sizes, from: .zero, direction: .row, gap: 10) == [CGPoint(x: 0, y: 0), CGPoint(x: 110, y: 0), CGPoint(x: 220, y: 0)])
        // 210 fits two boxes; the third wraps below the thicker of them.
        #expect(Layout.stack(sizes, from: .zero, direction: .row, gap: 10, wrapAt: 210, align: .end) == [CGPoint(x: 0, y: 30), CGPoint(x: 110, y: 0), CGPoint(x: 0, y: 90)])
        #expect(Layout.stack(sizes, from: CGPoint(x: 5, y: 5), direction: .column, gap: 20, align: .center) == [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 75), CGPoint(x: 5, y: 175)])
    }

    @Test func stackingGroupsMovesTheirMembersInOneStep() throws {
        let a = note(0, 0), b = note(300, 0), c = note(1000, 1000)
        let lane1 = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))
        let lane2 = board.create(type: .group, props: .object(["members": .array([.string(c.id)])]))
        let before = board.revision
        let steps = board.history.undoSteps.count
        let frames = try board.stack([lane1.id, lane2.id], direction: .column, gap: 40)
        let first = try #require(frames[lane1.id])
        #expect(try board.object(lane2.id).frame.y == first.maxY + 40)
        #expect(try board.object(lane2.id).frame.x == first.x)
        #expect(try board.object(c.id).frame.x == a.frame.x, "members moved with their lane")
        #expect(board.revision == before + 1)
        #expect(board.history.undoSteps.count == steps + 1)
        board.undo()
        #expect(try board.object(c.id).frame == c.frame)
        #expect(try board.object(lane2.id).frame == lane2.frame)
    }

    @Test func groupIsItsMembersBoundsPlusPaddingAndTitle() throws {
        let a = note(0, 0), b = note(300, 200)
        let group = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)]), "padding": 10]))
        let top = GroupSpec.titleHeight
        #expect(group.frame == Frame(x: -10, y: -10 - top, w: 520, h: 320 + top))

        // A member moves: the group follows in the same undo step.
        let outside = note(700, 50)
        #expect(!board.enclosed(by: try board.object(group.id)).map(\.id).contains(outside.id))
        try board.update(b.id, frame: Frame(x: 800, y: 200, w: 200, h: 100))
        let grown = try board.object(group.id)
        #expect(grown.frame.maxX == 1010)
        #expect(board.enclosed(by: grown).map(\.id).contains(outside.id), "encloses follows the region")
        board.undo()
        #expect(try board.object(group.id).frame == group.frame)

        // A frame written to a group is ignored; deleting a member shrinks it.
        try board.update(group.id, frame: Frame(x: 0, y: 0, w: 1, h: 1))
        #expect(try board.object(group.id).frame == group.frame)
        try board.delete(b.id)
        #expect(try board.object(group.id).frame == Frame(x: -10, y: -10 - top, w: 220, h: 120 + top))
    }

    @Test func nestedGroupsRefitOutward() throws {
        let a = note(0, 0), b = note(300, 0)
        let inner = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let outer = board.create(type: .group, props: .object(["members": .array([.string(inner.id), .string(b.id)])]))
        try board.update(a.id, frame: Frame(x: 0, y: 500, w: 200, h: 100))
        let innerNow = try board.object(inner.id).frame
        #expect(try board.object(outer.id).frame.contains(innerNow))
        #expect(innerNow.maxY == 600 + GroupSpec.defaultPadding)
        _ = outer
    }

    @Test func storedGroupsGetTitlesAndRealFrames() throws {
        let a = note(0, 0)
        var group = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        group.props = .object(["members": .array([.string(a.id)]), "name": "Old lane"])
        group.frame = Frame(x: 18, y: -50, w: 0, h: 0)
        let stored: JSONValue = .object(["id": "brd_x", "root": "/tmp", "revision": 3, "objects": try JSONValue.encode([a, group])])
        let loaded = Board(snapshot: try stored.decode(BoardSnapshot.self))
        let migrated = try loaded.object(group.id)
        #expect(migrated.props["title"] == .string("Old lane") && migrated.props["name"] == nil)
        #expect(migrated.frame.w > 200 && migrated.frame.contains(a.frame))
    }

    // MARK: Routing

    @Test func avoidRoutesAroundATileTheStraightLineCrosses() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 600, y: 0, width: 100, height: 100)
        let wall = CGRect(x: 250, y: -100, width: 200, height: 300)
        let straight = G.path(from: .bound(.rect(from)), to: .bound(.rect(to)), style: .straight)
        #expect(G.path(straight, crosses: wall))
        let avoid = G.path(from: .bound(.rect(from)), to: .bound(.rect(to)), style: .avoid, obstacles: [wall])
        #expect(!G.path(avoid, crosses: wall.insetBy(dx: -G.avoidMargin + 1, dy: -G.avoidMargin + 1)), "keeps its margin")
        #expect(!G.path(avoid, crosses: from) && !G.path(avoid, crosses: to))
        for (p, q) in zip(avoid, avoid.dropFirst()) { #expect(p.x == q.x || p.y == q.y, "axis-aligned segments") }
        let end = avoid[avoid.count - 1]
        #expect(to.insetBy(dx: -G.arrowGap - 1, dy: -G.arrowGap - 1).contains(end) && !to.contains(end))
    }

    @Test func orthogonalJogsBetweenOffsetBoxes() {
        let path = G.path(from: .bound(.rect(CGRect(x: 0, y: 0, width: 100, height: 100))), to: .bound(.rect(CGRect(x: 400, y: 300, width: 100, height: 100))), style: .orthogonal)
        #expect(path.count == 4)
        for (p, q) in zip(path, path.dropFirst()) { #expect(p.x == q.x || p.y == q.y) }
        #expect(path[0].x == 100 + G.arrowGap && path[3].x == 400 - G.arrowGap)
    }

    @Test func parallelArrowsInBothDirectionsDrawApart() {
        let offsets = G.parallelOffsets([("obj_1", "obj_a", "obj_b"), ("obj_2", "obj_b", "obj_a"), ("obj_3", "obj_a", "obj_c")])
        #expect(offsets["obj_3"] == nil)
        let a = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 0, y: 0, width: 200, height: 100)))
        let b = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 500, y: 40, width: 200, height: 100)))
        for style in [ArrowRouteStyle.straight, .orthogonal] {
            let forward = G.path(from: a, to: b, style: style, offset: offsets["obj_1"] ?? 0)
            let back = G.path(from: b, to: a, style: style, offset: offsets["obj_2"] ?? 0)
            // Reversed, the return arrow's route must not coincide with the forward one anywhere.
            let separation = forward.map { G.distance($0, toPath: back) }.min() ?? 0
            #expect(separation >= G.parallelSpacing - 0.5, "\(style): \(forward) vs \(back)")
        }
        // Diagonal pairs separate too.
        let c = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let forward = G.path(from: a, to: c, style: .straight, offset: 10)
        let back = G.path(from: c, to: a, style: .straight, offset: 10)
        #expect(G.distance(forward[0], toPath: back) > 15)
    }

    @Test func labelsSitBesideTheRouteAndClearOfBoxes() {
        let path = [CGPoint(x: 0, y: 100), CGPoint(x: 400, y: 100)]
        let size = CGSize(width: 80, height: 20)
        let free = G.labelRect(along: path, size: size, side: 0, obstacles: [])
        #expect(!G.path(path, crosses: free) && free.maxY <= 100 - G.labelClearance + 0.5, "above a horizontal line by default")
        let box = CGRect(x: 150, y: 50, width: 100, height: 45)
        let moved = G.labelRect(along: path, size: size, side: 0, obstacles: [box])
        #expect(!moved.intersects(box) && !G.path(path, crosses: moved))
        // An arrow shifted right of its travel (negative offset) labels that outer side.
        let other = G.labelRect(along: path, size: size, side: -1, obstacles: [])
        #expect(other.minY >= 100)
    }

    // MARK: Translate and grid

    @Test func gridColumnsAndRowsTakeTheirLargestCell() {
        let cells = [
            Layout.GridCell(row: 0, col: 0, size: CGSize(width: 100, height: 40)),
            Layout.GridCell(row: 0, col: 2, size: CGSize(width: 60, height: 90)),
            Layout.GridCell(row: 3, col: 0, size: CGSize(width: 180, height: 20)),
            Layout.GridCell(row: 3, col: 2, size: CGSize(width: 20, height: 30)),
        ]
        let grid = Layout.grid(cells, origin: CGPoint(x: 10, y: 5), colGap: 10, rowGap: 20)
        // Unused column 1 and rows 1–2 take no space.
        #expect(grid.columns == [Layout.Track(index: 0, start: 10, length: 180), Layout.Track(index: 2, start: 200, length: 60)])
        #expect(grid.rows == [Layout.Track(index: 0, start: 5, length: 90), Layout.Track(index: 3, start: 115, length: 30)])
        #expect(grid.origins == [CGPoint(x: 10, y: 5), CGPoint(x: 200, y: 5), CGPoint(x: 10, y: 115), CGPoint(x: 200, y: 115)])
        let centered = Layout.grid(cells, origin: .zero, colGap: 10, rowGap: 20, colAlign: .center, rowAlign: .end)
        #expect(centered.origins[0] == CGPoint(x: 40, y: 50))
        #expect(centered.origins[3] == CGPoint(x: 210, y: 110))
    }

    @Test func gridOfLaneMembersIsOneStepAndRejectsAGroupBesideItsMember() throws {
        let a = note(0, 0, 300, 100), b = note(1000, 0, 100, 100), c = note(0, 500, 150, 100), d = note(900, 500, 250, 100)
        let top = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))
        let bottom = board.create(type: .group, props: .object(["members": .array([.string(c.id), .string(d.id)])]))
        let steps = board.history.undoSteps.count
        let placed = try board.grid([(a.id, 0, 0), (b.id, 0, 1), (c.id, 1, 0), (d.id, 1, 1)], colGap: 40, rowGap: 200)
        #expect(placed.frames[b.id]?.x == 340 && placed.frames[d.id]?.x == 340, "column 1 starts past column 0's widest cell")
        #expect(try board.object(bottom.id).frame.y == 300 - GroupSpec.defaultPadding - GroupSpec.titleHeight, "row 1 starts at 100 + rowGap; its lane follows")
        #expect(board.history.undoSteps.count == steps + 1)
        board.undo()
        #expect(try board.object(d.id).frame == d.frame && (try board.object(top.id).frame) == top.frame)

        #expect(throws: BoardError.self) { try board.grid([(top.id, 0, 0), (a.id, 0, 1)]) }
        #expect(try board.object(a.id).frame == a.frame, "a rejected grid moves nothing")
    }

    @Test func translateMovesEverythingOnceInOneStep() throws {
        let a = note(0, 0), b = note(300, 0), c = note(0, 400)
        let inner = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let outer = board.create(type: .group, props: .object(["members": .array([.string(inner.id), .string(b.id)])]))
        let bound = board.create(type: .arrow, props: .object(["from": .object(["object": .string(b.id)]), "to": .object(["object": .string(c.id)])]))
        let before = board.revision
        let frames = try board.translate([outer.id, b.id], dx: 100, dy: -50)
        #expect(try board.object(a.id).frame.rect.origin == CGPoint(x: 100, y: -50))
        #expect(try board.object(b.id).frame.rect.origin == CGPoint(x: 400, y: -50))
        #expect(frames[outer.id] == moved(outer.frame, 100, -50))
        #expect(try board.object(inner.id).frame == moved(inner.frame, 100, -50))
        #expect(try board.object(c.id).frame == c.frame)
        #expect(try board.object(bound.id).props == bound.props, "a bound arrow follows by routing, not by rewriting")
        #expect(board.revision == before + 1)
        board.undo()
        #expect(try board.object(outer.id).frame == outer.frame && (try board.object(a.id).frame) == a.frame)
    }
}
