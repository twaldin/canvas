import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// Attention pills: bubbles beside marked objects and edge pills for offscreen ones never cover
/// each other, stay between the toolbar and the tray, and cover other tiles only when they must.
struct PillLayoutTests {
    /// A 1400×900 window whose toolbar and tray leave y 72…842 clear.
    let clear = CGRect(x: 0, y: 72, width: 1400, height: 770)
    let bubble = CGSize(width: 300, height: 28)

    func marker(_ id: String, _ target: CGRect, width: CGFloat = 300, titleBar: CGFloat = 26) -> PillLayout.Marker {
        .init(id: id, target: target, ringInset: 10, size: CGSize(width: width, height: 28), titleBar: titleBar)
    }

    func assertApart(_ rects: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(!a.intersects(b), "\(a) covers \(b)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func aBubbleSitsAboveItsObjectWhenThatCoversNothing() {
        let tile = CGRect(x: 200, y: 300, width: 640, height: 400)
        let placed = PillLayout.place(markers: [marker("a", tile)], edges: [], tiles: [("a", tile)], clear: clear)
        #expect(placed.bubbles["a"] == CGRect(x: 190, y: 256, width: 300, height: 28), "above the ring, left-aligned with it")
    }

    @Test func aBubbleMovesOntoItsOwnTitleBarRatherThanCoverTheTileAboveIt() {
        // Zoomed out: two tiles stacked 12 pt apart on screen; a bubble above the lower one would
        // sit on the upper one's last rows.
        let upper = CGRect(x: 200, y: 100, width: 400, height: 300)
        let lower = CGRect(x: 200, y: 412, width: 400, height: 300)
        let placed = PillLayout.place(markers: [marker("lower", lower, titleBar: 9)], edges: [], tiles: [("upper", upper), ("lower", lower)], clear: clear)
        let rect = try! #require(placed.bubbles["lower"])
        #expect(!rect.intersects(upper))
        #expect(rect.minY == lower.minY, "on the tile's own top edge, its title bar")
        #expect(lower.contains(rect))
    }

    @Test func bubblesOfNeighbouringObjectsNeverOverlap() {
        // Shot 15 of the omp study: two marked tiles side by side at fit zoom, long messages.
        let left = CGRect(x: 400, y: 400, width: 380, height: 260)
        let right = CGRect(x: 800, y: 400, width: 300, height: 260)
        let below = CGRect(x: 400, y: 680, width: 380, height: 150)
        let markers = [marker("left", left, width: 480), marker("right", right, width: 480), marker("below", below, width: 480)]
        let tiles = [("left", left), ("right", right), ("below", below)].map { (id: $0.0, rect: $0.1) }
        let placed = PillLayout.place(markers: markers, edges: [], tiles: tiles, clear: clear)
        #expect(placed.bubbles.count == 3)
        assertApart(Array(placed.bubbles.values))
        for rect in placed.bubbles.values { #expect(clear.contains(rect)) }
    }

    @Test func pillsStayBetweenTheToolbarAndTheTray() {
        // A marked tile whose top is under the toolbar, one reaching under the tray.
        let high = CGRect(x: 100, y: 20, width: 500, height: 300)
        let low = CGRect(x: 700, y: 700, width: 500, height: 400)
        let placed = PillLayout.place(markers: [marker("high", high), marker("low", low)], edges: [.init(id: "off", target: CGPoint(x: 700, y: 3000), size: CGSize(width: 200, height: 32))],
                                      tiles: [(id: "high", rect: high), (id: "low", rect: low)], clear: clear)
        for rect in Array(placed.bubbles.values) + Array(placed.edges.values) { #expect(clear.contains(rect), "\(rect) is under the chrome") }
        #expect(placed.edges["off"]?.maxY == clear.maxY, "an object below the view: its pill on the bottom edge")
    }

    @Test func edgePillsSlideAlongTheirEdgeOffEachOtherAndOffBubbles() {
        // Three objects far to the right at nearly the same height, and a marked tile whose
        // bubble (y 436…464) sits on the right edge where their pills would go.
        let tile = CGRect(x: 1050, y: 480, width: 330, height: 200)
        let edges = (0..<3).map { PillLayout.Edge(id: "e\($0)", target: CGPoint(x: 5000, y: 440 + CGFloat($0) * 4), size: CGSize(width: 220, height: 32)) }
        let placed = PillLayout.place(markers: [marker("m", tile, width: 300)], edges: edges, tiles: [(id: "m", rect: tile)], clear: clear)
        let all = Array(placed.bubbles.values) + Array(placed.edges.values)
        #expect(all.count == 4)
        assertApart(all)
        for id in ["e0", "e1", "e2"] {
            let rect = try! #require(placed.edges[id])
            #expect(rect.maxX == clear.maxX - PillLayout.edgeMargin, "\(id) stays on the right edge")
        }
    }

    @Test func aBubbleStaysAtItsObjectRatherThanStrayToSpareASliverOfANeighbour() {
        // Zoomed to ~48%: a terminal just above the marked tile and a neighbour 10 pt to its
        // right, so neither spot is clean; a marked note far right leaves free room beside its
        // bubble that the first tile's bubble must not jump to.
        let terminal = CGRect(x: 100, y: 137, width: 475, height: 295)
        let tile = CGRect(x: 100, y: 470, width: 304, height: 212)
        let neighbour = CGRect(x: 414, y: 470, width: 238, height: 212)
        let note = CGRect(x: 1002, y: 327, width: 133, height: 43)
        let tiles = [("t", terminal), ("tile", tile), ("n", neighbour), ("note", note)].map { (id: $0.0, rect: $0.1) }
        let placed = PillLayout.place(markers: [marker("tile", tile, width: 324, titleBar: 12), marker("note", note, width: 160)], edges: [], tiles: tiles, clear: clear)
        let rect = try! #require(placed.bubbles["tile"])
        #expect(rect.minX < tile.midX && rect.minY == tile.minY, "\(rect): on the tile's title bar, hiding a sliver of its neighbour")
    }

    @Test func aLongMessageTruncatesToTheObjectsWidth() {
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 300) == 300)
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 60) == PillLayout.minBubbleWidth, "a tiny object still gets a readable bubble")
        #expect(PillLayout.bubbleWidth(natural: 900, ringWidth: 2000) == PillLayout.maxBubbleWidth)
        #expect(PillLayout.bubbleWidth(natural: 120, ringWidth: 2000) == 120, "a short message keeps its own width")
    }
}
