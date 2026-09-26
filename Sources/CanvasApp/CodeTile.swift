import AppKit
import CanvasCore

/// Read-only code tile (TextKit 2 + tree-sitter). Diff mode (the default) shows the whole file
/// against the tile's diff base with real deleted rows interleaved; source mode shows the file.
/// The object's `range` is tinted and scrolled into view. Git and parsing run off the main
/// thread and only while the tile is live; file changes reload after a short debounce.
@MainActor
final class CodeTile: NSView, TileContent {
    private(set) var object: CanvasObject
    private let board: Board
    private let header = CodeHeaderBar(frame: .zero)
    private let scroll = NSScrollView()
    private let text: CodeTextView

    /// The loaded diff and what was rendered from it.
    private var diff: FileDiff?
    private var rendered: Rendered?
    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var renderGeneration = 0
    private var pendingScrollRow: Int?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Dispatch sources must be resumed before they are released, so suspension is tracked.
    private var watcherSuspended = false
    private var reloadWork: DispatchWorkItem?
    private var snapshotCover: NSImageView?

    /// What the background render produced; the attributed text is built off the main thread
    /// and handed over once.
    private struct Rendered: @unchecked Sendable {
        var display: DiffDisplay
        var old: SyntaxAnalysis
        var new: SyntaxAnalysis
        var attributed: NSAttributedString
    }

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        text = CodeTextView(usingTextLayoutManager: true)
        super.init(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.onEditHere = { [weak self] point in self?.editHere(at: point) }
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        addSubview(header)
        header.onMode = { [weak self] mode in self?.setMode(mode) }
        header.onHunk = { [weak self] forward in self?.jumpToHunk(forward: forward) }
        header.onPin = { [weak self] in self?.pin() }
        header.onLocation = { [weak self] location in self?.aim(at: location) }
        NotificationCenter.default.addObserver(self, selector: #selector(baseChanged), name: .gitDiffBaseChanged, object: nil)
        refreshHeader()
        resizeSubviews(withOldSize: .zero)
        load()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if watcherSuspended { watcher?.resume() }
        watcher?.cancel()
    }

    /// Posted off the main thread by the git engine when a commit, checkout, or fetch moved a base.
    @objc nonisolated private func baseChanged() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let height = header.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        scroll.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }

    // MARK: Props

    var path: String { object.props["path"]?.string ?? "" }

    var range: LineRange? {
        guard let start = object.props["range"]?["start"]?.int else { return nil }
        return LineRange(start: start, end: object.props["range"]?["end"]?.int ?? start)
    }

    var mode: DiffDisplay.Mode { DiffDisplay.Mode(rawValue: object.props["mode"]?.string ?? "") ?? .diff }
    private var diffBase: DiffBase { DiffBase(prop: object.props["diffBase"]?.string) }
    private var followOf: ObjectID? { object.props["followOf"]?.string }

    func update(_ object: CanvasObject) {
        let old = self.object
        self.object = object
        let props = { (key: String) in old.props[key] != object.props[key] }
        refreshHeader()
        if props("path") || props("diffBase") {
            load()
        } else if props("mode") {
            render()
        } else if props("range") {
            // Follow re-aims that only move the range reuse the loaded diff.
            showRange()
        }
    }

    // MARK: Loading

