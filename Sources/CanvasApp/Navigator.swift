import AppKit
import CanvasCore

/// One line of the Go to… navigator.
struct NavigatorRow {
    enum Target: Equatable {
        /// Zoom to Fit.
        case allContent
        case object(ObjectID)
    }

    let target: Target
    let title: String
    /// The object type, shown small at the trailing edge.
    let kind: String
    /// A terminal's agent lifecycle color (`TileFrameView.badgeColor`).
    let dot: NSColor?
    /// Tells rows with the same title apart: the tile's caption, else its group's title.
    var subtitle: String? = nil

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || kind.localizedCaseInsensitiveContains(query)
            || subtitle?.localizedCaseInsensitiveContains(query) == true
    }
}

extension CanvasView {
    /// "All content", then groups, then tiles, each in reading order (top to bottom, then left
    /// to right). Drawn objects (shapes, arrows) aren't listed.
    func navigatorRows() -> [NavigatorRow] {
        var groups: [(NSRect, NavigatorRow)] = []
        var tiles: [(NSRect, NavigatorRow)] = []
        for object in board.objects.values {
            // Hidden groups (no members left) have no frame.
            guard let rect = docFrame(object.id) else { continue }
            if object.type == .group {
                let title = object.props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled group"
                groups.append((rect, NavigatorRow(target: .object(object.id), title: title, kind: "Group", dot: nil)))
            } else if let tile = self.tiles[object.id] {
                tiles.append((rect, Self.navigatorRow(for: object, shownTitle: tile.title)))
            }
        }
        func readingOrder(_ lhs: (NSRect, NavigatorRow), _ rhs: (NSRect, NavigatorRow)) -> Bool {
            lhs.0.minY != rhs.0.minY ? lhs.0.minY < rhs.0.minY : lhs.0.minX < rhs.0.minX
        }
        let titleCounts = Dictionary(tiles.map { ($0.1.title, 1) }, uniquingKeysWith: +)
        for index in tiles.indices where titleCounts[tiles[index].1.title, default: 0] > 1 {
            if case .object(let id) = tiles[index].1.target { tiles[index].1.subtitle = distinguishing(id) }
        }
        let all = NavigatorRow(target: .allContent, title: "All content", kind: "Zoom to Fit", dot: nil)
        return [all] + groups.sorted(by: readingOrder).map(\.1) + tiles.sorted(by: readingOrder).map(\.1)
    }

    /// A tile's caption, else the title of the group that lists it directly.
    private func distinguishing(_ id: ObjectID) -> String? {
        func nonEmpty(_ value: JSONValue?) -> String? { value?.string.flatMap { $0.isEmpty ? nil : $0 } }
        if let caption = nonEmpty(board.objects[id]?.props["caption"]) { return CodeCaption.text(caption) }
        let group = board.objects.values.first { $0.type == .group && GroupSpec($0.props)?.members.contains(id) == true }
        return group.flatMap { nonEmpty($0.props["title"]) }
    }

    private static func navigatorRow(for object: CanvasObject, shownTitle: String) -> NavigatorRow {
        let props = object.props
        switch object.type {
        case .terminal:
            let title = shownTitle.isEmpty ? TileFrameView.title(for: object) : shownTitle
            let color = TileFrameView.badgeColor(props["lifecycle"]?["state"]?.string)
            return NavigatorRow(target: .object(object.id), title: title, kind: "Terminal", dot: color == .clear ? nil : color)
        case .code:
            var title = TileFrameView.title(for: object)
            if let start = props["range"]?["start"]?.int {
                let end = props["range"]?["end"]?.int ?? start
                title += end > start ? " · L\(start)–\(end)" : " · L\(start)"
            }
            return NavigatorRow(target: .object(object.id), title: title, kind: "Code", dot: nil)
        case .note:
            let markdown = props["markdown"]?.string ?? ""
            let line = markdown.split(whereSeparator: \.isNewline).lazy
                .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            let title = props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return NavigatorRow(target: .object(object.id), title: title ?? line ?? "Empty note", kind: "Note", dot: nil)
        case .html:
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: "HTML", dot: nil)
        default:
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: object.type.rawValue.capitalized, dot: nil)
        }
    }
}

