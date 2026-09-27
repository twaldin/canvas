import AppKit
import CanvasCore

/// Controls above a code tile: the diff base, named as the changes tile's picker names it
/// (Uncommitted changes, Branch vs origin/main, vs <commit>), previous/next change, the
/// status line and any warning, and for follow tiles "N new ▸" (while the user holds the tile),
/// Pin, and a strip of recent locations. An optional caption strip sits under the first row.
/// A file without changes against its base shows only a quiet "no changes" there until the
/// pointer is over the header, which brings the base picker back (a board of read-only diagram
/// tiles repeated "merge-base ⌄ ⌃⌄ no changes · …" on every one).
/// The picker's and the status's tooltips say exactly what the diff is against.
/// The rightmost `reservedTrailing` points stay free for tile-level buttons the language
/// service adds. Heights follow `CodeMetrics`.
@MainActor
final class CodeHeaderBar: NSView {
    struct Location: Equatable, Sendable {
        var path: String
        var range: LineRange?

        var title: String {
            let name = (path as NSString).lastPathComponent
            guard let range else { return name }
            return range.start == range.end ? "\(name):\(range.start)" : "\(name):\(range.start)-\(range.end)"
        }
    }

    static let reservedTrailing: CGFloat = 80
    private static let pencil: NSImage? = {
        let image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edited")
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    }()

    var onBase: ((String) -> Void)?
    var onChange: ((_ forward: Bool) -> Void)?
    var onPin: (() -> Void)?
    var onCatchUp: (() -> Void)?
    var onLocation: ((Location) -> Void)?

    /// The AppKit controls, built when the header first enters a window or is first drawn for a
    /// card: a tile created as a card (dozens at once, zoomed out or offscreen) never builds them
    /// on creation. What they show is kept below until then.
    private var controls: Controls?
    private var baseChoices: [ChangesBaseChoice] = [.uncommitted, .branch]
    private var baseTitles = [ChangesBaseChoice.uncommitted, .branch].map { $0.title(defaultBranch: nil) }
    private var baseSelected = 1
    private var baseDescription: String?
    private var statusLine = NSAttributedString()
    private var changes = false
    private var diffs = true
    private var follow = false
    private var missed = 0
    private var warned = false
    /// The pointer is over the header: a quiet header shows its controls.
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    /// Nothing to step through or warn about: the base picker and arrows wait for a hover.
    private var quiet: Bool { diffs && !changes && !warned && !hovering }
    private var history: [Location] = []
    /// Per history entry: the agent edited or wrote it there (a pencil on its chip).
    private var edited: [Bool] = []
    private var current: Location?
    private var captionText: String?

    @MainActor
    private final class Controls {
        let base = NSPopUpButton(frame: .zero, pullsDown: false)
        let previous = NSButton()
        let next = NSButton()
        let status = NSTextField(labelWithString: "")
        let pending = NSButton(title: "", target: nil, action: nil)
        let pin = NSButton(title: "Pin", target: nil, action: nil)
        let caption = NSTextField(labelWithString: "")
        let strip = NSStackView()
        /// The strip's location buttons, newest first (some hidden when the strip is too narrow).
        var stripButtons: [NSButton] = []
        /// What the caption and the strip's buttons were built for.
        var captionShown: String?
        var stripShown: (history: [Location], edited: [Bool], current: Location?) = ([], [], nil)

