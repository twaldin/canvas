import AppKit
import CanvasCore

/// Read-only code tile: the whole current file, scrolled to the object's `range` (tinted), with
/// gitsigns against the diff base in the gutter (green bar added, blue bar modified, red wedge
/// deleted; clicking a sign peeks the base lines inline). Rows are drawn straight from the
/// model, only those on screen (`CodeRowsView`); git and parsing run off the main thread and
/// only while the tile is live; file changes reload after a short debounce, and the rows a
/// write changed flash. Follow tiles hold still while the user works in them (`FollowLock`).
@MainActor
final class CodeTile: NSView, TileContent {
    typealias Aim = CodeHeaderBar.Location

    private(set) var object: CanvasObject
    private let board: Board
    private let header = CodeHeaderBar(frame: .zero)
    private let scroll = NSScrollView()
    private let content = CodeScrollDocument()
    private let rowsView = CodeRowsView(frame: .zero)

    /// What the tile shows, which the user may hold behind the props' aim.
    private var lock: FollowLock<Aim>
    private var displayed: Aim
    private var propsAim: Aim
    private var resumeWork: DispatchWorkItem?

    private var document: CodeDocument?
    /// Diff base the document was loaded against.
    private var loadedBase: DiffBase?
    private var peeked: Set<Int> = []
    private var flash: (lines: [Range<Int>], start: TimeInterval)?
    private var flashTimer: Timer?

    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    /// Bumped by every load; only the newest load installs its result.
    private var generation = 0
    /// Repository this tile holds in the git engine while live (bases watched).
    private var heldRepository: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Dispatch sources must be resumed before they are released, so suspension is tracked.
    private var watcherSuspended = false
    private var reloadWork: DispatchWorkItem?
    private var navigation: CodeNavigation?

