import Foundation
import Testing
import CanvasCore

/// Navigating code: which tile a navigation may re-aim, Back/Forward, Recent, and what undo says.
@MainActor
struct NavigationTargetTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-nav-\(UUID().uuidString)")
    let board: Board

    init() {
        board = Board(id: "brd_test", root: root)
        board.viewport = { Frame(x: 0, y: 0, w: 1600, h: 1000) }
    }

    func code(_ path: String, _ start: Int, at frame: Frame, caller: ObjectID? = nil, caption: String? = nil) -> CanvasObject {
        var props: [String: JSONValue] = ["path": .string(path), "range": .object(["start": .number(Double(start)), "end": .number(Double(start))])]
        if let caption { props["caption"] = .string(caption) }
        return board.create(type: .code, props: .object(props), frame: frame, caller: caller)
    }

    func range(_ id: ObjectID) throws -> Int? { try board.object(id).props["range"]?["start"]?.int }

    @Test func anAgentsCaptionedTileKeepsItsRangeAndANewTileOpens() throws {
        let agent = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 0, y: 0, w: 600, h: 400))
        let walkthrough = code("src/core.py", 903, at: Frame(x: 700, y: 0, w: 640, h: 446), caller: agent.id, caption: "7b · Context.invoke")
        let opened = board.openForNavigation(CodeAim(path: "src/core.py", range: LineRange(start: 2116, end: 2116)), from: nil)
        #expect(opened.created && opened.id != walkthrough.id)
        #expect(try range(walkthrough.id) == 903)
        #expect(try board.object(walkthrough.id).props["caption"]?.string == "7b · Context.invoke")
    }

    @Test func openAllExcerptsAndFollowTilesAreNotNavigationSurface() throws {
        let excerpt = code("src/core.py", 2076, at: Frame(x: 0, y: 0, w: 640, h: 220), caption: "Reference 1 of 6 · L2076")
        let grouped = code("src/core.py", 2098, at: Frame(x: 0, y: 300, w: 640, h: 220))
        board.create(type: .group, props: .object(["members": .array([.string(grouped.id)]), "title": .string("refs")]))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "def main():\n    pass\n".write(to: root.appendingPathComponent("src/core.py"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 900, y: 0, w: 600, h: 400))
        let follow = try #require(try board.follow(tile: terminal.id, path: "src/core.py", range: nil, action: "read"))
        let plain = code("src/core.py", 1, at: Frame(x: 700, y: 500, w: 640, h: 446))
        #expect(!board.isNavigationSurface(excerpt.id))
        #expect(!board.isNavigationSurface(grouped.id))
        #expect(!board.isNavigationSurface(follow.id))
        #expect(board.isNavigationSurface(plain.id))

        let opened = board.openForNavigation(CodeAim(path: "src/core.py", range: LineRange(start: 2141, end: 2141)), from: nil)
        #expect(opened.id == plain.id && !opened.created)
        #expect(try range(excerpt.id) == 2076 && range(grouped.id) == 2098)
    }

    @Test func aTileAnAgentEditedIsNoLongerNavigationSurface() throws {
        let agent = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 0, y: 600, w: 600, h: 400))
        let mine = code("a.ts", 1, at: Frame(x: 0, y: 0, w: 640, h: 446))
        try board.update(mine.id, frame: Frame(x: 20, y: 0, w: 640, h: 446), caller: agent.id)
        #expect(!board.isNavigationSurface(mine.id))
        try board.update(mine.id, frame: Frame(x: 40, y: 0, w: 640, h: 446))
        #expect(board.isNavigationSurface(mine.id), "the user took it back")
    }

    @Test func aReaimIsNavigationNotAnUndoStep() throws {
        let plain = code("src/core.py", 10, at: Frame(x: 100, y: 100, w: 640, h: 446))
        let steps = board.history.undoSteps.count
        let opened = board.openForNavigation(CodeAim(path: "src/core.py", range: LineRange(start: 50, end: 52)), from: nil)
        #expect(opened.reaim == CodeReaim(tile: plain.id, before: CodeAim(path: "src/core.py", range: LineRange(start: 10, end: 10)),
                                          after: CodeAim(path: "src/core.py", range: LineRange(start: 50, end: 52))))
        #expect(try range(plain.id) == 50)
        #expect(board.history.undoSteps.count == steps)
    }

    @Test func aFarTileIsNeverReaimedAndTheNearestInViewIs() throws {
        let far = code("src/core.py", 10, at: Frame(x: 20_000, y: 0, w: 640, h: 446))
        let source = board.create(type: .note, props: .object(["markdown": .string("x")]), frame: Frame(x: 900, y: 500, w: 280, h: 200))
        let nearer = code("src/core.py", 20, at: Frame(x: 800, y: 0, w: 640, h: 446))
        let farther = code("src/core.py", 30, at: Frame(x: 0, y: 0, w: 640, h: 446))
        let opened = board.openForNavigation(CodeAim(path: "src/core.py", range: LineRange(start: 99, end: 99)), from: source.id)
        #expect(opened.id == nearer.id)
        #expect(try range(far.id) == 10 && range(farther.id) == 30)

        board.viewport = { Frame(x: 19_000, y: 0, w: 400, h: 400) }
        let away = board.openForNavigation(CodeAim(path: "src/core.py", range: LineRange(start: 5, end: 5)), from: nil)
        #expect(away.created, "the only core.py tile in reach is out of view")
    }

    @Test func aChangesTileReusesItsPreviewUntilTheUserKeepsIt() throws {
        let changes = board.create(type: .changes, props: .object(["base": .string("HEAD")]), frame: Frame(x: 0, y: 0, w: 820, h: 620))
        let first = board.openForNavigation(CodeAim(path: "a.py", range: LineRange(start: 3, end: 3)), from: changes.id, preview: true, extra: ["diffBase": .string("HEAD")])
        #expect(first.created)
        #expect(try board.object(first.id).props["diffBase"]?.string == "HEAD")
        let second = board.openForNavigation(CodeAim(path: "b.py", range: LineRange(start: 8, end: 8)), from: changes.id, preview: true)
        #expect(second.id == first.id && second.reaim?.before.path == "a.py", "another file re-aims the preview")
        board.keepCode(first.id)
        let third = board.openForNavigation(CodeAim(path: "c.py", range: LineRange(start: 1, end: 1)), from: changes.id, preview: true)
        #expect(third.created && third.id != first.id)
    }

    @Test func restoringAnAimOnlyWhileTheTileStillShowsWhereNavigationPutIt() throws {
        let plain = code("a.ts", 10, at: Frame(x: 0, y: 0, w: 640, h: 446))
        let reaim = try #require(board.openForNavigation(CodeAim(path: "a.ts", range: LineRange(start: 40, end: 40)), from: nil).reaim)
        #expect(board.restoreAim(reaim.inverted))
        #expect(try range(plain.id) == 10)
        #expect(board.restoreAim(reaim))
        #expect(try range(plain.id) == 40)

        _ = board.openForNavigation(CodeAim(path: "a.ts", range: LineRange(start: 70, end: 70)), from: nil)
        #expect(!board.restoreAim(reaim.inverted), "aimed elsewhere since")
        #expect(try range(plain.id) == 70)
    }

    @Test func reviewChangesFindsTheTileForTheSameRootAndBase() throws {
        let subset = board.create(type: .changes, props: .object(["base": .string("HEAD"), "paths": .array([.string("src")])]), frame: Frame(x: 0, y: 0, w: 820, h: 620))
        #expect(board.changesTile(root: nil, base: "HEAD") == nil, "a tile of some paths isn't the whole review")
        let head = board.create(type: .changes, props: .object(["base": .string("HEAD")]), frame: Frame(x: 30_000, y: 0, w: 820, h: 620))
        _ = board.create(type: .changes, props: .object(["base": .string("merge-base")]), frame: Frame(x: 900, y: 0, w: 820, h: 620))
        _ = board.create(type: .changes, props: .object(["base": .string("HEAD"), "root": .string("../wt")]), frame: Frame(x: 900, y: 700, w: 820, h: 620))
        #expect(board.changesTile(root: nil, base: "HEAD") == head.id)
        #expect(board.changesTile(root: root.path, base: "HEAD") == head.id, "the board root spelled out")
        _ = subset
    }
}

