import AppKit
import CanvasCore

/// Controls above a code tile: diff/source toggle, previous/next hunk, a status line, and for
/// follow tiles Pin plus a strip of recent locations. The rightmost `reservedTrailing` points
/// stay free for tile-level buttons the language service adds.
@MainActor
final class CodeHeaderBar: NSView {
    struct Location: Equatable {
        var path: String
        var range: LineRange?

        var title: String {
            let name = (path as NSString).lastPathComponent
            guard let range else { return name }
            return range.start == range.end ? "\(name):\(range.start)" : "\(name):\(range.start)-\(range.end)"
        }
    }

    static let rowHeight: CGFloat = 26
    static let reservedTrailing: CGFloat = 80

    var onMode: ((DiffDisplay.Mode) -> Void)?
    var onHunk: ((_ forward: Bool) -> Void)?
    var onPin: (() -> Void)?
    var onLocation: ((Location) -> Void)?

    private let mode = NSSegmentedControl(labels: ["Diff", "Source"], trackingMode: .selectOne, target: nil, action: nil)
    private let previous = NSButton()
    private let next = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let pin = NSButton(title: "Pin", target: nil, action: nil)
    private let strip = NSStackView()
    private var history: [Location] = []
    private var current: Location?

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Unclipped (the macOS 14 default), AppKit backs this view with a layer spanning the
        // whole tile and passes dirty rects outside it, so the fill below covered the title bar
        // and the code beneath.
        clipsToBounds = true
        mode.controlSize = .small
        mode.segmentStyle = .rounded
        mode.target = self
        mode.action = #selector(modeChanged)
        for (button, symbol, action) in [(previous, "chevron.up", #selector(previousHunk)), (next, "chevron.down", #selector(nextHunk))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.up" ? "Previous hunk" : "Next hunk")
            button.bezelStyle = .recessed
            button.isBordered = false
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = symbol == "chevron.up" ? "Previous hunk" : "Next hunk"
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.cell?.truncatesLastVisibleLine = true
        pin.controlSize = .small
        pin.bezelStyle = .push
        pin.font = .systemFont(ofSize: 11)
        pin.target = self
        pin.action = #selector(pinClicked)
        pin.toolTip = "Keep this view as a permanent diff tile"
        strip.orientation = .horizontal
        strip.spacing = 4
        strip.alignment = .centerY
        for view in [mode, previous, next, status, pin, strip] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var height: CGFloat { history.isEmpty ? Self.rowHeight : Self.rowHeight * 2 - 4 }

    func show(mode value: DiffDisplay.Mode, status text: String, hunks: Bool, follow: Bool) {
        mode.selectedSegment = value == .diff ? 0 : 1
        status.stringValue = text
        previous.isEnabled = hunks
        next.isEnabled = hunks
        pin.isHidden = !follow
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
        let middle = Self.rowHeight / 2
        var x: CGFloat = 6
        func place(_ view: NSView, width: CGFloat) {
            let height = view.fittingSize.height
            view.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: width, height: height)
            x += width + 4
        }
        place(mode, width: mode.fittingSize.width)
        place(previous, width: 20)
        place(next, width: 20)
        let trailing = bounds.width - Self.reservedTrailing
        var statusEnd = trailing
        if !pin.isHidden {
            let width = pin.fittingSize.width
            pin.frame = NSRect(x: trailing - width, y: (middle - pin.fittingSize.height / 2).rounded(), width: width, height: pin.fittingSize.height)
            statusEnd = pin.frame.minX - 6
        }
        status.frame = NSRect(x: x + 4, y: (middle - 8).rounded(), width: max(0, statusEnd - x - 4), height: 16)
        strip.frame = NSRect(x: 6, y: Self.rowHeight - 4, width: max(0, bounds.width - 12), height: Self.rowHeight - 4)
        strip.isHidden = history.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    @objc private func modeChanged() {
        onMode?(mode.selectedSegment == 0 ? .diff : .source)
    }

    @objc private func previousHunk() { onHunk?(false) }
    @objc private func nextHunk() { onHunk?(true) }
    @objc private func pinClicked() { onPin?() }

    @objc private func locationClicked(_ sender: NSButton) {
        guard history.indices.contains(sender.tag) else { return }
        onLocation?(history[sender.tag])
    }
}
