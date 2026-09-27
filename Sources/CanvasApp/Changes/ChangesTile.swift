import AppKit
import CanvasCore

/// The changes tile (`type: changes`): every file that differs from the tile's base (default
/// HEAD: the uncommitted work) under its paths, each with its hunks as a highlighted unified
/// diff, Stage and Revert per hunk and per file (each one ⌘Z step, `Board.recordReview`), live
/// while files change. Drawn straight from the model like code tiles (`ChangesPainter`); git runs
/// off the main thread and only while the tile is live.
@MainActor
final class ChangesTile: NSView, TileContent {
    private(set) var object: CanvasObject
    private let board: Board
    /// A click on a line opened (`created`) or re-aimed this code tile.
    var onOpenedCode: ((ObjectID, _ created: Bool) -> Void)?

    private var set: ChangeSet?
    private var painter: ChangesPainter?
    private var collapsed: Set<String> = []
    /// The hunk the keys act on, by file and index.
    private var current: (file: Int, hunk: Int)?
    private var scroll: CGFloat = 0
    private var message: String?
    private var messageWork: DispatchWorkItem?
    private let cache = ChangesLineCache()

    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var events: FileEvents?
    private var reloadWork: DispatchWorkItem?
    /// A Stage or Revert is being applied; others wait for it (they'd be built from old rows).
    private var acting = false

