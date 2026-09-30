import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// A board's `avoid` arrows routed together (`ConnectorRouter`): ports, tracks, labels, flow,
/// stability, and what `layout.check` reports about arrows.
@MainActor
final class RoutingTests {
    private var serial = 0

    private func tile(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CanvasObject {
        serial += 1
        return CanvasObject(id: String(format: "obj_t%03d", serial), type: .note, frame: Frame(x: x, y: y, w: w, h: h), z: Double(serial),
                            createdBy: .user, createdAt: Date(timeIntervalSince1970: 0), props: .object(["markdown": .string("x")]))
    }

    private func arrow(_ a: CanvasObject, _ b: CanvasObject, _ label: String? = nil, route: String = "avoid") -> CanvasObject {
        serial += 1
        var props: [String: JSONValue] = ["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(b.id)]), "route": .string(route)]
        if let label { props["label"] = .string(label) }
        return CanvasObject(id: String(format: "obj_a%03d", serial), type: .arrow, frame: Frame(x: 0, y: 0, w: 1, h: 1), z: Double(serial),
                            createdBy: .user, createdAt: Date(timeIntervalSince1970: 0), props: .object(props))
    }

    private func line(from a: CGPoint, to b: CGPoint) -> CanvasObject {
        serial += 1
        return CanvasObject(id: String(format: "obj_a%03d", serial), type: .arrow, frame: Frame(x: 0, y: 0, w: 1, h: 1), z: Double(serial),
                            createdBy: .user, createdAt: Date(timeIntervalSince1970: 0),
                            props: .object(["from": .object(["point": [.number(a.x), .number(a.y)]]), "to": .object(["point": [.number(b.x), .number(b.y)]])]))
    }

    private func group(_ members: [CanvasObject], flow: String? = nil) -> CanvasObject {
        serial += 1
        var props: [String: JSONValue] = ["members": .array(members.map { .string($0.id) }), "title": .string("Lane")]
        if let flow { props["flow"] = .string(flow) }
        let spec = GroupSpec(.object(props))!
        return CanvasObject(id: String(format: "obj_g%03d", serial), type: .group, frame: Frame(spec.frame(around: members.map(\.frame.rect))!), z: 0,
                            createdBy: .user, createdAt: Date(timeIntervalSince1970: 0), props: .object(props))
    }

    /// Label chips sized as the drawing layer sizes them.
    private func geometry(_ objects: [CanvasObject]) -> BoardGeometry {
        var labels: [ObjectID: CGSize] = [:]
        for object in objects where object.type == .arrow {
            if let spec = ArrowSpec(object.props), let label = DrawingStyle.arrowLabel(spec) { labels[object.id] = label.size }
        }
        return BoardGeometry(objects: Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) }), labelSizes: labels)
    }

    /// Eight sources in a column, one target to their right.
    private func fanIn(labels: Bool = false) -> (sources: [CanvasObject], target: CanvasObject, arrows: [CanvasObject]) {
        let sources = (0..<8).map { tile(0, Double($0) * 150) }
        let target = tile(700, 500)
        let arrows = sources.enumerated().map { arrow($1, target, labels ? "input \($0 + 1)" : nil) }
        return (sources, target, arrows)
    }

    /// The smallest distance between parallel, overlapping segments of different arrows.
    private func narrowestTrack(_ paths: [ObjectID: [CGPoint]]) -> CGFloat {
        var narrowest = CGFloat.infinity
        let segments = paths.flatMap { id, path in zip(path, path.dropFirst()).map { (id, $0, $1) } }
        for (i, s) in segments.enumerated() {
            for t in segments[(i + 1)...] where s.0 != t.0 {
                let sVertical = s.1.x == s.2.x, tVertical = t.1.x == t.2.x
                guard sVertical == tVertical else { continue }
                let (sLow, sHigh) = sVertical ? (min(s.1.y, s.2.y), max(s.1.y, s.2.y)) : (min(s.1.x, s.2.x), max(s.1.x, s.2.x))
                let (tLow, tHigh) = tVertical ? (min(t.1.y, t.2.y), max(t.1.y, t.2.y)) : (min(t.1.x, t.2.x), max(t.1.x, t.2.x))
                guard min(sHigh, tHigh) - max(sLow, tLow) > 1 else { continue }
                narrowest = min(narrowest, sVertical ? abs(s.1.x - t.1.x) : abs(s.1.y - t.1.y))
            }
        }
        return narrowest
    }

    private func atlas() throws -> [CanvasObject] {
        struct Stored: Decodable {
            var id: String, type: ObjectType, frame: Frame, z: Double, props: JSONValue
        }
        struct Fixture: Decodable { var objects: [Stored] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Fixtures/atlas-board.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).objects.map {
            CanvasObject(id: $0.id, type: $0.type, frame: $0.frame, z: $0.z, createdBy: .user, createdAt: Date(timeIntervalSince1970: 0), props: $0.props)
        }
    }

    @Test func arrowsSharingASideGetDistinctPortsInTheOrderOfTheirSources() {
        let fan = fanIn()
        let paths = geometry(fan.sources + [fan.target] + fan.arrows).routes()
        let ends = fan.arrows.map { paths[$0.id]!.last! }
        let side = fan.target.frame.rect.minX - DrawingGeometry.arrowGap
        #expect(ends.allSatisfy { abs($0.x - side) < 0.5 }, "all enter the side facing them: \(ends)")
        let ys = ends.map(\.y)
        #expect(ys == ys.sorted(), "ports run in the order of the sources, so the arrows don't cross at the side: \(ys)")
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $1 - $0 >= 8 }, "distinct ports: \(ys)")
    }

    @Test func collinearRunsSpreadIntoSeparateTracksWithoutCrossing() {
        let fan = fanIn()
        let paths = geometry(fan.sources + [fan.target] + fan.arrows).routes()
        #expect(ConnectorRouter.overlaps(paths).isEmpty, "\(ConnectorRouter.overlaps(paths))")
        #expect(narrowestTrack(paths) >= 8)
        #expect(ConnectorRouter.intersections(paths).isEmpty, "a fan-in needs no crossing: \(ConnectorRouter.intersections(paths))")
        // Fanning out is the mirror image.
        let source = tile(0, 500)
        let targets = (0..<8).map { tile(700, Double($0) * 150) }
        let out = geometry([source] + targets + targets.map { arrow(source, $0) }).routes()
        #expect(ConnectorRouter.overlaps(out).isEmpty && ConnectorRouter.intersections(out).isEmpty)
    }

    @Test func labelsKeepOffTilesTitlesArrowsAndEachOther() {
        let fan = fanIn(labels: true)
        let lane = group(fan.sources)
        let objects = fan.sources + [fan.target, lane] + fan.arrows
        let routing = geometry(objects).routing()
        let labels = routing.labels
        #expect(labels.count == fan.arrows.count)
        let tiles = objects.filter(BoardGeometry.blocksRoutes).map(\.frame.rect)
        let title = ConnectorRouter.Region(id: lane.id, frame: lane.frame.rect, members: []).title
        for (id, label) in labels {
            let inner = label.rect.insetBy(dx: 0.5, dy: 0.5)
            #expect(!tiles.contains { $0.intersects(inner) } && !title.intersects(inner), "\(id) on a tile or the title")
            #expect(!labels.contains { $0.key != id && $0.value.rect.intersects(inner) }, "\(id) on another label")
            #expect(!routing.paths.contains { $0.key != id && DrawingGeometry.path($0.value, crosses: inner) }, "\(id) on another arrow")
        }
        let check = geometry(objects).layoutCheck()
        #expect(check.labelOverlaps.isEmpty, "\(check.labelOverlaps)")
    }

    @Test func movingAnUnrelatedTileLeavesARouteAlone() {
        let a = tile(0, 0), b = tile(600, 200), wall = tile(300, -100, 100, 400)
        let near = arrow(a, b, "near")
        let c = tile(3000, 0), d = tile(3600, 300)
        let far = arrow(c, d, "far")
        let objects = [a, b, wall, near, c, d, far]
        let before = geometry(objects).routing()
        var moved = d
        moved.frame = Frame(x: 3640, y: 360, w: 200, h: 100)
        let after = geometry([a, b, wall, near, c, moved, far]).routing()
        #expect(after.paths[near.id] == before.paths[near.id] && after.labels[near.id] == before.labels[near.id])
        #expect(after.paths[far.id] != before.paths[far.id], "the moved tile's own arrow follows it")
    }

    @Test func flowPicksTheSidesArrowsLeaveAndEnterWithoutUTurns() {
        let a = tile(0, 0), b = tile(400, 300)
        let link = arrow(a, b)
        func path(_ flow: String) -> [CGPoint] { geometry([a, b, group([a, b], flow: flow), link]).routes()[link.id]! }
        let down = path("down")
        #expect(abs(down[0].y - (a.frame.rect.maxY + DrawingGeometry.arrowGap)) < 0.5, "leaves the downstream (bottom) side: \(down)")
        #expect(abs(down.last!.y - (b.frame.rect.minY - DrawingGeometry.arrowGap)) < 0.5, "enters the upstream (top) side: \(down)")
        let right = path("right")
        #expect(abs(right[0].x - (a.frame.rect.maxX + DrawingGeometry.arrowGap)) < 0.5 && abs(right.last!.x - (b.frame.rect.minX - DrawingGeometry.arrowGap)) < 0.5,
                "leaves the right side and enters the left: \(right)")
        // Side by side, a downward flow still goes straight across rather than looping.
        let c = tile(400, 0)
        let across = arrow(a, c)
        let straight = geometry([a, c, group([a, c], flow: "down"), across]).routes()[across.id]!
        #expect(zip(straight, straight.dropFirst()).allSatisfy { $1.x >= $0.x - 0.5 }, "monotone: \(straight)")
    }

    @Test func aLineBoundEndKeepsItsRowWhileOthersSpread() {
        let code = CGRect(x: 0, y: 0, width: 300, height: 400)
        let targets = [CGRect(x: 700, y: 0, width: 200, height: 100), CGRect(x: 700, y: 300, width: 200, height: 100)]
        let router = ConnectorRouter(connectors: [
            .init(id: "row", from: .row(code, y: 130), to: .bound(.rect(targets[0])), fromObject: "code", toObject: "t0"),
            .init(id: "whole", from: .bound(.rect(code)), to: .bound(.rect(targets[1])), fromObject: "code", toObject: "t1"),
        ], obstacles: [.init(id: "code", rect: code), .init(id: "t0", rect: targets[0]), .init(id: "t1", rect: targets[1])])
        let paths = router.route().paths
        #expect(paths["row"]!.first!.y == 130 && paths["row"]!.first!.x > code.maxX)
        #expect(paths["whole"]!.first! != paths["row"]!.first!)
    }

    @Test func routingIsDeterministic() throws {
        let objects = try atlas()
        let first = geometry(objects).routing()
        let again = geometry(objects.reversed()).routing()
        #expect(first.paths == again.paths && first.labels == again.labels)
    }

    @Test func theAtlasBoardRoutesWithoutSharedRunsArrowsThroughTilesOrCoveredLabels() throws {
        let check = geometry(try atlas()).layoutCheck()
        #expect(check.arrowOverlaps.isEmpty, "\(check.arrowOverlaps)")
        #expect(check.crossings.isEmpty, "\(check.crossings)")
        #expect(check.labelOverlaps.isEmpty, "no label on a tile, title, label, or line: \(check.labelOverlaps.map { ($0.label, $0.overlaps, $0.lines) })")
    }

    @Test func layoutCheckReportsArrowsOnTopOfOrCrossingEachOther() {
        let under = line(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 400, y: 100))
        let over = line(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 600, y: 100))
        let across = line(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 300))
        let check = geometry([under, over, across]).layoutCheck()
        let overlap = check.arrowOverlaps.first { Set($0.arrows) == [under.id, over.id] }
        #expect(overlap.map { abs($0.length - 200) < 1 } == true, "\(check.arrowOverlaps)")
        #expect(check.arrowIntersections.contains { Set($0.arrows) == [under.id, across.id] && $0.count == 1 })
        #expect(!check.arrowIntersections.contains { Set($0.arrows) == [over.id, across.id] })
        #expect(geometry([under, over, across]).layoutCheck(scope: [over.id]).arrowIntersections.isEmpty, "scoped to what's involved")
    }
}
