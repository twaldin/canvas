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

    /// What the text view shows: one file, mode, diff, and its rendering, installed together
    /// so mentions and actions always describe the rows on screen.
    private var shown: Shown?
    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    /// Bumped by every load; only the newest load installs its result.
    private var generation = 0
    /// Repository this tile holds in the git engine while live (bases watched).
    private var heldRepository: String?
    private var pendingScrollRow: Int?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Dispatch sources must be resumed before they are released, so suspension is tracked.
    private var watcherSuspended = false
    private var reloadWork: DispatchWorkItem?
    private var snapshotCover: NSImageView?
    private var navigation: CodeNavigation?

    /// Built off the main thread and handed over once.
    private struct Shown: @unchecked Sendable {
        var path: String
        var mode: DiffDisplay.Mode
        var diff: FileDiff
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
        navigation = CodeNavigation(host: self, board: board, tile: object.id, accessories: header, reservedWidth: CodeHeaderBar.reservedTrailing)
        load()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if watcherSuspended { watcher?.resume() }
        watcher?.cancel()
        if let heldRepository { Task { await GitDiffEngine.shared.release(heldRepository) } }
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
        let changed = { (key: String) in old.props[key] != object.props[key] }
        refreshHeader()
        if changed("path") || changed("diffBase") || changed("mode") {
            load()
        } else if changed("range") {
            // Follow re-aims that only move the range reuse the loaded diff.
            showRange()
        }
    }

    /// Whether the rows on screen are the file and mode the object asks for; while a reload
    /// changes either, mentions and navigation wait for it.
    private var showsCurrent: Bool { shown.map { $0.path == path && $0.mode == mode } ?? false }

    // MARK: Loading

    /// Diff the file against its base (git, off the main thread), render it off the main thread,
    /// and install both at once. Deferred until the tile is live.
    private func load() {
        guard isLive else {
            needsLoad = true
            return
        }
        needsLoad = false
        let path = self.path
        let url = board.absoluteURL(path)
        watch(url)
        let base = diffBase
        let mode = self.mode
        generation += 1
        let current = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let engine = GitDiffEngine.shared
            let held = await engine.retain(containing: url)
            let diff = await engine.diff(file: url, base: base)
            let shown = await offPool { Self.render(diff, path: path, mode: mode) }
            guard let self, !Task.isCancelled, current == self.generation, self.isLive else {
                if let held { await engine.release(held) }
                return
            }
            self.loadTask = nil
            if let previous = self.heldRepository { Task { await engine.release(previous) } }
            self.heldRepository = held
            self.install(shown)
        }
    }

    nonisolated private static func render(_ diff: FileDiff, path: String, mode: DiffDisplay.Mode) -> Shown {
        let language = SyntaxLanguage(path: path)
        let showsOld = diff.state == .deleted || (mode == .diff && diff.state == .modified)
        let new = language.map { Syntax.analyze(diff.new.text, language: $0) } ?? .empty
        let old = language.flatMap { showsOld ? Syntax.analyze(diff.old.text, language: $0) : nil } ?? .empty
        let titles: [String?] = diff.hunks.map { hunk in
            hunk.removesOnly ? old.enclosingSymbol(line: hunk.original.lowerBound) : new.enclosingSymbol(line: hunk.modified.lowerBound)
        }
        let display = DiffDisplay(diff, mode: mode, hunkTitles: titles)
        let spans = display.place(old: old.spans, new: new.spans, diff: diff)
        return Shown(path: path, mode: mode, diff: diff, display: display, old: old, new: new, attributed: attributed(display, spans: spans))
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
    private func install(_ shown: Shown) {
        // Reloads of the same file without a range keep the reader's place.
        let keepScroll = self.shown?.path == shown.path && range == nil ? scroll.contentView.bounds.origin : nil
        let keepRow = keepScroll.flatMap { text.row(at: $0) } ?? 0
        self.shown = shown
        text.textStorage?.setAttributedString(shown.attributed)
        text.display = shown.display
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
        guard let shown, showsCurrent else { return }
        guard let range else {
            text.rangeRows = nil
            return
        }
        // Ranges are new-side lines; a deleted file only has old ones.
        let side: DiffSide = shown.diff.state == .deleted ? .old : .new
        text.rangeRows = shown.display.rows(for: range, side: side, hunks: [])
        if let row = text.rangeRows?.lowerBound ?? shown.display.row(showing: range.start, side: side) {
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
        let hunks = showsCurrent && mode == .diff && !(shown?.diff.hunks.isEmpty ?? true)
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
        guard let diff = shown?.diff, showsCurrent else { return "loading…" }
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
        case .submodule: return "submodule (not a text file)"
        case .unstable: return "file kept changing while diffing; waiting for the next write"
        }
    }

    // MARK: Actions

    private func setMode(_ mode: DiffDisplay.Mode) {
        guard mode != self.mode else { return }
        _ = try? board.update(object.id, props: .object(["mode": .string(mode.rawValue)]))
    }

    /// Scroll to the hunk after (or before) the one nearest the top of the view.
    private func jumpToHunk(forward: Bool) {
        guard let shown, showsCurrent, !shown.diff.hunks.isEmpty else { return }
        let display = shown.display
        let visibleTop = text.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 1)) ?? 0
        // The view parks a jump target three rows below the top; measure from there.
        let anchor = visibleTop + 3
        let headers = shown.diff.hunks.indices.compactMap { display.headerRow(ofHunk: $0) }
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
        guard let shown else { return }
        let line = sourceLine(atTextPoint: point, in: shown.display) ?? range?.start ?? 1
        let size = Board.defaultSize(.terminal)
        let frame = board.place(width: size.w, height: size.h, near: object.id)
        board.create(type: .terminal, props: .object([
            "cwd": .string(board.root.path),
            "command": .array(["nvim", "+\(line)", "--", shown.path].map(JSONValue.string)),
        ]), frame: frame)
    }

    /// New-side line of a row; deleted rows and headers map to the nearest following new line.
    private func sourceLine(atTextPoint point: NSPoint, in display: DiffDisplay) -> Int? {
        guard let row = text.row(at: point) else { return nil }
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
            MainActor.assumeIsolated {
                self?.reloadWork = nil
                self?.load()
            }
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
            // A cancelled load or a pending debounced reload must run when the tile comes back.
            if loadTask != nil || reloadWork != nil { needsLoad = true }
            reloadWork?.cancel()
            reloadWork = nil
            loadTask?.cancel()
            loadTask = nil
            if let heldRepository {
                Task { await GitDiffEngine.shared.release(heldRepository) }
                self.heldRepository = nil
                // Bases aren't watched while offscreen, so revalidate on return.
                needsLoad = true
            }
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let shown, showsCurrent, scroll.frame.contains(point) else { return nil }
        let display = shown.display
        let local = text.convert(point, from: self)
        let selection = text.selectedRange()
        if selection.length > 0, let row = text.row(at: local), let first = display.row(atOffset: selection.location),
           let last = display.row(atOffset: NSMaxRange(selection) - 1), (first...last).contains(row) {
            return target(rows: first...last, in: shown)
        }
        guard let row = text.row(at: local) else { return nil }
        if display.rows[row].kind == .header, let hunk = display.rows[row].hunk {
            let mention = shown.diff.hunks[hunk].mentionLines
            return code(mention.lines, side: mention.side, in: shown)
        }
        return target(rows: row...row, in: shown)
    }

    /// The lines a run of rows shows: new-side lines when there are any, else old-side ones.
    private func target(rows: ClosedRange<Int>, in shown: Shown) -> MentionTarget? {
        let lines = rows.compactMap { shown.display.rows[$0].sourceLine }
        let side: DiffSide = lines.contains { $0.side == .new } ? .new : .old
        let numbers = lines.filter { $0.side == side }.map(\.line)
        guard let first = numbers.min(), let last = numbers.max() else { return nil }
        return code(LineRange(start: first, end: last), side: side, in: shown)
    }

    /// In diff mode the mention carries its base commit, so the prompt can quote old-side lines
    /// and name the base however the tile changes before the tray drains.
    private func code(_ lines: LineRange, side: DiffSide, in shown: Shown) -> MentionTarget {
        let analysis = side == .old ? shown.old : shown.new
        let base = shown.mode == .diff ? shown.diff.base : nil
        return .code(object: object.id, path: shown.path, lines: lines, side: base == nil ? nil : side.rawValue,
                     symbol: analysis.enclosingSymbol(line: lines.start), commit: base)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, let side, _, _) = target, let shown, showsCurrent, path == shown.path,
              let rows = shown.display.rows(for: lines, side: side == DiffSide.old.rawValue ? .old : .new, hunks: shown.diff.hunks),
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

    /// Captures the tile as shown; content loads only while live, so an offscreen tile is a placeholder.
    func render(_ request: TileRenderRequest) async -> TileRender {
        guard isLive, shown != nil else { return .placeholder(request, "code loads only while the tile is on screen") }
        showSnapshot(true)
        defer { showSnapshot(false) }
        let image = request.image(of: self)
        return TileRender(image: image, contentSize: request.size, state: image == nil ? .failed : .rendered)
    }
}

// MARK: Code navigation (CodeNavigationHost)

extension CodeTile: CodeNavigationHost {
    /// Board-relative path of the new side.
    var navigationPath: String { path }

    var navigationTextView: NSTextView { text }

    /// 1-based line and 0-based UTF-16 column on the new side at a point in the text view;
    /// nil on deleted rows, hunk headers, and the gutter.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)? {
        guard let display = shown?.display, showsCurrent, let row = text.row(at: point),
              let shown = display.rows[row].sourceLine, shown.side == .new else { return nil }
        let index = text.characterIndexForInsertion(at: point)
        let lineRange = display.range(ofRow: row)
        let column = index - lineRange.location - display.gutterWidth
        guard column >= 0 else { return nil }
        return (shown.line, min(column, lineRange.length - display.gutterWidth))
    }

    /// Scroll a new-side line into view.
    func reveal(line: Int) {
        guard showsCurrent, let row = shown?.display.row(showing: line, side: .new) else { return }
        scroll(toRow: row)
    }
}