    static let tooltip = """
    Changes against the tile's base (props.base: HEAD, merge-base, or a commit). Click a line to open it in a code tile; \
    Hyper-click (⌃⌥⇧⌘) a line or hunk header to mention it; click a file's header to fold it.
    Keys once you click into the tile: j or ↓ next hunk, k or ↑ previous hunk, Return open the hunk in a code tile, \
    s stage the hunk, r revert the hunk, Esc back to the canvas. With the tile only selected: j/k, ↓/↑, Return.
    Every Stage and Revert is one ⌘Z.
    """

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(repositoryChanged(_:)), name: .gitDiffBaseChanged, object: nil)
        center.addObserver(self, selector: #selector(repositoryChanged(_:)), name: .reviewPatchApplied, object: nil)
        center.addObserver(self, selector: #selector(patchFailed(_:)), name: .reviewPatchFailed, object: object.id)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    private var hasKeyboard: Bool { window?.firstResponder === self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isLive, needsLoad { load() }
        refreshToolTip()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampScroll()
        refreshToolTip()
        needsDisplay = true
    }

    private var spec: ChangesSpec { ChangesSpec(object.props) }

    /// Posted off the main thread by the git engine, or on it after a patch applied.
    @objc nonisolated private func repositoryChanged(_ note: Notification) {
        let path = note.object as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.set?.repository?.path || self.set?.repository == nil else { return }
                self.scheduleReload(after: 0.05)
            }
        }
    }

    @objc nonisolated private func patchFailed(_ note: Notification) {
        let text = note.userInfo?["message"] as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.show(message: text ?? "couldn't apply") }
        }
    }

    // MARK: Loading

    func update(_ object: CanvasObject) {
        let old = ChangesSpec(self.object.props)
        self.object = object
        if ChangesSpec(object.props) != old { load() } else { refreshPainter() }
    }

    /// Lists and diffs the changes (git and parsing off the main thread) and installs them.
    /// Deferred until the tile is live.
    private func load() {
        guard isLive else {
            needsLoad = true
            return
        }
        needsLoad = false
        generation += 1
        let current = generation, root = board.root, spec = spec
        loadTask = Task { [weak self] in
            let set = await ChangeSet.load(root: root, spec: spec)
            await MainTurns.next()
            guard let self, current == self.generation, self.isLive else { return }
            self.loadTask = nil
            self.install(set)
            self.watch(set.repository)
        }
    }

    /// A new listing: the current hunk stays the same file and position (the next one when it
    /// went, e.g. reverted), folds stay folded, and the scroll stays put.
    private func install(_ set: ChangeSet) {
        let previous = current.flatMap { current in self.set.map { ($0.files[current.file].boardPath, current.hunk) } }
        self.set = set
        cache.removeAll()
        if let (path, hunk) = previous {
            if let file = set.files.firstIndex(where: { $0.boardPath == path }), !set.files[file].hunks.isEmpty {
                current = (file, min(hunk, set.files[file].hunks.count - 1))
            } else {
                current = set.hunkOrder.first { set.files[$0.file].boardPath > path }.map { ($0.file, $0.hunk) } ?? set.hunkOrder.last.map { ($0.file, $0.hunk) }
            }
        }
        refreshPainter()
    }

    private func refreshPainter() {
        guard let set else {
            painter = nil
            needsDisplay = true
            return
        }
        var painter = ChangesPainter(set: set, collapsed: collapsed)
        painter.current = current
        painter.message = message
        painter.focused = hasKeyboard
        painter.baseProp = spec.baseProp
        self.painter = painter
        clampScroll()
        needsDisplay = true
    }

    /// Working-tree writes, and the index, HEAD, and refs in the git directory, reload the
    /// listing (debounced); objects, logs, and lock files don't.
    private func watch(_ repository: URL?) {
        guard let repository else { return events = nil }
        let top = FileEvents.canonical(repository.path)
        guard events?.directories != [top] else { return }
        events = FileEvents(directories: [top], latency: 0.3) { [weak self] paths in
            guard paths.contains(where: Self.matters) else { return }
            self?.scheduleReload(after: 0.2)
        }
    }

    nonisolated static func matters(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return !path.hasSuffix("/.git") }
        let inside = path[range.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/") || inside == "packed-refs"
    }

    private func scheduleReload(after delay: TimeInterval) {
        guard isLive else {
            needsLoad = true
            return
        }
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadWork = nil
                self?.load()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.ChangesTile", since: perfStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard var painter else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            ("loading changes…" as NSString).draw(at: NSPoint(x: 12, y: 8), withAttributes: attributes)
            return
        }
        painter.focused = hasKeyboard
        painter.draw(in: context, size: bounds.size, scroll: scroll, cache: cache)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cache.removeAll()
        needsDisplay = true
    }

    private var viewportHeight: CGFloat { max(0, bounds.height - ChangesMetrics.headerHeight) }

    private func clampScroll() {
        let content = (painter?.rows.height ?? 0) + ChangesMetrics.bottomPadding
        scroll = min(max(0, scroll), max(0, content - viewportHeight)).rounded()
    }

    private func refreshToolTip() {
        removeAllToolTips()
        guard isLive, window != nil else { return }
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width, height: ChangesMetrics.headerHeight), owner: Self.tooltip as NSString, userData: nil)
    }

    /// A refusal or failure in the header for a few seconds.
    private func show(message text: String) {
        message = text
        refreshPainter()
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.message = nil
                self?.refreshPainter()
            }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= CodeMetrics.rowHeight
            dy *= CodeMetrics.rowHeight
        }
        let content = (painter?.rows.height ?? 0) + ChangesMetrics.bottomPadding
        guard abs(dy) >= abs(dx), dy != 0, content > viewportHeight + 0.5 else { return super.scrollWheel(with: event) }
        scroll -= dy
        clampScroll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let painter, let set else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = painter.row(at: point, scroll: scroll) else { return }
        let action = painter.button(at: point, row: index, width: bounds.width, scroll: scroll)
        switch painter.rows.rows[index] {
        case .file(let file):
            if let action { return perform(action, file: file, hunk: nil) }
            let path = set.files[file].boardPath
            if collapsed.remove(path) == nil { collapsed.insert(path) }
            refreshPainter()
        case .hunk(let file, let hunk):
            current = (file, hunk)
            refreshPainter()
            if let action { perform(action, file: file, hunk: hunk) }
        case .line(let file, let hunk, let line):
            current = (file, hunk)
            refreshPainter()
            open(file: file, hunk: hunk, line: line)
        default:
            break
        }
    }

    // MARK: Keyboard

    /// j/k, ↓/↑, and Return: also while the tile is only selected (the canvas's keyboard).
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, painter != nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (125, _), (_, "j"): step(1)
        case (126, _), (_, "k"): step(-1)
        case (36, _), (76, _): openCurrent()
        default: return false
        }
        return true
    }

    /// s and r only with the keyboard in the tile, so typing elsewhere can never stage or revert.
    override func keyDown(with event: NSEvent) {
        if handleNavigationKey(event) { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (53, _): (enclosingScrollView as? CanvasView)?.takeKeyboard(object.id)
        case (_, "s"): actOnCurrent(.stage)
        case (_, "r"): actOnCurrent(.revert)
        default: super.keyDown(with: event)
        }
    }

    private func actOnCurrent(_ action: ChangesAction) {
        guard let current else { return show(message: "pick a hunk first (j/k or click)") }
        perform(action, file: current.file, hunk: current.hunk)
    }

    /// The next or previous hunk becomes current (unfolding its file) and scrolls into view.
    private func step(_ delta: Int) {
        guard let set else { return }
        let order = set.hunkOrder
        guard !order.isEmpty else { return }
        let index = current.flatMap { current in order.firstIndex { $0 == current } }.map { min(max(0, $0 + delta), order.count - 1) } ?? (delta > 0 ? 0 : order.count - 1)
        let target = order[index]
        current = (target.file, target.hunk)
        collapsed.remove(set.files[target.file].boardPath)
        refreshPainter()
        reveal(file: target.file, hunk: target.hunk)
    }

    /// Scrolls the hunk's header near the top, unless all of it is already in view.
    private func reveal(file: Int, hunk: Int) {
        guard let painter, let row = painter.rows.index(ofHunk: file, hunk) else { return }
        let top = painter.rows.tops[row]
        let bottom = top + ChangesMetrics.hunkHeight + CGFloat(painter.set.files[file].hunks[hunk].lines.count) * ChangesMetrics.lineHeight
        if top < scroll || bottom > scroll + viewportHeight {
            scroll = top - ChangesMetrics.fileHeight
            clampScroll()
            needsDisplay = true
        }
    }

    // MARK: Actions

    private func openCurrent() {
        guard let current, let line = set?.openLine(file: current.file, hunk: current.hunk) else { return }
        openCode(file: current.file, line: line)
    }

    /// A clicked line in a code tile beside this one: its working-tree line (a removed line's
    /// place in the working tree; a deleted file's base line).
    private func open(file: Int, hunk: Int, line: Int) {
        guard let set, let location = set.location(file: file, hunk: hunk, line: line) else { return }
        let target = location.side == .old && set.files[file].status != .deleted ? set.openLine(file: file, hunk: hunk) ?? location.line : location.line
        openCode(file: file, line: target)
    }

    private func openCode(file: Int, line: Int) {
        guard let set else { return }
        let path = set.files[file].boardPath
        guard let opened = try? board.showCode(path: path, range: LineRange(start: line, end: line), beside: object.id, extra: ["diffBase": .string(spec.baseProp)]) else { return }
        onOpenedCode?(opened.id, opened.created)
    }

    /// Stage or revert one hunk (nil: the whole file): the patch is built, applied, and recorded
    /// as one undo step; a refusal shows in the header and changes nothing.
    private func perform(_ action: ChangesAction, file: Int, hunk: Int?) {
        guard !acting, let set, let repository = set.repository, set.files.indices.contains(file) else { return }
        let changed = set.files[file]
        let hunks = hunk.map { [changed.hunks[$0]] }
        if action == .stage, let hunks, hunks.allSatisfy({ $0.status != .unstaged }) { return show(message: "already staged") }
        acting = true
        var entry: [String: JSONValue] = ["action": .string(action == .stage ? "stage" : "revert"), "path": .string(changed.boardPath),
                                          "scope": .string(hunk == nil ? "file" : "hunk"), "status": .string(changed.status.rawValue)]
        if let hunks {
            entry["header"] = .string(hunks[0].header)
            entry["added"] = .number(Double(hunks[0].added))
            entry["removed"] = .number(Double(hunks[0].removed))
        } else {
            entry["added"] = .number(Double(changed.added))
            entry["removed"] = .number(Double(changed.removed))
        }
        let tile = object.id, board = board
        Task { [weak self] in
            defer { self?.acting = false }
            do {
                let patch = action == .stage ? try await ReviewPatch.stage(hunks, of: changed, in: repository)
                    : try ReviewPatch.revert(hunks ?? changed.hunks, of: changed, in: repository)
                try await ReviewGit.shared.apply(patch)
                try board.recordReview(tile: tile, entry: .object(entry), patch: patch)
            } catch let failure as ChangesFailure {
                self?.show(message: "\(action.rawValue) refused: \(failure.message)")
            } catch {
                self?.show(message: "\(action.rawValue) failed: \(error)")
            }
        }
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            refreshToolTip()
            if needsLoad || events == nil { load() }
        } else {
            if loadTask != nil || reloadWork != nil { needsLoad = true }
            loadTask?.cancel()
            loadTask = nil
            reloadWork?.cancel()
            reloadWork = nil
            // Nothing watched, laid out, or tracked while the card covers the tile.
            events = nil
            needsLoad = true
            cache.removeAll()
            layer?.contents = nil
            removeAllToolTips()
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let painter, let set, let index = painter.row(at: point, scroll: scroll) else { return nil }
        switch painter.rows.rows[index] {
        case .line(let file, let hunk, let line):
            guard let location = set.location(file: file, hunk: hunk, line: line) else { return nil }
            return mention(file: file, path: location.path, lines: LineRange(start: location.line, end: location.line), side: location.side)
        case .hunk(let file, let hunk):
            let changed = set.files[file], target = changed.hunks[hunk]
            let whole = target.mentionLines
            return mention(file: file, path: whole.side == .old ? changed.oldBoardPath ?? changed.boardPath : changed.boardPath, lines: whole.lines, side: whole.side)
        default:
            return nil
        }
    }

    /// A mention names the lines on their side and the base they were diffed against, so the
    /// prompt quotes them however the tile changes before the tray drains.
    private func mention(file: Int, path: String, lines: LineRange, side: DiffSide) -> MentionTarget {
        let symbol = set?.files[file].symbol(line: lines.start, side: side)
        return .code(object: object.id, path: path, lines: lines, side: set?.base == nil ? nil : side.rawValue, symbol: symbol, commit: set?.base)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(let id, let path, let lines, let side, _, _) = target, id == object.id, let painter, let set else { return nil }
        var union: NSRect?
        for index in painter.rows.visible(from: scroll, to: scroll + viewportHeight) {
            guard case .line(let file, let hunk, let line) = painter.rows.rows[index], let location = set.location(file: file, hunk: hunk, line: line),
                  location.path == path, location.side.rawValue == (side ?? DiffSide.new.rawValue), lines.start <= location.line, location.line <= lines.end else { continue }
            let rect = painter.rect(ofRow: index, width: bounds.width, scroll: scroll)
            union = union.map { $0.union(rect) } ?? rect
        }
        return union?.intersection(NSRect(x: 0, y: ChangesMetrics.headerHeight, width: bounds.width, height: viewportHeight))
    }

    var takesKeyboardFocus: Bool { false }

    func render(_ request: TileRenderRequest) async -> TileRender {
        var loaded = set
        if loaded == nil {
            let fresh = await ChangeSet.load(root: board.root, spec: spec)
            guard !Task.isCancelled else { return .placeholder(request, "cancelled") }
            if set == nil {
                install(fresh)
                // Not live: revalidate the next time it is.
                if !isLive { needsLoad = true }
            }
            loaded = fresh
        }
        guard let loaded else { return .placeholder(request, "not loaded") }
        var painter = ChangesPainter(set: loaded, collapsed: collapsed)
        painter.current = current
        painter.message = message
        painter.baseProp = spec.baseProp
        let content = CGSize(width: request.size.width, height: painter.contentHeight)
        let size = request.full ? CGSize(width: request.size.width, height: max(request.size.height, content.height)) : request.size
        let scrollY = request.full ? 0 : scroll
        let image = request.image(size: size) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            painter.draw(in: context, size: rect.size, scroll: scrollY, cache: nil)
        }
        guard let image else { return TileRender(image: nil, contentSize: content, state: .failed, reason: "could not allocate the bitmap") }
        return TileRender(image: image, contentSize: content, state: .rendered, reason: nil)
    }
}