struct NavigationHistoryTests {
    func view(_ x: Double) -> Viewport { Viewport(rect: Frame(x: x, y: 0, w: 1000, h: 800), zoom: 1) }
    let reaim = CodeReaim(tile: "obj_a", before: CodeAim(path: "a.py", range: LineRange(start: 2116, end: 2116)),
                          after: CodeAim(path: "a.py", range: LineRange(start: 1987, end: 1987)))

    @Test func backReturnsViewAndTileAndForwardGoesAgain() {
        var history = NavigationHistory()
        history.record(.init(from: view(0), to: view(500), reaim: reaim))
        history.record(.init(from: view(500), to: view(900), reaim: nil))

        let back = history.goBack()
        #expect(back?.viewport == view(500) && back?.reaim == nil)
        let back2 = history.goBack()
        #expect(back2?.viewport == view(0) && back2?.reaim == reaim.inverted)
        #expect(history.goBack() == nil)

        let forward = history.goForward()
        #expect(forward?.viewport == view(500) && forward?.reaim == reaim)
        #expect(history.canGoForward)
    }

    @Test func aNewNavigationAfterBackDropsForward() {
        var history = NavigationHistory()
        history.record(.init(from: view(0), to: view(500), reaim: nil))
        _ = history.goBack()
        history.record(.init(from: view(0), to: view(300), reaim: nil))
        #expect(!history.canGoForward)
        #expect(history.goBack()?.viewport == view(0))
    }

