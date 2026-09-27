import AppKit
import CanvasCore

/// An image file on the canvas (`type: image`, `props.path`): a chart an agent saved, a
/// screenshot, an SVG, a PDF's first page. The picture keeps its aspect ratio inside the body,
/// above an optional one-line `caption`, and reloads whenever the file changes on disk (agents
/// re-save charts in place). A Hyper-click on the picture mentions that pixel of the image.
@MainActor
final class ImageTile: NSView, TileContent {
    /// File events arrive in bursts (write, rename, touch); reload once they settle.
    static let debounce: TimeInterval = 0.2

    private var object: CanvasObject
    private let board: Board
    private var live = true
    /// The loaded picture and its natural size (pixels for bitmaps, points for SVG and PDF).
    private var picture: (image: NSImage, size: CGSize)?
    /// Why there is no picture: the file is missing or unreadable.
    private var failure: String?
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var events: FileEvents?
    private var pendingReload: DispatchWorkItem?
    /// The file changed while the tile wasn't watching (not live): reload when it is again.
    private var stale = false

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private var path: String { object.props["path"]?.string ?? "" }
    private var caption: String? { object.props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    private var file: URL { LocalImage.tileFile(path, root: board.root) }

    // MARK: Loading

    /// Reads the file off the main thread; the newest read wins.
    private func reload() {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let file = file
        let path = path
        loadTask = Task { [weak self] in
            let read = path.isEmpty ? nil : await LocalImage.read(file)
            guard let self, self.loadGeneration == generation else { return }
            self.loaded = true
            if let read, let image = NSImage(data: read.data) {
                image.size = read.size
                self.picture = (image, read.size)
                self.failure = nil
            } else {
                self.picture = nil
                self.failure = path.isEmpty ? "no image path" : FileManager.default.fileExists(atPath: file.path) ? "not a readable image: \(path)" : "image not found: \(path)"
            }
            self.needsDisplay = true
        }
        watch()
    }

    /// One FSEvents stream on the directory holding the file while live (the nearest existing
    /// ancestor when it doesn't exist yet), so a chart re-saved in place, or written later, shows.
    private func watch() {
        guard live, window != nil, !path.isEmpty else {
            events = nil
            return
        }
        let target = FileEvents.canonical(file.path)
        let directory = FileEvents.watchableDirectory(for: target)
        guard events?.directories != [directory] else { return }
        events = FileEvents(directories: [directory]) { [weak self] paths in
            guard paths.contains(target) else { return }
            self?.scheduleReload()
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            events = nil
            pendingReload?.cancel()
        } else {
            watch()
        }
    }

    // MARK: Geometry and drawing

    /// The body minus the caption strip.
    private func pictureArea(_ size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - (caption == nil ? 0 : LocalImage.captionHeight)))
    }

    /// Where the picture draws: aspect-fit and centered in the picture area, never scaled up past
    /// its natural size.
    private func pictureRect(_ size: CGSize) -> CGRect? {
        guard let natural = picture?.size, natural.width > 0, natural.height > 0 else { return nil }
        let area = pictureArea(size)
        let scale = min(area.width / natural.width, area.height / natural.height, 1)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        paint(in: bounds)
    }

    /// Picture, caption, or the reason there is none; `bounds` is the body (top-left origin).
    private func paint(in bounds: CGRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        if let picture, let rect = pictureRect(bounds.size) {
            picture.image.drawUpright(in: rect)
        } else if loaded, let failure {
            let text = NSAttributedString(string: failure, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size()
            text.draw(at: CGPoint(x: max(8, (bounds.width - size.width) / 2), y: max(8, (pictureArea(bounds.size).height - size.height) / 2)))
        }
        guard let caption else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let strip = CGRect(x: 10, y: bounds.height - LocalImage.captionHeight + 4, width: max(0, bounds.width - 20), height: LocalImage.captionHeight - 8)
        NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
            .draw(with: strip, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live {
            watch()
            if stale {
                stale = false
                reload()
            }
        } else {
            // Not watching: the next time it's live the file is read again.
            events = nil
            stale = true
        }
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        if !loaded || stale {
            stale = false
            reload()
            await loadTask?.value
        }
        let image = request.image { bounds in paint(in: bounds) }
        guard let image else { return TileRender(image: nil, contentSize: request.size, state: .failed, reason: "bitmap allocation failed") }
        return TileRender(image: image, contentSize: request.size, state: .rendered)
    }

    /// A pixel of the picture (in the image's own pixels from its top-left), else the tile.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let natural = picture?.size, let rect = pictureRect(bounds.size), rect.contains(point) else { return .object(object.id) }
        let x = Int(((point.x - rect.minX) / rect.width * natural.width).rounded(.down))
        let y = Int(((point.y - rect.minY) / rect.height * natural.height).rounded(.down))
        return .image(object: object.id, path: path, x: min(max(0, x), Int(natural.width) - 1), y: min(max(0, y), Int(natural.height) - 1))
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .image = target, let rect = pictureRect(bounds.size) else { return bounds }
        return rect
    }

    var takesKeyboardFocus: Bool { false }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        if previous.props["path"] != object.props["path"] {
            events = nil
            reload()
        } else if previous.props["caption"] != object.props["caption"] {
            needsDisplay = true
        }
    }
}
