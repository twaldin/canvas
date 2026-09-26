import Foundation

/// `view.render` / `view.snapshot` types and the geometry that maps canvas space to image pixels.
public enum RenderState: String, Sendable {
    /// The content painted.
    case rendered
    /// Content not loaded in time or not renderable here; a stand-in was drawn.
    case placeholder
    /// Rendering errored.
    case failed
}

public enum ImageFormat: String, Sendable {
    case png, jpeg

    /// Format named by a file's extension; nil for anything we can't write.
    public init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        default: return nil
        }
    }
}

public enum RenderTarget: Equatable, Sendable {
    case objects([ObjectID])
    case rect(Frame)
}

public struct RenderRequest: Sendable {
    public var target: RenderTarget
    /// Pixels per canvas point, as asked.
    public var scale: Double
    public var full: Bool
    public var exclude: Set<ObjectType>
    public var padding: Double
    public var timeout: Duration

    public init(target: RenderTarget, scale: Double = 1, full: Bool = false, exclude: Set<ObjectType> = [], padding: Double = 0, timeout: Duration = .seconds(8)) {
        self.target = target
        self.scale = scale
        self.full = full
        self.exclude = exclude
        self.padding = padding
        self.timeout = timeout
    }
}

public struct RenderedObject: Equatable, Sendable {
    public var id: ObjectID
    public var type: ObjectType
    /// Image pixels, top-left origin.
    public var pixelRect: Frame
    public var state: RenderState
    public var reason: String?
    /// The content's own extent in points (tiles).
    public var contentSize: CGSize?
    public var overflow: CGSize?

    public init(id: ObjectID, type: ObjectType, pixelRect: Frame, state: RenderState, reason: String? = nil, contentSize: CGSize? = nil, overflow: CGSize? = nil) {
        self.id = id
        self.type = type
        self.pixelRect = pixelRect
        self.state = state
        self.reason = reason
        self.contentSize = contentSize
        self.overflow = overflow
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "type": .string(type.rawValue), "pixelRect": RenderMath.json(pixelRect), "state": .string(state.rawValue)]
        if let reason { fields["reason"] = .string(reason) }
        if let contentSize { fields["contentSize"] = .object(["w": .number(contentSize.width.rounded()), "h": .number(contentSize.height.rounded())]) }
        if let overflow { fields["overflow"] = .object(["x": .number(overflow.width.rounded()), "y": .number(overflow.height.rounded())]) }
        return .object(fields)
    }
}

/// A rendered image and where everything landed in it.
public struct RenderOutput: Sendable {
    public var image: Data
    public var format: ImageFormat
    public var width: Int
    public var height: Int
    public var canvasRect: Frame
    public var scale: Double
    public var objects: [RenderedObject]

    public init(image: Data, format: ImageFormat, width: Int, height: Int, canvasRect: Frame, scale: Double, objects: [RenderedObject]) {
        self.image = image
        self.format = format
        self.width = width
        self.height = height
        self.canvasRect = canvasRect
        self.scale = scale
        self.objects = objects
    }
}

/// `view.get`: what the user is looking at.
public struct ViewState: Sendable {
    public var viewport: Viewport
    public var promptTarget: ObjectID?
    public var focused: ObjectID?
    public var selection: [ObjectID]
    public var enteredGroup: ObjectID?
    public var visible: Bool

    public init(viewport: Viewport, promptTarget: ObjectID?, focused: ObjectID?, selection: [ObjectID], enteredGroup: ObjectID?, visible: Bool) {
        self.viewport = viewport
        self.promptTarget = promptTarget
        self.focused = focused
        self.selection = selection
        self.enteredGroup = enteredGroup
        self.visible = visible
    }
}