    @Test func aNavigationThatChangedNothingIsNoStep() {
        var history = NavigationHistory()
        history.record(.init(from: view(0), to: view(0.4), reaim: nil))
        history.record(.init(from: view(0), to: view(0), reaim: CodeReaim(tile: "obj_a", before: reaim.before, after: reaim.before)))
        #expect(!history.canGoBack)
        history.record(.init(from: view(0), to: view(0), reaim: reaim))
        #expect(history.canGoBack, "a re-aim in place is a step")
    }

    @Test func theOldestStepsGoPastTheLimit() {
        var history = NavigationHistory(limit: 3)
        for step in 0..<5 { history.record(.init(from: view(Double(step) * 100), to: view(Double(step) * 100 + 50), reaim: nil)) }
        #expect(history.back.map(\.from.rect.x) == [200, 300, 400])
    }

    @Test func recentLocationsAreNewestFirstEachLineOnce() {
        var recent = RecentLocations(limit: 3)
        recent.visit(CodeAim(path: "a.py", range: LineRange(start: 10, end: 10)))
        recent.visit(CodeAim(path: "b.py", range: LineRange(start: 5, end: 9), symbol: "run"))
        recent.visit(CodeAim(path: "a.py", range: LineRange(start: 10, end: 14)))
        #expect(recent.locations.map(\.label) == ["a.py:10-14", "b.py:5-9"])
        #expect(recent.locations[1].symbol == nil)
        recent.visit(CodeAim(path: "a.py", range: LineRange(start: 99, end: 99)))
        recent.visit(CodeAim(path: "c.py", range: nil))
        #expect(recent.locations.map(\.label) == ["c.py", "a.py:99", "a.py:10-14"])
    }
}

struct DeclarationPatternTests {
    func names(_ line: String, _ ext: String = "ts") -> [String] { TextNavigation.declarations(inLine: line, pathExtension: ext).map(\.name) }

