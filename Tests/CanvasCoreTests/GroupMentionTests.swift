import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// A Hyper-click on a titled group's title or empty interior (and ⇧⌘M on a selected group)
/// mentions the whole group; its context lists the members and the arrows among them.
@MainActor
struct GroupMentionTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    func group(_ members: [ObjectID], title: String?, on board: Board) -> CanvasObject {
        var props: [String: JSONValue] = ["members": .array(members.map(JSONValue.string))]
        if let title { props["title"] = .string(title) }
        return board.create(type: .group, props: .object(props))
    }

    @Test func aPressInsideAGroupIsAClickUntilItMovesPastTheThreshold() {
        let start = CGPoint(x: 100, y: 100)
        var click = GroupMention.Press(start: start, window: start, group: "grp")
        click.move(window: CGPoint(x: 102, y: 101))
        #expect(!click.dragging, "a jitter under the threshold is still a click")
        #expect(click.release(at: CGPoint(x: 102, y: 101), window: CGPoint(x: 102, y: 101)) == .group("grp"))

        var drag = GroupMention.Press(start: start, window: start, group: "grp")
        drag.move(window: CGPoint(x: 140, y: 130))
        drag.move(window: start)
        #expect(drag.release(at: start, window: start) == .marquee(CGRect(origin: start, size: .zero)), "once a drag, back at the start is still a marquee")

        var released = GroupMention.Press(start: start, window: start, group: "grp")
        #expect(released.release(at: CGPoint(x: 160, y: 80), window: CGPoint(x: 160, y: 80)) == .marquee(CGRect(x: 100, y: 80, width: 60, height: 20)),
                "a release far away with no drag events between is a drag")

        var bare = GroupMention.Press(start: start, window: start, group: nil)
        #expect(bare.release(at: start, window: start) == .nothing, "a click on bare canvas stages nothing")
    }

    @Test func nestedGroupsPickTheInnermostUnderThePointer() {
        let board = makeBoard()
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 0, y: 400, w: 200, h: 100))
        let inner = group([b.id], title: "Queue", on: board)
        let outer = group([a.id, inner.id], title: "Ingress", on: board)
        let regions = [outer, inner].map { GroupMention.Region(id: $0.id, frame: board.objects[$0.id]!.frame.rect) }
        let innerFrame = board.objects[inner.id]!.frame.rect, outerFrame = board.objects[outer.id]!.frame.rect
        #expect(outerFrame.contains(innerFrame))

        #expect(GroupMention.innermost(at: CGPoint(x: innerFrame.minX + 4, y: innerFrame.minY + 4), in: regions) == inner.id, "the inner group's title band")
        #expect(GroupMention.innermost(at: CGPoint(x: innerFrame.minX + 4, y: innerFrame.maxY - 4), in: regions) == inner.id, "the inner group's interior")
        #expect(GroupMention.innermost(at: CGPoint(x: outerFrame.minX + 4, y: outerFrame.minY + 4), in: regions) == outer.id, "the outer group's title band")
        #expect(GroupMention.innermost(at: CGPoint(x: outerFrame.maxX + 10, y: outerFrame.midY), in: regions) == nil)
        #expect(GroupMention.target(inner.id, on: board) == .group(objects: [b.id], name: "Queue"))
        #expect(GroupMention.target(outer.id, on: board) == .group(objects: [a.id, inner.id], name: "Ingress"))
    }

    @Test func aGroupMentionTogglesAndIsLabelledByItsTitle() throws {
        let board = makeBoard()
        let a = board.create(type: .note, props: .object(["markdown": "a"]))
        let b = board.create(type: .note, props: .object(["markdown": "b"]))
        let titled = group([a.id, b.id], title: "Ingress", on: board)
        let untitled = group([a.id, b.id], title: "", on: board)
        let target = try #require(GroupMention.target(titled.id, on: board))

        board.toggle(target)
        #expect(board.tray.map(\.label) == ["Ingress"])
        board.toggle(try #require(GroupMention.target(untitled.id, on: board)))
        #expect(board.tray.map(\.label) == ["Ingress", "2 objects"], "an untitled group is named by its size")
        board.toggle(target)
        #expect(board.tray.map(\.label) == ["2 objects"], "a second Hyper-click unstages it")
    }

    @Test func mentionCommandOnASelectedGroupMentionsTheGroup() {
        let board = makeBoard()
        let a = board.create(type: .note, props: .object(["markdown": "a"]))
        let term = board.create(type: .terminal, props: .object(["cwd": "/"]))
        let region = group([a.id, term.id], title: "Ingress", on: board)
        #expect(KeyboardMention.target(keyboardTile: nil, selection: [region.id], current: nil, on: board) == .group(objects: [a.id, term.id], name: "Ingress"))
    }

    @Test func aGroupMentionListsEachMemberAndTheArrowsAmongThem() async throws {
        let board = makeBoard()
        let file = root.appendingPathComponent("Sources/Webhook.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (1...20).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let note = board.create(type: .note, props: .object(["markdown": "# Webhooks\n\nVerifies the signature.\nThen queues it.\n"]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
        let code = board.create(type: .code, props: .object(["path": "Sources/Webhook.swift", "range": .object(["start": .number(3), "end": .number(5)])]), frame: Frame(x: 0, y: 300, w: 300, h: 200))
        let terminal = board.create(type: .terminal, props: .object(["cwd": "/", "name": "ingest worker"]), frame: Frame(x: 0, y: 600, w: 300, h: 200))
        let page = board.create(type: .browser, props: .object(["url": "http://localhost:3000/hooks", "title": "Hooks dashboard"]), frame: Frame(x: 0, y: 900, w: 300, h: 200))
        let outside = board.create(type: .note, props: .object(["markdown": "Delivery"]), frame: Frame(x: 1000, y: 0, w: 300, h: 200))
        let verifies = board.create(type: .arrow, props: ArrowSpec(from: .object(note.id), to: .object(code.id), relation: "calls", label: "verifies with").props)
        let runs = board.create(type: .arrow, props: ArrowSpec(from: .object(code.id), to: .object(terminal.id)).props)
        board.create(type: .arrow, props: ArrowSpec(from: .object(terminal.id), to: .object(outside.id)).props)
        let region = group([note.id, code.id, terminal.id, page.id], title: "Ingress", on: board)

        board.toggle(try #require(GroupMention.target(region.id, on: board)))
        let context = await board.drain().context
        #expect(context.contains("""
            [1] group "Ingress" of 4 objects · group \(region.id)
                - note \(note.id) "Webhooks"
                  Verifies the signature.
                  Then queues it.
                - code \(code.id) "Sources/Webhook.swift" · lines 3-5
                    2    line 2
                  > 3    line 3
                  > 4    line 4
                  > 5    line 5
                    6    line 6
                - terminal \(terminal.id) "ingest worker" · arrow → \(outside.id)
                - browser \(page.id) "Hooks dashboard" · http://localhost:3000/hooks
                arrows among them:
                  \(note.id) "Webhooks" → \(code.id) "Sources/Webhook.swift" · "verifies with" (calls) · arrow \(verifies.id)
                  \(code.id) "Sources/Webhook.swift" → \(terminal.id) "ingest worker" · arrow \(runs.id)
            """), "\(context)")
    }

    @Test func aBigGroupListsEveryMemberAndSaysWhatTextItLeftOut() async throws {
        let board = makeBoard()
        let notes = (0..<30).map { index in
            board.create(type: .note, props: .object(["markdown": .string((0..<10).map { "note \(index) line \($0)" }.joined(separator: "\n"))]))
        }
        let region = group(notes.map(\.id), title: "Atlas", on: board)
        board.toggle(try #require(GroupMention.target(region.id, on: board)))
        let lines = await board.drain().context.split(separator: "\n").map(String.init)
        let block = lines.drop { !$0.hasPrefix("[1] group") }.prefix { !$0.hasPrefix("Read more") }
        #expect(block.contains("      note 0 line 1"), "the first members keep their text")
        #expect(block.count <= 122, "\(block.count) lines")
        #expect(block.last?.hasPrefix("    (left out to keep this short: the text of ") == true, "\(block.last ?? "")")
    }
}
