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

    private let base = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previous = NSButton()
    private let next = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let pending = NSButton(title: "", target: nil, action: nil)
    private let pin = NSButton(title: "Pin", target: nil, action: nil)
    private let caption = NSTextField(labelWithString: "")
    private let strip = NSStackView()
    private var history: [Location] = []
    private var current: Location?
    private var captionText: String?

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Unclipped (the macOS 14 default), AppKit backs this view with a layer spanning the
        // whole tile and passes dirty rects outside it, so the fill below covered the title bar
        // and the code beneath.
        clipsToBounds = true
        base.controlSize = .small
        base.font = .systemFont(ofSize: 11)
        base.isBordered = false
        base.target = self
        base.action = #selector(baseChanged)
        base.toolTip = "Changes are shown against this base"
        for (button, symbol, action) in [(previous, "chevron.up", #selector(previousChange)), (next, "chevron.down", #selector(nextChange))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.up" ? "Previous change" : "Next change")
            button.bezelStyle = .recessed
            button.isBordered = false
            button.controlSize = .small
            button.target = self
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
        pending.target = self
        pending.action = #selector(catchUp)
        pending.toolTip = "The agent moved on while you were reading; click to catch up"
        pending.isHidden = true
        pin.controlSize = .small
        pin.bezelStyle = .push
        pin.font = .systemFont(ofSize: 11)
        pin.target = self
        pin.action = #selector(pinClicked)
        pin.toolTip = "Keep this view as a permanent code tile"
        caption.lineBreakMode = .byTruncatingTail
        caption.cell?.truncatesLastVisibleLine = true
        caption.isHidden = true
        strip.orientation = .horizontal
        strip.spacing = 4
        strip.alignment = .centerY
        for view in [base, previous, next, status, pending, pin, caption, strip] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var height: CGFloat {
        CodeMetrics.chromeHeight(caption: captionText != nil, history: !history.isEmpty) - CodeMetrics.titleHeight
    }

    /// `diffBase` is the prop (`merge-base`, `head`, or a commit); `warning` shows before the
    /// status in orange.
    func show(diffBase: String, status text: String, warning: String?, changes: Bool, follow: Bool, missed: Int) {
        let choices = ["merge-base", "HEAD"] + (["merge-base", "head", "HEAD"].contains(diffBase) ? [] : [String(diffBase.prefix(12))])
        if base.itemTitles != choices {
            base.removeAllItems()
            base.addItems(withTitles: choices)
        }
        base.selectItem(at: diffBase == "merge-base" ? 0 : diffBase.lowercased() == "head" ? 1 : 2)
        let line = NSMutableAttributedString()
        if let warning {
            line.append(NSAttributedString(string: "⚠︎ \(warning)", attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
            if !text.isEmpty { line.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])) }
        }
        line.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        status.attributedStringValue = line
        status.toolTip = line.string
        previous.isEnabled = changes
        next.isEnabled = changes
        pin.isHidden = !follow
        pending.isHidden = missed == 0
        pending.title = "\(missed) new ▸"
        needsLayout = true
    }

    /// One line under the header (`CodeCaption`: `inline code` in backticks is set in the code font).
    func show(caption text: String?) {
        let text = text.flatMap { $0.isEmpty ? nil : CodeCaption.text($0) }
        guard text != captionText else { return }
        captionText = text
        caption.isHidden = text == nil
        caption.attributedStringValue = text.map(CodeCaption.string) ?? NSAttributedString()
        caption.toolTip = text
        needsLayout = true
    }

    func show(history: [Location], current: Location?) {
        guard history != self.history || current != self.current else { return }
        self.history = history
        self.current = current
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, location) in history.enumerated() {
            let button = NSButton(title: location.title, target: self, action: #selector(locationClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.font = location == current ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
            button.contentTintColor = location == current ? .labelColor : .linkColor
            button.toolTip = location.path
            strip.addArrangedSubview(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let middle = CodeMetrics.headerHeight / 2
        var x: CGFloat = 4
        func place(_ view: NSView, width: CGFloat) {
            let height = view.fittingSize.height
            view.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: width, height: height)
            x += width + 2
        }
        place(base, width: base.fittingSize.width)
        place(previous, width: 20)
        place(next, width: 20)
        var end = bounds.width - Self.reservedTrailing
        for button in [pin, pending] where !button.isHidden {
            let size = button.fittingSize
            button.frame = NSRect(x: end - size.width, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
            end = button.frame.minX - 6
        }
        status.frame = NSRect(x: x + 4, y: (middle - 8).rounded(), width: max(0, end - x - 4), height: 16)
        var y = CodeMetrics.headerHeight
        if captionText != nil {
            caption.frame = NSRect(x: CodeMetrics.captionInset, y: y + 1, width: max(0, bounds.width - 2 * CodeMetrics.captionInset), height: CodeMetrics.captionHeight - 4)
            y += CodeMetrics.captionHeight
        }
        strip.frame = NSRect(x: 6, y: y, width: max(0, bounds.width - 12), height: CodeMetrics.historyHeight - 2)
        strip.isHidden = history.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// The header as it would draw, for offscreen renders and cards (no live controls).
    static func drawStatic(in rect: NSRect, path: String, diffBase: String, status: String, warning: String?, caption: String?, history: [Location], current: Location?, missed: Int) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let line = NSMutableAttributedString(string: "\(diffBase == "merge-base" ? "merge-base" : diffBase.lowercased() == "head" ? "HEAD" : String(diffBase.prefix(12))) ▾   ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        if let warning {
            line.append(NSAttributedString(string: "⚠︎ \(warning)\(status.isEmpty ? "" : " · ")", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemOrange]))
        }
        line.append(NSAttributedString(string: status, attributes: small))
        if missed > 0 {
            line.append(NSAttributedString(string: "   \(missed) new ▸", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]))
        }
        line.draw(with: NSRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        var y = rect.minY + CodeMetrics.headerHeight
        if let caption, !caption.isEmpty {
            CodeCaption.string(caption).draw(with: NSRect(x: rect.minX + CodeMetrics.captionInset + 2, y: y + 2, width: rect.width - 2 * CodeMetrics.captionInset - 4, height: CodeMetrics.captionHeight - 4),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += CodeMetrics.captionHeight
        }
        if !history.isEmpty {
            let strip = NSMutableAttributedString()
            for location in history {
                strip.append(NSAttributedString(string: location.title + "   ", attributes: [
                    .font: location == current ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11),
                    .foregroundColor: location == current ? NSColor.labelColor : NSColor.linkColor,
                ]))
            }
            strip.draw(with: NSRect(x: rect.minX + 8, y: y + 3, width: rect.width - 16, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += CodeMetrics.historyHeight
        }
        NSColor.separatorColor.setFill()
        NSRect(x: rect.minX, y: y - 1, width: rect.width, height: 1).fill()
    }

    @objc private func baseChanged() {
        onBase?(base.indexOfSelectedItem == 0 ? "merge-base" : base.indexOfSelectedItem == 1 ? "head" : base.titleOfSelectedItem ?? "merge-base")
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