/// Go to… (⌘P): a floating search-and-list panel over the board, in the window like the drawing
/// toolbar (not a separate window, never modal). Typing filters, ↑/↓ move, Return or a click
/// goes, Esc, ⌘P, or a click anywhere else closes. Keyboard focus returns to whoever had it.
@MainActor
final class NavigatorPanel: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 28
    static let visibleRows = 10
    private static let fieldHeight: CGFloat = 40

    private let field = NSTextField()
    private let table = NSTableView()
    private let list = NSScrollView()
    private let separator = NSBox()
    private var height: NSLayoutConstraint!
    private var allRows: [NavigatorRow] = []
    private var rows: [NavigatorRow] = []
    private weak var previousResponder: NSResponder?
    private var clickMonitor: Any?

    var onGo: ((NavigatorRow.Target) -> Void)?
    var isOpen: Bool { !isHidden }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Go to…"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        column.resizingMask = .autoresizingMask
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        // The search field keeps the keyboard; clicks still select and go.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        list.documentView = table
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true

        for view in [icon, field, separator, list] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            height,
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Open / close

    func open(rows: [NavigatorRow]) {
        guard let window else { return }
        allRows = rows
        field.stringValue = ""
        isHidden = false
        previousResponder = window.firstResponder
        window.makeFirstResponder(field)
        filter()
        // A press anywhere outside the panel closes it and still does what it does.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    /// Hides the panel and gives the keyboard back to whoever had it before (unless something
    /// else took it meanwhile).
    func close() {
        guard isOpen else { return }
        isHidden = true
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        allRows = []
        rows = []
        table.reloadData()
        guard let window else { return }
        if let editor = window.firstResponder as? NSText, editor.delegate === field {
            let previous = previousResponder as? NSView
            window.makeFirstResponder(previous?.window === window ? previous : window.initialFirstResponder)
        }
        previousResponder = nil
    }

    private func go(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        let target = rows[row].target
        close()
        onGo?(target)
    }

    @objc private func rowClicked() {
        go(table.clickedRow)
    }

    // MARK: Filtering and keys

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        rows = allRows.filter { $0.matches(query) }
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        // The inset table style pads above the first row; keep the same room below the last.
        let shown = min(rows.count, Self.visibleRows)
        let listHeight = shown > 0 ? table.rect(ofRow: shown - 1).maxY + table.rect(ofRow: 0).minY : 0
        height.constant = Self.fieldHeight + 1 + (shown > 0 ? listHeight + 8 : 0)
        list.isHidden = rows.isEmpty
        separator.isHidden = rows.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): go(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        let row = min(rows.count - 1, max(0, table.selectedRow + step))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NavigatorCell.identifier, owner: nil) as? NavigatorCell ?? NavigatorCell()
        cell.show(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NavigatorRowView()
    }
}

/// Selection stays accent-colored although the table never holds the keyboard.
private final class NavigatorRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class NavigatorCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("navigator.cell")

    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        kind.font = .systemFont(ofSize: 11)
        kind.alignment = .right
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [dot, title, detail, kind] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            kind.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            kind.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show(_ row: NavigatorRow) {
        title.stringValue = row.title
        title.font = row.target == .allContent ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        detail.stringValue = row.subtitle ?? ""
        kind.stringValue = row.kind
        dot.layer?.backgroundColor = (row.dot ?? .clear).cgColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        kind.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        detail.textColor = kind.textColor
    }
}

/// Shown at the bottom center while the board has objects but none is in view (panned far
/// away): one button back to them (Zoom to Fit).
@MainActor
final class NothingHerePill: NSVisualEffectView {
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true
        let label = NSTextField(labelWithString: "Nothing here ·")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: "Back to content", target: self, action: #selector(back))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.refusesFirstResponder = true
        let stack = NSStackView(views: [label, button])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func back() {
        onBack?()
    }
}
