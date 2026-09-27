import AppKit
import Markdown

/// Intrinsic sizes: the full object frame (tile title bar included) that shows an object's
/// content without scrolling or clipping. Code follows `CodeMetrics`, notes lay out the note
/// tile's own `NoteRenderer` output with TextKit 2 at a width, text shapes use the drawing
/// layer's font, HTML pages are laid out by the app's WebKit (`html`). Other types (browser,
/// terminal, ink, arrows, groups) have no intrinsic size.
@MainActor
public enum ObjectMeasure {
    public enum Failure: Error, Equatable {
        /// This type (or shape kind) has no intrinsic size.
        case unsupported(String)
        /// The content can't be read right now (a code range that doesn't resolve).
        case unavailable(String)
        /// What the props name isn't there: no such file, on disk or at the pinned commit, or
        /// no such commit.
        case notFound(String)
        case invalidParams(String)
    }

    /// Note display insets: `NoteTile` lays its text out with exactly these.
    public static let noteInset = NSSize(width: 8, height: 10)
    public static let noteLineFragmentPadding: CGFloat = 2
    /// Notes measured without a width wrap at the width a new note gets.
    public static var defaultNoteWidth: CGFloat { Board.defaultSize(.note).w }
    /// Room around the label of a rect (an ellipse scales it to its inscribed box).
    static let shapeLabelPadding = CGSize(width: 16, height: 12)
    /// Tallest frame `size: "fit"` gives an HTML tile, in canvas points (title bar included); a
    /// longer page scrolls inside it, and `layout.check` reports the rest as overflow.
    public static let maxHtmlFitHeight: Double = 4000
    /// The app's WebKit measurer: the document extent (scroll width and height, CSS px = points)
    /// of an HTML tile's page with these props laid out `width` points wide, `<canvas-code>`
    /// excerpts read against `root`. Nil in CanvasCore alone, where HTML is `unsupported`.
    public static var html: ((_ props: JSONValue, _ width: CGFloat, _ root: URL) async throws -> CGSize)?

