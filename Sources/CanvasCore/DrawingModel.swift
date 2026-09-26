import CoreGraphics
import Foundation

/// Typed views of `ShapeProps`, `ArrowProps`, and `Binding` (schema/canvas-api.json). Props stay
/// JSON on the object; these parse them where drawing code needs typed values.
public struct ShapeSpec: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case rect, ellipse, text, ink
    }

    public enum Fill: String, Sendable {
        case none, semi, solid
    }

    public var kind: Kind
    public var text: String?
    /// Ink points in object-local coordinates (relative to the frame origin).
    public var points: [InkPoint]
    public var color: String?
    public var fill: Fill

    public init(kind: Kind, text: String? = nil, points: [InkPoint] = [], color: String? = nil, fill: Fill = .none) {
        self.kind = kind
        self.text = text
        self.points = points
        self.color = color
        self.fill = fill
    }

    public init?(_ props: JSONValue) {
        guard let kind = props["kind"]?.string.flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        text = props["text"]?.string
        color = props["color"]?.string
        fill = props["fill"]?.string.flatMap(Fill.init(rawValue:)) ?? .none
        points = (props["points"]?.array ?? []).compactMap { value in
            guard let values = value.array?.compactMap(\.number), values.count >= 2 else { return nil }
            return InkPoint(x: values[0], y: values[1], pressure: values.count > 2 ? values[2] : nil)
        }
    }

    public var props: JSONValue {
        var props: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let text { props["text"] = .string(text) }
        if let color { props["color"] = .string(color) }
        if fill != .none { props["fill"] = .string(fill.rawValue) }
        if !points.isEmpty { props["points"] = .array(points.map(\.json)) }
        return .object(props)
    }
}

public struct InkPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// 0…1 from a pressure-sensitive device; nil means pressure is simulated from speed.
    public var pressure: Double?

    public init(x: Double, y: Double, pressure: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }

    public var json: JSONValue {
        .array([.number(x), .number(y)] + (pressure.map { [.number($0)] } ?? []))
    }
}

/// One end of an arrow: bound to an object (optionally to lines or a DOM selector inside it), or
/// a free point in canvas coordinates.
public enum ArrowBinding: Equatable, Sendable {
    case object(ObjectID, lines: LineRange? = nil, selector: String? = nil)
    case point(CGPoint)

    public init?(_ json: JSONValue) {
        if let id = json["object"]?.string {
            self = .object(id, lines: try? json["lines"]?.decode(LineRange.self), selector: json["selector"]?.string)
        } else if let values = json["point"]?.array?.compactMap(\.number), values.count == 2 {
            self = .point(CGPoint(x: values[0], y: values[1]))
        } else {
            return nil
        }
    }

    public var objectID: ObjectID? {
        if case .object(let id, _, _) = self { return id }
        return nil
    }

    public var json: JSONValue {
        switch self {
        case .object(let id, let lines, let selector):
            var binding: [String: JSONValue] = ["object": .string(id)]
            if let lines { binding["lines"] = .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))]) }
            if let selector { binding["selector"] = .string(selector) }
            return .object(binding)
        case .point(let point):
            return .object(["point": .array([.number(point.x), .number(point.y)])])
        }
    }
}

public struct ArrowSpec: Equatable, Sendable {
    public var from: ArrowBinding
    public var to: ArrowBinding
    public var relation: String?
    public var label: String?
    public var color: String?
    public var route: ArrowRouteStyle

    public init(from: ArrowBinding, to: ArrowBinding, relation: String? = nil, label: String? = nil, color: String? = nil, route: ArrowRouteStyle = .straight) {
        self.from = from
        self.to = to
        self.relation = relation
        self.label = label
        self.color = color
        self.route = route
    }

    public init?(_ props: JSONValue) {
        guard let from = props["from"].flatMap(ArrowBinding.init), let to = props["to"].flatMap(ArrowBinding.init) else { return nil }
        self.from = from
        self.to = to
        relation = props["relation"]?.string
        label = props["label"]?.string
        color = props["color"]?.string
        route = props["route"]?.string.flatMap(ArrowRouteStyle.init) ?? .straight
    }

    public var props: JSONValue {
        var props: [String: JSONValue] = ["from": from.json, "to": to.json]
        if let relation { props["relation"] = .string(relation) }
        if let label { props["label"] = .string(label) }
        if let color { props["color"] = .string(color) }
        if route != .straight { props["route"] = .string(route.rawValue) }
        return .object(props)
    }
}

extension Frame {
    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