    static let flashDuration: TimeInterval = 3

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        let aim = Self.aim(of: object)
        displayed = aim
        propsAim = aim
        lock = FollowLock(showing: aim)
        super.init(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        scroll.documentView = content
        content.addSubview(rowsView)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        addSubview(header)
        rowsView.onSign = { [weak self] sign in self?.togglePeek(sign) }
        rowsView.onInteract = { [weak self] in self?.userInteracted() }
        rowsView.onEditHere = { [weak self] point in self?.editHere(at: point) }
        header.onBase = { [weak self] base in self?.setBase(base) }
        header.onChange = { [weak self] forward in self?.jumpToChange(forward: forward) }
        header.onPin = { [weak self] in self?.pin() }
        header.onCatchUp = { [weak self] in self?.catchUp() }
        header.onLocation = { [weak self] location in self?.userAim(location) }
        NotificationCenter.default.addObserver(self, selector: #selector(baseChanged), name: .gitDiffBaseChanged, object: nil)
        header.show(caption: object.props["caption"]?.string)
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
        updateContentSize()
    }

    @objc private func clipMoved() {
        rowsView.track(scroll.documentVisibleRect)
    }

    private func updateContentSize() {
        let clip = scroll.contentView.bounds.size
        let size = rowsView.painter?.contentSize ?? .zero
        content.setFrameSize(NSSize(width: max(clip.width, size.width), height: max(clip.height, size.height)))
        rowsView.track(scroll.documentVisibleRect)
    }

    // MARK: Props

    private static func aim(of object: CanvasObject) -> Aim {
        let start = object.props["range"]?["start"]?.int
        return Aim(path: object.props["path"]?.string ?? "", range: start.map { LineRange(start: $0, end: object.props["range"]?["end"]?.int ?? $0) })
    }

    var path: String { displayed.path }
    private var diffBaseProp: String { object.props["diffBase"]?.string ?? "merge-base" }
    private var diffBase: DiffBase { DiffBase(prop: object.props["diffBase"]?.string) }
    private var followOf: ObjectID? { object.props["followOf"]?.string }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func update(_ object: CanvasObject) {
        let old = self.object
        self.object = object
        header.show(caption: object.props["caption"]?.string)
        let aim = Self.aim(of: object)
        if aim != propsAim {
            propsAim = aim
            if let shown = lock.aim(aim, at: Self.now) {
                apply(shown)
            } else {
                scheduleResume()
            }
        }
        if old.props["diffBase"] != object.props["diffBase"] { load() }
        refreshHeader()
        resizeSubviews(withOldSize: bounds.size)
    }

    /// Show an aim: another file loads it; the same file only moves the range.
    private func apply(_ aim: Aim) {
        let previous = displayed
        displayed = aim
        navigation?.contentChanged()
        if aim.path != previous.path {
            load()
        } else if aim.range != previous.range {
            refreshPainter(keepSelection: true)
            showRange()
        }
        refreshHeader()
    }

    /// Whether the rows are the file the tile shows; while a reload changes it, mentions and
    /// navigation wait for it.
    private var showsCurrent: Bool { document?.path == displayed.path }

    // MARK: Follow lock

    private func userInteracted() {
        guard followOf != nil else { return }
        lock.interact(at: Self.now)
        scheduleResume()
    }

    /// One pending check at the end of the hold; interactions push the end out, so the check
    /// re-arms until it has really lapsed.
    private func scheduleResume() {
        guard resumeWork == nil, let until = lock.until else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resumeWork = nil
                if let aim = self.lock.resume(at: Self.now) {
                    self.apply(aim)
                } else if self.lock.until != nil {
                    self.scheduleResume()
                }
                self.refreshHeader()
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, until - Self.now), execute: work)
    }

    private func catchUp() {
        if let aim = lock.catchUp() { apply(aim) }
        refreshHeader()
    }

    /// The user picked a location (history strip, same-file definition): shown at once.
    private func userAim(_ aim: Aim) {
        lock.userAimed(aim)
        apply(aim)
        let range: JSONValue = aim.range.map { .object(["start": .number(Double($0.start)), "end": .number(Double($0.end))]) } ?? .null
        _ = try? board.update(object.id, props: .object(["path": .string(aim.path), "range": range]))
    }

    // MARK: Loading

    /// Diff the file against its base (git, off the main thread), build the model off the main
    /// thread, and install it. Deferred until the tile is live.
    private func load() {
        guard isLive else {
            needsLoad = true
            return
        }
        needsLoad = false
        let path = displayed.path
        let url = board.absoluteURL(path)
        watch(url)
        let base = diffBase
        generation += 1
        let current = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let engine = GitDiffEngine.shared
            let held = await engine.retain(containing: url)
            let diff = await engine.diff(file: url, base: base)
            let document = await offPool { CodeDocument(path: path, diff: diff) }
            guard let self, !Task.isCancelled, current == self.generation, self.isLive else {
                if let held { await engine.release(held) }
                return
            }
            self.loadTask = nil
            if let previous = self.heldRepository { Task { await engine.release(previous) } }
            self.heldRepository = held
            self.install(document, base: base)
        }
    }

    /// The model without holding the repository, for renders and cards of tiles that aren't live.
    private func loadOffscreen() async -> CodeDocument? {
        if showsCurrent, loadedBase == diffBase, let document { return document }
        let path = displayed.path, base = diffBase
        let diff = await GitDiffEngine.shared.diff(file: board.absoluteURL(path), base: base)
        let document = await offPool { CodeDocument(path: path, diff: diff) }
        guard path == displayed.path, base == diffBase else { return nil }
        if !showsCurrent || loadedBase != base || self.document?.text != document.text {
            install(document, base: base)
            // Not live: the next time it is, revalidate against the watched file and bases.
            if !isLive { needsLoad = true }
        }
        return document
    }

    private func install(_ document: CodeDocument, base: DiffBase) {
        let previous = self.document
        self.document = document
        loadedBase = base
        // Laid-out lines are keyed by line number, which a new text reassigns.
        rowsView.cache.removeAll()
        let sameFile = previous.map { $0.path == document.path && $0.side == document.side } ?? false
        if sameFile, let previous, let edit = CodeEdits.changes(from: previous.text, to: document.text) {
            peeked = []
            refreshPainter(keepSelection: false)
            startFlash(edit.lines)
            if followOf != nil, !lock.isHeld(at: Self.now) {
                scroll(toRow: rowsView.painter?.rows.index(ofLine: edit.first) ?? 0)
            }
        } else if sameFile, let previous {
            let sameSigns = previous.signs == document.signs
            if !sameSigns { peeked = [] }
            refreshPainter(keepSelection: sameSigns)
        } else {
            peeked = []
            refreshPainter(keepSelection: false)
            showRange()
            flashFollowedEdit(in: document)
        }
        navigation?.contentChanged()
        refreshHeader()
    }

    /// An agent's edit to a file the tile wasn't showing has no earlier load to compare with:
    /// flash the change around the reported line (a whole new file for writes).
    private func flashFollowedEdit(in document: CodeDocument) {
        guard followOf != nil, displayed == propsAim, let action = object.props["lastAction"]?.string, action == "edit" || action == "write" else { return }
        if let line = displayed.range?.start, let sign = document.sign(at: line), !document.signs[sign].lines.isEmpty {
            startFlash([document.signs[sign].lines])
        } else if displayed.range == nil, document.diff.state == .added || document.diff.state == .noBase, document.text.lineCount > 0 {
            startFlash([1..<(document.text.lineCount + 1)])
        } else if displayed.range == nil, let first = document.signs.first(where: { !$0.lines.isEmpty }) {
            startFlash([first.lines])
            scroll(toRow: rowsView.painter?.rows.index(ofLine: first.lines.lowerBound) ?? 0)
        }
    }

    /// Rebuild what the rows view draws from the document, peeks, range, and flash.
    private func refreshPainter(keepSelection: Bool) {
        guard let document, showsCurrent else {
            rowsView.painter = nil
            updateContentSize()
            return
        }
        var painter = CodePainter(document: document, rows: CodeRows(lineCount: document.text.lineCount, signs: document.signs, peeked: peeked))
        painter.rangeLines = displayed.range.flatMap(document.lines(for:))
        painter.flash = flash.map { ($0.lines, flashStrength($0.start)) }
        painter.selection = keepSelection ? rowsView.painter?.selection : nil
        rowsView.painter = painter
        updateContentSize()
    }
}

