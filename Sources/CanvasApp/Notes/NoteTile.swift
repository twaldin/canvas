import AppKit
import CanvasCore
import Markdown

/// A markdown note (docs/design.md "Notes"). Displays rendered markdown with live code fences;
/// double-click edits the raw markdown, ⌘↩ or clicking away commits, Esc cancels. The note
/// holds keyboard focus only while editing, then hands it back to the prompt-target terminal.
/// A conflicting change by someone else is only overwritten by an explicit ⌘↩.
@MainActor
final class NoteTile: NSView, TileContent {
    static let placeholder = ObjectMeasure.notePlaceholder
    /// File changes arrive in bursts (editors write, rename, and touch); resolve once they settle.
    static let debounce: TimeInterval = 0.25

    private(set) var object: CanvasObject
    private let board: Board
    private let displayScroll = OverlayScrollView()
    private let display = NoteDisplayView(usingTextLayoutManager: true)
    private let layoutDelegate = NoteLayoutDelegate()
    private let editorScroll = NSScrollView()
    private let editor = NoteEditor(usingTextLayoutManager: true)
    private let banner = NSTextField(labelWithString: "")

    private var document: Document
    private var fences: [NoteMarkdown.AnchoredFence] = []
    private var excerpts: [String: NoteExcerpt] = [:]
    /// `![alt](path)` pictures by destination, re-read when their files change.
    private var images: [String: NSImage] = [:]
    /// Text each fence showed when first resolved: re-finds moved ranges, stands in when lost,
    /// for fences whose anchor couldn't be written back (see `persistAnchors`).
    private var captured: [String: [String]] = [:]
    /// Canonical paths of excerpted files; any change under `events` to one re-resolves.
    private var watchedFiles: Set<String> = []
    /// A symbol fence found no file yet: any (non-hidden) change under the root may declare it.
    private var watchesRoot = false
    private var events: FileEvents?
    private var resolveTask: Task<Void, Never>?
    private var resolveGeneration = 0
    private var pendingResolve: DispatchWorkItem?
    private var live = true

    private var session: NoteEditSession?
    var isEditing: Bool { session != nil }
    private var clickMonitor: Any?

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        document = NoteMarkdown.parse(object.props["markdown"]?.string ?? "")
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor

        display.isEditable = false
        display.isSelectable = false
        display.drawsBackground = false
        display.textContainerInset = ObjectMeasure.noteInset
        display.textContainer?.lineFragmentPadding = ObjectMeasure.noteLineFragmentPadding
        display.autoresizingMask = [.width]
        display.textLayoutManager?.delegate = layoutDelegate
        configure(displayScroll, document: display)

        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = NoteRenderer.codeFont
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.autoresizingMask = [.width]
        editor.onCommit = { [weak self] in self?.endEditing(.confirmed) }
        // Esc leaves like a click away (saving), except that with a conflict shown it keeps theirs.
        editor.onCancel = { [weak self] in
            guard let self else { return }
            self.endEditing(self.banner.isHidden ? .implicit : .cancel)
        }
        // Focus is already moving elsewhere; don't pull it to the prompt target mid-change.
        editor.onResign = { [weak self] in self?.endEditing(.implicit, returningFocus: false) }
        configure(editorScroll, document: editor)
        editorScroll.isHidden = true

        banner.font = .systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .systemOrange
        banner.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        banner.drawsBackground = true
        banner.lineBreakMode = .byWordWrapping
        banner.maximumNumberOfLines = 2
        banner.isHidden = true
        addSubview(banner)

        fences = NoteMarkdown.anchoredFences(in: document)
        renderDisplay()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func configure(_ scroll: NSScrollView, document: NSTextView) {
        document.isVerticallyResizable = true
        document.isHorizontallyResizable = false
        document.textContainer?.widthTracksTextView = true
        document.minSize = .zero
        document.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        document.frame = NSRect(origin: .zero, size: scroll.contentSize)
        addSubview(scroll)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
    }

