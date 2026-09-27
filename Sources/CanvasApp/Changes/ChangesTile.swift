import AppKit
import CanvasCore

/// The changes tile (`type: changes`): every file that differs from the tile's base (default
/// HEAD: the uncommitted work) under its paths, in the board's worktree or another worktree of
/// its repository (`props.root`), each with its hunks as a highlighted unified diff, Stage and
/// Discard per file, hunk, or selected lines (each one ⌘Z step, `Board.recordReview`), a file
/// list and filter to find files, and Viewed checks that fold files until their diff changes.
/// Live while files change. Drawn straight from the model like code tiles (`ChangesPainter`);
/// git runs off the main thread and only while the tile is live.
@MainActor
final class ChangesTile: NSView, TileContent, NSSearchFieldDelegate, NSViewToolTipOwner {
    private(set) var object: CanvasObject
    private let board: Board
    /// A click on a line opened (`created`) or re-aimed this code tile.
    var onOpenedCode: ((ObjectID, _ created: Bool) -> Void)?
    /// With every listing of the board's own checkout: the branch checked out there (nil when
    /// detached), which the title names.
    var onBranch: ((String?) -> Void)?

    private var set: ChangeSet?
    private var painter: ChangesPainter?
    private var collapsed: Set<String> = []
    /// Files listed before: a deleted or viewed file starts folded the first time it shows up,
    /// and stays as the user leaves it after that.
    private var seen: Set<String> = []
    /// Files folded because they were marked Viewed: they unfold when their diff changes.
    private var viewedFolded: Set<String> = []
    /// The hunk the keys act on, by file and index.
    private var current: (file: Int, hunk: Int)?
    /// Lines picked in one hunk (with the other half of each edited line, `pairedRows`), and
    /// the line a ⇧-click or drag extends from.
    private var selection: (file: Int, hunk: Int, lines: Set<Int>)?
    private var anchor: (file: Int, hunk: Int, line: Int)?
    /// A line pressed and not yet dragged: releasing it opens the line.
    private var pressed: (file: Int, hunk: Int, line: Int)?
    private var dragged = false
    private var filter = ""
    private var listOpen = true
    private var scroll: CGFloat = 0
    private var message: String?
    private var messageWork: DispatchWorkItem?
    private let cache = ChangesLineCache()
    private var filterField: NSSearchField?
    /// Who a trackpad gesture scrolls, decided by its first movement and kept to its end
    /// (momentum included): the tile never hands a gesture to the canvas halfway.
    private var gestureOwner: GestureOwner?
    private enum GestureOwner { case tile, canvas }
    private var toolTipWork: DispatchWorkItem?
    /// The rows of the last painter and what they were laid out for: stepping through hunks or
    /// selecting lines doesn't rewrap every line.
    private var laidOut: (key: LayoutKey, rows: ChangeRows, names: [String])?
    private struct LayoutKey: Equatable {
        var version: Int
        var collapsed: Set<String>
        var columns: Int
        var filter: String
        var listOpen: Bool
    }
    /// Bumped with every listing installed.
    private var setVersion = 0

    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var events: FileEvents?
    private var reloadWork: DispatchWorkItem?
    /// A Stage or Discard is being applied; others wait for it (they'd be built from old rows).
    private var acting = false
    /// The listing after an action: its current hunk scrolls into view.
    private var revealAfterLoad = false

