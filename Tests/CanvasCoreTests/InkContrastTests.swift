import CoreGraphics
import Testing
import CanvasCore

/// The default ink reads on whatever it's drawn over (confirm study N6: "Black" drew white in
/// dark mode, invisible over a white web page, in Copy as Image and renders too).
struct InkContrastTests {
    let darkCanvas = 0.01
    let lightCanvas = 0.9
    let white = 1.0
    let page = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func overAWhitePageInDarkModeTheInkIsDark() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 80)
        #expect(InkContrast.ink(for: box, over: [.init(rect: page, luminance: white)], canvas: darkCanvas) == .dark)
    }

    @Test func overTheBareCanvasTheInkFollowsIt() {
        let box = CGRect(x: 1000, y: 1000, width: 200, height: 80)
        #expect(InkContrast.ink(for: box, over: [.init(rect: page, luminance: white)], canvas: darkCanvas) == .light)
        #expect(InkContrast.ink(for: box, over: [], canvas: lightCanvas) == .dark)
    }

    @Test func overADarkPageInLightModeTheInkIsLight() {
        let box = CGRect(x: 100, y: 100, width: 200, height: 80)
        #expect(InkContrast.ink(for: box, over: [.init(rect: page, luminance: 0.02)], canvas: lightCanvas) == .light)
    }

    @Test func theTopmostSurfaceDecides() {
        // A dark terminal lying on top of most of a white page, the box drawn over both.
        let terminal = CGRect(x: 0, y: 0, width: 800, height: 500)
        let box = CGRect(x: 100, y: 100, width: 200, height: 300)
        let surfaces: [InkContrast.Surface] = [.init(rect: page, luminance: white), .init(rect: terminal, luminance: 0.02)]
        #expect(InkContrast.ink(for: box, over: surfaces, canvas: darkCanvas) == .light)
        #expect(InkContrast.ink(for: box, over: surfaces.reversed(), canvas: darkCanvas) == .dark)
    }

    @Test func aDrawingMostlyOverThePageReadsOnThePage() {
        // A rectangle around a heading near the page's right edge, a sliver of it on the canvas.
        let box = CGRect(x: 640, y: 40, width: 200, height: 60)
        #expect(InkContrast.ink(for: box, over: [.init(rect: page, luminance: white)], canvas: darkCanvas) == .dark)
    }

    @Test func aMidGreyPageTakesDarkInk() {
        // Past the contrast crossover (≈0.18), dark text contrasts more than white.
        #expect(InkContrast.ink(for: CGRect(x: 10, y: 10, width: 50, height: 50), over: [.init(rect: page, luminance: 0.3)], canvas: darkCanvas) == .dark)
        #expect(InkContrast.ink(for: CGRect(x: 10, y: 10, width: 50, height: 50), over: [.init(rect: page, luminance: 0.1)], canvas: lightCanvas) == .light)
    }

    @Test func luminanceOfSRGBColors() {
        #expect(InkContrast.luminance(red: 1, green: 1, blue: 1) == 1)
        #expect(InkContrast.luminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(InkContrast.luminance(red: 0.5, green: 0.5, blue: 0.5) - 0.214) < 0.001)
    }

    @MainActor @Test func explicitColorsStayAsChosen() {
        #expect(DrawingStyle.isDefaultInk(nil))
        #expect(DrawingStyle.isDefaultInk("black"), "the palette's Black is the default ink")
        #expect(DrawingStyle.isDefaultInk("not-a-color"), "an unknown name draws in the default ink")
        #expect(!DrawingStyle.isDefaultInk("blue"))
        #expect(!DrawingStyle.isDefaultInk("#000000"), "an explicit hex black stays black")
        #expect(!DrawingStyle.isDefaultInk("ffffff"))
    }
}
