import AppKit
import CanvasCore

/// Render-ready geometry for one shape or arrow, in document coordinates. Built once per object
/// revision (and per re-route for arrows) so redraws only replay cached paths.
@MainActor
struct DrawnItem {
    enum Kind {
        case shape(ShapeSpec)
        case arrow(ArrowSpec, start: CGPoint, end: CGPoint)
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

    var color: NSColor { DrawingStyle.color(colorName) }

    private var colorName: String? {
        switch kind {
        case .shape(let shape): shape.color
        case .arrow(let arrow, _, _): arrow.color
        }
    }

    var shape: ShapeSpec? {
        if case .shape(let shape) = kind { return shape }
        return nil
    }

    var arrow: (spec: ArrowSpec, start: CGPoint, end: CGPoint)? {
        if case .arrow(let spec, let start, let end) = kind { return (spec, start, end) }
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
            label = DrawingStyle.text(spec.text ?? "", size: DrawingStyle.textSize, color: DrawingStyle.color(spec.color))
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
        return DrawnItem(object: object, kind: .shape(spec), frame: frame, bounds: bounds, stroke: stroke, fill: fill, fillAlpha: fillAlpha,
                         label: label, labelRect: labelRect, inkOutline: inkOutline)
    }

    static func arrow(_ object: CanvasObject, _ spec: ArrowSpec, start: CGPoint, end: CGPoint) -> DrawnItem {
        var random = DrawingRough.Random(seed: DrawingRough.seed(object.id))
        let (left, right) = DrawingGeometry.arrowhead(start: start, end: end)
        let strokes = DrawingRough.line(from: start, to: end, random: &random)
            + DrawingRough.line(from: end, to: left, random: &random)
            + DrawingRough.line(from: end, to: right, random: &random)
        let stroke = path(strokes)
        var label: NSAttributedString?
        var labelRect: NSRect?
        let caption = spec.label ?? spec.relation
        if let caption, !caption.isEmpty {
            let color = spec.label == nil ? NSColor.secondaryLabelColor : DrawingStyle.color(spec.color)
            let attributed = DrawingStyle.text(caption, size: DrawingStyle.arrowLabelSize, color: color, alignment: .center)
            let size = attributed.boundingRect(with: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
            label = attributed
            let width = ceil(size.width) + 8
            let height = ceil(size.height)
            var center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            // A caption wider than a short arrow would hide it: set it beside the shaft instead.
            let length = hypot(end.x - start.x, end.y - start.y)
            if length < width + 32, length > 0 {
                var normal = CGPoint(x: (start.y - end.y) / length, y: (end.x - start.x) / length)
                if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
                let lift = abs(normal.x) * width / 2 + abs(normal.y) * height / 2 + 4
                center = CGPoint(x: center.x + normal.x * lift, y: center.y + normal.y * lift)
            }
            labelRect = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }
        let frame = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        var bounds = stroke.boundingBoxOfPath.union(frame).insetBy(dx: -6, dy: -6)
        if let labelRect { bounds = bounds.union(labelRect.insetBy(dx: -2, dy: -2)) }
        return DrawnItem(object: object, kind: .arrow(spec, start: start, end: end), frame: frame, bounds: bounds, stroke: stroke, fill: nil, fillAlpha: 0, label: label, labelRect: labelRect)
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

    func draw(in context: CGContext) {
        let color = self.color
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
                // Arrow captions sit on a chip of canvas color so the shaft doesn't cross the text.
                context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
                context.addPath(CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            }
            label.draw(with: labelRect, options: [.usesLineFragmentOrigin])
        }
    }

    func hits(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .shape(let spec):
            return DrawingGeometry.hits(spec, frame: frame, at: point, tolerance: tolerance, labelRect: spec.kind == .text ? nil : labelRect, inkOutline: inkOutline)
        case .arrow(_, let start, let end):
            if let labelRect, labelRect.contains(point) { return true }
            return DrawingGeometry.hitsArrow(start: start, end: end, at: point, tolerance: tolerance)
        }
    }

    /// Outline an arrow end bound to this item attaches to.
    var outline: DrawingGeometry.Outline {
        shape?.kind == .ellipse ? .ellipse(frame) : .rect(frame)
    }
}