        init(in header: CodeHeaderBar) {
            base.controlSize = .small
            base.font = .systemFont(ofSize: 11)
            base.isBordered = false
            base.target = header
            base.action = #selector(CodeHeaderBar.baseChanged(_:))
            for (button, symbol, action) in [(previous, "chevron.up", #selector(CodeHeaderBar.previousChange)), (next, "chevron.down", #selector(CodeHeaderBar.nextChange))] {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.up" ? "Previous change" : "Next change")
                button.bezelStyle = .recessed
                button.isBordered = false
                button.controlSize = .small
                button.target = header
                button.action = action
                button.toolTip = symbol == "chevron.up" ? "Previous change" : "Next change"
            }
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byTruncatingTail
            status.cell?.truncatesLastVisibleLine = true
            pending.isBordered = false
            pending.font = .systemFont(ofSize: 11, weight: .semibold)
            pending.contentTintColor = .controlAccentColor
            pending.target = header
            pending.action = #selector(CodeHeaderBar.catchUp)
            pending.toolTip = "The agent moved on while you were reading; click to catch up"
            pending.isHidden = true
            pin.controlSize = .small
            pin.bezelStyle = .push
            pin.font = .systemFont(ofSize: 11)
            pin.target = header
            pin.action = #selector(CodeHeaderBar.pinClicked)
            pin.toolTip = "Keep this view as a permanent code tile"
            caption.lineBreakMode = .byTruncatingTail
            caption.cell?.truncatesLastVisibleLine = true
            caption.isHidden = true
            strip.orientation = .horizontal
            strip.spacing = 4
            strip.alignment = .centerY
            // Behind anything added meanwhile (the language service's Outline button).
            for view in [base, previous, next, status, pending, pin, caption, strip] as [NSView] { header.addSubview(view, positioned: .below, relativeTo: nil) }
        }
    }

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Unclipped (the macOS 14 default), AppKit backs this view with a layer spanning the
        // whole tile and passes dirty rects outside it, so the fill below covered the title bar
        // and the code beneath.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyIfShown() }
            }
        }
        guard window != nil else { return }
        if controls == nil { controls = Controls(in: self) }
        applyIfShown()
    }

    /// What the controls show changed while nobody could see them (see `refreshControls`).
    private var controlsStale = true
    private var occlusionObserver: NSObjectProtocol?

    /// The strips' height: while presenting, without the first row.
    var height: CGFloat {
        CodeMetrics.chromeHeight(caption: captionText != nil, history: !history.isEmpty) - CodeMetrics.titleHeight - (presenting ? CodeMetrics.headerHeight : 0)
    }

    /// `diffBase` is the prop (`merge-base`, `head`, or a commit), named in the picker with
    /// `defaultBranch` (`Branch vs origin/main`); `baseDescription` is what the diff is against
    /// exactly, for the tooltips; `warning` shows before the status in orange.
    /// `diffBase` nil: the tile shows no diff (pinned to a commit), so there is no base to pick
    /// and no changes to step through.
    func show(diffBase: String?, defaultBranch: String?, baseDescription: String?, status text: String, warning: String?, changes: Bool, follow: Bool, missed: Int) {
        diffs = diffBase != nil
        if let diffBase {
            let current = ChangesBaseChoice(prop: diffBase)
            baseChoices = ChangesBaseChoice.choices(current: current)
            baseTitles = baseChoices.map { $0.title(defaultBranch: defaultBranch) }
            baseSelected = baseChoices.firstIndex(of: current) ?? 1
        }
        self.baseDescription = baseDescription
        let line = NSMutableAttributedString()
        if let warning {
            line.append(NSAttributedString(string: "⚠︎ \(warning)", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
            if !text.isEmpty { line.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])) }
        }
        line.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        statusLine = line
        self.changes = changes
        self.follow = follow
        self.missed = missed
        warned = warning != nil
        refreshControls()
    }

    /// One line under the header (`CodeCaption`: `inline code` in backticks is set in the code font).
    func show(caption text: String?) {
        let text = text.flatMap { $0.isEmpty ? nil : CodeCaption.text($0) }
        guard text != captionText else { return }
        captionText = text
        refreshControls()
    }

    func show(history: [Location], edited: [Bool], current: Location?) {
        guard history != self.history || edited != self.edited || current != self.current else { return }
        self.history = history
        self.edited = edited
        self.current = current
        refreshControls()
    }

    /// Pushes what the header shows into its controls, once they exist and can be seen. A follow
    /// tile's header changes with every re-aim of a working agent, and rebuilding and laying out
    /// its controls cost ~10 ms each time even in a minimized window or an offscreen tile (not in
    /// the window): that waits until the header is shown or drawn for a card.
    private func refreshControls() {
        controlsStale = true
        applyIfShown()
    }

    private func applyIfShown() {
        guard controlsStale, let controls, window?.occlusionState.contains(.visible) == true else { return }
        apply(controls)
    }

    private func apply(_ controls: Controls) {
        controlsStale = false
        if controls.base.itemTitles != baseTitles {
            controls.base.removeAllItems()
            controls.base.addItems(withTitles: baseTitles)
        }
        controls.base.selectItem(at: baseSelected)
        controls.base.toolTip = "Changes are shown " + (baseDescription ?? "against this base")
        controls.status.attributedStringValue = quiet ? Self.quietLine(statusLine.string) : statusLine
        controls.status.toolTip = [statusLine.string, baseDescription.map { "Changes " + $0 }].compactMap { $0 }.joined(separator: "\n")
        controls.previous.isEnabled = changes
        controls.next.isEnabled = changes
        for control in [controls.base, controls.previous, controls.next] as [NSView] { control.isHidden = !diffs || quiet }
        controls.pin.isHidden = !follow
        // A follow tile explains itself where it differs from a code tile.
        let followTip = follow ? CanvasBasics.followTile : nil
        if toolTip != followTip { toolTip = followTip }
        let historyTip = follow ? CanvasBasics.followHistory : nil
        if controls.strip.toolTip != historyTip { controls.strip.toolTip = historyTip }
        controls.pending.isHidden = missed == 0
        controls.pending.title = "\(missed) new ▸"
        if controls.captionShown != captionText {
            controls.captionShown = captionText
            controls.caption.isHidden = captionText == nil
            controls.caption.attributedStringValue = captionText.map(CodeCaption.string) ?? NSAttributedString()
            controls.caption.toolTip = captionText
        }
        if controls.stripShown.history != history || controls.stripShown.edited != edited || controls.stripShown.current != current {
            controls.stripShown = (history, edited, current)
            // Re-aims shift the same few locations along: retitle the buttons already there.
            for extra in controls.stripButtons.dropFirst(history.count) {
                controls.strip.removeArrangedSubview(extra)
                extra.removeFromSuperview()
            }
            controls.stripButtons = Array(controls.stripButtons.prefix(history.count))
            for (index, location) in history.enumerated() {
                let button = index < controls.stripButtons.count ? controls.stripButtons[index] : NSButton(title: "", target: self, action: #selector(locationClicked(_:)))
                button.tag = index
                button.isBordered = false
                button.title = location.title
                button.font = location == current ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
                let isEdit = edited.indices.contains(index) && edited[index]
                button.contentTintColor = location == current ? .labelColor : isEdit ? .systemOrange : .linkColor
                button.image = isEdit ? Self.pencil : nil
                button.imagePosition = isEdit ? .imageLeading : .noImage
                button.imageHugsTitle = true
                button.toolTip = isEdit ? "Edited: \(location.path)" : location.path
                if index >= controls.stripButtons.count {
                    controls.stripButtons.append(button)
                    controls.strip.addArrangedSubview(button)
                }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Stale controls still show an older history and caption than the header's state (the
        // strip's buttons are indexed by the history they were built for): lay them out once
        // they are applied, which asks for layout again.
        guard let controls, !controlsStale else { return }
        let middle = CodeMetrics.headerHeight / 2
        var x: CGFloat = 4
        func place(_ view: NSView, width: CGFloat) {
            let height = view.fittingSize.height
            view.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: width, height: height)
            x += width + 2
        }
        if diffs && !quiet {
            place(controls.base, width: controls.base.fittingSize.width)
            place(controls.previous, width: 20)
            place(controls.next, width: 20)
        }
        var end = bounds.width - Self.reservedTrailing
        for button in [controls.pin, controls.pending] where !button.isHidden {
            let size = button.fittingSize
            button.frame = NSRect(x: end - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
            end = button.frame.minX - 6
        }
        controls.status.frame = NSRect(x: x + 4, y: (middle - 8).rounded(), width: max(0, end - x - 4), height: 16)
        var y = CodeMetrics.headerHeight
        if captionText != nil {
            controls.caption.frame = NSRect(x: CodeMetrics.captionInset, y: y + 1, width: max(0, bounds.width - 2 * CodeMetrics.captionInset), height: CodeMetrics.captionHeight - 4)
            y += CodeMetrics.captionHeight
        }
        controls.strip.frame = NSRect(x: 6, y: y, width: max(0, bounds.width - 12), height: CodeMetrics.historyHeight - 2)
        controls.strip.isHidden = history.isEmpty
        fitStrip(controls)
    }

    /// Shows the current location, then the edits, then the newest reads, as many as fit whole,
    /// in history order; the oldest reads drop off a narrow tile first (a strip wider than its
    /// frame clipped or squeezed buttons, the current one included).
    private func fitStrip(_ controls: Controls) {
        let buttons = controls.stripButtons
        let widths = buttons.map(\.fittingSize.width)
        let pinned = history.firstIndex { $0 == current }
        var room = controls.strip.frame.width - (pinned.map { widths[$0] } ?? 0)
        var shown = Set(pinned.map { [$0] } ?? [])
        let isEdit = { (index: Int) in self.edited.indices.contains(index) && self.edited[index] }
        let order = buttons.indices.filter(isEdit) + buttons.indices.filter { !isEdit($0) }
        for index in order where index != pinned {
            let needed = widths[index] + (shown.isEmpty ? 0 : controls.strip.spacing)
            guard needed <= room else { break }
            room -= needed
            shown.insert(index)
        }
        for (index, button) in buttons.enumerated() where button.isHidden == shown.contains(index) { button.isHidden = !shown.contains(index) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.CodeHeaderBar", since: perfStart) }
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// The status's first part ("no changes"), muted like line numbers (4.5:1, `CodeTheme.lineNumber`).
    private static func quietLine(_ status: String) -> NSAttributedString {
        let head = status.components(separatedBy: " · ").first ?? status
        return NSAttributedString(string: head, attributes: [.foregroundColor: CodeTheme.lineNumber, .font: NSFont.systemFont(ofSize: 11)])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: bounds.width, height: CodeMetrics.headerHeight),
                                  options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshControls()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshControls()
    }

    /// Readies the header to be drawn offscreen (`cacheDisplay`) for cards and renders: its own
    /// controls, built if it never entered a window, laid out, so the image is exactly what the
    /// live header shows.
    func prepareForSnapshot() {
        if controls == nil { controls = Controls(in: self) }
        if controlsStale, let controls { apply(controls) }
        layoutSubtreeIfNeeded()
    }

    // MARK: Presenting

    /// Hidden canvas chrome (View › Hide Canvas Chrome): the first row (diff base, change
    /// arrows, status, Pin, the Outline button) leaves the header, scrolled out above its bounds
    /// where nothing draws or takes clicks, and `height` drops it, so the code tile moves its rows
    /// up (arrows bound to lines follow them); the caption and history strips stay.
    var presenting = false {
        didSet {
            guard presenting != oldValue else { return }
            setBoundsOrigin(NSPoint(x: 0, y: presenting ? CodeMetrics.headerHeight : 0))
            needsDisplay = true
        }
    }

    @objc private func baseChanged(_ sender: NSPopUpButton) {
        guard baseChoices.indices.contains(sender.indexOfSelectedItem) else { return }
        let choice = baseChoices[sender.indexOfSelectedItem]
        onBase?(choice == .uncommitted ? "head" : choice.prop)
    }

    @objc private func previousChange() { onChange?(false) }
    @objc private func nextChange() { onChange?(true) }
    @objc private func pinClicked() { onPin?() }
    @objc private func catchUp() { onCatchUp?() }

    @objc private func locationClicked(_ sender: NSButton) {
        guard history.indices.contains(sender.tag) else { return }
        onLocation?(history[sender.tag])
    }
}