    var markdown: String { object.props["markdown"]?.string ?? "" }
    /// Where the note's relative paths resolve (`Board.linkRoot`).
    private var linkRoot: URL { board.linkRoot(of: object) }

    func update(_ object: CanvasObject) {
        let changed = object.props["markdown"] != self.object.props["markdown"]
        let rerooted = object.props["root"] != self.object.props["root"]
        self.object = object
        guard changed else {
            if rerooted {
                excerpts = [:]
                captured = [:]
                resolve()
            }
            return
        }
        if let session {
            session.observe(object)
            if session.conflicted { showConflict() }
            return
        }
        applyMarkdown()
    }

    private func applyMarkdown() {
        let previous = fences
        document = NoteMarkdown.parse(markdown)
        fences = NoteMarkdown.anchoredFences(in: document)
        // A fence that only gained an `anchor=` (ours, written back, or an agent's) keeps what
        // it showed instead of flashing "loading…".
        for fence in fences where excerpts[fence.key] == nil {
            var bare = fence.fence
            bare.anchor = nil
            guard let old = previous.first(where: { $0.fence == bare }) else { continue }
            excerpts[fence.key] = excerpts[old.key]
            captured[fence.key] = captured[old.key]
        }
        let keys = Set(fences.map(\.key))
        excerpts = excerpts.filter { keys.contains($0.key) }
        captured = captured.filter { keys.contains($0.key) }
        renderDisplay()
        resolve()
    }

    /// Fills the on-screen text view. Only while live: a not-live note keeps its parsed document
    /// and excerpts but no text layout (about 1 MB per note on a large board).
    private func renderDisplay() {
        guard live || isEditing else { return }
        let text = NoteRenderer(excerpts: excerpts, images: images).render(document, placeholder: Self.placeholder)
        display.textStorage?.setAttributedString(text)
    }

    // MARK: Live fences

    /// Resolve every anchored fence off the main actor, one at a time per note, then re-render
    /// if anything changed. Only while live and on screen.
    private func resolve() {
        pendingResolve?.cancel()
        pendingResolve = nil
        resolveTask?.cancel()
        guard live, window != nil else { return }
        let sources = NoteImages.sources(in: document)
        guard !fences.isEmpty || !sources.isEmpty else {
            if !images.isEmpty {
                images = [:]
                renderDisplay()
            }
            watch(files: [], root: false)
            return
        }
        resolveGeneration += 1
        let generation = resolveGeneration
        let jobs = fences
        let captured = captured
        let root = linkRoot
        resolveTask = Task { [weak self] in
            var results: [String: NoteExcerpt] = [:]
            for job in jobs {
                results[job.key] = await NoteSource.excerpt(for: job.fence, root: root, captured: captured[job.key], body: job.body)
                if Task.isCancelled { return }
            }
            let images = await NoteImages.load(sources, root: root)
            if Task.isCancelled { return }
            guard let self, self.resolveGeneration == generation else { return }
            self.apply(results, images: images, imageFiles: Array(NoteImages.files(sources, root: root).values))
        }
    }

    private func apply(_ results: [String: NoteExcerpt], images: [String: NSImage], imageFiles: [URL]) {
        for (key, excerpt) in results where captured[key] == nil && excerpt.status == .exact && !excerpt.lines.isEmpty {
            captured[key] = excerpt.lines
        }
        // Images come back re-read (a chart re-saved in place): any image re-renders.
        if results != excerpts || !images.isEmpty || !self.images.isEmpty {
            excerpts = results
            self.images = images
            renderDisplay()
        }
        let unpinned = fences.filter { $0.fence.commit == nil }
        let files = unpinned.compactMap { results[$0.key]?.path }.filter { !$0.isEmpty }
        let unfound = unpinned.contains { $0.fence.path == nil && results[$0.key]?.path.isEmpty != false }
        let root = linkRoot
        watch(files: Set(files.map { FileEvents.canonical($0.hasPrefix("/") ? $0 : root.appendingPathComponent($0).path) } + imageFiles.map { FileEvents.canonical($0.path) }), root: unfound)
        persistAnchors(results)
    }

