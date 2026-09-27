import AppKit
import CanvasCore

/// Render-ready geometry for one shape or arrow, in document coordinates. Built once per object
/// revision (and per re-route for arrows) so redraws only replay cached paths.
@MainActor
struct DrawnItem {
    enum Kind {
        case shape(ShapeSpec)
        /// The routed polyline, at least two points.
        case arrow(ArrowSpec, path: [CGPoint])
    }

    let object: CanvasObject
    let kind: Kind
    /// The shape's frame, or the arrow's route bounds.
    let frame: NSRect
    /// Everything this item paints (stroke jitter, label); the rect to invalidate.
    let bounds: NSRect
    let stroke: CGPath?
    let fill: CGPath?
    let fillAlpha: CGFloat
    let label: NSAttributedString?
    let labelRect: NSRect?
    /// Ink's painted outline polygon (document coordinates), kept for hit testing.
    var inkOutline: [CGPoint] = []
    /// A shape's label in the default ink resolved dark and light (`InkContrast`), built with the
    /// item so a redraw only picks one.
    var inkLabels: (dark: NSAttributedString, light: NSAttributedString)?

    var color: NSColor { DrawingStyle.color(colorName) }

    /// Drawn in the default ink, which the canvas resolves against what lies under it.
    var usesDefaultInk: Bool { DrawingStyle.isDefaultInk(colorName) }

    private var colorName: String? {
        switch kind {
        case .shape(let shape): shape.color
        case .arrow(let arrow, _): arrow.color
        }
    }

    var shape: ShapeSpec? {
        if case .shape(let shape) = kind { return shape }
        return nil
    }

    var arrow: (spec: ArrowSpec, path: [CGPoint], start: CGPoint, end: CGPoint)? {
        if case .arrow(let spec, let path) = kind { return (spec, path, path[0], path[path.count - 1]) }
        return nil
    }

    // MARK: Building