// MARK: Presentation

extension CodeTile {
    /// Bring the range into view (a few rows below the top), or the top of a new file.
    private func showRange() {
        guard showsCurrent, let rows = rowsView.painter?.rows else { return }
        scroll(toRow: displayed.range.map { rows.index(ofLine: $0.start) } ?? 0)
    }

    private func scroll(toRow row: Int) {
        let clip = scroll.contentView
        let top = CodePainter.rowTop(max(0, row - 3)) - CodeMetrics.verticalPadding
        let maxY = max(0, content.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, top), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    private func startFlash(_ lines: [Range<Int>]) {
        guard !lines.isEmpty, isLive else { return }
        flash = (lines, Self.now)
        rowsView.painter?.flash = (lines, 1)
        guard flashTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func flashStrength(_ start: TimeInterval) -> CGFloat {
        let t = min(1, (Self.now - start) / Self.flashDuration)
        return CGFloat(1 - t * t)
    }

    private func flashTick() {
        guard let flash, Self.now - flash.start < Self.flashDuration else { return stopFlash() }
        rowsView.painter?.flash = (flash.lines, flashStrength(flash.start))
    }

    private func stopFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flash = nil
        rowsView.painter?.flash = nil
    }

    private func refreshHeader() {
        let document = showsCurrent ? document : nil
        header.show(diffBase: diffBaseProp, status: document?.status ?? "loading…", warning: document?.warning,
                    changes: !(document?.signs.isEmpty ?? true), follow: followOf != nil, missed: lock.missed)
        let before = header.height
        header.show(history: followOf == nil ? [] : history, current: displayed)
        if header.height != before { resizeSubviews(withOldSize: bounds.size) }
    }

    private var history: [Aim] {
        (object.props["history"]?.array ?? []).compactMap { entry -> Aim? in
            guard let path = entry["path"]?.string else { return nil }
            let start = entry["range"]?["start"]?.int
            return Aim(path: path, range: start.map { LineRange(start: $0, end: entry["range"]?["end"]?.int ?? $0) })
        }
    }

    // MARK: Actions

    private func setBase(_ base: String) {
        guard base != diffBaseProp else { return }
        _ = try? board.update(object.id, props: .object(["diffBase": .string(base)]))
    }

    private func togglePeek(_ sign: Int) {
        guard let document, showsCurrent, document.signs.indices.contains(sign), document.signs[sign].peekable else { return }
        if peeked.remove(sign) == nil { peeked.insert(sign) }
        refreshPainter(keepSelection: false)
    }

    /// Scroll to the change after (or before) the line a few rows below the top.
    private func jumpToChange(forward: Bool) {
        guard let document, showsCurrent, let rows = rowsView.painter?.rows else { return }
        userInteracted()
        let anchorRow = CodePainter.row(atY: scroll.documentVisibleRect.minY + CodeMetrics.verticalPadding) + 3
        let line: Int
        switch rows.row(min(anchorRow, rows.count - 1)) {
        case .line(let number)?: line = number
        case .peek(_, let sign)?: line = document.signs[sign].lines.lowerBound
        case nil: line = 1
        }
        if let target = document.changeLine(after: line, forward: forward) {
            scroll(toRow: rows.index(ofLine: target))
        }
    }

    /// Keep what the follow tile shows as a permanent code tile beside it.
    private func pin() {
        _ = try? board.pin(object.id, path: displayed.path, range: displayed.range)
    }

    /// Open nvim at the clicked line in a terminal tile beside this one.
    private func editHere(at point: NSPoint) {
        guard let document, showsCurrent, document.side == .new else { return }
        let line = displayedLine(atY: point.y) ?? displayed.range?.start ?? 1
        let size = Board.defaultSize(.terminal)
        let frame = board.place(width: size.w, height: size.h, near: object.id)
        board.create(type: .terminal, props: .object([
            "cwd": .string(board.root.path),
            "command": .array(["nvim", "+\(line)", "--", document.path].map(JSONValue.string)),
        ]), frame: frame)
    }

    /// Displayed line of a row; peek rows map to the line their change sits at.
    private func displayedLine(atY y: CGFloat) -> Int? {
        guard let document, let rows = rowsView.painter?.rows else { return nil }
        switch rows.row(CodePainter.row(atY: y)) {
        case .line(let line)?: return line
        case .peek(_, let sign)?: return min(document.signs[sign].lines.lowerBound, max(1, document.text.lineCount))
        case nil: return nil
        }
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
            stopFlash()
            rowsView.releaseCaches()
            if let heldRepository {
                Task { await GitDiffEngine.shared.release(heldRepository) }
                self.heldRepository = nil
                // Bases aren't watched while offscreen, so revalidate on return.
                needsLoad = true
            }
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let document, showsCurrent, let painter = rowsView.painter, scroll.frame.contains(point) else { return nil }
        let local = rowsView.convert(point, from: self)
        let row = CodePainter.row(atY: local.y)
        if let selected = rowsView.selectedRows, selected.contains(row) {
            return target(rows: selected, painter: painter, document: document)
        }
        if rowsView.isInGutter(local), let sign = painter.sign(atY: local.y), !painter.rows.peekedSigns.contains(sign) {
            let change = document.signs[sign]
            if change.lines.isEmpty {
                return code(LineRange(start: change.old.lowerBound, end: change.old.upperBound - 1), side: .old, in: document)
            }
            return code(LineRange(start: change.lines.lowerBound, end: change.lines.upperBound - 1), side: document.side, in: document)
        }
        guard row >= 0, row < painter.rows.count else { return nil }
        return target(rows: row...row, painter: painter, document: document)
    }

    /// The lines a run of rows shows: displayed lines when there are any, else peeked base lines.
    private func target(rows: ClosedRange<Int>, painter: CodePainter, document: CodeDocument) -> MentionTarget? {
        var lines: [Int] = []
        var old: [Int] = []
        for row in rows {
            switch painter.rows.row(row) {
            case .line(let line)?: lines.append(line)
            case .peek(let line, _)?: old.append(line)
            case nil: break
            }
        }
        if let first = lines.min(), let last = lines.max() {
            return code(LineRange(start: first, end: last), side: document.side, in: document)
        }
        guard let first = old.min(), let last = old.max() else { return nil }
        return code(LineRange(start: first, end: last), side: .old, in: document)
    }

    /// Mentions carry the diff base while the tile shows changes against it, so the prompt can
    /// quote base lines and name the base however the tile changes before the tray drains.
    private func code(_ lines: LineRange, side: DiffSide, in document: CodeDocument) -> MentionTarget {
        let commit = side == .old ? document.diff.base : document.mentionCommit
        return .code(object: object.id, path: document.path, lines: lines, side: commit == nil ? nil : side.rawValue,
                     symbol: document.enclosingSymbol(line: lines.start, side: side), commit: commit)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, let side, _, _) = target, let document, showsCurrent, path == document.path,
              let rows = rowsView.painter?.rows else { return nil }
        let first: Int?, last: Int?
        if side == DiffSide.old.rawValue, document.side == .new {
            let sign = document.signs.firstIndex { $0.old.contains(lines.start) }
            if let sign, rows.peekedSigns.contains(sign) {
                first = rows.index(ofPeek: sign, old: lines.start)
                last = rows.index(ofPeek: sign, old: min(lines.end, document.signs[sign].old.upperBound - 1))
            } else if let sign {
                // An unpeeked deletion: its wedge.
                let row = rows.index(ofLine: document.signs[sign].lines.lowerBound)
                let edge = CodePainter.rowTop(row)
                let rect = NSRect(x: scroll.documentVisibleRect.minX, y: edge - 3, width: scroll.documentVisibleRect.width, height: 6)
                return convert(rect, from: content).intersection(scroll.frame)
            } else {
                return nil
            }
        } else {
            first = rows.index(ofLine: lines.start)
            last = rows.index(ofLine: lines.end)
        }
        guard let first, let last else { return nil }
        let rect = NSRect(x: scroll.documentVisibleRect.minX, y: CodePainter.rowTop(first), width: scroll.documentVisibleRect.width,
                          height: CGFloat(last - first + 1) * CodeMetrics.rowHeight)
        return convert(rect, from: content).intersection(scroll.frame)
    }

