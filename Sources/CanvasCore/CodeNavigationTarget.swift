import Foundation

/// Where a code tile points: its file (board-relative when under the root), lines and symbol.
public struct CodeAim: Equatable, Sendable {
    public var path: String
    public var range: LineRange?
    public var symbol: String?

    public init(path: String, range: LineRange?, symbol: String? = nil) {
        self.path = path
        self.range = range
        self.symbol = symbol
    }

    /// The aim of a code tile; nil for anything else.
    public init?(_ object: CanvasObject) {
        guard object.type == .code, let path = object.props["path"]?.string else { return nil }
        let start = object.props["range"]?["start"]?.int
        self.init(path: path, range: start.map { LineRange(start: $0, end: object.props["range"]?["end"]?.int ?? $0) },
                  symbol: object.props["symbol"]?.string)
    }

    /// The props that aim a tile here (null clears a range or symbol it had).
    var props: JSONValue {
        .object(["path": .string(path),
                 "range": range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null,
                 "symbol": symbol.map(JSONValue.string) ?? .null])
    }

    /// `path:12`, `path:12-20`, or the path alone.
    public var label: String {
        guard let range else { return path }
        return range.end > range.start ? "\(path):\(range.start)-\(range.end)" : "\(path):\(range.start)"
    }
}

/// A code tile a navigation re-aimed: what it showed before and what it shows after.
public struct CodeReaim: Equatable, Sendable {
    public var tile: ObjectID
    public var before: CodeAim
    public var after: CodeAim

    public init(tile: ObjectID, before: CodeAim, after: CodeAim) {
        self.tile = tile
        self.before = before
        self.after = after
    }

    /// The same tile the other way round (Back).
    public var inverted: CodeReaim { CodeReaim(tile: tile, before: after, after: before) }
}

/// What a navigation to code did: the tile that shows it, whether it is new, and the re-aim of
/// an existing tile when there was one.
public struct CodeOpened: Equatable, Sendable {
    public var id: ObjectID
    public var created: Bool
    public var reaim: CodeReaim?
}

extension Board {
    /// Whether code tile `id` is plain navigation surface that navigating may re-aim: a tile the
    /// user made and an agent hasn't touched since, with no caption, in no group, not a follow
    /// tile. An agent's walkthrough tile, an Open All excerpt (captioned, grouped) and a follow
    /// tile keep their range: navigation opens another tile instead.
    public func isNavigationSurface(_ id: ObjectID) -> Bool {
        guard let object = objects[id], object.type == .code, object.createdBy == .user,
              object.updatedBy.map({ $0 == .user }) ?? true,
              object.props["followOf"] == nil, object.parent == nil else { return false }
        if let caption = object.props["caption"]?.string, !caption.isEmpty { return false }
        return !objects.values.contains { $0.type == .group && GroupSpec($0.props)?.members.contains(id) == true }
    }

