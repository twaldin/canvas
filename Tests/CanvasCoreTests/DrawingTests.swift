import CoreGraphics
import Foundation
import Testing
import CanvasCore

struct ArrowRoutingTests {
    typealias G = DrawingGeometry
    let gap = DrawingGeometry.arrowGap

    @Test func sideBySideObjectsConnectFacingEdgesThroughTheirOverlap() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = CGRect(x: 400, y: 20, width: 200, height: 100)
        let route = G.route(from: .bound(.rect(a)), to: .bound(.rect(b)))
        // Vertical extents overlap on 20…100, so the arrow runs flat through y = 60.
        #expect(route.start == CGPoint(x: a.maxX + gap, y: 60))
        #expect(route.end == CGPoint(x: b.minX - gap, y: 60))
    }

    @Test func movingABoundObjectReroutesToTheNewNearestEdges() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let before = G.route(from: .bound(.rect(a)), to: .bound(.rect(CGRect(x: 400, y: 0, width: 200, height: 100))))
        let moved = CGRect(x: 50, y: 300, width: 200, height: 100)
        let after = G.route(from: .bound(.rect(a)), to: .bound(.rect(moved)))
        #expect(before.start.x == a.maxX + gap, "right edge while b is to the right")
        // Now stacked with horizontal overlap 50…200: bottom edge of a to top edge of b.
        #expect(after.start == CGPoint(x: 125, y: a.maxY + gap))
        #expect(after.end == CGPoint(x: 125, y: moved.minY - gap))
    }

    @Test func diagonalObjectsAimCenterToCenterAndStayOutsideBothOutlines() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 300, y: 250, width: 100, height: 100)
        let route = G.route(from: .bound(.rect(a)), to: .bound(.rect(b)))
        #expect(!a.contains(route.start) && !b.contains(route.start))
        #expect(!a.contains(route.end) && !b.contains(route.end))
        // Each tip sits `gap` beyond its outline.
        #expect(abs(G.distanceToSegment(route.start, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)) - gap) < 0.5
            || abs(G.distanceToSegment(route.start, CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)) - gap) < 0.5)
        #expect(route.start.x > a.midX && route.start.y > a.midY, "leaves from the corner facing b")
        #expect(route.end.x < b.midX && route.end.y < b.midY)
    }

    @Test func ellipseOutlinesAttachOnTheCurveNotTheBoundingBox() {
        let circle = CGRect(x: 0, y: 0, width: 100, height: 100)
        let route = G.route(from: .bound(.ellipse(circle)), to: .point(CGPoint(x: 300, y: 300)))
        let center = CGPoint(x: 50, y: 50)
        #expect(abs(hypot(route.start.x - center.x, route.start.y - center.y) - (50 + gap)) < 0.01)
        #expect(route.end == CGPoint(x: 300, y: 300), "free ends stay exactly where they were put")
    }
}

struct DrawingHitTests {
    typealias G = DrawingGeometry
    let frame = CGRect(x: 100, y: 100, width: 200, height: 120)

    @Test func unfilledRectHitsOnItsStrokeButPassesThroughItsInterior() {
        let rect = ShapeSpec(kind: .rect)
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 101), tolerance: 4))
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 305, y: 160), tolerance: 4), "just outside the edge, within tolerance")
        #expect(!G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4), "empty interior must not block tiles beneath")
        #expect(!G.hits(rect, frame: frame, at: CGPoint(x: 330, y: 160), tolerance: 4))
    }

    @Test func filledShapesHitInside() {
        #expect(G.hits(ShapeSpec(kind: .rect, fill: .semi), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        #expect(G.hits(ShapeSpec(kind: .ellipse, fill: .solid), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        // The ellipse's bounding-box corner is outside its fill.
        #expect(!G.hits(ShapeSpec(kind: .ellipse, fill: .solid), frame: frame, at: CGPoint(x: 110, y: 110), tolerance: 4))
    }

    @Test func unfilledEllipseHitsOnlyNearItsCurve() {
        let ellipse = ShapeSpec(kind: .ellipse)
        #expect(G.hits(ellipse, frame: frame, at: CGPoint(x: 300, y: 160), tolerance: 4), "right extreme of the curve")
        #expect(G.hits(ellipse, frame: frame, at: CGPoint(x: 200, y: 98), tolerance: 4), "top extreme, just outside")
        #expect(!G.hits(ellipse, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        #expect(!G.hits(ellipse, frame: frame, at: CGPoint(x: 105, y: 105), tolerance: 4), "bounding-box corner is empty space")
    }

    @Test func labelsAndTextHitAnywhereInTheirBounds() {
        let rect = ShapeSpec(kind: .rect, text: "auth path?")
        let label = CGRect(x: 160, y: 150, width: 80, height: 20)
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4, labelRect: label))
        #expect(G.hits(ShapeSpec(kind: .text, text: "note"), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
    }

    @Test func inkHitsAlongItsPathOnly() {
        let ink = ShapeSpec(kind: .ink, points: (0...20).map { InkPoint(x: Double($0) * 10, y: 0) })
        let inkFrame = CGRect(x: 100, y: 100, width: 200, height: 10)
        #expect(G.hits(ink, frame: inkFrame, at: CGPoint(x: 250, y: 104), tolerance: 4))
        #expect(!G.hits(ink, frame: inkFrame, at: CGPoint(x: 250, y: 130), tolerance: 4))
    }

    @Test func arrowsHitAlongTheShaft() {
        #expect(G.hitsArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), at: CGPoint(x: 50, y: 5), tolerance: 4))
        #expect(!G.hitsArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), at: CGPoint(x: 50, y: 20), tolerance: 4))
        #expect(!G.hitsArrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), at: CGPoint(x: 120, y: 0), tolerance: 4))
    }
}

