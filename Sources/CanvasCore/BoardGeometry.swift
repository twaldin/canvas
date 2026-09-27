import CoreGraphics
import Foundation

/// A board's objects as a value, with the arrow label sizes the drawing layer measured: the pure
/// geometry of arrow routes, label placement, and layout checks. Being a value, it computes off
/// the main actor (`layout.check` routes every arrow, each `avoid` route a grid search).
public struct BoardGeometry: Sendable {
    public let objects: [ObjectID: CanvasObject]
    /// Label chip sizes by arrow (`DrawingStyle.arrowLabel`, measured on the main actor);
    /// arrows without a caption have none.
    public let labelSizes: [ObjectID: CGSize]

    public init(objects: [ObjectID: CanvasObject], labelSizes: [ObjectID: CGSize]) {
        self.objects = objects
        self.labelSizes = labelSizes
    }

    /// Whether arrows route around this object and count as crossing it: tiles, text, and filled
    /// shapes. Unfilled rects and ellipses are regions drawn around things; ink, arrows, and
    /// groups never block.
    public static func blocksRoutes(_ object: CanvasObject) -> Bool {
        switch object.type {
        case .terminal, .browser, .code, .note, .html, .changes, .image: return true
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return false }
            return spec.kind == .text || (spec.kind != .ink && spec.fill != .none)
        case .arrow, .group: return false
        }
    }

    /// Members of a group, nested groups expanded, without the groups themselves.
    public static func leafMembers(of id: ObjectID, in objects: [ObjectID: CanvasObject]) -> [ObjectID] {
        var seen: Set<ObjectID> = [id]
        var result: [ObjectID] = []
        var queue = [id]
        while let next = queue.popLast() {
            guard let group = objects[next], let spec = GroupSpec(group.props) else { continue }
            for member in spec.members where !seen.contains(member) {
                seen.insert(member)
                guard let object = objects[member] else { continue }
                if object.type == .group { queue.append(member) } else { result.append(member) }
            }
        }
        return result
    }

    /// Every arrow's routed polyline from object frames alone (the app routes the same way from
    /// what it draws): parallel arrows offset apart, `avoid` routes around blocking objects, an
    /// end bound to `lines` of a code tile at that line's row (`CodeMetrics.lineY`, freshly
    /// aimed; `rows` gives a tile's visual rows when known, else one row per line). `only`
    /// routes just those arrows (offsets still account for all of them).
    public func routes(rows: [ObjectID: CodeRows] = [:], only: Set<ObjectID>? = nil) -> [ObjectID: [CGPoint]] {
        let arrows = objects.values.filter { $0.type == .arrow }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        let blockers = objects.values.filter(Self.blocksRoutes)
        var result: [ObjectID: [CGPoint]] = [:]
        for (arrow, spec) in arrows where only?.contains(arrow.id) ?? true {
            guard let from = arrowEnd(spec.from, rows: rows), let to = arrowEnd(spec.to, rows: rows) else { continue }
            let ends = Set([spec.from.objectID, spec.to.objectID].compactMap { $0 })
            let obstacles = spec.route == .avoid ? blockers.filter { !ends.contains($0.id) }.map(\.frame.rect) : []
            result[arrow.id] = DrawingGeometry.path(from: from, to: to, style: spec.route, offset: offsets[arrow.id] ?? 0, obstacles: obstacles)
        }
        return result
    }

    /// What a binding attaches to: a point, an object's frame (an ellipse's curve), or the row
    /// of the first of `lines` on a code tile. Nil when the object is gone.
    func arrowEnd(_ binding: ArrowBinding, rows: [ObjectID: CodeRows]) -> DrawingGeometry.ArrowEnd? {
        switch binding {
        case .point(let point): return .point(point)
        case .object(let id, let lines, _):
            guard let object = objects[id] else { return nil }
            if let lines, object.type == .code {
                return .row(object.frame.rect, y: CodeMetrics.lineY(line: lines.start, frame: object.frame, props: object.props, rows: rows[id]))
            }
            let isEllipse = object.type == .shape && ShapeSpec(object.props)?.kind == .ellipse
            return .bound(isEllipse ? .ellipse(object.frame.rect) : .rect(object.frame.rect))
        }
    }

    /// Where each captioned arrow's label sits along `routes`, as the drawing layer places it
    /// (`labelSizes`, `DrawingGeometry.labelRect`): beside the route, clear of blocking objects
    /// where it can be.
    public func labelRects(routes: [ObjectID: [CGPoint]]) -> [ObjectID: CGRect] {
        let arrows = objects.values.filter { $0.type == .arrow }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        let blockers = objects.values.filter(Self.blocksRoutes).map(\.frame.rect)
        var result: [ObjectID: CGRect] = [:]
        for (arrow, _) in arrows {
            guard let path = routes[arrow.id], let size = labelSizes[arrow.id] else { continue }
            result[arrow.id] = DrawingGeometry.labelRect(along: path, size: size, side: offsets[arrow.id] ?? 0, obstacles: blockers)
        }
        return result
    }
}

extension Board {
    /// The objects as they are now, with their arrows' label sizes, for route and layout math
    /// off the main actor.
    public var geometry: BoardGeometry {
        var labelSizes: [ObjectID: CGSize] = [:]
        for object in objects.values where object.type == .arrow {
            guard let spec = ArrowSpec(object.props), let label = DrawingStyle.arrowLabel(spec) else { continue }
            labelSizes[object.id] = label.size
        }
        return BoardGeometry(objects: objects, labelSizes: labelSizes)
    }
}