    /// Diff the file against its base (git, off the main thread) and render it. Deferred until
    /// the tile is live.
    private func load() {
        guard isLive else {
            needsLoad = true
            return
        }
        needsLoad = false
        let url = board.absoluteURL(path)
        watch(url)
        let base = diffBase
        loadGeneration += 1
        let current = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let diff = await GitDiffEngine.shared.diff(file: url, base: base)
            guard let self, !Task.isCancelled, current == self.loadGeneration else { return }
            self.loadTask = nil
            self.diff = diff
            if let sha = diff.base {
                self.board.setDiffContext(.init(base: sha, old: diff.old), for: self.object.id)
            }
            self.render()
        }
    }

    /// Rebuild the display (mode switch or new diff): syntax, rows, and attributes off-main.
    private func render() {
        guard let diff else { return }
        let mode = self.mode
        let language = SyntaxLanguage(path: path)
        renderGeneration += 1
        let current = renderGeneration
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { Self.render(diff, mode: mode, language: language) }.value
            guard let self, current == self.renderGeneration else { return }
            self.apply(rendered)
        }
    }

    nonisolated private static func render(_ diff: FileDiff, mode: DiffDisplay.Mode, language: SyntaxLanguage?) -> Rendered {
        let showsOld = diff.state == .deleted || (mode == .diff && diff.state == .modified)
        let new = language.map { Syntax.analyze(diff.new.text, language: $0) } ?? .empty
        let old = language.flatMap { showsOld ? Syntax.analyze(diff.old.text, language: $0) : nil } ?? .empty
        let titles: [String?] = diff.hunks.map { hunk in
            hunk.modified.isEmpty ? old.enclosingSymbol(line: hunk.original.lowerBound) : new.enclosingSymbol(line: hunk.modified.lowerBound)
        }
        let display = DiffDisplay(diff, mode: mode, hunkTitles: titles)
        let spans = display.place(old: old.spans, new: new.spans, diff: diff)
        return Rendered(display: display, old: old, new: new, attributed: attributed(display, spans: spans))
    }

    nonisolated private static func attributed(_ display: DiffDisplay, spans: [SyntaxSpan]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: display.text, attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.labelColor])
        for span in spans {
            result.addAttribute(.foregroundColor, value: CodeTheme.color(span.style), range: span.range)
        }
        for (index, row) in display.rows.enumerated() {
            let gutter = NSRange(location: row.offset, length: min(display.gutterWidth, display.range(ofRow: index).length))
            result.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: gutter)
            switch row.kind {
            case .deleted, .added:
                result.addAttribute(.foregroundColor, value: row.kind == .deleted ? NSColor.systemRed : NSColor.systemGreen, range: NSRange(location: row.offset + display.gutterWidth - 2, length: 1))
            case .header:
                let line = display.range(ofRow: index)
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            case .context:
                break
            }
        }
        return result
    }
}

// MARK: Presentation

extension CodeTile {
    private func apply(_ rendered: Rendered) {
        // Reloads of a file without a range keep the reader's place.
        let keepScroll = self.rendered != nil && range == nil ? scroll.contentView.bounds.origin : nil
        let keepRow = keepScroll.flatMap { text.row(at: $0) } ?? 0
        self.rendered = rendered
        text.textStorage?.setAttributedString(rendered.attributed)
        text.display = rendered.display
        text.minSize = scroll.contentSize
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        refreshHeader()
        if let keepScroll {
            text.ensureLayout(throughRow: keepRow)
            text.scroll(keepScroll)
        } else {
            text.ensureLayout(throughRow: 0)
        }
        showRange()
    }

    /// Tint the object's range and bring it into view.
    private func showRange() {
        guard let rendered, let diff else { return }
        guard let range else {
            text.rangeRows = nil
            return
        }
        // Ranges are new-side lines; a deleted file only has old ones.
        let side: DiffSide = diff.state == .deleted ? .old : .new
        text.rangeRows = rendered.display.rows(for: range, side: side, hunks: [])
        if let row = text.rangeRows?.lowerBound ?? rendered.display.row(showing: range.start, side: side) {
            scroll(toRow: row)
        }
    }

    private func scroll(toRow row: Int) {
        // Before the tile is in a window the text view has no layout to scroll; retry once it is.
        guard window != nil else {
            pendingScrollRow = row
            return
        }
        pendingScrollRow = nil
        text.scroll(toRow: row)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let row = pendingScrollRow {
            DispatchQueue.main.async { [weak self] in self?.scroll(toRow: row) }
        }
    }

    private func refreshHeader() {
        let hunks = mode == .diff && !(diff?.hunks.isEmpty ?? true)
        header.show(mode: mode, status: statusText, hunks: hunks, follow: followOf != nil)
        let history = (object.props["history"]?.array ?? []).compactMap { entry -> CodeHeaderBar.Location? in
            guard let path = entry["path"]?.string else { return nil }
            let start = entry["range"]?["start"]?.int
            return CodeHeaderBar.Location(path: path, range: start.map { LineRange(start: $0, end: entry["range"]?["end"]?.int ?? $0) })
        }
        let before = header.height
        header.show(history: followOf == nil ? [] : history, current: CodeHeaderBar.Location(path: path, range: range))
        if header.height != before { resizeSubviews(withOldSize: bounds.size) }
    }

