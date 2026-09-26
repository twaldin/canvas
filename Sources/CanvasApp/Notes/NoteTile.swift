import AppKit
import CanvasCore
import Markdown

/// A markdown note (docs/design.md "Notes"). Displays rendered markdown with live code fences;
/// double-click edits the raw markdown, ⌘↩ or clicking away commits, Esc cancels. The note
/// holds keyboard focus only while editing, then hands it back to the prompt-target terminal.
@MainActor
final class NoteTile: NSView, TileContent {
    static let placeholder = "Double-click to write a note"
    /// File changes arrive in bursts (editors write, rename, and touch); resolve once they settle.
    static let debounce: TimeInterval = 0.25

    private(set) var object: CanvasObject
    private let board: Board
    private let displayScroll = NSScrollView()
    private let display = NSTextView(usingTextLayoutManager: true)
    private let layoutDelegate = NoteLayoutDelegate()
    private let editorScroll = NSScrollView()
    private let editor = NoteEditor(usingTextLayoutManager: true)
    private let banner = NSTextField(labelWithString: "")

    private var document: Document
    private var fences: [NoteRenderer.AnchoredFence] = []
    private var excerpts: [String: NoteExcerpt] = [:]
    /// Text each fence showed when first resolved: re-finds moved ranges, stands in when lost.
    private var captured: [String: [String]] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var resolveTask: Task<Void, Never>?
    private var resolveGeneration = 0
    private var pendingResolve: DispatchWorkItem?
    private var live = true

    private(set) var isEditing = false
    private var editBaseRev = 0
    private var clickMonitor: Any?

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        document = NoteRenderer.parse(object.props["markdown"]?.string ?? "")
        super.init(frame: NSRect(x: 0, y: 0, width: object.frame.w, height: object.frame.h))
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor

        display.isEditable = false
        display.isSelectable = false
        display.drawsBackground = false
        display.textContainerInset = NSSize(width: 8, height: 10)
        display.textContainer?.lineFragmentPadding = 2
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
        editor.onCommit = { [weak self] in self?.endEditing(commit: true) }
        editor.onCancel = { [weak self] in self?.endEditing(commit: false) }
        // Focus is already moving elsewhere; don't pull it to the prompt target mid-change.
        editor.onResign = { [weak self] in self?.endEditing(commit: true, returningFocus: false) }
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

        fences = NoteRenderer.anchoredFences(in: document)
        render()
        resolve()
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

    func update(_ object: CanvasObject) {
        let changed = object.props["markdown"] != self.object.props["markdown"]
        self.object = object
        guard changed else { return }
        if isEditing {
            showBanner("Changed by someone else while you were editing. ⌘↩ saves yours over it; Esc keeps theirs.")
            return
        }
        applyMarkdown()
    }

    private func applyMarkdown() {
        document = NoteRenderer.parse(markdown)
        fences = NoteRenderer.anchoredFences(in: document)
        let keys = Set(fences.map(\.key))
        excerpts = excerpts.filter { keys.contains($0.key) }
        captured = captured.filter { keys.contains($0.key) }
        render()
        resolve()
    }

    private func render() {
        let text = NoteRenderer(excerpts: excerpts).render(document, placeholder: Self.placeholder)
        display.textStorage?.setAttributedString(text)
    }

    // MARK: Live fences

    /// Resolve every anchored fence off the main actor, one at a time per note, then re-render
    /// if anything changed.
    private func resolve() {
        pendingResolve?.cancel()
        pendingResolve = nil
        resolveTask?.cancel()
        guard live else { return }
        guard !fences.isEmpty else {
            watch([])
            return
        }
        resolveGeneration += 1
        let generation = resolveGeneration
        let jobs = fences
        let captured = captured
        let root = board.root
        resolveTask = Task { [weak self] in
            var results: [String: NoteExcerpt] = [:]
            for job in jobs {
                results[job.key] = await NoteSource.excerpt(for: job.fence, root: root, captured: captured[job.key], body: job.body)
                if Task.isCancelled { return }
            }
            guard let self, self.resolveGeneration == generation else { return }
            self.apply(results)
        }
    }