    @Test func declarationsAcrossLanguages() {
        #expect(names("export const ogImage = `${SITE}/og.png`;") == ["ogImage"])
        #expect(names("export async function injectMetaIntoSpa(html: string) {") == ["injectMetaIntoSpa"])
        #expect(names("export default class Store<T> extends Base {") == ["Store"])
        #expect(names("export interface Props {") == ["Props"])
        #expect(names("type Handler = (req: Request) => void") == ["Handler"])
        #expect(names("  const fetchPrices = async (id: string) => {") == ["fetchPrices"])
        #expect(names("  handler: function (event) {") == ["handler"])
        #expect(names("  async resolve(ctx: Context): Promise<void> {") == ["resolve"])
        #expect(names("    def resolve_command(self, ctx, args):", "py") == ["resolve_command"])
        #expect(names("class Group(MultiCommand):", "py") == ["Group"])
        #expect(names("DEFAULT_TIMEOUT: int = 30", "py") == ["DEFAULT_TIMEOUT"])
        #expect(names("func (s *Server) Serve(l net.Listener) error {", "go") == ["Serve"])
        #expect(names("type Config struct {", "go") == ["Config"])
        #expect(names("pub const fn new(size: usize) -> Self {", "rs") == ["new"])
        #expect(names("pub struct Walker<'a> {", "rs") == ["Walker"])
        #expect(names("    public func navigate(_ action: KeyboardNavigation) -> Bool {", "swift") == ["navigate"])
    }

    @Test func usesCommentsAndImportsDeclareNothing() {
        #expect(names("  if (ready) {").isEmpty)
        #expect(names("  const html = injectMetaIntoSpa(raw);") == ["html"])
        #expect(names("  return injectMetaIntoSpa(raw)").isEmpty)
        #expect(names("// function injectMetaIntoSpa is deprecated").isEmpty)
        #expect(names("import { ogImage } from './seo'").isEmpty)
        #expect(names("import type Store from './store'").isEmpty)
        #expect(names("x = compute()", "ts").isEmpty, "a module-level assignment declares only in Python")
    }

    @Test func declarationsRankThisFileThenItsLanguage() {
        let matches = [
            TextNavigation.Match(path: "docs/api.md", line: 3, column: 1, text: "const ogImage = 1"),
            TextNavigation.Match(path: "client/seo.tsx", line: 7, column: 5, text: "export const ogImage = url"),
            TextNavigation.Match(path: "server/app.ts", line: 40, column: 9, text: "  res.send(ogImage)"),
            TextNavigation.Match(path: "server/seo.ts", line: 12, column: 14, text: "export const ogImage = `x`"),
        ]
        let ranked = TextNavigation.rankDeclarations(of: "ogImage", among: matches, preferring: "server/seo.ts")
        #expect(ranked.map(\.path) == ["server/seo.ts", "client/seo.tsx", "docs/api.md"])
        #expect(ranked[0].column == 14, "the declared name's column")
    }

