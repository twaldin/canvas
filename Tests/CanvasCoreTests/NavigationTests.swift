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
        var props: [String: JSONValue] = ["path": .string(path), "range": LineRange(start: start, end: start).json]
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

    @Test func aStopAlreadyShowingTheLinesIsGoneToWhereverItIs() throws {
        // Presenter P1: a walkthrough's overview links to its own stops, far out of view.
        let agent = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 0, y: 0, w: 600, h: 400))
        var props: [String: JSONValue] = ["path": .string("src/broker.ts"), "range": .object(["start": .number(3399), "end": .number(3428)]),
                                          "caption": .string("5 · Promotion")]
        let stop = board.create(type: .code, props: .object(props), frame: Frame(x: 9000, y: 0, w: 900, h: 600), caller: agent.id)
        let overview = board.create(type: .html, props: .object(["html": .string("<p>")]), frame: Frame(x: 0, y: 500, w: 1200, h: 600))
        let count = board.objects.count

        let exact = board.openForNavigation(CodeAim(path: "src/broker.ts", range: LineRange(start: 3399, end: 3428)), from: overview.id)
        #expect(exact == CodeOpened(id: stop.id, created: false, reaim: nil, existing: true))
        let inside = board.openForNavigation(CodeAim(path: "src/broker.ts", range: LineRange(start: 3426, end: 3426)), from: overview.id)
        #expect(inside.id == stop.id && inside.existing, "a captioned stop whose range holds the line shows it")
        #expect(board.objects.count == count, "no duplicate tile")
        #expect(try range(stop.id) == 3399)

        let past = board.openForNavigation(CodeAim(path: "src/broker.ts", range: LineRange(start: 3420, end: 3440)), from: overview.id)
        #expect(past.created, "lines running past the stop's range open beside the source")

        props["caption"] = nil
        let plain = board.create(type: .code, props: .object(props.merging(["range": .object(["start": .number(10), "end": .number(90)])]) { $1 }),
                                 frame: Frame(x: 9000, y: 900, w: 900, h: 600))
        let uncaptioned = board.openForNavigation(CodeAim(path: "src/broker.ts", range: LineRange(start: 50, end: 50)), from: overview.id)
        #expect(uncaptioned.id != plain.id, "an uncaptioned tile holding the line elsewhere is not a stop")
    }

    @Test func anExactMatchInViewWinsAndFollowTilesNeverCount() throws {
        let far = code("a.py", 7, at: Frame(x: 20_000, y: 0, w: 640, h: 446))
        #expect(board.tileShowing(CodeAim(path: "a.py", range: LineRange(start: 7, end: 7)), near: nil) == far.id)
        let near = code("a.py", 7, at: Frame(x: 100, y: 100, w: 640, h: 446))
        #expect(board.tileShowing(CodeAim(path: "a.py", range: LineRange(start: 7, end: 7)), near: nil) == near.id)

        let terminal = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 900, y: 0, w: 600, h: 400))
        board.create(type: .code, props: .object(["path": .string("b.py"), "range": .object(["start": .number(3), "end": .number(3)]),
                                                  "followOf": .string(terminal.id)]), frame: Frame(x: 0, y: 0, w: 640, h: 446))
        #expect(board.tileShowing(CodeAim(path: "b.py", range: LineRange(start: 3, end: 3)), near: nil) == nil)
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
        _ = board.create(type: .changes, props: .object(["base": .string("HEAD"), "paths": .array([.string("src")])]), frame: Frame(x: 0, y: 0, w: 820, h: 620))
        #expect(board.changesTile(root: nil, base: "HEAD") == nil, "a tile of some paths isn't the whole review")
        let head = board.create(type: .changes, props: .object(["base": .string("HEAD")]), frame: Frame(x: 30_000, y: 0, w: 820, h: 620))
        _ = board.create(type: .changes, props: .object(["base": .string("merge-base")]), frame: Frame(x: 900, y: 0, w: 820, h: 620))
        _ = board.create(type: .changes, props: .object(["base": .string("HEAD"), "root": .string("../wt")]), frame: Frame(x: 900, y: 700, w: 820, h: 620))
        #expect(board.changesTile(root: nil, base: "HEAD") == head.id)
        #expect(board.changesTile(root: root.path, base: "HEAD") == head.id, "the board root spelled out")
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

    @Test func aStepIsABackEntryThatSelectsTheStopItCameFrom() {
        var history = NavigationHistory()
        history.record(.init(from: view(0), to: view(0), reaim: nil, selectedBefore: "obj_1", selectedAfter: "obj_2"))
        history.record(.init(from: view(0), to: view(900), reaim: nil, selectedBefore: "obj_2", selectedAfter: "obj_3"))
        let back = history.goBack()
        #expect(back?.viewport == view(0) && back?.selection == "obj_2")
        #expect(history.goBack()?.selection == "obj_1", "a stop already in view is still a step")
        #expect(history.goForward()?.selection == "obj_2")
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

    /// The rust study: Go to Definition on `print_error!(…)` found no declaration.
    @Test func rustMacrosAndStaticsAreDeclarations() {
        let macro = TextNavigation.declarations(inLine: "macro_rules! print_error {", pathExtension: "rs")
        #expect(macro.map { "\($0.name) \($0.kind) \($0.column)" } == ["print_error macro 13"])
        #expect(names("pub static mut COUNTER: AtomicUsize = AtomicUsize::new(0);", "rs") == ["COUNTER"])
        #expect(names("pub(crate) static DEFAULT_MAX: usize = 8;", "rs") == ["DEFAULT_MAX"])
        #expect(names("  static helper(x) {", "ts") == ["helper"], "elsewhere static is a modifier")
        #expect(names("        print_error!(\"{}\", err);", "rs").isEmpty)
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

    /// The rust study: Outline listed `impl IntoIterator for Batch` as "Batch · impl", like the
    /// inherent `impl Batch`, and had no macros, consts, statics or type aliases.
    @Test func rustOutlineNamesTraitImplsAndItems() {
        let text = """
        const MAX: usize = 8;
        static mut SEEN: usize = 0;
        pub type Result<T> = std::result::Result<T, Error>;
        macro_rules! print_error {
            ($($arg:tt)*) => { eprintln!($($arg)*) };
        }
        impl Batch {
            const LIMIT: usize = 4;
            fn new() -> Self { Batch }
        }
        impl IntoIterator for Batch {
            fn into_iter(self) -> Self::IntoIter { todo!() }
        }
        fn main() {
            const LOCAL: u8 = 1;
        }
        """
        let outline = TextNavigation.outline(of: text, path: "src/walk.rs")
        #expect(outline.map(\.name) == ["MAX", "SEEN", "Result", "print_error", "Batch", "LIMIT", "new", "IntoIterator for Batch", "into_iter", "main"])
        #expect(outline.map(\.kind) == ["constant", "static", "type", "macro", "impl", "constant", "function", "impl", "function", "function"])
        #expect(outline.map(\.depth) == [0, 0, 0, 0, 0, 1, 1, 0, 1, 0])
        // Members still qualify by the type, so mentions read `Batch.into_iter`.
        let symbols = Syntax.analyze(text, language: .rust).symbols
        #expect(symbols.first { $0.lines.lowerBound == 12 }?.name == "Batch.into_iter")
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
        #expect(board.undo())
    }

    @Test func theUsersOwnStepHasNoAuthorName() throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]), frame: Frame(x: 0, y: 0, w: 280, h: 200))
        try board.update(note.id, frame: Frame(x: 50, y: 0, w: 280, h: 200))
        let step = try #require(board.nextUndo)
        #expect(board.authorName(step.author) == nil)
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