    /// `width` wraps notes and text (a note defaults to a new note's width; text defaults to
    /// one unwrapped line per paragraph); for code it is the widest the frame may get (default
    /// `CodeMetrics.defaultFitWidth`), past which long lines wrap. Sizes and `width` are canvas
    /// points: a tile with `props.scale` lays out at `width / scale` and measures `scale` times
    /// its natural size; a text shape's font is `scale` times the text size.
    public static func size(type: ObjectType, props: JSONValue, width: Double?, root: URL) async throws -> CGSize {
        let scale = RenderMath.isTile(type) ? ObjectScale.of(props) : 1
        let natural = width.map { CGFloat($0 / scale) }
        let size: CGSize
        switch type {
        case .code:
            let excerpt = try await codeExcerpt(props, root: root)
            let caption = props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            size = code(lines: excerpt.lines, fileLineCount: excerpt.fileLineCount, caption: caption, follow: props["followOf"]?.string != nil,
                        maxWidth: natural ?? CodeMetrics.defaultFitWidth)
        case .note:
            let markdown = props["markdown"]?.string ?? ""
            let document = NoteMarkdown.parse(markdown)
            var excerpts: [String: NoteExcerpt] = [:]
            for fence in NoteMarkdown.anchoredFences(in: document) {
                excerpts[fence.key] = await NoteSource.excerpt(for: fence.fence, root: root, captured: nil, body: fence.body)
            }
            size = note(document, width: natural ?? defaultNoteWidth, excerpts: excerpts)
        case .shape:
            guard let spec = ShapeSpec(props) else { throw Failure.invalidParams("shape props need a kind") }
            return try shape(spec, width: width.map { CGFloat($0) })
        case .html:
            // `width` wide (what the page wraps at), as tall as the document up to the cap.
            let extent = try await htmlExtent(props, width: width, root: root)
            return CGSize(width: CGFloat(width ?? Board.defaultSize(.html).w), height: min(extent.height, CGFloat(maxHtmlFitHeight)))
        case .changes:
            // The rows of every changed file, as wide as the longest line up to `width`.
            let set = await ChangeSet.load(root: root, spec: ChangesSpec(props), highlight: false)
            size = ChangesMetrics.fit(set, maxWidth: natural)
        case .browser, .terminal, .arrow, .group:
            throw Failure.unsupported("\(type.rawValue) objects have no intrinsic size")
        }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The frame an HTML tile needs to show its whole document with the page laid out `width`
    /// canvas points wide (default a new HTML tile's width) at `width / scale`: as wide as that or
    /// the document's scroll width, as tall as the title bar plus the document, uncapped.
    public static func htmlExtent(_ props: JSONValue, width: Double?, root: URL) async throws -> CGSize {
        guard let html else { throw Failure.unsupported("html objects are measured by the app's WebKit") }
        let scale = CGFloat(ObjectScale.of(props))
        let natural = CGFloat(width ?? Board.defaultSize(.html).w) / scale
        let document = try await html(props, natural, root)
        return CGSize(width: max(natural, document.width.rounded(.up)) * scale,
                      height: (CGFloat(RenderMath.tileTitleHeight) + document.height.rounded(.up)) * scale)
    }

    /// The lines a code tile shows fitted: its `range` (what the tile scrolls to and tints; a
    /// `symbol` beside it only names it), else the symbol's declaration, else the whole file.
    public static func codeExcerpt(_ props: JSONValue, root: URL) async throws -> NoteExcerpt {
        guard let path = props["path"]?.string else { throw Failure.invalidParams("code props need a path") }
        let range = try? props["range"]?.decode(LineRange.self)
        let fence = NoteFence(path: path, commit: props["pinnedCommit"]?.string, lines: range, symbol: range == nil ? props["symbol"]?.string : nil)
        let excerpt = await NoteSource.excerpt(for: fence, root: root, captured: nil)
        guard excerpt.range != nil else {
            if case .stale(let reason) = excerpt.status { throw excerpt.missing ? Failure.notFound(reason) : Failure.unavailable(reason) }
            throw Failure.unavailable("cannot resolve \(path)")
        }
        return excerpt
    }

    /// A code tile showing exactly `lines` of a file with `fileLineCount` lines, wide enough for
    /// its whole `caption` too, but at most `maxWidth` (at least `CodeMetrics.minWidth`): past
    /// that, long lines wrap and the caption truncates.
    nonisolated public static func code(lines: [String], fileLineCount: Int, caption: String?, follow: Bool, maxWidth: CGFloat) -> CGSize {
        var size = codeRows(lines: lines, fileLineCount: fileLineCount, caption: caption != nil, follow: follow, maxWidth: maxWidth)
        if let caption { size.width = min(max(size.width, captionWidth(caption)), max(CodeMetrics.minWidth, maxWidth.rounded(.down))) }
        return size
    }

    /// `code` without the caption's width: the frame the rows themselves need, as wide as the
    /// longest line or `maxWidth` (at least `CodeMetrics.minWidth`) with the longer lines wrapped,
    /// and as tall as the rows that makes.
    nonisolated public static func codeRows(lines: [String], fileLineCount: Int, caption: Bool, follow: Bool, maxWidth: CGFloat) -> CGSize {
        let longest = lines.map { CodeMetrics.columns($0) }.max() ?? 0
        let header = CodeMetrics.chromeHeight(caption: caption, history: follow) - CodeMetrics.titleHeight
        let gutter = CodeMetrics.gutterWidth(lineCount: fileLineCount)
        let natural = CodeMetrics.content(rows: lines.count, longestLine: longest, gutterWidth: gutter, headerHeight: header).width
        let width = min(natural, max(CodeMetrics.minWidth, maxWidth.rounded(.down)))
        let columns = CodeMetrics.textColumns(width: width, lineCount: fileLineCount)
        let rows = longest <= columns ? lines.count : lines.reduce(0) { $0 + 1 + CodeMetrics.wrap($1.utf16, columns: columns).breaks.count }
        return CGSize(width: width, height: CodeMetrics.content(rows: rows, longestLine: 0, gutterWidth: gutter, headerHeight: header).height + CodeMetrics.titleHeight)
    }

    /// Narrowest code tile frame whose caption strip shows `caption` untruncated: the header's
    /// caption text (`CodeCaption.string`), `CodeMetrics.captionInset` on each side, and the
    /// label cell's 2-point text padding on each side, plus a point of slack.
    nonisolated public static func captionWidth(_ caption: String) -> CGFloat {
        let text = CodeCaption.string(caption)
        let width = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
        return (ceil(width) + 2 * CodeMetrics.captionInset + 4 + 1).rounded(.up)
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
            let label = DrawingStyle.text(text, size: DrawingStyle.textSize * spec.scale, color: .labelColor)
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

/// The one-line caption strip of a code tile, as the header draws it (live and offscreen) and as
/// `ObjectMeasure` sizes it.
public enum CodeCaption {
    /// Newlines become spaces: the strip is one line.
    public static func text(_ caption: String) -> String {
        caption.replacingOccurrences(of: "\n", with: " ")
    }

    /// `inline code` in backticks is set in the code font.
    public static func string(_ caption: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor]
        let code: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor,
                                                   .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.25)]
        for (index, part) in text(caption).split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            out.append(NSAttributedString(string: String(part), attributes: index % 2 == 1 ? code : body))
        }
        return out
    }
}