    @Test func parsesGitGrepOutput() {
        let output = "server/seo.ts\u{0}551\u{0}14\u{0}  ogImage: string,\nweird:name.ts\u{0}2\u{0}1\u{0}a:b\n"
        #expect(TextNavigation.parse(output) == [
            TextNavigation.Match(path: "server/seo.ts", line: 551, column: 14, text: "  ogImage: string,"),
            TextNavigation.Match(path: "weird:name.ts", line: 2, column: 1, text: "a:b"),
        ])
    }

    @Test func wordMatchesSearchTrackedAndUntrackedButNotIgnoredFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-grep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "export const ogImage = 1\nconst ogImageUrl = 2\n".write(to: root.appendingPathComponent("src/seo.ts"), atomically: true, encoding: .utf8)
        try "use(ogImage)\n".write(to: root.appendingPathComponent("src/new.ts"), atomically: true, encoding: .utf8)
        try "ogImage\n".write(to: root.appendingPathComponent("src/built.ts"), atomically: true, encoding: .utf8)
        try "src/built.ts\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await GitRunner.shared.run(["init", "-q"], in: root)
        _ = try await GitRunner.shared.run(["add", "src/seo.ts", ".gitignore"], in: root)
        let found = try await TextNavigation.wordMatches("ogImage", in: root)
        #expect(found.matches.map { "\($0.path):\($0.line):\($0.column)" } == ["src/new.ts:1:5", "src/seo.ts:1:14"])
        #expect(!found.truncated)
        let declared = try await TextNavigation.declarations(of: "ogImage", in: root, preferring: "src/new.ts")
        #expect(declared.map(\.path) == ["src/seo.ts"])
    }

    @Test func outlineWithoutAServerListsTypesMembersAndTopLevelNotLocals() {
        let text = """
        import { x } from './x'
        export const SITE = 'https://example.com'
        export interface Props { title: string }
        export class Seo {
          render(props: Props) {
            const helper = () => 1
            return helper()
          }
        }
        export function injectMetaIntoSpa(html: string) {
          function inner() {}
          return html
        }
        """
        let outline = TextNavigation.outline(of: text, path: "server/seo.ts")
        #expect(outline.map(\.name) == ["SITE", "Props", "Seo", "render", "injectMetaIntoSpa"])
        #expect(outline.map(\.depth) == [0, 0, 0, 1, 0])
        #expect(outline.map(\.line) == [2, 3, 4, 5, 10])
        #expect(outline[2].kind == "class" && outline[3].kind == "method")
    }
}

@MainActor
struct UndoSummaryTests {
    let board = Board(id: "brd_test", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    @Test func anAgentsBatchIsNamedWithItsAuthor() throws {
        let agent = board.create(type: .terminal, props: .object(["agent": .object(["kind": .string("omp")])]), frame: Frame(x: 0, y: 0, w: 600, h: 400))
        try board.atomically {
            var tiles: [ObjectID] = []
            for index in 0..<3 {
                tiles.append(board.create(type: .code, props: .object(["path": .string("a.py")]), frame: Frame(x: Double(index) * 700, y: 600, w: 640, h: 400), caller: agent.id).id)
            }
            board.create(type: .arrow, props: .object(["from": .object(["object": .string(tiles[0])]), "to": .object(["object": .string(tiles[1])])]), caller: agent.id)
            board.create(type: .group, props: .object(["members": .array(tiles.map(JSONValue.string)), "title": .string("Steps")]), caller: agent.id)
        }
        let step = try #require(board.nextUndo)
        #expect(board.authorName(step.author) == "omp")
        #expect(step.summary == "created 3 code tiles, an arrow, a group")
        #expect(step.title == "Create 3 Code Tiles, Arrow, Group")
        #expect(board.undo())
        #expect(board.nextRedo?.summary == "created 3 code tiles, an arrow, a group")
    }

    @Test func theUsersOwnStepHasNoAuthorName() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]), frame: Frame(x: 0, y: 0, w: 280, h: 200))
        try board.update(note.id, frame: Frame(x: 50, y: 0, w: 280, h: 200))
        let step = try #require(board.nextUndo)
        #expect(board.authorName(step.author) == nil)
        #expect(step.title == "Move Note" && step.summary == "moved a note")
    }
}

struct RevealKeepingTests {
    /// Confirm N4: a changes tile and the code tile opened beside it that together just fit the
    /// view both show whole, rather than the diff's edge going off-screen for the padding.
    @Test func bothTilesShowWholeWhenTheyJustFit() {
        let changes = CGRect(x: -420, y: 0, width: 820, height: 600)
        let code = CGRect(x: 424, y: 0, width: 640, height: 446)
        let jump = Layout.Jump(zoom: 1, origin: CGPoint(x: -440, y: -20))
        let clear = CGRect(x: 0, y: 0, width: 1492, height: 800)
        let moved = Layout.reveal(code, keeping: changes, from: jump, clear: clear, padding: 20)
        let shown = CGRect(origin: moved.origin, size: clear.size)
        #expect(shown.contains(changes) && shown.contains(code))
    }
}
