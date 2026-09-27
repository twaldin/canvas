import AppKit
import CanvasCore

/// A button drawn in a changes tile's file or hunk header.
enum ChangesAction: String {
    case stage = "Stage"
    case revert = "Revert"
}

/// Laid-out diff lines on screen, keyed by what they show; each draw keeps only what it drew.
@MainActor
final class ChangesLineCache {
    struct Key: Hashable {
        var file: Int
        var side: DiffSide
        var line: Int
    }

    private var lines: [Key: CTLine] = [:]
    private var drawn: [Key: CTLine] = [:]

    func line(_ key: Key, make: () -> CTLine) -> CTLine {
        if let line = drawn[key] ?? lines[key] {
            drawn[key] = line
            return line
        }
        let line = make()
        drawn[key] = line
        return line
    }

    func commit() {
        lines = drawn
        drawn = [:]
    }

    func removeAll() {
        lines = [:]
        drawn = [:]
    }
}

/// Draws a changes tile's body in a flipped context: the header strip (base, counts, a message,
/// the keys), then the rows scrolled by `scroll`: file headers with Stage/Revert, hunk headers
/// with theirs, and unified-diff lines highlighted like code tiles (`CodeTheme`, `SyntaxLines`),
/// clipped at the tile's width. The live view, cards, and `view.render` all draw through this.
@MainActor
struct ChangesPainter {
    let set: ChangeSet
    let rows: ChangeRows
    var collapsed: Set<String> = []
    /// The hunk j/k, Return, s and r act on.
    var current: (file: Int, hunk: Int)?
    /// A refusal or failure, shown in the header in place of the summary.
    var message: String?
    /// The tile holds the keyboard: the header says which keys work.
    var focused = false

    init(set: ChangeSet, collapsed: Set<String>) {
        self.set = set
        self.collapsed = collapsed
        rows = ChangeRows(set, collapsed: collapsed)
    }

    var digits: Int { ChangesMetrics.digits(set) }
    var gutterWidth: CGFloat { ChangesMetrics.gutterWidth(digits: digits) }
    var contentHeight: CGFloat { ChangesMetrics.headerHeight + rows.height + ChangesMetrics.bottomPadding }

    static let keysHint = "j/k hunks · ↩ open · s stage · r revert · esc done"

    // MARK: Geometry

    /// A row's rect in body coordinates at `scroll`.
    func rect(ofRow index: Int, width: CGFloat, scroll: CGFloat) -> CGRect {
        CGRect(x: 0, y: ChangesMetrics.headerHeight + rows.tops[index] - scroll, width: width, height: rows.height(ofRow: index))
    }

    /// The row under a body point, nil over the header.
    func row(at point: CGPoint, scroll: CGFloat) -> Int? {
        guard point.y >= ChangesMetrics.headerHeight else { return nil }
        return rows.index(atY: point.y - ChangesMetrics.headerHeight + scroll)
    }

    /// Stage and Revert in a file or hunk header row, right-aligned.
    func buttons(inRow rect: CGRect) -> [(ChangesAction, CGRect)] {
        let width = ChangesMetrics.buttonWidth, gap = ChangesMetrics.buttonGap
        let height = min(18, rect.height - 6)
        let y = rect.minY + (rect.height - height) / 2
        let revert = CGRect(x: rect.maxX - ChangesMetrics.trailingPadding - width, y: y, width: width, height: height)
        let stage = revert.offsetBy(dx: -(width + gap), dy: 0)
        return [(.stage, stage), (.revert, revert)]
    }

    func button(at point: CGPoint, row index: Int, width: CGFloat, scroll: CGFloat) -> ChangesAction? {
        switch rows.rows[index] {
        case .file, .hunk:
            return buttons(inRow: rect(ofRow: index, width: width, scroll: scroll)).first { $0.1.insetBy(dx: -2, dy: -2).contains(point) }?.0
        default:
            return nil
        }
    }

    // MARK: Drawing

