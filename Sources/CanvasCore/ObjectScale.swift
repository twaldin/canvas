import Foundation

/// `props.scale` of tiles and text shapes: the object's whole drawing magnified inside its frame
/// (a tile's title bar and content, a text shape's font). A tile's content lays out in its
/// natural frame, the frame divided by the scale, so setting only `scale` zooms the content in
/// place; scaling by hand (⌥-drag a corner, the Scale menu) changes frame and scale together,
/// so what the object shows stays laid out the same, just bigger or smaller.
public enum ObjectScale {
    public static let range: ClosedRange<Double> = 0.25...8
    /// The Scale menu's choices; its Actual Size item sets 1.
    public static let presets: [Double] = [0.5, 0.75, 1.25, 1.5, 2]

    /// The scale Object › Scale › Bigger (`bigger`) or Smaller steps to from `scale`: the next of
    /// the menu's levels (the presets and 1) past it; nil past the last level that way.
    public static func step(from scale: Double, bigger: Bool) -> Double? {
        let levels = (presets + [1]).sorted()
        return bigger ? levels.first { $0 > scale + 0.001 } : levels.last { $0 < scale - 0.001 }
    }

    /// `props.scale` clamped to `range`; 1 when absent or not a positive number.
    public static func of(_ props: JSONValue) -> Double {
        guard let value = props["scale"]?.number, value.isFinite, value > 0 else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether objects of this kind take `props.scale`: tiles and text shapes.
    public static func applies(to type: ObjectType, props: JSONValue) -> Bool {
        RenderMath.isTile(type) || (type == .shape && props["kind"]?.string == ShapeSpec.Kind.text.rawValue)
    }

    /// `frame` resized so its content keeps its layout at `scale` after being laid out at `from`:
    /// the natural size times the new scale, top-left corner fixed.
    public static func rescaled(_ frame: Frame, from: Double, to scale: Double) -> Frame {
        Frame(x: frame.x, y: frame.y, w: frame.w / from * scale, h: frame.h / from * scale)
    }
}

extension CanvasObject {
    /// `props.scale` for tiles and text shapes; 1 for everything else.
    public var scale: Double { ObjectScale.applies(to: type, props: props) ? ObjectScale.of(props) : 1 }

    /// The frame a tile's content lays out in: the frame's size divided by `scale`, same origin.
    public var naturalFrame: Frame {
        let scale = self.scale
        return Frame(x: frame.x, y: frame.y, w: frame.w / scale, h: frame.h / scale)
    }
}
