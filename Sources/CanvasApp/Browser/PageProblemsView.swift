import AppKit
import CanvasCore

/// The list a browser tile's error badge opens, over the top right of its page: the page's
/// errors newest first (uncaught errors, console errors, failed requests), each with where
/// and when. A Hyper-click on a row mentions that entry (`BrowserTile.problemMention`).
@MainActor
final class PageProblemsView: NSView {
    static let preferredWidth: CGFloat = 440
    /// Rows the list shows; the API has the rest.
    static let maxRows = 50
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 24
    private static let inset: CGFloat = 10

    var onClose: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Hyper-click an entry to mention it to your agent")
    private let scroll = NSScrollView()
    private let rowsView = FlippedView()
    private var rows: [Row] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        close.isBordered = false
        close.toolTip = "Close"
        close.target = self
        close.action = #selector(closeClicked)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rowsView
        [title, close, scroll, hint].forEach(addSubview)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page errors")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    /// The page's errors, newest first.
    func show(_ entries: [PageLogEntry]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.prefix(Self.maxRows).map(Row.init)
        rows.forEach(rowsView.addSubview)
        let count = entries.count
        title.stringValue = count == 1 ? "1 error on this page" : "\(count) errors on this page"
        needsLayout = true
        layoutRows()
    }

    /// Header, every row at `width`, and the footer.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let rowWidth = width - 2
        return Self.headerHeight + rows.reduce(0) { $0 + $1.height(width: rowWidth) } + Self.footerHeight
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutRows()
    }

    private func layoutRows() {
        let inset = Self.inset
        title.frame = NSRect(x: inset, y: 8, width: max(0, bounds.width - inset * 2 - 22), height: 16)
        close.frame = NSRect(x: bounds.width - inset - 16, y: 7, width: 16, height: 16)
        scroll.frame = NSRect(x: 1, y: Self.headerHeight, width: max(0, bounds.width - 2),
                              height: max(0, bounds.height - Self.headerHeight - Self.footerHeight))
        hint.frame = NSRect(x: inset, y: bounds.height - Self.footerHeight + 5, width: max(0, bounds.width - inset * 2), height: 14)
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for row in rows {
            let height = row.height(width: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        rowsView.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    /// The entry of the row under `point` (this view's coordinates), where the list shows it.
    func entry(at point: NSPoint) -> PageLogEntry? {
        guard scroll.frame.contains(point) else { return nil }
        let local = rowsView.convert(point, from: self)
        return rows.first { $0.frame.contains(local) }?.entry
    }

    /// The visible part of `entry`'s row, in this view's coordinates.
    func rowRect(of entry: PageLogEntry) -> NSRect? {
        guard let row = rows.first(where: { $0.entry == entry }) else { return nil }
        let rect = convert(row.frame, from: rowsView).intersection(scroll.frame)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    @objc private func closeClicked() { onClose?() }

    /// One entry: what it said (up to three lines), then what kind, where, and when.
    private final class Row: NSView {
        let entry: PageLogEntry
        private let message = NSTextField(wrappingLabelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private static let messageFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private static let maxMessageLines = 3

        init(_ entry: PageLogEntry) {
            self.entry = entry
            super.init(frame: .zero)
            message.stringValue = entry.text
            message.font = Self.messageFont
            message.textColor = .labelColor
            message.maximumNumberOfLines = Self.maxMessageLines
            message.lineBreakMode = .byTruncatingTail
            message.cell?.truncatesLastVisibleLine = true
            detail.stringValue = [entry.noun, entry.shortSource, entry.clockTime].compactMap { $0 }.joined(separator: " · ")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            [message, detail].forEach(addSubview)
            toolTip = ([entry.text, entry.source].compactMap { $0 }.joined(separator: "\n")) + "\n\nHyper-click to mention it to your agent"
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel("\(entry.noun): \(entry.text)")
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        nonisolated override var isFlipped: Bool { true }

        private func messageHeight(width: CGFloat) -> CGFloat {
            let line = ceil(Self.messageFont.ascender - Self.messageFont.descender + Self.messageFont.leading)
            let fitted = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? line
            return min(ceil(fitted), line * CGFloat(Self.maxMessageLines))
        }

        func height(width: CGFloat) -> CGFloat {
            8 + messageHeight(width: width - 20) + 2 + 14 + 8
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            let width = bounds.width - 20
            let height = messageHeight(width: width)
            message.frame = NSRect(x: 10, y: 8, width: width, height: height)
            detail.frame = NSRect(x: 10, y: 8 + height + 2, width: width, height: 14)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.withAlphaComponent(0.8).setFill()
            NSRect(x: 0, y: 8, width: 3, height: bounds.height - 16).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 10, y: bounds.height - 1, width: bounds.width - 10, height: 1).fill()
        }
    }
}

private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