    static let tooltip = """
    Click a line to open it in a code tile; drag over lines, ⇧-click or ⌘-click to select lines (an edited line brings its old version), then Stage or Discard just those; \
    Hyper-click (⌃⌥⇧⌘) a line or hunk header to mention it; click a file's header to fold it, its Viewed box to fold it until it changes.
    Keys once the tile has the keyboard (↩ or a click): j or ↓ next hunk, k or ↑ previous hunk, J or ] next file, K or [ previous file, \
    / filter files, Return open the hunk in a code tile, s stage, r discard (the selected lines, else the hunk), Esc back to the canvas. \
    With the tile only selected: j/k, J/K, ]/[, ↓/↑.
    Every Stage and Discard is one ⌘Z.
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
        installFilterField()
        refreshToolTips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { refreshPainter() }
        layoutFilterField()
        clampScroll()
        scheduleToolTips()
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
        let old = ChangesSpec(self.object.props), oldViewed = self.object.props["viewed"]
        self.object = object
        if ChangesSpec(object.props) != old { return load() }
        if object.props["viewed"] != oldViewed { syncViewed(from: oldViewed) }
        refreshPainter()
    }

    /// `props.viewed` changed under the tile (⌘Z of a Viewed check, an agent): files that
    /// became viewed fold, files that stopped being viewed unfold.
    private func syncViewed(from old: JSONValue?) {
        guard let set else { return }
        let viewed = object.props["viewed"]
        for file in set.files {
            let was = file.isViewed(in: old), now = file.isViewed(in: viewed)
            if now, !was {
                collapsed.insert(file.boardPath)
                viewedFolded.insert(file.boardPath)
            } else if was, !now, viewedFolded.remove(file.boardPath) != nil {
                collapsed.remove(file.boardPath)
            }
        }
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
            let branch = spec.root == nil ? await Self.branch(in: root) : nil
            await MainTurns.next()
            guard let self, current == self.generation, self.isLive else { return }
            self.loadTask = nil
            let previous = self.set
            self.install(set)
            self.watch(set.repository)
            self.growIfFitted(from: previous, to: set)
            if spec.root == nil { self.onBranch?(branch) }
        }
    }

    /// The branch checked out in `directory`'s worktree; nil when detached or outside git.
    private static func branch(in directory: URL) async -> String? {
        guard let output = try? await GitRunner.shared.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory, allowedStatus: [0, 1]) else { return nil }
        let name = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A new listing: the current hunk stays the same file and position (the next one when it
    /// went, e.g. discarded), folds stay folded, a selection stays while its hunk does, and the
    /// scroll stays put (after an action, the current hunk scrolls into view).
    private func install(_ set: ChangeSet) {
        let previous = current.flatMap { current in self.set.map { ($0.files[current.file].boardPath, current.hunk) } }
        let picked = selection.flatMap { selection in self.set.map { ($0.files[selection.file].hunks[selection.hunk].id, selection.lines) } }
        self.set = set
        setVersion += 1
        cache.removeAll()
        let viewed = object.props["viewed"]
        for file in set.files {
            let isViewed = file.isViewed(in: viewed)
            if !seen.contains(file.boardPath) {
                seen.insert(file.boardPath)
                if file.status == .deleted || isViewed { collapsed.insert(file.boardPath) }
                if isViewed { viewedFolded.insert(file.boardPath) }
            } else if viewedFolded.contains(file.boardPath), !isViewed {
                // Its diff changed since it was marked: show it again.
                viewedFolded.remove(file.boardPath)
                collapsed.remove(file.boardPath)
            }
        }
        if let (path, hunk) = previous {
            if let file = set.files.firstIndex(where: { $0.boardPath == path }), !set.files[file].hunks.isEmpty {
                current = (file, min(hunk, set.files[file].hunks.count - 1))
            } else {
                current = set.hunkOrder.first { set.files[$0.file].boardPath > path }.map { ($0.file, $0.hunk) } ?? set.hunkOrder.last.map { ($0.file, $0.hunk) }
            }
        }
        selection = nil
        anchor = nil
        if let (id, lines) = picked {
            for (fileIndex, file) in set.files.enumerated() {
                if let hunk = file.hunks.firstIndex(where: { $0.id == id }), lines.allSatisfy({ $0 < file.hunks[hunk].lines.count }) {
                    selection = (fileIndex, hunk, lines)
                }
            }
        }
        refreshPainter()
        if revealAfterLoad, let current {
            revealAfterLoad = false
            reveal(file: current.file, hunk: current.hunk)
        }
    }

    private func refreshPainter() {
        guard let set else {
            painter = nil
            needsDisplay = true
            return
        }
        let key = LayoutKey(version: setVersion, collapsed: collapsed, columns: ChangesMetrics.textColumns(width: bounds.width, digits: ChangesMetrics.digits(set)),
                            filter: filter, listOpen: listOpen)
        let reused = laidOut.flatMap { $0.key == key ? ($0.rows, $0.names) : nil }
        var painter = ChangesPainter(set: set, collapsed: collapsed, width: bounds.width, filter: filter, listOpen: listOpen, laidOut: reused)
        laidOut = (key, painter.rows, painter.names)
        painter.viewed = object.props["viewed"]
        painter.current = current
        painter.selection = selection
        painter.message = message
        painter.focused = hasKeyboard
        painter.drawsFilter = filterField == nil
        self.painter = painter
        clampScroll()
        scheduleToolTips()
        needsDisplay = true
    }

    /// A tile fitted to its diff (its height is what `size: "fit"` gave the last listing) grows
    /// with it when hunks are added, up to the fit maximum; one the user or an agent sized
    /// otherwise keeps its size.
    private func growIfFitted(from old: ChangeSet?, to new: ChangeSet) {
        guard let old, old.notice == nil, new.notice == nil else { return }
        let natural = object.naturalFrame
        let viewed = object.props["viewed"]
        let before = ChangesMetrics.fit(old, maxWidth: natural.w, viewed: viewed).height
        let after = ChangesMetrics.fit(new, maxWidth: natural.w, viewed: viewed).height
        guard abs(natural.h - before) <= 1, after > natural.h + 0.5 else { return }
        let scale = ObjectScale.of(object.props)
        board.growFitted(object.id, frame: Frame(x: object.frame.x, y: object.frame.y, w: object.frame.w, h: (after * scale).rounded(.up)))
    }

    /// Working-tree writes, and the index, HEAD, and refs in the git directory, reload the
    /// listing (debounced); objects, logs, and lock files don't. A linked worktree's own index
    /// and HEAD live in the common git directory, which is watched too.
    private func watch(_ repository: URL?) {
        guard let repository else { return events = nil }
        var directories = [FileEvents.canonical(repository.path)]
        if let worktree = GitWorktree.containing(repository.path), !worktree.gitDir.hasPrefix(directories[0] + "/") {
            directories.append(FileEvents.canonical(worktree.gitDir))
        }
        guard events?.directories != directories else { return }
        events = FileEvents(directories: directories, latency: 0.3) { [weak self] paths in
            guard paths.contains(where: Self.matters) else { return }
            self?.scheduleReload(after: 0.2)
        }
    }

    nonisolated static func matters(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return !path.hasSuffix("/.git") }
        var inside = path[range.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        if inside.hasPrefix("worktrees/"), let slash = inside.dropFirst("worktrees/".count).firstIndex(of: "/") {
            inside = inside[inside.index(after: slash)...]
        }
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
    private var contentHeight: CGFloat { (painter?.rows.height ?? 0) + ChangesMetrics.bottomPadding }

    private func clampScroll() {
        scroll = min(max(0, scroll), max(0, contentHeight - viewportHeight)).rounded()
    }

    private func setScroll(_ value: CGFloat) {
        let before = scroll
        scroll = value
        clampScroll()
        guard scroll != before else { return }
        scheduleToolTips()
        needsDisplay = true
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

    // MARK: Filter

    /// The header's filter field, live only (cards and renders draw its text).
    private func installFilterField() {
        guard window != nil, isLive, filterField == nil else { return }
        let field = NSSearchField()
        field.placeholderString = "Filter files"
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: 11)
        field.stringValue = filter
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        addSubview(field)
        filterField = field
        layoutFilterField()
        refreshPainter()
    }

    private func removeFilterField() {
        guard let field = filterField else { return }
        if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        filterField = nil
    }

    private func layoutFilterField() {
        filterField?.frame = ChangesPainter.filterRect(width: bounds.width)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField, field === filterField else { return }
        filter = field.stringValue
        selection = nil
        refreshPainter()
    }

    /// Return and Esc in the field give the keyboard back to the tile (Esc clears it first).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === filterField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if !filter.isEmpty {
                filterField?.stringValue = ""
                filter = ""
                refreshPainter()
            } else {
                window?.makeFirstResponder(self)
            }
            return true
        }
        return false
    }

    private func focusFilter() {
        guard let field = filterField else { return }
        window?.makeFirstResponder(field)
    }

    // MARK: Tooltips

    private func scheduleToolTips() {
        toolTipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshToolTips() } }
        toolTipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// One tooltip area per thing that says something (the header; each visible header row's
    /// label, Viewed box, and buttons; each line), answered by `view(_:stringForToolTip:…)`.
    private func refreshToolTips() {
        removeAllToolTips()
        guard isLive, window != nil, let painter else { return }
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width, height: ChangesMetrics.headerHeight), owner: self, userData: nil)
        var areas: [NSRect] = []
        for index in painter.rows.visible(from: scroll, to: scroll + viewportHeight) {
            let rect = painter.rect(ofRow: index, width: bounds.width, scroll: scroll)
            switch painter.rows.rows[index] {
            case .file(let file) where painter.set.files[file].notice == nil:
                let buttons = painter.buttons(inRow: rect).map(\.1)
                let viewed = painter.viewedRect(inRow: rect)
                areas += [NSRect(x: 0, y: rect.minY, width: viewed.minX, height: rect.height), viewed] + buttons
            case .hunk:
                let buttons = painter.buttons(inRow: rect).map(\.1)
                areas += [NSRect(x: 0, y: rect.minY, width: buttons[0].minX, height: rect.height)] + buttons
            default:
                areas.append(rect)
            }
        }
        let body = NSRect(x: 0, y: ChangesMetrics.headerHeight, width: bounds.width, height: viewportHeight)
        for area in areas {
            let clipped = area.intersection(body)
            if !clipped.isEmpty { addToolTip(clipped, owner: self, userData: nil) }
        }
    }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { painter?.tooltip(at: point, width: bounds.width, scroll: scroll) ?? "" }
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= CodeMetrics.rowHeight
            dy *= CodeMetrics.rowHeight
        }
        let scrollable = contentHeight > viewportHeight + 0.5
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard gesture else {
            // A mouse wheel notch or a replayed step: each one on its own.
            guard scrollable, abs(dy) >= abs(dx), dy != 0 else { return super.scrollWheel(with: event) }
            return setScroll(scroll - dy)
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { gestureOwner = nil }
        if gestureOwner == nil, dx != 0 || dy != 0 {
            gestureOwner = scrollable && abs(dy) >= abs(dx) ? .tile : .canvas
        }
        switch gestureOwner {
        case .tile?:
            if dy != 0 { setScroll(scroll - dy) }
        case .canvas?:
            super.scrollWheel(with: event)
        case nil:
            // A gesture's first event without movement: the canvas mustn't start tracking a
            // gesture that may turn out to scroll the tile.
            if !scrollable { super.scrollWheel(with: event) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let painter, let set else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressed = nil
        dragged = false
        guard let hit = painter.hit(at: point, width: bounds.width, scroll: scroll) else { return }
        switch hit {
        case .button(let action, let file, let hunk):
            let lines = hunk.flatMap { hunk in selection.flatMap { $0.file == file && $0.hunk == hunk ? $0.lines : nil } }
            if let hunk { current = (file, hunk) }
            perform(action, file: file, hunk: hunk, lines: lines)
        case .viewed(let file):
            toggleViewed(file)
        case .file(let file):
            let path = set.files[file].boardPath
            if collapsed.remove(path) == nil { collapsed.insert(path) }
            refreshPainter()
            keepHeaderInView(file)
        case .list:
            listOpen.toggle()
            refreshPainter()
        case .listed(let file):
            jump(toFile: file)
        case .hunk(let file, let hunk):
            current = (file, hunk)
            if selection.map({ $0.file != file || $0.hunk != hunk }) ?? false { selection = nil }
            refreshPainter()
        case .line(let file, let hunk, let line):
            current = (file, hunk)
            let flags = event.modifierFlags
            if flags.contains(.command) {
                // ⌘-click adds or removes one line (and its pair).
                var lines = selection.flatMap { $0.file == file && $0.hunk == hunk ? $0.lines : nil } ?? []
                let pair = set.files[file].hunks[hunk].pairedRows([line])
                if lines.isSuperset(of: pair) { lines.subtract(pair) } else { lines.formUnion(pair) }
                selection = lines.isEmpty ? nil : (file, hunk, lines)
                anchor = (file, hunk, line)
            } else if flags.contains(.shift) {
                let from = anchor.flatMap { $0.file == file && $0.hunk == hunk ? $0.line : nil } ?? line
                select(file: file, hunk: hunk, from: from, to: line)
                anchor = anchor ?? (file, hunk, line)
            } else {
                pressed = (file, hunk, line)
                anchor = (file, hunk, line)
            }
            refreshPainter()
        }
    }

    /// Dragging over a hunk's lines selects them (within that hunk).
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let painter else { return }
        let point = convert(event.locationInWindow, from: nil)
        var line: Int?
        if case .line(let file, let hunk, let over)? = painter.hit(at: point, width: bounds.width, scroll: scroll), file == pressed.file, hunk == pressed.hunk {
            line = over
        } else if let row = painter.rows.index(ofHunk: pressed.file, pressed.hunk) {
            // Past the hunk's first or last line: its end.
            let y = point.y - ChangesMetrics.headerHeight + scroll
            let count = painter.set.files[pressed.file].hunks[pressed.hunk].lines.count
            line = y < painter.rows.tops[row] ? 0 : count - 1
        }
        guard let line else { return }
        dragged = dragged || line != pressed.line
        guard dragged else { return }
        select(file: pressed.file, hunk: pressed.hunk, from: pressed.line, to: line)
        refreshPainter()
    }

    /// The hunk's lines from one row to another, with the other half of each edited line.
    private func select(file: Int, hunk: Int, from: Int, to: Int) {
        guard let set else { return }
        selection = (file, hunk, set.files[file].hunks[hunk].pairedRows(Set(min(from, to)...max(from, to))))
    }

    /// A click (no drag) on a line opens it and drops any selection.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            dragged = false
        }
        guard let pressed, !dragged else { return }
        if selection != nil {
            selection = nil
            refreshPainter()
        }
        open(file: pressed.file, hunk: pressed.hunk, line: pressed.line)
    }

    // MARK: Keyboard

    private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// j/k, ↓/↑, J/K, ]/[ and Return: also while the tile is only selected (the canvas's keyboard).
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, painter != nil else { return false }
        let modifiers = Self.modifiers(event)
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers, modifiers == .shift) {
        case (125, _, false), (_, "j", false): step(1)
        case (126, _, false), (_, "k", false): step(-1)
        case (_, "J", _), (_, "]", false): stepFile(1)
        case (_, "K", _), (_, "[", false): stepFile(-1)
        case (36, _, false), (76, _, false): openCurrent()
        default: return false
        }
        return true
    }

    func enterKeyboard() -> Bool {
        window?.makeFirstResponder(self) == true
    }

    /// s and r only with the keyboard in the tile, so typing elsewhere can never stage or discard.
    override func keyDown(with event: NSEvent) {
        if handleNavigationKey(event) { return }
        guard Self.modifiers(event).isEmpty else { return super.keyDown(with: event) }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (53, _):
            if selection != nil {
                selection = nil
                refreshPainter()
            } else {
                (enclosingScrollView as? CanvasView)?.leaveTile(object.id)
            }
        case (_, "s"): actOnCurrent(.stage)
        case (_, "r"): actOnCurrent(.revert)
        case (_, "/"): focusFilter()
        default: super.keyDown(with: event)
        }
    }

    private func actOnCurrent(_ action: ChangesAction) {
        if let selection { return perform(action, file: selection.file, hunk: selection.hunk, lines: selection.lines) }
        guard let current else { return show(message: "pick a hunk first (j/k or click)") }
        perform(action, file: current.file, hunk: current.hunk, lines: nil)
    }

    /// The next or previous hunk of an unfolded, listed file becomes current and scrolls into view.
    private func step(_ delta: Int) {
        guard let set, let painter else { return }
        let shown = Set(painter.rows.shown)
        let order = set.hunkOrder.filter { shown.contains($0.file) && !collapsed.contains(set.files[$0.file].boardPath) }
        guard !order.isEmpty else { return }
        let index = current.flatMap { current in order.firstIndex { $0 == current } }.map { min(max(0, $0 + delta), order.count - 1) } ?? (delta > 0 ? 0 : order.count - 1)
        let target = order[index]
        current = (target.file, target.hunk)
        refreshPainter()
        reveal(file: target.file, hunk: target.hunk)
    }

    /// The next or previous listed file: its header at the top, its first hunk current.
    private func stepFile(_ delta: Int) {
        guard let painter else { return }
        let shown = painter.rows.shown
        guard !shown.isEmpty else { return }
        let from: Int? = current?.file ?? painter.row(at: CGPoint(x: 1, y: ChangesMetrics.headerHeight + 1), width: bounds.width, scroll: scroll).flatMap { painter.rows.rows[$0].file }
        let position = from.flatMap { shown.firstIndex(of: $0) }
        let next = position.map { min(max(0, $0 + delta), shown.count - 1) } ?? (delta > 0 ? 0 : shown.count - 1)
        jump(toFile: shown[next], unfold: false)
    }

    /// Scrolls a file's header to the top (unfolding it when asked) and makes its first hunk current.
    private func jump(toFile file: Int, unfold: Bool = true) {
        guard let set else { return }
        let path = set.files[file].boardPath
        if unfold { collapsed.remove(path) }
        if !set.files[file].hunks.isEmpty, !collapsed.contains(path) { current = (file, 0) }
        refreshPainter()
        guard let painter, let row = painter.rows.index(ofFile: file) else { return }
        setScroll(painter.rows.tops[row])
    }

    /// Scrolls the hunk into the tile's view (below the pinned file header), its header near
    /// the top when it doesn't all fit; nothing when all of it shows already. The canvas never moves.
    private func reveal(file: Int, hunk: Int) {
        guard let painter, let row = painter.rows.index(ofHunk: file, hunk), let bottom = painter.rows.bottom(ofHunk: file, hunk) else { return }
        let top = painter.rows.tops[row]
        let covered = ChangesMetrics.fileHeight
        if top < scroll + covered || bottom > scroll + viewportHeight {
            setScroll(bottom - top <= viewportHeight - covered && top >= scroll + covered ? bottom - viewportHeight : top - covered)
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

    /// Marks a file Viewed for its current diff (folding it) or unmarks it (unfolding it):
    /// `props.viewed`, one ⌘Z step; entries for diffs that changed since are dropped with it.
    private func toggleViewed(_ file: Int) {
        guard let set else { return }
        let changed = set.files[file]
        let current = object.props["viewed"]
        var viewed: [String: JSONValue] = [:]
        for other in set.files where other.boardPath != changed.boardPath && other.isViewed(in: current) {
            viewed[other.boardPath] = .string(other.fingerprint)
        }
        if changed.isViewed(in: current) {
            viewedFolded.remove(changed.boardPath)
            collapsed.remove(changed.boardPath)
        } else {
            viewed[changed.boardPath] = .string(changed.fingerprint)
            viewedFolded.insert(changed.boardPath)
            collapsed.insert(changed.boardPath)
            if self.current?.file == file { self.current = nil }
        }
        _ = try? board.update(object.id, props: .object(["viewed": viewed.isEmpty ? .null : .object(viewed)]))
        refreshPainter()
        keepHeaderInView(file)
    }

    /// After a fold from a pinned header: that header at the top, where it was.
    private func keepHeaderInView(_ file: Int) {
        guard let painter, let row = painter.rows.index(ofFile: file), painter.rows.tops[row] < scroll else { return }
        setScroll(painter.rows.tops[row])
    }

    /// Stage or discard one hunk (nil: the whole file), or some of its lines: the patch is
    /// built, applied, and recorded as one undo step; a refusal shows in the header and changes
    /// nothing.
    private func perform(_ action: ChangesAction, file: Int, hunk: Int?, lines: Set<Int>?) {
        guard !acting, let set, let repository = set.repository, set.files.indices.contains(file) else { return }
        let changed = set.files[file]
        let target = hunk.map { changed.hunks[$0] }
        if action == .stage, let target, !target.status.stageable { return show(message: "already staged") }
        acting = true
        let tile = object.id, board = board
        Task { [weak self] in
            defer { self?.acting = false }
            do {
                let hunks = target.map { [$0] }
                let patch = action == .stage ? try await ReviewPatch.stage(hunks, of: changed, in: repository, lines: lines)
                    : try ReviewPatch.revert(hunks ?? changed.hunks, of: changed, in: repository, lines: lines)
                try await ReviewGit.shared.apply(patch)
                try board.recordReview(tile: tile, entry: ReviewPatch.entry(action.entryName, file: changed, hunk: target, lines: lines, patch: patch), patch: patch)
                self?.revealAfterLoad = true
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
            installFilterField()
            refreshToolTips()
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
            removeFilterField()
            layer?.contents = nil
            removeAllToolTips()
            toolTipWork?.cancel()
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let painter, let set else { return nil }
        switch painter.hit(at: point, width: bounds.width, scroll: scroll) {
        case .line(let file, let hunk, let line)?:
            guard let location = set.location(file: file, hunk: hunk, line: line) else { return nil }
            return mention(file: file, path: location.path, lines: LineRange(start: location.line, end: location.line), side: location.side,
                           diff: set.mentionDetail(file: file, hunk: hunk, lines: line..<(line + 1)))
        case .hunk(let file, let hunk)?, .button(_, let file, let hunk?)?:
            let changed = set.files[file], target = changed.hunks[hunk]
            let whole = target.mentionLines
            return mention(file: file, path: whole.side == .old ? changed.oldBoardPath ?? changed.boardPath : changed.boardPath, lines: whole.lines, side: whole.side,
                           diff: set.mentionDetail(file: file, hunk: hunk, lines: nil))
        default:
            return nil
        }
    }

    /// A mention names the lines on their side and the base they were diffed against, so the
    /// prompt quotes them however the tile changes before the tray drains, and says what they
    /// are in the diff (`ChangeSet.mentionDetail`).
    private func mention(file: Int, path: String, lines: LineRange, side: DiffSide, diff: String?) -> MentionTarget {
        let symbol = set?.files[file].symbol(line: lines.start, side: side)
        return .code(object: object.id, path: path, lines: lines, side: set?.base == nil ? nil : side.rawValue, symbol: symbol, commit: set?.base, diff: diff)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(let id, let path, let lines, let side, _, _, _) = target, id == object.id, let painter, let set else { return nil }
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
        var painter = ChangesPainter(set: loaded, collapsed: collapsed, width: request.size.width, filter: filter, listOpen: listOpen)
        painter.viewed = object.props["viewed"]
        painter.current = current
        painter.selection = selection
        painter.message = message
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