struct PresentTests {
    let clear = CGRect(x: 0, y: 60, width: 1280, height: 700)
    let jump = Layout.Jump(zoom: 1, origin: CGPoint(x: 0, y: 0))

    func shown(_ jump: Layout.Jump) -> CGRect {
        CGRect(x: jump.origin.x + clear.minX / jump.zoom, y: jump.origin.y + clear.minY / jump.zoom, width: clear.width / jump.zoom, height: clear.height / jump.zoom)
    }

    /// Presenter P2: the next stop is centered like a slide, not pulled flush to the edge.
    @Test func aStopOutOfViewIsCenteredAndOneInViewStays() {
        let inView = CGRect(x: 100, y: 200, width: 600, height: 400)
        #expect(Layout.present(inView, from: jump, clear: clear, padding: 20, zoom: 0.1...1) == jump)

        let next = CGRect(x: 1100, y: 200, width: 800, height: 500)
        let moved = Layout.present(next, from: jump, clear: clear, padding: 20, zoom: 0.1...1)
        #expect(moved.zoom == 1)
        #expect(abs(shown(moved).midX - next.midX) < 0.5 && abs(shown(moved).midY - next.midY) < 0.5)
    }

    @Test func aStopLargerThanTheViewIsFittedNeverZoomedIn() {
        let big = CGRect(x: 3000, y: 0, width: 2400, height: 900)
        let moved = Layout.present(big, from: jump, clear: clear, padding: 20, zoom: 0.1...1)
        #expect(moved.zoom < 1 && shown(moved).contains(big))

        let out = Layout.Jump(zoom: 0.25, origin: .zero)
        let small = CGRect(x: 9000, y: 0, width: 300, height: 200)
        #expect(Layout.present(small, from: out, clear: clear, padding: 20, zoom: 0.1...1).zoom == 0.25, "the zoom the presenter chose stays")
    }

