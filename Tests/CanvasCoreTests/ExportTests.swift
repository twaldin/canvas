import Foundation
import Testing
import CanvasCore

/// Exports: tidy file names, save sheets that never start in the board's repo, and pictures of a
/// selection that keep whole diagrams (groups, the arrows between their tiles).
struct ExportTests {
    @Test func separatorsInATitleReadAsDashes() {
        // Auditor F2: "Findings report: trade-up-bot top 5" saved as "Findings report  trade-up-bot top 5".
        #expect(ExportFile.name("Findings report: trade-up-bot top 5", ext: "html") == "Findings report - trade-up-bot top 5.html")
        #expect(ExportFile.name("src/app/page.tsx:10-20", ext: "png") == "src - app - page.tsx - 10-20.png")
        #expect(ExportFile.name("a :/ b\tc\n", ext: "png") == "a - b c.png", "runs of separators and spaces collapse")
    }

    @Test func aNameNeverStartsHiddenOrEndsInASeparator() {
        #expect(ExportFile.name(".env: values", ext: "png") == "env - values.png")
        #expect(ExportFile.name("Report:", ext: "png") == "Report.png")
        #expect(ExportFile.name(" / : ", ext: "png") == "Canvas selection.png", "nothing left: the fallback")
        #expect(ExportFile.name(nil, ext: "png") == "Canvas selection.png")
        let long = ExportFile.name(String(repeating: "word ", count: 40), ext: "png")
        #expect(long.count <= ExportFile.maxNameLength + 4 && !long.contains(" .png"))
    }

    @Test func aSaveSheetStartsInTheLastFolderUsedButNeverInTheBoard() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let reports = URL(fileURLWithPath: "/Users/me/Reports")
        let all: (URL) -> Bool = { _ in true }
        #expect(ExportFile.directory(lastUsed: nil, boardRoot: root, downloads: downloads, exists: all) == downloads)
        #expect(ExportFile.directory(lastUsed: reports, boardRoot: root, downloads: downloads, exists: all) == reports)
        #expect(ExportFile.directory(lastUsed: root, boardRoot: root, downloads: downloads, exists: all) == downloads, "the board's own directory")
        #expect(ExportFile.directory(lastUsed: root.appendingPathComponent("out"), boardRoot: root, downloads: downloads, exists: all) == downloads, "inside the board")
        #expect(ExportFile.directory(lastUsed: URL(fileURLWithPath: "/tmp/repo-exports"), boardRoot: root, downloads: downloads, exists: all).path == "/tmp/repo-exports",
                "a sibling whose name starts like the board's")
        #expect(ExportFile.directory(lastUsed: reports, boardRoot: root, downloads: downloads, exists: { _ in false }) == downloads, "a folder since deleted")
    }

    @Test func aMarqueeAroundGroupsSelectsThemAndTheArrowsBetweenThem() {
        // Auditor F3: four groups of code tiles joined by arrows; one arrow's route bends outside
        // the marquee, another leads to a tile outside it.
        let groups = [
            SelectionScope.Group(id: "g1", members: ["a", "b"], enclosed: true),
            SelectionScope.Group(id: "g2", members: ["c"], enclosed: true),
            SelectionScope.Group(id: "far", members: ["x"], enclosed: false),
        ]
        let arrows = [
            SelectionScope.Arrow(id: "a→c", from: "a", to: "c"),
            SelectionScope.Arrow(id: "g1→g2", from: "g1", to: "g2"),
            SelectionScope.Arrow(id: "c→x", from: "c", to: "x"),
            SelectionScope.Arrow(id: "loose", from: "a", to: nil),
        ]
        let selected = SelectionScope.marquee(enclosed: ["a", "b", "c"], groups: groups, arrows: arrows)
        #expect(selected == ["a", "b", "c", "g1", "g2", "a→c", "g1→g2"])
    }

    @Test func aMarqueeOverPartOfAGroupLeavesTheGroupOut() {
        let groups = [SelectionScope.Group(id: "g", members: ["a", "b"], enclosed: false)]
        let arrows = [SelectionScope.Arrow(id: "a→b", from: "a", to: "b")]
        #expect(SelectionScope.marquee(enclosed: ["a"], groups: groups, arrows: arrows) == ["a"])
    }

    @Test func anExportTakesTheGroupsWhoseMembersAreAllSelected() {
        let groups = [
            SelectionScope.Group(id: "inner", members: ["a", "b"]),
            SelectionScope.Group(id: "outer", members: ["inner", "c"]),
            SelectionScope.Group(id: "other", members: ["a", "z"]),
        ]
        #expect(SelectionScope.export(selection: ["a", "b", "c"], groups: groups) == ["a", "b", "c", "inner", "outer"])
        #expect(SelectionScope.export(selection: ["a"], groups: groups) == ["a"])
    }
}