    /// A line-range fence without `anchor=` gets its resolved first line written back as
    /// `anchor="…"`, so the range can be re-found after lines move even across app restarts,
    /// and agents reading the markdown see what it's anchored to. One update for all fences.
    private func persistAnchors(_ results: [String: NoteExcerpt]) {
        guard session == nil else { return }
        let text = NoteMarkdown.anchoringRanges(markdown, fences: fences, results: results)
        guard text != markdown else { return }
        _ = try? board.update(object.id, rev: object.rev, props: .object(["markdown": .string(text)]), actor: .system)
    }

    private func scheduleResolve() {
        pendingResolve?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resolve() }
        }
        pendingResolve = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// One recursive FSEvents stream per note over the directories holding its files (the
    /// nearest existing ancestor for a file that doesn't exist yet), plus the root while a
    /// symbol is unfound. Creation, deletion, and replacement by rename all arrive as events.
    private func watch(files: Set<String>, root: Bool) {
        watchedFiles = files
        watchesRoot = root
        let rootPath = FileEvents.canonical(linkRoot.path)
        var directories = Set(files.map(FileEvents.watchableDirectory(for:)))
        if root { directories.insert(rootPath) }
        // A directory inside another watched one adds nothing to a recursive stream.
        let minimal = directories.filter { directory in !directories.contains { $0 != directory && directory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }.sorted()
        guard minimal != events?.directories else { return }
        events = minimal.isEmpty ? nil : FileEvents(directories: minimal) { [weak self] paths in
            self?.filesChanged(paths, root: rootPath)
        }
    }

    private func filesChanged(_ paths: [String], root: String) {
        let relevant = paths.contains { path in
            if watchedFiles.contains(path) { return true }
            guard watchesRoot, path.hasPrefix(root + "/") else { return false }
            // Hidden directories (.git, .build) churn constantly and declare nothing.
            return !path.dropFirst(root.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
        }
        if relevant { scheduleResolve() }
    }

    /// Stop everything that runs on this note's behalf: resolution, file events, edit monitors.
    private func suspendWork() {
        pendingResolve?.cancel()
        pendingResolve = nil
        resolveTask?.cancel()
        resolveTask = nil
        events = nil
        watchedFiles = []
        watchesRoot = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Removed from the canvas (deleted, or its window closed).
            suspendWork()
            if session != nil { finishEditing(returningFocus: false) }
        } else {
            resolve()
        }
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isEditing else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let scroller = displayScroll.verticalScroller, !scroller.isHidden, scroller.bounds.contains(scroller.convert(local, from: self)) {
            return scroller
        }
        return self
    }

    /// The canvas often sits behind the app the user is typing in (the prompt goes to a
    /// terminal, dictation pastes there); a click on a note link should act, not just focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            beginEditing(at: point)
        } else if let link = link(at: point) {
            open(link)
        } else {
            // Selecting and dragging the note is the frame's job.
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if display.frame.height > displayScroll.contentSize.height + 1 {
            displayScroll.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// The layout fragment (one paragraph) under a point in this view's coordinates.
    private func fragment(at point: NSPoint) -> NSTextLayoutFragment? {
        let local = display.convert(point, from: self)
        guard display.bounds.contains(local), let layout = display.textLayoutManager else { return nil }
        let origin = display.textContainerOrigin
        let inContainer = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: inContainer), fragment.layoutFragmentFrame.contains(inContainer) else { return nil }
        return fragment
    }

    private func offset(of location: NSTextLocation) -> Int? {
        guard let content = display.textLayoutManager?.textContentManager else { return nil }
        return content.offset(from: content.documentRange.location, to: location)
    }

    private func link(at point: NSPoint) -> NoteLink? {
        guard let fragment = fragment(at: point), let layout = display.textLayoutManager, let content = layout.textContentManager,
              let storage = display.textStorage, let start = offset(of: fragment.rangeInElement.location),
              let end = offset(of: fragment.rangeInElement.endLocation) else { return nil }
        let local = display.convert(point, from: self)
        let origin = display.textContainerOrigin
        let inContainer = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
        var found: NoteLink?
        storage.enumerateAttribute(.noteLink, in: NSRange(location: start, length: end - start)) { value, range, stop in
            guard let encoded = value as? String,
                  let from = content.location(content.documentRange.location, offsetBy: range.location),
                  let to = content.location(from, offsetBy: range.length),
                  let textRange = NSTextRange(location: from, end: to) else { return }
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                if rect.insetBy(dx: -2, dy: -2).contains(inContainer) { found = NoteLink(encoded: encoded) }
                return found == nil
            }
            if found != nil { stop.pointee = true }
        }
        return found
    }

    /// Links open beside the note: repo paths as code tiles, web URLs as browser tiles.
    private func open(_ link: NoteLink) {
        switch link {
        case .code(let path, let lines):
            var props: [String: JSONValue] = ["path": .string(board.boardPath(path, linkRoot: linkRoot))]
            if let lines { props["range"] = .object(["start": .number(Double(lines.start)), "end": .number(Double(lines.end))]) }
            let size = Board.defaultSize(.code)
            board.create(type: .code, props: .object(props), frame: board.place(width: size.w, height: size.h, near: object.id))
        case .web(let url) where url.scheme == "http" || url.scheme == "https":
            let size = Board.defaultSize(.browser)
            board.create(type: .browser, props: .object(["url": .string(url.absoluteString)]), frame: board.place(width: size.w, height: size.h, near: object.id))
        case .web(let url):
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Editing

    /// Return on the selected note: editing, the caret at the end; Esc or ⌘↩ gives the keyboard
    /// back to the canvas with the note selected.
    func enterKeyboard() -> Bool {
        guard session == nil else { return false }
        beginEditing(at: nil)
        enteredByKeyboard = true
        return true
    }

    /// Whether this edit started from the keyboard (Return), so ending it returns to the canvas.
    private var enteredByKeyboard = false

    /// Editing, the caret where `point` is (nil: at the end).
    private func beginEditing(at point: NSPoint?) {
        guard session == nil else { return }
        session = NoteEditSession(object)
        enteredByKeyboard = false
        let text = markdown
        editor.string = text
        editor.setSelectedRange(NSRange(location: point.map { caretOffset(at: $0, in: text) } ?? (text as NSString).length, length: 0))
        displayScroll.isHidden = true
        editorScroll.isHidden = false
        window?.makeFirstResponder(editor)
        editor.scrollRangeToVisible(editor.selectedRange())
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.session != nil, event.window === self.window else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.endEditing(.implicit) }
            }
            return event
        }
    }

    /// Start of the markdown line the clicked paragraph was rendered from.
    private func caretOffset(at point: NSPoint, in text: String) -> Int {
        guard let fragment = fragment(at: point), let offset = offset(of: fragment.rangeInElement.location),
              let storage = display.textStorage, offset < storage.length,
              let line = storage.attribute(.noteMarkdownLine, at: offset, effectiveRange: nil) as? Int else {
            return (text as NSString).length
        }
        var current = 1
        var utf16 = 0
        for scalar in text.utf16 {
            if current >= line { break }
            if scalar == 0x0A { current += 1 }
            utf16 += 1
        }
        return utf16
    }

    enum EditEnd {
        /// ⌘↩: save, and overwrite a conflict that is already shown.
        case confirmed
        /// Clicking away or focus moving elsewhere: save unless there is a conflict.
        case implicit
        case cancel
    }

    private func endEditing(_ end: EditEnd, returningFocus: Bool = true) {
        guard let session else { return }
        if end != .cancel {
            do {
                if try session.commit(editor.string, confirmed: end == .confirmed, on: board) == .conflict {
                    // Keep the user's text in the editor until they choose (⌘↩ or Esc).
                    showConflict()
                    return
                }
            } catch {
                // The note is gone; nothing to save into.
            }
        }
        finishEditing(returningFocus: returningFocus)
    }

    private func finishEditing(returningFocus: Bool) {
        session = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        banner.isHidden = true
        let hadFocus = window?.firstResponder === editor
        editorScroll.isHidden = true
        displayScroll.isHidden = false
        if let current = board.objects[object.id] { object = current }
        applyMarkdown()
        if hadFocus, returningFocus { returnFocus() }
    }

    private func showConflict() {
        showBanner("Changed by someone else while you were editing. ⌘↩ saves yours over it; Esc keeps theirs.")
    }

    /// Keyboard focus goes back to the canvas with the note selected after an edit started with
    /// Return, else to where prompts go.
    private func returnFocus() {
        let canvas = enclosingScrollView as? CanvasView
        if enteredByKeyboard, let canvas {
            canvas.leaveTile(object.id)
        } else if let canvas, let target = canvas.promptTarget, let terminal = canvas.tiles[target]?.content as? TerminalTile {
            terminal.focus()
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    private func showBanner(_ text: String) {
        banner.stringValue = text
        banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        banner.isHidden = false
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live {
            attachScrollViews()
            renderDisplay()
            resolve()
        } else {
            suspendWork()
            guard !isEditing else { return }
            // Offscreen or carded, a note holds no text layout, and its scroll views leave the
            // hierarchy: AppKit re-tiles every scroll view and rebuilds its tracking areas on each
            // frame of a canvas pan, hidden or not. `render(_:)` and cards don't use them.
            display.textStorage?.setAttributedString(NSAttributedString())
            displayScroll.removeFromSuperview()
            editorScroll.removeFromSuperview()
        }
    }

    private func attachScrollViews() {
        for scroll in [displayScroll, editorScroll] where scroll.superview !== self {
            scroll.frame = bounds
            addSubview(scroll, positioned: .below, relativeTo: banner)
        }
    }

    /// Lays the note out on its own text stack (never the on-screen view, which only holds text
    /// while live) and draws every paragraph. Anchored fences the note hasn't resolved yet (it
    /// was never live) are resolved first.
    func render(_ request: TileRenderRequest) async -> TileRender {
        var resolved = excerpts
        let root = linkRoot
        for fence in fences where resolved[fence.key] == nil {
            resolved[fence.key] = await NoteSource.excerpt(for: fence.fence, root: root, captured: captured[fence.key], body: fence.body)
        }
        if resolved != excerpts, !live {
            excerpts = resolved
        }
        let sources = NoteImages.sources(in: document)
        let pictures = await NoteImages.load(sources, root: root)
        let text = NoteRenderer(excerpts: resolved, images: pictures).render(document, placeholder: Self.placeholder)
        let inset = NSSize(width: 8, height: 10)
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let delegate = NoteLayoutDelegate()
        layout.delegate = delegate
        let container = NSTextContainer(size: CGSize(width: max(1, request.size.width - 2 * inset.width), height: 0))
        container.lineFragmentPadding = 2
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        content.attributedString = text
        layout.ensureLayout(for: layout.documentRange)
        var fragments: [NSTextLayoutFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragments.append(fragment)
            return true
        }
        let used = fragments.last.map { $0.layoutFragmentFrame.maxY } ?? 0
        let contentSize = CGSize(width: request.size.width, height: (used + 2 * inset.height).rounded(.up))
        let size = request.full ? CGSize(width: request.size.width, height: min(max(request.size.height, contentSize.height), RenderMath.maxContentExtent)) : request.size
        let image = request.image(size: size) { bounds in
            NSColor.systemYellow.withAlphaComponent(0.16).setFill()
            bounds.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            for fragment in fragments where fragment.layoutFragmentFrame.minY < bounds.height {
                fragment.draw(at: CGPoint(x: fragment.layoutFragmentFrame.minX + inset.width, y: fragment.layoutFragmentFrame.minY + inset.height), in: context)
            }
        }
        withExtendedLifetime((content, delegate)) {}
        return TileRender(image: image, contentSize: contentSize, state: image == nil ? .failed : .rendered, reason: image == nil ? "bitmap allocation failed" : nil)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard !isEditing, let fragment = fragment(at: point), let offset = offset(of: fragment.rangeInElement.location),
              let storage = display.textStorage, offset < storage.length,
              let row = storage.attribute(.noteCodeRow, at: offset, effectiveRange: nil) as? NoteCodeRow else {
            hoveredRow = nil
            return .object(object.id)
        }
        let target = MentionTarget.code(object: object.id, path: row.path, lines: LineRange(start: row.line, end: row.line), side: nil, symbol: row.symbol, commit: row.commit)
        hoveredRow = (target, rect(of: fragment))
        return target
    }

    /// The row last hovered and its outline: a proposal's added row mentions the real line it
    /// would be inserted before, so the same target can come from two rows.
    private var hoveredRow: (target: MentionTarget, rect: NSRect)?

    private func rect(of fragment: NSTextLayoutFragment) -> NSRect {
        let frame = fragment.layoutFragmentFrame
        let inText = NSRect(x: 0, y: frame.minY + display.textContainerOrigin.y, width: display.bounds.width, height: frame.height)
        return convert(inText, from: display).intersection(bounds)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, _, let symbol, let commit, _) = target else { return bounds }
        if let hoveredRow, hoveredRow.target == target { return hoveredRow.rect }
        let wanted = NoteCodeRow(path: path, line: lines.start, symbol: symbol, commit: commit)
        guard let storage = display.textStorage, let layout = display.textLayoutManager, let content = layout.textContentManager else { return nil }
        var rect: NSRect?
        storage.enumerateAttribute(.noteCodeRow, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let row = value as? NoteCodeRow, row == wanted,
                  let location = content.location(content.documentRange.location, offsetBy: range.location),
                  let fragment = layout.textLayoutFragment(for: location) else { return }
            rect = self.rect(of: fragment)
            stop.pointee = true
        }
        return rect
    }

    var takesKeyboardFocus: Bool { isEditing }
}