struct InkOutlineTests {
    /// Shoelace area of an implicitly closed polygon.
    func area(_ polygon: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    @Test func singlePointBecomesARoundDot() {
        let outline = DrawingInk.outline([InkPoint(x: 10, y: 20)])
        #expect(outline.count >= 8)
        #expect(outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let box = bounds(outline)
        #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: 10, y: 20)))
        // Roughly a disc of the stroke's diameter, not a sliver.
        #expect(area(outline) > 0.3 * .pi * pow(DrawingGeometry.inkSize / 2, 2) * 0.5)
        #expect(box.width > 1 && box.height > 1)
    }

    @Test func longStrokeOutlineCoversItsPathWithVariableWidth() {
        let points = (0..<60).map { index in InkPoint(x: Double(index) * 4, y: sin(Double(index) / 6) * 30) }
        let outline = DrawingInk.outline(points)
        #expect(outline.count > points.count / 2)
        #expect(outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let box = bounds(outline).insetBy(dx: -0.5, dy: -0.5)
        #expect(points.allSatisfy { box.contains($0.point) }, "the outline must wrap the whole path")
        let pathLength = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // A band along the path: at least a thin ribbon, at most the full-pressure width.
        #expect(area(outline) > pathLength * DrawingGeometry.inkSize * 0.2)
        #expect(area(outline) < pathLength * DrawingGeometry.inkSize * 1.5)
    }

    @Test func realPressureWidensTheStroke() {
        let light = (0..<30).map { InkPoint(x: Double($0) * 5, y: 0, pressure: 0.1) }
        let heavy = (0..<30).map { InkPoint(x: Double($0) * 5, y: 0, pressure: 1) }
        #expect(area(DrawingInk.outline(heavy)) > area(DrawingInk.outline(light)) * 1.5)
    }

    @Test func twoPointStrokeIsNonDegenerate() {
        let outline = DrawingInk.outline([InkPoint(x: 0, y: 0), InkPoint(x: 40, y: 0)])
        #expect(area(outline) > 40 * DrawingGeometry.inkSize * 0.2)
    }
}

struct RoughStrokeTests {
    func endpoints(_ strokes: [DrawingRough.Stroke]) -> [CGPoint] {
        strokes.flatMap { [$0.start] + $0.curves.map(\.end) }
    }

    @Test func sameIdDrawsTheSameStrokesAndDifferentIdsDiffer() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 140)
        var first = DrawingRough.Random(seed: DrawingRough.seed("obj_A"))
        var again = DrawingRough.Random(seed: DrawingRough.seed("obj_A"))
        var other = DrawingRough.Random(seed: DrawingRough.seed("obj_B"))
        let a = DrawingRough.rectangle(rect, random: &first)
        #expect(a == DrawingRough.rectangle(rect, random: &again))
        #expect(a != DrawingRough.rectangle(rect, random: &other))
    }

    @Test func jitterStaysWithinTheHitAllowance() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 180)
        for id in ["obj_1", "obj_2", "obj_3", "obj_4"] {
            var random = DrawingRough.Random(seed: DrawingRough.seed(id))
            for point in endpoints(DrawingRough.rectangle(rect, random: &random)) {
                #expect(rect.insetBy(dx: -3, dy: -3).contains(point))
            }
            var ellipseRandom = DrawingRough.Random(seed: DrawingRough.seed(id))
            for point in endpoints(DrawingRough.ellipse(rect, random: &ellipseRandom)) {
                #expect(rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08).contains(point))
            }
        }
    }
}