    private var statusText: String {
        guard let diff else { return "loading…" }
        let base = diff.base.map { " · \(diff.baseLabel ?? "base") \($0.prefix(7))" } ?? diff.baseLabel.map { " · \($0)" } ?? ""
        switch diff.state {
        case .modified: return "+\(diff.addedCount) −\(diff.removedCount)\(base)"
        case .unchanged: return "no changes\(base)"
        case .added: return "new file · +\(diff.addedCount)\(base)"
        case .deleted: return "deleted · −\(diff.removedCount)\(base)"
        case .binary: return "binary file\(base)"
        case .missing: return "file not found: \(path)"
        case .notRepository: return "not in a git repository"
        case .tooLarge: return "file too large to show"
        }
    }

    // MARK: Actions

    private func setMode(_ mode: DiffDisplay.Mode) {
        guard mode != self.mode else { return }
        _ = try? board.update(object.id, props: .object(["mode": .string(mode.rawValue)]))
    }

    /// Scroll to the hunk after (or before) the one nearest the top of the view.
    private func jumpToHunk(forward: Bool) {
        guard let display = rendered?.display, let diff, !diff.hunks.isEmpty else { return }
        let visibleTop = text.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY + text.textContainerOrigin.y + 1)) ?? 0
        // The view parks a jump target three rows below the top; measure from there.
        let anchor = visibleTop + 3
        let headers = diff.hunks.indices.compactMap { display.headerRow(ofHunk: $0) }
        let target = forward ? headers.first { $0 > anchor } ?? headers.first : headers.last { $0 < anchor } ?? headers.last
        if let target { scroll(toRow: target) }
    }

    /// Keep the follow tile's current view as a permanent diff tile beside it.
    private func pin() {
        var props: [String: JSONValue] = ["path": .string(path), "mode": .string(mode.rawValue), "diffBase": object.props["diffBase"] ?? .string("merge-base")]
        if let range = object.props["range"] { props["range"] = range }
        let frame = board.place(width: object.frame.w, height: object.frame.h, near: object.id)
        board.create(type: .code, props: .object(props), frame: frame)
    }

    private func aim(at location: CodeHeaderBar.Location) {
        let range: JSONValue = location.range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        _ = try? board.update(object.id, props: .object(["path": .string(location.path), "range": range]))
    }

    /// Open nvim at the clicked line in a terminal tile beside this one.
    private func editHere(at point: NSPoint) {
        let line = sourceLine(atTextPoint: point, preferring: .new) ?? range?.start ?? 1
        let size = Board.defaultSize(.terminal)
        let frame = board.place(width: size.w, height: size.h, near: object.id)
        board.create(type: .terminal, props: .object([
            "cwd": .string(board.root.path),
            "command": .array(["nvim", "+\(line)", path].map(JSONValue.string)),
        ]), frame: frame)
    }

    /// New-side line of a row; deleted rows and headers map to the nearest following new line.
    private func sourceLine(atTextPoint point: NSPoint, preferring side: DiffSide) -> Int? {
        guard let display = rendered?.display, let row = text.row(at: point) else { return nil }
        for index in row..<display.rows.count {
            if let line = display.rows[index].newLine, display.rows[index].kind != .deleted { return line }
        }
        return display.rows[..<row].last { $0.kind != .deleted && $0.newLine != nil }?.newLine
    }

    // MARK: File watching

    /// Reload (debounced) when the file is written or replaced; editors and agents often rename
    /// over it. A missing file watches its directory so creating it shows up.
    private func watch(_ url: URL) {
        var target = url.path
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) {
            target = url.deletingLastPathComponent().path
        }
        guard target != watchedPath else { return }
        if watcherSuspended { watcher?.resume() }
        watcher?.cancel()
        watcher = nil
        watcherSuspended = false
        watchedPath = target
        let fd = open(target, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.intersection([.rename, .delete]).isEmpty { self.watchedPath = nil }
                self.scheduleReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: TileContent

extension CodeTile {
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            if watcherSuspended { watcher?.resume() }
            watcherSuspended = false
            if needsLoad { load() }
        } else {
            if !watcherSuspended { watcher?.suspend() }
            watcherSuspended = watcher != nil
            reloadWork?.cancel()
            loadTask?.cancel()
            // A cancelled load must run again when the tile comes back.
            if loadTask != nil { needsLoad = true }
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let rendered, let diff, scroll.frame.contains(point) else { return nil }
        let display = rendered.display
        let local = text.convert(point, from: self)
        let selection = text.selectedRange()
        if selection.length > 0, let row = text.row(at: local), let first = display.row(atOffset: selection.location),
           let last = display.row(atOffset: NSMaxRange(selection) - 1), (first...last).contains(row) {
            return target(rows: first...last, display: display, rendered: rendered)
        }
        guard let row = text.row(at: local) else { return nil }
        if display.rows[row].kind == .header, let hunk = display.rows[row].hunk {
            let mention = diff.hunks[hunk].mentionLines
            return code(mention.lines, side: mention.side, rendered: rendered)
        }
        return target(rows: row...row, display: display, rendered: rendered)
    }

    /// The lines a run of rows shows: new-side lines when there are any, else old-side ones.
    private func target(rows: ClosedRange<Int>, display: DiffDisplay, rendered: Rendered) -> MentionTarget? {
        let shown = rows.compactMap { display.rows[$0].sourceLine }
        let side: DiffSide = shown.contains { $0.side == .new } ? .new : .old
        let lines = shown.filter { $0.side == side }.map(\.line)
        guard let first = lines.min(), let last = lines.max() else { return nil }
        return code(LineRange(start: first, end: last), side: side, rendered: rendered)
    }

    private func code(_ lines: LineRange, side: DiffSide, rendered: Rendered) -> MentionTarget {
        let analysis = side == .old ? rendered.old : rendered.new
        let showsDiff = mode == .diff && diff?.base != nil
        return .code(object: object.id, path: path, lines: lines, side: showsDiff ? side.rawValue : nil, symbol: analysis.enclosingSymbol(line: lines.start))
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, _, let lines, let side, _) = target, let rendered, let diff,
              let rows = rendered.display.rows(for: lines, side: side == DiffSide.old.rawValue ? .old : .new, hunks: diff.hunks),
              let frame = text.frame(ofRows: rows) else { return nil }
        return convert(frame, from: text).intersection(scroll.frame)
    }

    var takesKeyboardFocus: Bool { false }

    func showSnapshot(_ show: Bool) {
        snapshotCover?.removeFromSuperview()
        snapshotCover = nil
        guard show, let image = text.renderVisible() else { return }
        let cover = NSImageView(frame: scroll.frame)
        cover.image = image
        cover.imageScaling = .scaleNone
        cover.imageAlignment = .alignTopLeft
        addSubview(cover)
        snapshotCover = cover
    }

    func snapshot() -> NSImage? {
        showSnapshot(true)
        defer { showSnapshot(false) }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: Code navigation (CodeNavigationHost)

extension CodeTile {
    /// Board-relative path of the new side.
    var navigationPath: String { path }

    var navigationTextView: NSTextView { text }

    /// 1-based line and 0-based UTF-16 column on the new side at a point in the text view;
    /// nil on deleted rows, hunk headers, and the gutter.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)? {
        guard let display = rendered?.display, let row = text.row(at: point),
              let shown = display.rows[row].sourceLine, shown.side == .new else { return nil }
        let index = text.characterIndexForInsertion(at: point)
        let lineRange = display.range(ofRow: row)
        let column = index - lineRange.location - display.gutterWidth
        guard column >= 0 else { return nil }
        return (shown.line, min(column, lineRange.length - display.gutterWidth))
    }

    /// Scroll a new-side line into view.
    func reveal(line: Int) {
        guard let row = rendered?.display.row(showing: line, side: .new) else { return }
        scroll(toRow: row)
    }
}