/// The rendered note. TextKit 2 lays out only a viewport around what's visible, and on the canvas
/// "visible" follows every pan and pinch step (the canvas clips too), so each step re-laid out
/// every note on screen and resized it to a new height estimate, sometimes never converging: a
/// seconds-long beachball while zooming a board of notes, once an AppKit layout-loop exception.
/// A note is short; lay all of it out once per content change instead. NSTextView implements
/// this viewport delegate method without exposing it to Swift, hence the selector.
final class NoteDisplayView: NSTextView {
    @objc(viewportBoundsForTextViewportLayoutController:)
    func wholeTextViewport(_ controller: NSTextViewportLayoutController) -> CGRect {
        bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.NoteDisplayView", since: perfStart) }
        super.draw(dirtyRect)
    }
}

/// The rendered note's scroll view keeps overlay scrollers whatever the system setting, so the
/// text always wraps at the width `ObjectMeasure` fits notes at. A legacy scroller (a mouse
/// attached, or "Show scroll bars: Always") took its width from the text once a note overflowed,
/// even briefly, and the narrower wrap kept it a line taller than its fitted frame: clipped.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// The raw-markdown editor: ⌘↩ commits, Esc cancels, losing focus commits.
final class NoteEditor: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResign: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window offers key equivalents to every view; only the focused editor commits.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command,
           event.charactersIgnoringModifiers == "\r" || event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) {
            onCancel?()
        } else {
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}