    var takesKeyboardFocus: Bool { false }

    // MARK: Offscreen drawing

    /// The body (header, caption, history, rows) drawn from the model: never from live views,
    /// so it works offscreen, not live, and on any Space. `full` draws every row from the top.
    private func image(of document: CodeDocument, size: CGSize, scale: CGFloat, full: Bool, appearance: NSAppearance) -> (image: NSImage?, content: CGSize) {
        let rows = CodeRows(lineCount: document.text.lineCount, signs: document.signs, peeked: showsCurrent ? peeked : [])
        var painter = CodePainter(document: document, rows: rows)
        painter.rangeLines = displayed.range.flatMap(document.lines(for:))
        let headerHeight = header.height
        let content = CGSize(width: max(size.width, painter.contentSize.width), height: headerHeight + painter.contentSize.height)
        var imageSize = full ? CGSize(width: max(size.width, content.width), height: max(size.height, content.height)) : size
        // One bitmap dimension stays within what Core Graphics and memory allow.
        let maxPoints = 16_384 / max(scale, 0.1)
        imageSize = CGSize(width: min(imageSize.width, maxPoints), height: min(imageSize.height, maxPoints))
        let width = Int((imageSize.width * scale).rounded(.up)), height = Int((imageSize.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return (nil, content) }
        rep.size = imageSize
        let origin = full ? .zero : (showsCurrent && document.path == self.document?.path ? scroll.documentVisibleRect.origin : .zero)
        appearance.performAsCurrentDrawingAppearance {
            let cg = bitmap.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: imageSize.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            CodeHeaderBar.drawStatic(in: NSRect(x: 0, y: 0, width: imageSize.width, height: headerHeight), path: document.path, diffBase: diffBaseProp,
                                     status: document.status, warning: document.warning, caption: object.props["caption"]?.string,
                                     history: followOf == nil ? [] : history, current: displayed, missed: lock.missed)
            let rowsRect = CGRect(x: origin.x, y: origin.y, width: imageSize.width, height: max(0, imageSize.height - headerHeight))
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: headerHeight, width: imageSize.width, height: rowsRect.height))
            cg.translateBy(x: -origin.x, y: headerHeight - origin.y)
            painter.draw(in: cg, rect: rowsRect, gutterX: origin.x, cache: nil)
            cg.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        return (image, content)
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let document = await loadOffscreen() else {
            return TileRender(image: nil, contentSize: request.size, state: .placeholder, reason: "the tile changed while loading")
        }
        let drawn = image(of: document, size: request.size, scale: request.scale, full: request.full, appearance: request.appearance)
        guard let image = drawn.image else { return TileRender(image: nil, contentSize: drawn.content, state: .failed, reason: "could not allocate the bitmap") }
        return TileRender(image: image, contentSize: drawn.content, state: .rendered, reason: nil)
    }

    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        let appearance = effectiveAppearance
        let size = bounds.size
        if showsCurrent, loadedBase == diffBase, let document {
            return deliver(image(of: document, size: size, scale: TileFrameView.cardPixelsPerPoint, full: false, appearance: appearance).image)
        }
        Task { [weak self] in
            guard let self, let document = await self.loadOffscreen() else { return deliver(nil) }
            deliver(self.image(of: document, size: size, scale: TileFrameView.cardPixelsPerPoint, full: false, appearance: appearance).image)
        }
    }

    func snapshot() -> NSImage? {
        guard let document, showsCurrent else { return nil }
        return image(of: document, size: bounds.size, scale: window?.backingScaleFactor ?? 2, full: false, appearance: effectiveAppearance).image
    }
}

// MARK: Code navigation (CodeNavigationHost)

extension CodeTile: CodeNavigationHost {
    var navigationPath: String { displayed.path }

    var navigationView: NSView { rowsView }

    var navigationLineHeight: CGFloat { CodeMetrics.rowHeight }

    /// 1-based line and 0-based UTF-16 column of the working-tree file at a point in the rows
    /// view; nil over peeked base rows, the gutter, and deleted files.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)? {
        guard let document, showsCurrent, document.side == .new, !rowsView.isInGutter(point),
              let position = rowsView.position(at: point), case .line(let line)? = rowsView.painter?.rows.row(position.row),
              CodePainter.row(atY: point.y) == position.row else { return nil }
        return (line, position.offset)
    }

    func reveal(line: Int) {
        guard showsCurrent, let rows = rowsView.painter?.rows else { return }
        scroll(toRow: rows.index(ofLine: line))
    }

    func aim(at lines: LineRange) {
        userAim(Aim(path: displayed.path, range: lines))
    }
}