    static func shape(_ object: CanvasObject, _ spec: ShapeSpec, frame: NSRect) -> DrawnItem {
        var random = DrawingRough.Random(seed: DrawingRough.seed(object.id))
        var stroke: CGPath?
        var fill: CGPath?
        var fillAlpha: CGFloat = 0
        var label: NSAttributedString?
        var labelRect: NSRect?
        var inkOutline: [CGPoint] = []
        switch spec.kind {
        case .rect, .ellipse:
            let strokes = spec.kind == .rect ? DrawingRough.rectangle(frame, random: &random) : DrawingRough.ellipse(frame, random: &random)
            stroke = path(strokes)
            if spec.fill != .none {
                fill = spec.kind == .rect ? CGPath(rect: frame, transform: nil) : CGPath(ellipseIn: frame, transform: nil)
                fillAlpha = spec.fill == .semi ? 0.14 : 0.85
            }
            if let text = spec.text, !text.isEmpty {
                let attributed = DrawingStyle.text(text, size: DrawingStyle.labelSize, color: DrawingStyle.color(spec.color), alignment: .center)
                let width = max(20, frame.width - 16)
                let size = attributed.boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
                label = attributed
                // Tight around the text: the label hits, the rest of the interior stays see-through.
                let tight = min(width, ceil(size.width) + 8)
                labelRect = NSRect(x: frame.midX - tight / 2, y: frame.midY - size.height / 2, width: tight, height: ceil(size.height))
            }
        case .text:
            label = DrawingStyle.text(spec.text ?? "", size: DrawingStyle.textSize * spec.scale, color: DrawingStyle.color(spec.color))
            labelRect = frame
        case .ink:
            inkOutline = DrawingInk.outline(spec.points).map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) }
            fill = smoothPolygon(inkOutline)
            fillAlpha = 1
        }
        var bounds = frame.insetBy(dx: -DrawingGeometry.strokeWidth - 4, dy: -DrawingGeometry.strokeWidth - 4)
        if spec.kind == .ellipse { bounds = bounds.insetBy(dx: -frame.width * 0.06, dy: -frame.height * 0.06) }
        if let stroke { bounds = bounds.union(stroke.boundingBoxOfPath.insetBy(dx: -2, dy: -2)) }
        if let fill { bounds = bounds.union(fill.boundingBoxOfPath.insetBy(dx: -2, dy: -2)) }
        if let labelRect { bounds = bounds.union(labelRect) }
        var item = DrawnItem(object: object, kind: .shape(spec), frame: frame, bounds: bounds, stroke: stroke, fill: fill, fillAlpha: fillAlpha,
                             label: label, labelRect: labelRect, inkOutline: inkOutline)
        if let label, DrawingStyle.isDefaultInk(spec.color) {
            func recolored(_ ink: InkContrast.Ink) -> NSAttributedString {
                let copy = NSMutableAttributedString(attributedString: label)
                copy.addAttribute(.foregroundColor, value: DrawingStyle.color(ink), range: NSRange(location: 0, length: copy.length))
                return copy
            }
            item.inkLabels = (recolored(.dark), recolored(.light))
        }
        return item
    }

    /// An arrow along a routed polyline. The label sits beside the route, on the `labelSide`
    /// first (the sign of its parallel offset), clear of `obstacles` where it can be.
    static func arrow(_ object: CanvasObject, _ spec: ArrowSpec, path points: [CGPoint], labelSide: CGFloat = 0, obstacles: [CGRect] = []) -> DrawnItem {
        var random = DrawingRough.Random(seed: DrawingRough.seed(object.id))
        let points = points.count >= 2 ? points : [points.first ?? .zero, points.first ?? .zero]
        let end = points[points.count - 1]
        let (left, right) = DrawingGeometry.arrowhead(start: points[points.count - 2], end: end)
        var strokes: [DrawingRough.Stroke] = []
        for (a, b) in zip(points, points.dropFirst()) { strokes += DrawingRough.line(from: a, to: b, random: &random) }
        strokes += DrawingRough.line(from: end, to: left, random: &random) + DrawingRough.line(from: end, to: right, random: &random)
        let stroke = path(strokes)
        var label: NSAttributedString?
        var labelRect: NSRect?
        if let caption = DrawingStyle.arrowLabel(spec) {
            label = caption.text
            labelRect = DrawingGeometry.labelRect(along: points, size: caption.size, side: labelSide, obstacles: obstacles)
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let frame = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        var bounds = stroke.boundingBoxOfPath.union(frame).insetBy(dx: -6, dy: -6)
        if let labelRect { bounds = bounds.union(labelRect.insetBy(dx: -2, dy: -2)) }
        return DrawnItem(object: object, kind: .arrow(spec, path: points), frame: frame, bounds: bounds, stroke: stroke, fill: nil, fillAlpha: 0, label: label, labelRect: labelRect)
    }

    static func path(_ strokes: [DrawingRough.Stroke]) -> CGPath {
        let path = CGMutablePath()
        for stroke in strokes {
            path.move(to: stroke.start)
            for curve in stroke.curves {
                path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
            }
        }
        return path
    }

    /// Closed outline through the midpoints of the polygon's edges (perfect-freehand's SVG recipe),
    /// which rounds off the outline's corners.
    static func smoothPolygon(_ points: [CGPoint]) -> CGPath? {
        guard points.count > 2 else { return nil }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let path = CGMutablePath()
        path.move(to: mid(points[points.count - 1], points[0]))
        for index in points.indices {
            path.addQuadCurve(to: mid(points[index], points[(index + 1) % points.count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }

    // MARK: Drawing and hit testing

    /// `ink`: the default ink resolved against what lies under the item (nil: the item's own
    /// color, for explicit colors). An arrow's caption keeps its canvas-colored chip and text.
    func draw(in context: CGContext, ink: InkContrast.Ink? = nil) {
        let color = ink.map(DrawingStyle.color) ?? self.color
        if let fill {
            context.addPath(fill)
            context.setFillColor(color.withAlphaComponent(fillAlpha).cgColor)
            context.fillPath()
        }
        if let stroke {
            context.addPath(stroke)
            context.setStrokeColor(color.cgColor)
            context.strokePath()
        }
        if let label, let labelRect {
            if arrow != nil {
                // Arrow captions sit on a chip of canvas color so strokes passing by don't cross the text.
                context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
                context.addPath(CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            }
            let shown = ink.flatMap { ink in inkLabels.map { ink == .dark ? $0.dark : $0.light } } ?? label
            shown.draw(with: labelRect, options: [.usesLineFragmentOrigin])
        }
    }

    func hits(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .shape(let spec):
            return DrawingGeometry.hits(spec, frame: frame, at: point, tolerance: tolerance, labelRect: spec.kind == .text ? nil : labelRect, inkOutline: inkOutline)
        case .arrow(_, let path):
            if let labelRect, labelRect.contains(point) { return true }
            return DrawingGeometry.hitsArrow(path: path, at: point, tolerance: tolerance)
        }
    }

    /// Outline an arrow end bound to this item attaches to.
    var outline: DrawingGeometry.Outline {
        shape?.kind == .ellipse ? .ellipse(frame) : .rect(frame)
    }
}
