import AppKit
import CanvasCore

/// Read-only source view (TextKit 2). Skeleton scope: file text with line numbers, the object's
/// range highlighted and scrolled into view, live reload on file change, and line/selection
/// mentions. Diff presentation and language features arrive in the code-tiles slice.
@MainActor
final class CodeTile: NSView, TileContent {
    private(set) var object: CanvasObject
    private let board: Board
    private let scroll = NSScrollView()
    private let text: NSTextView
    private var lineStarts: [Int] = []
    private var numberWidth = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pendingScrollLine: Int?
    var onFocusRelease: (() -> Void)?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        text = NSTextView(usingTextLayoutManager: true)
        super.init(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = NSColor.textBackgroundColor
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var path: String { object.props["path"]?.string ?? "" }

    var range: LineRange? {
        guard let start = object.props["range"]?["start"]?.int else { return nil }
        return LineRange(start: start, end: object.props["range"]?["end"]?.int ?? start)
    }

    func update(_ object: CanvasObject) {
        let moved = object.props["path"] != self.object.props["path"] || object.props["range"] != self.object.props["range"]
        self.object = object
        if moved { reload() }
    }

    private func reload() {
        let url = board.absoluteURL(path)
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? "(cannot read \(url.path))"
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        numberWidth = max(3, String(lines.count).count)
        let attributed = NSMutableAttributedString()
        let dim = [NSAttributedString.Key.font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let body = [NSAttributedString.Key.font: Self.font, .foregroundColor: NSColor.labelColor]
        lineStarts = []
        let highlight = range
        for (index, line) in lines.enumerated() {
            lineStarts.append(attributed.length)
            let number = String(index + 1)
            attributed.append(NSAttributedString(string: String(repeating: " ", count: numberWidth - number.count) + number + "  ", attributes: dim))
            attributed.append(NSAttributedString(string: String(line) + "\n", attributes: body))
            if let highlight, (highlight.start...highlight.end).contains(index + 1) {
                let lineRange = NSRange(location: lineStarts[index], length: attributed.length - lineStarts[index])
                attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.22), range: lineRange)
            }
        }
        text.textStorage?.setAttributedString(attributed)
        if let highlight { scrollTo(line: highlight.start) }
        watch(url.path)
    }

    private func scrollTo(line: Int) {
        guard line >= 1, line <= lineStarts.count else { return }
        // Before the tile is in a window the text view has no layout to scroll; retry once it is.
        guard window != nil else {
            pendingScrollLine = line
            return
        }
        pendingScrollLine = nil
        let target = NSRange(location: lineStarts[max(0, line - 4)], length: 0)
        if let layout = text.textLayoutManager, let content = layout.textContentManager,
           let location = content.location(content.documentRange.location, offsetBy: target.location),
           let upToTarget = NSTextRange(location: content.documentRange.location, end: location) {
            // Lay out through the target and grow the text view to match; an occluded window
            // never runs the display pass that would otherwise size it, and scrolling clamps to it.
            layout.ensureLayout(for: upToTarget)
            text.sizeToFit()
            if let fragment = layout.textLayoutFragment(for: location) {
                text.scroll(NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY))
                return
            }
        }
        text.scrollRangeToVisible(target)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let line = pendingScrollLine {
            DispatchQueue.main.async { [weak self] in self?.scrollTo(line: line) }
        }
    }

    /// Reload when the file is written or replaced (editors and agents often rename over it).
    private func watch(_ path: String) {
        guard path != watchedPath else { return }
        watcher?.cancel()
        watchedPath = path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let renamed = !source.data.intersection([.rename, .delete]).isEmpty
            if renamed { self.watchedPath = nil }
            self.reload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// 1-based source line at a character index.
    private func line(atCharacter index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        if !live { watcher?.suspend() } else { watcher?.resume() }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        let selection = text.selectedRange()
        let lines: LineRange
        if selection.length > 0 {
            lines = LineRange(start: line(atCharacter: selection.location), end: line(atCharacter: selection.location + selection.length - 1))
        } else {
            let local = text.convert(point, from: self)
            let index = text.characterIndexForInsertion(at: local)
            let hit = line(atCharacter: index)
            lines = LineRange(start: hit, end: hit)
        }
        return .code(object: object.id, path: path, lines: lines, side: nil, symbol: nil)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, _, let lines, _, _) = target, lines.start <= lineStarts.count,
              let layout = text.textLayoutManager, let content = layout.textContentManager else { return nil }
        let start = lineStarts[lines.start - 1]
        let end = lines.end < lineStarts.count ? lineStarts[lines.end] : (text.string as NSString).length
        guard let startLocation = content.location(content.documentRange.location, offsetBy: start),
              let endLocation = content.location(content.documentRange.location, offsetBy: end),
              let textRange = NSTextRange(location: startLocation, end: endLocation) else { return nil }
        var union = NSRect.null
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            union = union.union(rect)
            return true
        }
        guard !union.isNull else { return nil }
        let inText = NSRect(x: 0, y: union.minY + text.textContainerInset.height, width: text.bounds.width, height: union.height)
        return convert(inText, from: text).intersection(bounds)
    }

    var takesKeyboardFocus: Bool { false }
}