    /// Draws the body `size` points big with the rows scrolled by `scroll`.
    func draw(in context: CGContext, size: CGSize, scroll: CGFloat, cache: ChangesLineCache?) {
        let bounds = CGRect(origin: .zero, size: size)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: ChangesMetrics.headerHeight, width: size.width, height: max(0, size.height - ChangesMetrics.headerHeight)))
        let visible = rows.visible(from: scroll, to: scroll + size.height - ChangesMetrics.headerHeight)
        for index in visible {
            drawRow(index, in: context, rect: rect(ofRow: index, width: size.width, scroll: scroll), cache: cache)
        }
        context.restoreGState()
        cache?.commit()
        drawHeader(width: size.width)
        drawScrollIndicator(size: size, scroll: scroll)
    }

    private func drawHeader(width: CGFloat) {
        let strip = CGRect(x: 0, y: 0, width: width, height: ChangesMetrics.headerHeight)
        NSColor.windowBackgroundColor.setFill()
        strip.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: strip.maxY - 0.5, width: width, height: 0.5).fill()
        let small = NSFont.systemFont(ofSize: 11)
        let hint = focused ? Self.keysHint : "↩ or click to use keys"
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: focused ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor]
        let hintSize = (hint as NSString).size(withAttributes: hintAttributes)
        let showsHint = width > hintSize.width + 260
        if showsHint {
            (hint as NSString).draw(at: CGPoint(x: width - ChangesMetrics.trailingPadding - hintSize.width, y: (strip.height - hintSize.height) / 2), withAttributes: hintAttributes)
        }
        let text: String
        let color: NSColor
        if let message {
            text = message
            color = .systemOrange
        } else {
            text = set.summary
            color = .secondaryLabelColor
        }
        let available = width - 12 - (showsHint ? hintSize.width + 24 : ChangesMetrics.trailingPadding)
        drawText(text, at: CGPoint(x: 10, y: 0), height: strip.height, width: available, attributes: [.font: small, .foregroundColor: color])
    }

    private func drawRow(_ index: Int, in context: CGContext, rect: CGRect, cache: ChangesLineCache?) {
        switch rows.rows[index] {
        case .file(let file): drawFile(file, rect: rect)
        case .hunk(let file, let hunk): drawHunk(file: file, hunk: hunk, rect: rect)
        case .line(let file, let hunk, let line): drawLine(file: file, hunk: hunk, line: line, rect: rect, context: context, cache: cache)
        case .notice(let file):
            drawText(set.files[file].notice ?? "", at: CGPoint(x: gutterWidth, y: rect.minY), height: rect.height, width: rect.width - gutterWidth,
                     attributes: [.font: NSFont.systemFont(ofSize: 11).withTraits(.italic), .foregroundColor: NSColor.secondaryLabelColor])
        case .message(let text):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: max(12, (rect.width - size.width) / 2), y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        case .omitted(let count):
            drawText("… \(count) more changed file\(count == 1 ? "" : "s") (limit \(ChangeSet.maxFiles); narrow it with paths)", at: CGPoint(x: 12, y: rect.minY), height: rect.height,
                     width: rect.width - 24, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func drawFile(_ index: Int, rect: CGRect) {
        let file = set.files[index]
        NSColor.controlBackgroundColor.blended(withFraction: 0.5, of: NSColor.windowBackgroundColor)?.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: rect.minY, width: rect.width, height: 0.5).fill()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        var x: CGFloat = 8
        let chevron = collapsed.contains(file.boardPath) ? "▸" : "▾"
        x += drawText(chevron, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: 14, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]) + 4
        let (letter, color) = Self.badge(file.status)
        let badge = CGRect(x: x, y: rect.midY - 8, width: 16, height: 16)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        let badgeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: color]
        let letterSize = (letter as NSString).size(withAttributes: badgeAttributes)
        (letter as NSString).draw(at: CGPoint(x: badge.midX - letterSize.width / 2, y: badge.midY - letterSize.height / 2), withAttributes: badgeAttributes)
        x = badge.maxX + 8
        let buttons = buttons(inRow: rect)
        let right = (buttons.first?.1.minX ?? rect.maxX) - 10
        let counts = "+\(file.added) −\(file.removed)"
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let countWidth = (counts as NSString).size(withAttributes: [.font: countFont]).width
        let name = file.oldBoardPath.map { "\($0) → \(file.boardPath)" } ?? file.boardPath
        let nameWidth = drawText(name, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: max(0, right - x - countWidth - 12),
                                 attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        x += nameWidth + 10
        let countText = NSMutableAttributedString(string: "+\(file.added)", attributes: [.font: countFont, .foregroundColor: CodeTheme.added])
        countText.append(NSAttributedString(string: " −\(file.removed)", attributes: [.font: countFont, .foregroundColor: CodeTheme.deleted]))
        if x + countWidth < right { countText.draw(at: CGPoint(x: x, y: rect.minY + (rect.height - countText.size().height) / 2)) }
        // Binary, oversized, and mode-only files have no lines to patch.
        guard file.notice == nil else { return }
        let allStaged = !file.hunks.isEmpty && file.hunks.allSatisfy { $0.status != .unstaged }
        drawButtons(buttons, stageEnabled: !allStaged)
    }

    private func drawHunk(file: Int, hunk: Int, rect: CGRect) {
        let changed = set.files[file], target = changed.hunks[hunk]
        let isCurrent = current.map { $0 == (file, hunk) } ?? false
        (isCurrent ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.systemBlue.withAlphaComponent(0.06)).setFill()
        rect.fill()
        if isCurrent { drawCurrentBar(file: file, hunk: hunk, from: rect) }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var text = target.header
        let side: DiffSide = target.mappings.allSatisfy(\.modified.isEmpty) ? .old : .new
        let line = side == .old ? target.mappings.first?.original.lowerBound ?? 1 : target.modified.lowerBound
        if let symbol = changed.symbol(line: line, side: side) { text += " \(symbol)" }
        let buttons = buttons(inRow: rect)
        var right = (buttons.first?.1.minX ?? rect.maxX) - 10
        if target.status != .unstaged {
            let label = target.status.rawValue
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: target.status == .staged ? CodeTheme.added : NSColor.secondaryLabelColor]
            let size = (label as NSString).size(withAttributes: attributes)
            let pill = CGRect(x: right - size.width - 10, y: rect.midY - 8, width: size.width + 10, height: 16)
            (target.status == .staged ? CodeTheme.added : NSColor.secondaryLabelColor).withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            (label as NSString).draw(at: CGPoint(x: pill.minX + 5, y: pill.midY - size.height / 2), withAttributes: attributes)
            right = pill.minX - 8
        }
        drawText(text, at: CGPoint(x: 10, y: rect.minY), height: rect.height, width: max(0, right - 10), attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        drawButtons(buttons, stageEnabled: target.status == .unstaged)
    }

    /// The current hunk's accent bar, down its header and lines.
    private func drawCurrentBar(file: Int, hunk: Int, from rect: CGRect) {
        let lines = CGFloat(set.files[file].hunks[hunk].lines.count)
        NSColor.controlAccentColor.setFill()
        CGRect(x: 0, y: rect.minY, width: 3, height: rect.height + lines * ChangesMetrics.lineHeight).fill()
    }

    private func drawButtons(_ buttons: [(ChangesAction, CGRect)], stageEnabled: Bool) {
        for (action, frame) in buttons {
            let enabled = action == .revert || stageEnabled
            NSColor.controlColor.setFill()
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let tint: NSColor = !enabled ? .tertiaryLabelColor : action == .revert ? .systemRed : .labelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tint]
            let size = (action.rawValue as NSString).size(withAttributes: attributes)
            (action.rawValue as NSString).draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawLine(file: Int, hunk: Int, line: Int, rect: CGRect, context: CGContext, cache: ChangesLineCache?) {
        let changed = set.files[file]
        let row = changed.hunks[hunk].lines[line]
        switch row.kind {
        case .added:
            CodeTheme.added.withAlphaComponent(0.14).setFill()
            rect.fill()
        case .removed:
            CodeTheme.deleted.withAlphaComponent(0.14).setFill()
            rect.fill()
        case .context: break
        }
        if let current, current == (file, hunk) {
            NSColor.controlAccentColor.setFill()
            CGRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
        }
        let advance = CodeMetrics.charAdvance
        let columns = CGFloat(digits) * advance
        let numbers: [NSAttributedString.Key: Any] = [.font: CodeTheme.font, .foregroundColor: NSColor.tertiaryLabelColor.cgColor]
        let oldRight = ChangesMetrics.gutterLeading + columns, newRight = oldRight + ChangesMetrics.numberGap / 2 + columns
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (number, right) in [(row.old, oldRight), (row.new, newRight)] {
            guard let number else { continue }
            let label = String(number)
            context.textPosition = CGPoint(x: right - CGFloat(label.count) * advance, y: rect.minY + CodeMetrics.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: numbers)), context)
        }
        let sign = row.kind == .added ? "+" : row.kind == .removed ? "−" : ""
        if !sign.isEmpty {
            let color = row.kind == .added ? CodeTheme.added : CodeTheme.deleted
            context.textPosition = CGPoint(x: newRight + ChangesMetrics.numberGap / 2 + 3, y: rect.minY + CodeMetrics.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: sign, attributes: [.font: CodeTheme.font, .foregroundColor: color.cgColor])), context)
        }
        let side: DiffSide = row.kind == .removed ? .old : .new
        let text = side == .old ? changed.old : changed.new
        if let number = side == .old ? row.old : row.new, number >= 1, number <= text.lineCount {
            let laid = cache?.line(.init(file: file, side: side, line: number)) { makeLine(changed, side: side, line: number) } ?? makeLine(changed, side: side, line: number)
            context.saveGState()
            context.clip(to: CGRect(x: gutterWidth, y: rect.minY, width: max(0, rect.width - gutterWidth), height: rect.height))
            context.textPosition = CGPoint(x: gutterWidth, y: rect.minY + CodeMetrics.baseline)
            CTLineDraw(laid, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// One side's line, tabs expanded, highlighted by its syntax runs.
    private func makeLine(_ file: ChangedFile, side: DiffSide, line: Int) -> CTLine {
        let text = side == .old ? file.old : file.new
        let row = CodeRowText(line: text.line(line), start: 0, startColumn: 0)
        let string = NSMutableAttributedString(string: row.display, attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.labelColor.cgColor])
        for run in (side == .old ? file.oldSyntax : file.newSyntax).runs(line: line) {
            let from = row.display(ofOffset: Int(run.start)), to = row.display(ofOffset: Int(run.end))
            guard from < to else { continue }
            string.addAttribute(.foregroundColor, value: CodeTheme.color(run.style).cgColor, range: NSRange(location: from, length: to - from))
        }
        return CTLineCreateWithAttributedString(string)
    }

    private func drawScrollIndicator(size: CGSize, scroll: CGFloat) {
        let viewport = size.height - ChangesMetrics.headerHeight
        let content = rows.height + ChangesMetrics.bottomPadding
        guard content > viewport + 0.5, viewport > 0 else { return }
        let length = max(24, viewport * viewport / content)
        let y = ChangesMetrics.headerHeight + (viewport - length) * scroll / (content - viewport)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: size.width - 5, y: y + 2, width: 3, height: length - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Text on one line, vertically centered in `height` from `origin.y`, truncated to `width`;
    /// returns the width drawn.
    @discardableResult
    private func drawText(_ text: String, at origin: CGPoint, height: CGFloat, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard width > 4 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        var attributes = attributes
        attributes[.paragraphStyle] = style
        let size = (text as NSString).size(withAttributes: attributes)
        let drawn = min(size.width, width)
        (text as NSString).draw(with: CGRect(x: origin.x, y: origin.y + (height - size.height) / 2, width: drawn + 1, height: size.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return drawn
    }

    static func badge(_ status: ChangeStatus) -> (String, NSColor) {
        switch status {
        case .added: ("A", CodeTheme.added)
        case .modified: ("M", CodeTheme.modified)
        case .deleted: ("D", CodeTheme.deleted)
        case .renamed: ("R", .systemPurple)
        }
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}