public enum RenderMath {
    /// Title bar above every tile's body (the tile's frame is the body; its outline includes this).
    public static let tileTitleHeight: Double = 26
    /// Largest image `view.render` produces; bigger requests render at a lower scale.
    public static let pixelBudget: Double = 32_000_000
    /// Tallest a tile's full content is drawn, in points (a runaway page can't allocate gigabytes).
    public static let maxContentExtent: Double = 20_000

    /// What an object covers on the canvas. A tile's `frame.h` is its body; the tile also draws a
    /// 26-point title bar, so its outline is `h + 26` tall from `frame.y`.
    public static func outline(_ object: CanvasObject) -> Frame {
        guard isTile(object.type) else { return object.frame }
        return Frame(x: object.frame.x, y: object.frame.y, w: object.frame.w, h: object.frame.h + tileTitleHeight)
    }

    public static func isTile(_ type: ObjectType) -> Bool {
        ![.shape, .arrow, .group].contains(type)
    }

    /// The tile's outline grown to show `content` when drawing full content (never shrunk).
    public static func extended(_ outline: Frame, body: CGSize, content: CGSize) -> Frame {
        let w = min(max(Double(body.width), Double(content.width)), maxContentExtent)
        let h = min(max(Double(body.height), Double(content.height)), maxContentExtent)
        return Frame(x: outline.x, y: outline.y, w: w, h: outline.h - Double(body.height) + h)
    }

    /// Content beyond the frame, in points; nil when it fits (sub-point differences are layout noise).
    public static func overflow(content: CGSize, body: CGSize) -> CGSize? {
        let x = max(0, (content.width - body.width).rounded()), y = max(0, (content.height - body.height).rounded())
        return x >= 1 || y >= 1 ? CGSize(width: x, height: y) : nil
    }

    public static func union(_ frames: [Frame]) -> Frame? {
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for frame in frames.dropFirst() {
            minX = min(minX, frame.x)
            minY = min(minY, frame.y)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        return Frame(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// Canvas rect snapped out to whole points, so pixel rects land on whole pixels at integer scales.
    public static func snapped(_ rect: Frame, padding: Double = 0) -> Frame {
        let minX = (rect.x - padding).rounded(.down), minY = (rect.y - padding).rounded(.down)
        let maxX = (rect.maxX + padding).rounded(.up), maxY = (rect.maxY + padding).rounded(.up)
        return Frame(x: minX, y: minY, w: max(1, maxX - minX), h: max(1, maxY - minY))
    }

    /// The requested scale, lowered so the image stays within `pixelBudget`.
    public static func fittedScale(_ requested: Double, for rect: Frame) -> Double {
        let area = max(rect.w * rect.h, 1)
        let cap = (pixelBudget / area).squareRoot()
        return min(requested, cap)
    }

    /// Image size in pixels for a canvas rect at a scale.
    public static func pixelSize(_ rect: Frame, scale: Double) -> (width: Int, height: Int) {
        (max(1, Int((rect.w * scale).rounded())), max(1, Int((rect.h * scale).rounded())))
    }

    /// Where a canvas-space rect lands in the image: top-left origin, whole pixels (rounded out),
    /// clipped to the image.
    public static func pixelRect(_ frame: Frame, in canvasRect: Frame, scale: Double) -> Frame {
        let size = pixelSize(canvasRect, scale: scale)
        let minX = max(0, ((frame.x - canvasRect.x) * scale).rounded(.down))
        let minY = max(0, ((frame.y - canvasRect.y) * scale).rounded(.down))
        let maxX = min(Double(size.width), ((frame.maxX - canvasRect.x) * scale).rounded(.up))
        let maxY = min(Double(size.height), ((frame.maxY - canvasRect.y) * scale).rounded(.up))
        return Frame(x: minX, y: minY, w: max(0, maxX - minX), h: max(0, maxY - minY))
    }

    public static func json(_ frame: Frame) -> JSONValue {
        .object(["x": .number(frame.x), "y": .number(frame.y), "w": .number(frame.w), "h": .number(frame.h)])
    }
}