    /// Opens code the user navigated to (Go to, a definition, a changes tile's line, a page's
    /// link) near where the user is, never re-aiming someone else's tile and never far away:
    /// - a code tile in view already showing `aim` at its lines is the answer as it is;
    /// - `preview` (a changes tile): the tile this source last created, while nobody changed it
    ///   since and it is still plain navigation surface (`isNavigationSurface`), is re-aimed,
    ///   even at another file, like a terminal's ⌘-click preview;
    /// - else a plain navigation tile in view showing the same file is re-aimed, the one nearest
    ///   the source (the viewport center without one);
    /// - else a new tile opens beside the source (at the viewport center without one) with
    ///   `extra` props, shrunk down to a follow tile's minimum to land wholly in view.
    /// Re-aims are navigation, not content changes: never an undo step (Back undoes them).
    /// Without a viewport (no window) every tile counts as in view.
    @discardableResult
    public func openForNavigation(_ aim: CodeAim, from source: ObjectID?, preview: Bool = false, extra: [String: JSONValue] = [:]) -> CodeOpened {
        let view = viewport()
        func inView(_ object: CanvasObject) -> Bool { view.map { $0.intersects(object.frame) } ?? true }
        let codes = objects.values.filter { $0.type == .code && inView($0) }
        if let range = aim.range, let shown = codes.filter({ CodeAim($0).map { $0.path == aim.path && $0.range == range } ?? false }).max(by: { $0.z < $1.z }) {
            return CodeOpened(id: shown.id, created: false, reaim: nil)
        }
        if preview, let source, let previous = codePreviews[source], let object = objects[previous.tile], object.rev == previous.rev,
           isNavigationSurface(object.id), let reaim = reaimForNavigation(object.id, to: aim) {
            codePreviews[source] = (object.id, objects[object.id]?.rev ?? 0)
            return CodeOpened(id: object.id, created: false, reaim: reaim)
        }
        let center = source.flatMap { objects[$0]?.frame } ?? view
        func distance(_ frame: Frame) -> Double {
            guard let center else { return 0 }
            return hypot(frame.x + frame.w / 2 - (center.x + center.w / 2), frame.y + frame.h / 2 - (center.y + center.h / 2))
        }
        let nearest = codes.filter { $0.props["path"]?.string == aim.path && isNavigationSurface($0.id) }
            .min { (distance($0.frame), $0.id) < (distance($1.frame), $1.id) }
        if let nearest, let reaim = reaimForNavigation(nearest.id, to: aim) {
            return CodeOpened(id: nearest.id, created: false, reaim: reaim)
        }
        var props = extra
        if let aimed = aim.props.object {
            for (key, value) in aimed where value != .null { props[key] = value }
        }
        let size = Board.defaultSize(.code)
        let frame = source.map { place(width: size.w, height: size.h, near: $0, shrinkingTo: Board.followMinimumSize) }
            ?? place(width: size.w, height: size.h, near: nil)
        let created = create(type: .code, props: .object(props), frame: frame)
        if preview, let source { codePreviews[source] = (created.id, created.rev) }
        return CodeOpened(id: created.id, created: true, reaim: nil)
    }

    /// Back or Forward re-aiming tile `reaim.tile` from `reaim.before` to `reaim.after`, only
    /// while it is still plain navigation surface showing `before` (nobody aimed it elsewhere
    /// meanwhile). True when it was re-aimed.
    @discardableResult
    public func restoreAim(_ reaim: CodeReaim) -> Bool {
        guard isNavigationSurface(reaim.tile), let object = objects[reaim.tile], CodeAim(object) == reaim.before else { return false }
        return reaimForNavigation(reaim.tile, to: reaim.after) != nil
    }

    /// Re-aims code tile `id` as navigation: credited to the user, not an undo step.
    private func reaimForNavigation(_ id: ObjectID, to aim: CodeAim) -> CodeReaim? {
        guard let object = objects[id], let before = CodeAim(object) else { return nil }
        guard before != aim else { return CodeReaim(tile: id, before: before, after: aim) }
        guard (try? unrecorded({ try update(id, props: aim.props) })) != nil else { return nil }
        return CodeReaim(tile: id, before: before, after: aim)
    }
}

extension Board {
    /// Review Changes' existing answer: a changes tile of the whole of `root` (nil: the board
    /// root) against `base`, the one in view when there is one, else the one nearest the view.
    public func changesTile(root: String?, base: String) -> ObjectID? {
        let directory = ChangesSpec(.object(root.map { ["root": .string($0)] } ?? [:])).directory(boardRoot: self.root).standardizedFileURL.path
        let view = viewport()
        let matching = objects.values.filter { object in
            guard object.type == .changes else { return false }
            let spec = ChangesSpec(object.props)
            return spec.paths.isEmpty && spec.baseProp == base && spec.directory(boardRoot: self.root).standardizedFileURL.path == directory
        }
        func rank(_ object: CanvasObject) -> (Int, Double, ObjectID) {
            guard let view else { return (0, 0, object.id) }
            let distance = hypot(object.frame.x + object.frame.w / 2 - (view.x + view.w / 2), object.frame.y + object.frame.h / 2 - (view.y + view.h / 2))
            return (view.intersects(object.frame) ? 0 : 1, distance, object.id)
        }
        return matching.min { rank($0) < rank($1) }?.id
    }
}
