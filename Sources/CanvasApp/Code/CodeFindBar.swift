import AppKit
import CanvasCore

/// Find matches in a code tile: case-insensitive, per displayed line (peeked base lines aren't
/// searched), in order.
struct CodeFind {
    struct Match: Equatable {
        var entry: Int
        /// UTF-16 offsets in the line.
        var start: Int
        var end: Int
    }

    /// Matches past this aren't collected (a one-letter query in a long file).
    static let limit = 10_000

    let query: String
    let matches: [Match]
    /// The indices of each entry's matches.
    let byEntry: [Int: Range<Int>]
    var current: Int?

    init(query: String, rows: CodeRows, text: (Int) -> NSString) {
        self.query = query
        var matches: [Match] = []
        if !query.isEmpty {
            outer: for entry in 0..<rows.entryCount {
                guard case .line? = rows.entryRow(entry) else { continue }
                let line = text(entry)
                var from = 0
                while from < line.length {
                    let found = line.range(of: query, options: [.caseInsensitive], range: NSRange(location: from, length: line.length - from))
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    matches.append(Match(entry: entry, start: found.location, end: found.location + found.length))
                    if matches.count >= Self.limit { break outer }
                    from = found.location + found.length
                }
            }
        }
        var byEntry: [Int: Range<Int>] = [:]
        for (index, match) in matches.enumerated() {
            byEntry[match.entry] = (byEntry[match.entry]?.lowerBound ?? index)..<(index + 1)
        }
        self.matches = matches
        self.byEntry = byEntry
    }

    /// "3 of 17", "No results", or nothing for an empty query.
    var status: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        let total = matches.count >= Self.limit ? "\(Self.limit)+" : "\(matches.count)"
        return current.map { "\($0 + 1) of \(total)" } ?? total
    }
}

/// The find bar over a code tile's rows (⌘F): a field with live matches, the match count,
/// previous/next, and close. Return / ⇧Return step through matches, Esc closes.
@MainActor
final class CodeFindBar: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 300, height: 30)

    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?
    /// Step to the next match (false) or the previous one (true).
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        let previous = Self.button("chevron.up", "Previous match (⇧Return)", #selector(previousClicked), self)
        let next = Self.button("chevron.down", "Next match (Return)", #selector(nextClicked), self)
        let close = Self.button("xmark", "Close (Esc)", #selector(closeClicked), self)
        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.widthAnchor.constraint(equalToConstant: 72),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private static func button(_ symbol: String, _ tip: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func show(status: String) {
        count.stringValue = status
    }

    /// Whether the field is being typed in (its editor is the window's first responder).
    var holdsKeyboard: Bool {
        (window?.firstResponder as? NSText)?.delegate === field
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onStep?(true)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    @objc private func previousClicked() { onStep?(true) }
    @objc private func nextClicked() { onStep?(false) }
    @objc private func closeClicked() { onClose?() }
}