    private func apply(_ results: [String: NoteExcerpt]) {
        for (key, excerpt) in results where captured[key] == nil && excerpt.status == .exact && !excerpt.lines.isEmpty {
            captured[key] = excerpt.lines
        }
        if results != excerpts {
            excerpts = results
            render()
        }
        let pinned = Set(fences.filter { $0.fence.commit != nil }.map(\.key))
        watch(Set(results.filter { !pinned.contains($0.key) && !$0.value.path.isEmpty }.map { board.absoluteURL($0.value.path).path }))
    }

    private func scheduleResolve() {
        pendingResolve?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resolve() }
        }
        pendingResolve = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// One watcher per excerpted file. Editors and agents often replace a file by renaming over
    /// it, which orphans the watcher, so a rename or delete drops it and the next resolve re-opens.
    private func watch(_ paths: Set<String>) {
        for (path, source) in watchers where !paths.contains(path) {
            source.cancel()
            watchers[path] = nil
        }
        for path in paths where watchers[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !source.data.intersection(DispatchSource.FileSystemEvent([.rename, .delete])).isEmpty {
                        source.cancel()
                        if self.watchers[path] === source { self.watchers[path] = nil }
                    }
                    self.scheduleResolve()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[path] = source
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
            var props: [String: JSONValue] = ["path": .string(board.relativePath(path))]
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

    private func beginEditing(at point: NSPoint) {
        guard !isEditing else { return }
        isEditing = true
        editBaseRev = object.rev
        let text = markdown
        editor.string = text
        editor.setSelectedRange(NSRange(location: caretOffset(at: point, in: text), length: 0))
        displayScroll.isHidden = true
        editorScroll.isHidden = false
        window?.makeFirstResponder(editor)
        editor.scrollRangeToVisible(editor.selectedRange())
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isEditing, event.window === self.window else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.endEditing(commit: true) }
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

    private func endEditing(commit: Bool, returningFocus: Bool = true) {
        guard isEditing else { return }
        let text = editor.string
        if commit, text != markdown || object.rev != editBaseRev {
            do {
                try board.update(object.id, rev: editBaseRev, props: .object(["markdown": .string(text)]))
            } catch BoardError.conflict {
                // Someone else changed the note meanwhile; keep the user's text and let them choose.
                editBaseRev = board.objects[object.id]?.rev ?? object.rev
                showBanner("Changed by someone else while you were editing. ⌘↩ saves yours over it; Esc keeps theirs.")
                return
            } catch {
                return
            }
        }
        isEditing = false
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

    /// Keyboard focus goes back to where prompts go.
    private func returnFocus() {
        if let canvas = enclosingScrollView as? CanvasView, let target = canvas.promptTarget,
           let terminal = canvas.tiles[target]?.content as? TerminalTile {
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
            resolve()
        } else {
            pendingResolve?.cancel()
            resolveTask?.cancel()
            watch([])
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard !isEditing, let fragment = fragment(at: point), let offset = offset(of: fragment.rangeInElement.location),
              let storage = display.textStorage, offset < storage.length,
              let row = storage.attribute(.noteCodeRow, at: offset, effectiveRange: nil) as? NoteCodeRow else {
            hoveredRow = nil
            return .object(object.id)
        }
        let target = MentionTarget.code(object: object.id, path: row.path, lines: LineRange(start: row.line, end: row.line), side: nil, symbol: row.symbol)
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
        guard case .code(_, let path, let lines, _, let symbol) = target else { return bounds }
        if let hoveredRow, hoveredRow.target == target { return hoveredRow.rect }
        let wanted = NoteCodeRow(path: path, line: lines.start, symbol: symbol)
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
