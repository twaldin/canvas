import Foundation
import Testing
import CanvasCore

/// The canvas ↔ pixel mapping `view.render` reports, which agents use instead of pixel math.
struct RenderMathTests {
    func object(_ type: ObjectType, _ frame: Frame) -> CanvasObject {
        CanvasObject(id: "obj_x", type: type, frame: frame, z: 1, createdBy: .user, createdAt: Date(), props: .object([:]))
    }

    /// Screen positions (points) of the visible dots (opacity above 1%) along one axis, from
    /// canvas 0 up to `extent` units, with their opacity.
    func dots(scale: Double, extent: Double = 640) -> [Double: Double] {
        let (spacing, fade) = RenderMath.gridLevel(scale: scale)
        var dots: [Double: Double] = [:]
        for step in stride(from: 0, through: extent, by: spacing / 2) {
            let coarse = step.truncatingRemainder(dividingBy: spacing) == 0
            if coarse || fade > 0.01 { dots[(step * scale * 1000).rounded() / 1000] = coarse ? 1 : fade }
        }
        return dots
    }

    @Test func zoomingAcrossAGridDoublingKeepsTheSameDots() {
        // Just above 0.4 the 40-unit grid is coarse; just below, the 80-unit grid is coarse and
        // the 40-unit midpoints must be (all but) fully shown, so the same dots stay on screen.
        for (above, below) in [(0.4001, 0.3999), (0.2001, 0.1999)] {
            let before = dots(scale: above), after = dots(scale: below)
            #expect(before.count == after.count)
            #expect(after.values.allSatisfy { $0 > 0.99 })
            for (position, _) in before { #expect(after.keys.contains { abs($0 - position * below / above) < 0.01 }) }
        }
    }

    @Test func finerDotsFadeOutGraduallyAsTheGridShrinks() {
        // Between doublings the midpoints fade from shown to gone, never jumping.
        let fades = stride(from: 0.399, through: 0.2, by: -0.01).map { RenderMath.gridLevel(scale: $0) }
        #expect(fades.allSatisfy { $0.spacing == 80 })
        #expect(zip(fades, fades.dropFirst()).allSatisfy { $0.fade >= $1.fade && $0.fade - $1.fade < 0.1 })
        #expect(fades.first!.fade > 0.99 && fades.last!.fade < 0.01)
        #expect(RenderMath.gridLevel(scale: 1).fade == 0 && RenderMath.gridLevel(scale: 1).spacing == 40)
    }

    @Test func pixelRectsScaleFromTheCanvasRectOrigin() {
        let canvas = Frame(x: 100, y: 200, w: 400, h: 300)
        let size = RenderMath.pixelSize(canvas, scale: 2)
        #expect(size.width == 800 && size.height == 600)
        #expect(RenderMath.pixelRect(Frame(x: 150, y: 250, w: 100, h: 50), in: canvas, scale: 2) == Frame(x: 100, y: 100, w: 200, h: 100))
        // Fractional canvas positions round outward so the rect covers every pixel the object touches.
        #expect(RenderMath.pixelRect(Frame(x: 100.3, y: 200.3, w: 10, h: 10), in: canvas, scale: 1) == Frame(x: 0, y: 0, w: 11, h: 11))
    }

    @Test func pixelRectsAreClippedToTheImage() {
        let canvas = Frame(x: 0, y: 0, w: 100, h: 100)
        #expect(RenderMath.pixelRect(Frame(x: -50, y: 80, w: 100, h: 100), in: canvas, scale: 1) == Frame(x: 0, y: 80, w: 50, h: 20))
        #expect(RenderMath.pixelRect(Frame(x: 200, y: 0, w: 10, h: 10), in: canvas, scale: 1).w == 0)
    }

    @Test func largeRegionsRenderAtAScaleWithinTheBudget() {
        let huge = Frame(x: 0, y: 0, w: 10_000, h: 10_000)
        let scale = RenderMath.fittedScale(2, for: huge)
        #expect(scale < 2)
        let size = RenderMath.pixelSize(huge, scale: scale)
        #expect(Double(size.width * size.height) <= RenderMath.pixelBudget * 1.001)
        #expect(RenderMath.fittedScale(2, for: Frame(x: 0, y: 0, w: 800, h: 600)) == 2, "small regions keep the requested scale")
    }

    @Test func overflowIsContentBeyondTheBody() {
        let body = CGSize(width: 280, height: 240)
        #expect(RenderMath.overflow(content: CGSize(width: 300, height: 500), body: body) == CGSize(width: 20, height: 260))
        #expect(RenderMath.overflow(content: CGSize(width: 200, height: 240.4), body: body) == nil, "fits; sub-point differences are layout noise")
        #expect(RenderMath.overflow(content: CGSize(width: 280, height: 100), body: body) == nil)
    }

    @Test func fullContentExtendsTheOutlineBelowAndRight() {
        let outline = Frame(x: 0, y: 0, w: 280, h: 266)
        let body = CGSize(width: 280, height: 240)
        #expect(RenderMath.extended(outline, body: body, content: CGSize(width: 280, height: 900)) == Frame(x: 0, y: 0, w: 280, h: 926))
        #expect(RenderMath.extended(outline, body: body, content: CGSize(width: 100, height: 100)) == outline, "never shrinks")
        #expect(RenderMath.extended(outline, body: body, content: CGSize(width: 280, height: 1e9)).h == RenderMath.maxContentExtent + 26)
    }

    @Test func snappedRectsCoverTheTargetOnWholePoints() {
        #expect(RenderMath.snapped(Frame(x: 10.5, y: -3.2, w: 100, h: 50), padding: 8) == Frame(x: 2, y: -12, w: 117, h: 67))
    }

    @Test func outputExtensionPicksTheFormat() {
        #expect(ImageFormat(path: "/tmp/a.PNG") == .png)
        #expect(ImageFormat(path: "/tmp/a.jpg") == .jpeg)
        #expect(ImageFormat(path: "/tmp/a.webp") == nil)
    }
}
