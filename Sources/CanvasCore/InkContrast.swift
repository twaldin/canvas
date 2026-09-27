import CoreGraphics
import Foundation

/// The default ink ("black", or no color at all) reads on whatever it's drawn over: dark over a
/// light surface (a white web page, a light image, a light terminal theme), light over a dark one
/// (the dark canvas, a dark page). Explicit colors are drawn as chosen. The screen, Copy as
/// Image, and `view.render` all decide the same way, so a mark the agent is told about is one
/// the user can see.
public enum InkContrast {
    public enum Ink: Equatable, Sendable {
        case dark, light
    }

    /// Something under a drawing: a tile's rect and the relative luminance (0 black … 1 white)
    /// of what it shows.
    public struct Surface: Equatable, Sendable {
        public var rect: CGRect
        public var luminance: Double

        public init(rect: CGRect, luminance: Double) {
            self.rect = rect
            self.luminance = luminance
        }
    }

    /// Below this relative luminance light ink contrasts more than dark ink (WCAG contrast
    /// ratios against black and white cross at ≈0.179).
    public static let crossover = 0.179

    /// Samples per side of the grid laid over a drawing's rect.
    static let samples = 5

    /// The ink for a drawing whose rect is `rect`, over `surfaces` (bottom to top, the canvas's
    /// own luminance `canvas` wherever none is): the one most of the drawing reads on, judged
    /// at a grid of points over the rect, each against the topmost surface there. A tie goes to
    /// the ink of the average luminance.
    public static func ink(for rect: CGRect, over surfaces: [Surface], canvas: Double) -> Ink {
        var darkVotes = 0
        var total = 0.0
        let n = samples
        for row in 0..<n {
            for column in 0..<n {
                let point = CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(n),
                                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(n))
                let luminance = surfaces.last { $0.rect.contains(point) }?.luminance ?? canvas
                total += luminance
                if luminance > crossover { darkVotes += 1 }
            }
        }
        let count = n * n
        if darkVotes * 2 == count { return total / Double(count) > crossover ? .dark : .light }
        return darkVotes * 2 > count ? .dark : .light
    }

    /// Relative luminance of an sRGB color (components 0…1).
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
