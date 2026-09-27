import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Author marks: which objects name the agent terminal that made them, by what name, and how much
/// of a title bar the mark takes.
struct AuthorMarkTests {
    func object(_ id: ObjectID, _ type: ObjectType, by actor: Actor, _ props: [String: JSONValue] = [:]) -> CanvasObject {
        CanvasObject(id: id, type: type, frame: Frame(x: 0, y: 0, w: 100, h: 100), z: 0, createdBy: actor, createdAt: Date(), props: .object(props))
    }

    @Test func agentObjectsNameTheirTerminalAndNothingElseDoes() {
        let named = object("named", .terminal, by: .user, ["name": .string("B ssrSafe"), "agent": .object(["kind": .string("omp")])])
        let unnamed = object("unnamed", .terminal, by: .user, ["agent": .object(["kind": .string("codex")])])
        let objects = Dictionary(uniqueKeysWithValues: [
            named, unnamed,
            object("review", .note, by: .agent(tile: "named")),
            object("explainer", .html, by: .agent(tile: "unnamed")),
            object("lane", .group, by: .agent(tile: "named")),
            object("mine", .note, by: .user),
            object("follow", .code, by: .agent(tile: "named"), ["followOf": .string("named")]),
            object("shell", .terminal, by: .agent(tile: "named")),
            object("orphan", .note, by: .agent(tile: "closed")),
        ].map { ($0.id, $0) })
        func name(_ id: ObjectID, program: String? = nil) -> String? {
            AuthorMark.name(of: objects[id]!, in: objects) { _ in program }
        }
        #expect(name("review") == "B ssrSafe")
        #expect(name("review", program: "omp") == "B ssrSafe", "the terminal's name before its program")
        #expect(name("lane") == "B ssrSafe")
        #expect(name("explainer", program: "codex exec") == "codex exec", "no name: the program in its foreground")
        #expect(name("explainer") == "codex", "at the prompt: the agent kind")
        #expect(name("mine") == nil, "the user's objects carry no mark")
        #expect(name("follow") == nil, "a follow tile belongs visibly to its terminal")
        #expect(name("shell") == nil, "terminals carry none")
        #expect(name("orphan") == nil, "the author terminal is gone")
        #expect(AuthorMark.name(of: object("bare", .terminal, by: .user, ["name": .string("  ")]), program: nil) == "Terminal")
    }

    @Test func theMarkTruncatesBeforeTheTitleAndGoesInANarrowBar() {
        #expect(AuthorMark.width(natural: 60, title: 80, space: 300) == 60, "a short title leaves room for all of it")
        #expect(AuthorMark.width(natural: 250, title: 80, space: 300) == 212, "it takes what the title leaves")
        #expect(AuthorMark.width(natural: 200, title: 400, space: 300) == 105, "beside a long title it keeps 35% and truncates")
        #expect(AuthorMark.width(natural: 60, title: 400, space: 300) == 60)
        #expect(AuthorMark.width(natural: 60, title: 10, space: 150) == 0, "a narrow bar shows only the title")
    }
}
