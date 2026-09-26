import AppKit
import Markdown

/// Intrinsic sizes: the full object frame (tile title bar included) that shows an object's
/// content without scrolling or clipping. Code follows `CodeMetrics`, notes lay out the note
/// tile's own `NoteRenderer` output with TextKit 2 at a width, text shapes use the drawing
/// layer's font. Other types (HTML, browser, terminal, ink, arrows, groups) have no intrinsic
/// size.
@MainActor
public enum ObjectMeasure {
    public enum Failure: Error, Equatable {
        /// This type (or shape kind) has no intrinsic size.
        case unsupported(String)
        /// The content can't be read right now (a code range that doesn't resolve).
        case unavailable(String)
        case invalidParams(String)
    }

    /// Note display insets: `NoteTile` lays its text out with exactly these.
    public static let noteInset = NSSize(width: 8, height: 10)
    public static let noteLineFragmentPadding: CGFloat = 2
    /// Notes measured without a width wrap at the width a new note gets.
    public static var defaultNoteWidth: CGFloat { Board.defaultSize(.note).w }
    /// Room around the label of a rect (an ellipse scales it to its inscribed box).
    static let shapeLabelPadding = CGSize(width: 16, height: 12)

    /// `width` wraps notes and text (a note defaults to a new note's width; text defaults to
    /// one unwrapped line per paragraph); for code it is the widest the frame may get (default
    /// `CodeMetrics.defaultFitWidth`), past which long lines wrap.
    public static func size(type: ObjectType, props: JSONValue, width: Double?, root: URL) async throws -> CGSize {
        switch type {
        case .code:
            guard let path = props["path"]?.string else { throw Failure.invalidParams("code props need a path") }
            let range = try? props["range"]?.decode(LineRange.self)
            let fence = NoteFence(path: path, commit: props["pinnedCommit"]?.string, lines: range, symbol: props["symbol"]?.string)
            let excerpt = await NoteSource.excerpt(for: fence, root: root, captured: nil)
            guard excerpt.range != nil else {
                if case .stale(let reason) = excerpt.status { throw Failure.unavailable(reason) }
                throw Failure.unavailable("cannot resolve \(path)")
            }
            let caption = props["caption"]?.string.map { !$0.isEmpty } ?? false
            return code(lines: excerpt.lines, fileLineCount: excerpt.fileLineCount, caption: caption, follow: props["followOf"]?.string != nil,
                        maxWidth: width.map { CGFloat($0) } ?? CodeMetrics.defaultFitWidth)
        case .note:
            let markdown = props["markdown"]?.string ?? ""
            let document = NoteMarkdown.parse(markdown)
            var excerpts: [String: NoteExcerpt] = [:]
            for fence in NoteMarkdown.anchoredFences(in: document) {
                excerpts[fence.key] = await NoteSource.excerpt(for: fence.fence, root: root, captured: nil, body: fence.body)
            }
            return note(document, width: width.map { CGFloat($0) } ?? defaultNoteWidth, excerpts: excerpts)
        case .shape:
            guard let spec = ShapeSpec(props) else { throw Failure.invalidParams("shape props need a kind") }
            return try shape(spec, width: width.map { CGFloat($0) })
        case .html, .browser, .terminal, .arrow, .group:
            throw Failure.unsupported("\(type.rawValue) objects have no intrinsic size")
        }
    }

    /// A code tile showing exactly `lines` of a file with `fileLineCount` lines: as wide as the
    /// longest line, or `maxWidth` (at least `CodeMetrics.minWidth`) with the longer lines
    /// wrapped, and as tall as the rows that makes.
    public static func code(lines: [String], fileLineCount: Int, caption: Bool, follow: Bool, maxWidth: CGFloat) -> CGSize {
        let longest = lines.map { CodeMetrics.columns($0) }.max() ?? 0
        let natural = CodeMetrics.size(lines: lines.count, longestLine: longest, caption: caption).width
            + CodeMetrics.gutterWidth(lineCount: fileLineCount) - CodeMetrics.gutterWidth(lineCount: 1)
        let width = min(natural, max(CodeMetrics.minWidth, maxWidth.rounded(.down)))
        let columns = CodeMetrics.textColumns(width: width, lineCount: fileLineCount)
        let rows = longest <= columns ? lines.count : lines.reduce(0) { $0 + 1 + CodeMetrics.wrap($1.utf16, columns: columns).breaks.count }
        var size = CGSize(width: width, height: CodeMetrics.size(lines: rows, longestLine: 0, caption: caption).height)
        if follow { size.height += CodeMetrics.historyHeight }
        return size
    }

    /// A note of `width` points whose rendered markdown fits without scrolling.
    public static func note(_ document: Document, width: CGFloat, excerpts: [String: NoteExcerpt]) -> CGSize {
        let text = NoteRenderer(excerpts: excerpts).render(document, placeholder: notePlaceholder)
        let height = noteTextHeight(text, width: width - 2 * noteInset.width)
        return CGSize(width: width, height: (CodeMetrics.titleHeight + 2 * noteInset.height + height).rounded(.up))
    }

    /// What an empty note shows (and so how tall it is).
    public static let notePlaceholder = "Double-click to write a note"

    /// Height TextKit 2 lays `text` out at in a container `width` wide, as the note display does.
    public static func noteTextHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let delegate = NoteLayoutDelegate()
        layout.delegate = delegate
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: 0))
        container.lineFragmentPadding = noteLineFragmentPadding
        layout.textContainer = container
        content.attributedString = text
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height
    }

    static func shape(_ spec: ShapeSpec, width: CGFloat?) throws -> CGSize {
        let text = spec.text ?? ""
        switch spec.kind {
        case .text:
            let label = DrawingStyle.text(text, size: DrawingStyle.textSize, color: .labelColor)
            let bounds = textBounds(label, width: width)
            return CGSize(width: width ?? bounds.width, height: bounds.height)
        case .rect, .ellipse:
            // The label wraps 16 points inside the frame (DrawnItem.shape) and sits centered.
            let label = DrawingStyle.text(text, size: DrawingStyle.labelSize, color: .labelColor, alignment: .center)
            let inner = width.map { $0 - 16 - shapeLabelPadding.width }
            let bounds = textBounds(label, width: inner)
            let box = CGSize(width: (inner ?? bounds.width) + 16 + shapeLabelPadding.width, height: bounds.height + 2 * shapeLabelPadding.height)
            guard spec.kind == .ellipse else { return box }
            let scale = 2.0.squareRoot()
            return CGSize(width: width ?? (box.width * scale).rounded(.up), height: (box.height * scale).rounded(.up))
        case .ink:
            throw Failure.unsupported("ink has no intrinsic size")
        }
    }

    /// Rounded-up text bounds with a point of slack so the drawn label never re-wraps.
    static func textBounds(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let size = text.boundingRect(with: NSSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }
}
