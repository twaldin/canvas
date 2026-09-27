import AppKit
import CanvasCore

/// Controls above a code tile: the diff base (merge-base | HEAD), previous/next change, the
/// status line and any warning, and for follow tiles "N new ▸" (while the user holds the tile),
/// Pin, and a strip of recent locations. An optional caption strip sits under the first row.
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

    var onBase: ((String) -> Void)?
    var onChange: ((_ forward: Bool) -> Void)?
    var onPin: (() -> Void)?
    var onCatchUp: (() -> Void)?
    var onLocation: ((Location) -> Void)?

    /// The AppKit controls, built when the header first enters a window or is first drawn for a
    /// card: a tile created as a card (dozens at once, zoomed out or offscreen) never builds them
    /// on creation. What they show is kept below until then.
    private var controls: Controls?
    private var baseChoices = ["merge-base", "HEAD"]
    private var baseSelected = 0
    private var statusLine = NSAttributedString()
    private var changes = false
    private var follow = false
    private var missed = 0
    private var history: [Location] = []
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
        /// What the caption and the strip's buttons were built for.
        var captionShown: String?
        var stripShown: (history: [Location], current: Location?) = ([], nil)

        init(in header: CodeHeaderBar) {
            base.controlSize = .small
            base.font = .systemFont(ofSize: 11)
            base.isBordered = false
            base.target = header
            base.action = #selector(CodeHeaderBar.baseChanged(_:))
            base.toolTip = "Changes are shown against this base"
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
        guard window != nil, controls == nil else { return }
        controls = Controls(in: self)
        refreshControls()
    }

    var height: CGFloat {
        CodeMetrics.chromeHeight(caption: captionText != nil, history: !history.isEmpty) - CodeMetrics.titleHeight
    }

    /// `diffBase` is the prop (`merge-base`, `head`, or a commit); `warning` shows before the
    /// status in orange.
    func show(diffBase: String, status text: String, warning: String?, changes: Bool, follow: Bool, missed: Int) {
        baseChoices = ["merge-base", "HEAD"] + (["merge-base", "head", "HEAD"].contains(diffBase) ? [] : [String(diffBase.prefix(12))])
        baseSelected = diffBase == "merge-base" ? 0 : diffBase.lowercased() == "head" ? 1 : 2
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
        refreshControls()
    }

    /// One line under the header (`CodeCaption`: `inline code` in backticks is set in the code font).
    func show(caption text: String?) {
        let text = text.flatMap { $0.isEmpty ? nil : CodeCaption.text($0) }
        guard text != captionText else { return }
        captionText = text
        refreshControls()
    }

    func show(history: [Location], current: Location?) {
        guard history != self.history || current != self.current else { return }
        self.history = history
        self.current = current
        refreshControls()
    }

    /// Pushes what the header shows into its controls, once they exist.
    private func refreshControls() {
        guard let controls else { return }
        if controls.base.itemTitles != baseChoices {
            controls.base.removeAllItems()
            controls.base.addItems(withTitles: baseChoices)
        }
        controls.base.selectItem(at: baseSelected)
        controls.status.attributedStringValue = statusLine
        controls.status.toolTip = statusLine.string
        controls.previous.isEnabled = changes
        controls.next.isEnabled = changes
        controls.pin.isHidden = !follow
        controls.pending.isHidden = missed == 0
        controls.pending.title = "\(missed) new ▸"
        if controls.captionShown != captionText {
            controls.captionShown = captionText
            controls.caption.isHidden = captionText == nil
            controls.caption.attributedStringValue = captionText.map(CodeCaption.string) ?? NSAttributedString()
            controls.caption.toolTip = captionText
        }
        if controls.stripShown.history != history || controls.stripShown.current != current {
            controls.stripShown = (history, current)
            controls.strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index, location) in history.enumerated() {
                let button = NSButton(title: location.title, target: self, action: #selector(locationClicked(_:)))
                button.tag = index
                button.isBordered = false
                button.font = location == current ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
                button.contentTintColor = location == current ? .labelColor : .linkColor
                button.toolTip = location.path
                controls.strip.addArrangedSubview(button)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let controls else { return }
        let middle = CodeMetrics.headerHeight / 2
        var x: CGFloat = 4
        func place(_ view: NSView, width: CGFloat) {
            let height = view.fittingSize.height
            view.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: width, height: height)
            x += width + 2
        }
        place(controls.base, width: controls.base.fittingSize.width)
        place(controls.previous, width: 20)
        place(controls.next, width: 20)
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
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Readies the header to be drawn offscreen (`cacheDisplay`) for cards and renders: its own
    /// controls, built if it never entered a window, laid out, so the image is exactly what the
    /// live header shows.
    func prepareForSnapshot() {
        if controls == nil {
            controls = Controls(in: self)
            refreshControls()
        }
        layoutSubtreeIfNeeded()
    }

    @objc private func baseChanged(_ sender: NSPopUpButton) {
        onBase?(sender.indexOfSelectedItem == 0 ? "merge-base" : sender.indexOfSelectedItem == 1 ? "head" : sender.titleOfSelectedItem ?? "merge-base")
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