    /// Persona study B8 (codexapp): stepping a walkthrough from the ⌘9 overview (41%) only moved
    /// the selection; each stop is now framed readably, and a readable zoom is kept.
    @Test func aWalkthroughStopIsFramedReadablyFromAnOverview() {
        let overview = Layout.Jump(zoom: 0.41, origin: .zero)
        let stop = CGRect(x: 400, y: 300, width: 500, height: 300)
        #expect(Layout.present(stop, from: overview, clear: clear, padding: 20, zoom: 0.1...1) == overview, "in view: a plain step doesn't move")
        let framed = Layout.presentStop(stop, from: overview, clear: clear, padding: 20, fitPadding: 60, zoom: 0.1...1, readable: 0.5)
        #expect(framed.zoom == 1 && shown(framed).contains(stop))

        let readable = Layout.Jump(zoom: 0.67, origin: .zero)
        let next = CGRect(x: 2400, y: 300, width: 500, height: 300)
        let stepped = Layout.presentStop(next, from: readable, clear: clear, padding: 20, fitPadding: 60, zoom: 0.1...1, readable: 0.5)
        #expect(stepped.zoom == 0.67 && shown(stepped).contains(next), "the presenter's readable zoom stays")
    }
}

@MainActor
struct StepOrderTests {
    let board = Board(id: "brd_test", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func tile(_ x: Double, _ y: Double = 0) -> ObjectID {
        board.create(type: .note, props: .object(["markdown": .string("stop")]), frame: Frame(x: x, y: y, w: 300, h: 200)).id
    }

    func arrow(_ from: ObjectID, _ to: ObjectID, _ relation: String = "next_step") {
        board.create(type: .arrow, props: .object(["from": .object(["object": .string(from)]), "to": .object(["object": .string(to)]), "relation": .string(relation)]))
    }

    /// Presenter P3: the authored order wins over the layout (stop 2 sits left of stop 1).
    @Test func stepsFollowNextStepArrowsAndSayWhereTheSequenceEnds() {
        let one = tile(1000), two = tile(0, 800), three = tile(2000), loose = tile(3000)
        arrow(one, two)
        arrow(two, three)
        arrow(three, loose, "calls")
        #expect(StepOrder.step(from: one, forward: true, in: board.objects) == .to(two))
        #expect(StepOrder.step(from: two, forward: true, in: board.objects) == .to(three))
        #expect(StepOrder.step(from: three, forward: false, in: board.objects) == .to(two))
        #expect(StepOrder.step(from: three, forward: true, in: board.objects) == .end)
        #expect(StepOrder.step(from: one, forward: false, in: board.objects) == .end)
        #expect(StepOrder.step(from: loose, forward: true, in: board.objects) == .none, "other relations are geometry's")
    }

    @Test func aBranchGoesToTheStopFirstInReadingOrder() throws {
        let start = tile(0), lower = tile(400, 600), upper = tile(800, 0)
        arrow(start, lower)
        arrow(start, upper)
        #expect(StepOrder.step(from: start, forward: true, in: board.objects) == .to(upper))
        try board.delete(upper)
        #expect(StepOrder.step(from: start, forward: true, in: board.objects) == .to(lower), "a deleted stop drops out")
    }

    func group(_ members: [ObjectID]) -> ObjectID {
        board.create(type: .group, props: .object(["members": .array(members.map(JSONValue.string))])).id
    }

    /// Persona study B8 (staff, codexapp): ⌥⌘→ after clicking an agent's "Start here" marker on
    /// the walkthrough's group, or with nothing selected, went to an unrelated tile.
    @Test func aWalkthroughStartsAtItsFirstStopFromItsGroupOrFromNothing() {
        let unrelated = tile(0, 0)
        // Stop 1 sits right of stop 2: the first stop is the one no arrow steps to, not the leftmost.
        let one = tile(1400, 1000), two = tile(1000, 1000), three = tile(1800, 1000)
        arrow(one, two)
        arrow(two, three)
        let walkthrough = group([one, two, three])
        let far = tile(9000, 9000), farNext = tile(9400, 9000)
        arrow(far, farNext)

        #expect(StepOrder.start(from: walkthrough, center: .zero, in: board.objects) == one)
        #expect(StepOrder.start(from: group([group([three, two, one])]), center: .zero, in: board.objects) == one, "nested groups count")
        #expect(StepOrder.start(from: nil, center: CGPoint(x: 1500, y: 1100), in: board.objects) == one, "the walkthrough in view")
        #expect(StepOrder.start(from: nil, center: CGPoint(x: 8000, y: 8000), in: board.objects) == far, "the one nearer the view")
        #expect(StepOrder.start(from: unrelated, center: .zero, in: board.objects) == nil, "a selected tile steps from itself")
        #expect(StepOrder.start(from: group([unrelated]), center: .zero, in: board.objects) == nil, "a group without stops is geometry's")
    }

    @Test func aLoopStartsAtItsStopFirstInReadingOrder() {
        let a = tile(800, 0), b = tile(0, 400)
        arrow(a, b)
        arrow(b, a)
        #expect(StepOrder.start(from: nil, center: .zero, in: board.objects) == a)
    }
}
