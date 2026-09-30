import AppKit
import CanvasCore

/// An inline editor living in the shape layer (document coordinates). Enter or clicking away
/// commits; Escape cancels an arrow's caption and keeps typed text. Keyboard focus goes back to
/// whoever had it before.
@MainActor
protocol ShapeEditing: NSView {
    /// The object being edited (hidden while editing), nil when creating.
    var editing: ObjectID? { get }
    func begin()
    func commit()
    func cancel()
}

/// Shared lifecycle: focus hand-off and the click-away monitor.
@MainActor
private final class EditorSession {
    private var previousResponder: NSResponder?
    private var monitor: Any?
    private(set) var finished = false

    func begin(_ editor: ShapeEditing, in layer: ShapeLayer, focus: NSView) {
        previousResponder = layer.window?.firstResponder
        layer.addSubview(editor)
        layer.window?.makeFirstResponder(focus)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak editor] event in
            MainActor.assumeIsolated {
                guard let editor, event.window === editor.window else { return }
                let point = editor.convert(event.locationInWindow, from: nil)
                if !editor.bounds.contains(point) { editor.commit() }
            }
            return event
        }
    }

    /// Returns false if the session already ended.
    func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        return true
    }

    /// `restoreFocus`: the editor closed on its own (Enter, Escape, click-away), so the keyboard
    /// goes back to where it was. When focus already moved elsewhere, it stays there.
    func end(_ editor: ShapeEditing, in layer: ShapeLayer, restoreFocus: Bool) {
        let window = editor.window
        let holdsFocus = (window?.firstResponder as? NSView)?.isDescendant(of: editor) == true
        editor.removeFromSuperview()
        if restoreFocus && holdsFocus { returnFocus(in: window, layer: layer) }
        layer.editorEnded(editor)
    }

    /// Back to the view that had the keyboard before editing, else the prompt-target terminal.
    private func returnFocus(in window: NSWindow?, layer: ShapeLayer) {
        if let previous = previousResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        } else if let target = layer.canvas.promptTarget, let terminal = layer.canvas.tiles[target]?.content as? TerminalTile {
            terminal.focus()
        } else {
            window?.makeFirstResponder(nil)
        }
    }
}

/// Click-to-type text shapes, and labels inside rectangles and ellipses. Shows as a box with a
/// caret from the start; Enter, Esc, and clicking away all keep what was typed (an emptied text
/// shape is deleted). A text shape wraps at its wrap width (`TextShapeLayout`): the dragged or
/// existing width, else it grows with the text up to `TextShapeLayout.autoWidth`.
@MainActor
final class ShapeTextEditor: NSTextView, ShapeEditing, NSTextViewDelegate {
    /// Room between the box and the text, in document points.
    static let padding: CGFloat = 4

    unowned let shapeLayer: ShapeLayer
    let editing: ObjectID?
    private let object: CanvasObject?
    /// A text shape's text size (`props.textSize`); labels are always `DrawingStyle.labelSize`.
    private let textSize: CGFloat
    private let isLabel: Bool
    /// A text shape's wrap width; nil grows with the text (up to `TextShapeLayout.autoWidth`).
    private let wrapWidth: CGFloat?
    private let session = EditorSession()

    /// `origin`: a new text shape's top-left (ignored when editing). `wrapWidth`: a new text
    /// shape's width from a drag; nil grows with the text.
    init(layer: ShapeLayer, origin: NSPoint, wrapWidth newWidth: CGFloat? = nil, editing object: CanvasObject?, text: String) {
        shapeLayer = layer
        self.object = object
        editing = object?.id
        let spec = object.flatMap { ShapeSpec($0.props) }
        isLabel = spec.map { $0.kind == .rect || $0.kind == .ellipse } ?? false
        textSize = isLabel ? 1 : spec?.textSize ?? 1
        wrapWidth = isLabel ? nil : object.map { TextShapeLayout.wrapWidth(of: $0) } ?? newWidth
        let size = isLabel ? DrawingStyle.labelSize : DrawingStyle.textPointSize * textSize
        let pad = Self.padding
        let frame: NSRect
        if isLabel, let object {
            let shape = ShapeLayer.docRect(object.frame)
            frame = NSRect(x: shape.minX + 8 - pad, y: shape.midY - size * 0.8 - pad, width: max(40, shape.width - 16) + 2 * pad, height: size * 1.6 + 2 * pad)
        } else {
            let textOrigin = object.map { ShapeLayer.docRect($0.frame).origin } ?? origin
            frame = NSRect(x: textOrigin.x - pad, y: textOrigin.y - pad, width: 40, height: size * 1.5 + 2 * pad)
        }
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let containerWidth = isLabel ? frame.width - 2 * pad : wrapWidth ?? TextShapeLayout.autoWidth * textSize
        let container = NSTextContainer(size: NSSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = isLabel
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        textContainerInset = NSSize(width: pad, height: pad)
        font = DrawingStyle.font(size: size)
        textColor = DrawingStyle.color(spec?.color ?? layer.color)
        alignment = isLabel ? .center : .left
        // The box: see-through enough to keep what's under it in view, outlined so an empty
        // editor shows where typing goes.
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.75)
        wantsLayer = true
        self.layer?.cornerRadius = 4
        self.layer?.borderColor = NSColor.controlAccentColor.cgColor
        // One and a half screen points at the zoom it opened at.
        self.layer?.borderWidth = 1.5 / max(layer.canvas.magnification, 0.1)
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        focusRingType = .none
        insertionPointColor = .controlAccentColor
        string = text
        delegate = self
        fitToText()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// AppKit draws (and blinks) the caret only in the key window. Typing still reaches a
    /// Chalkwork window that isn't key (the app never takes focus by itself, `CanvasApplication`
    /// dispatches keys to it), so there the editor shows a steady caret: an empty editor is
    /// never just a box.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.isKeyWindow == false, window?.firstResponder === self, selectedRange().length == 0, let caret = caretRect else { return }
        insertionPointColor.setFill()
        caret.fill()
    }

    /// Where the insertion point is, in this view's coordinates.
    private var caretRect: NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let index = selectedRange().location
        let width = 2 / max(shapeLayer.canvas.magnification, 0.1)
        let line: NSRect
        let x: CGFloat
        if index >= storage.length, layoutManager.extraLineFragmentTextContainer != nil {
            // Empty, or after a trailing newline: the extra line's start (its middle when centered).
            line = layoutManager.extraLineFragmentRect
            x = alignment == .center ? line.midX : line.minX
        } else if index >= storage.length, storage.length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX
        } else if index < storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = line.minX + layoutManager.location(forGlyphAt: glyph).x
        } else {
            return nil
        }
        let origin = textContainerOrigin
        return NSRect(x: origin.x + x - width / 2, y: origin.y + line.minY, width: width, height: line.height)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if window?.isKeyWindow == false { needsDisplay = true }
    }

    func begin() {
        session.begin(self, in: shapeLayer, focus: self)
        selectAll(nil)
    }

    func commit() {
        save(restoreFocus: true)
    }

    private func save(restoreFocus: Bool) {
        guard session.finish() else { return }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let board = shapeLayer.board
        if let object {
            let isText = ShapeSpec(object.props)?.kind == .text
            if isText && text.isEmpty {
                try? board.delete(object.id)
            } else if text != (object.props["text"]?.string ?? "") {
                var frame: Frame?
                if isText { frame = ShapeLayer.canvasFrame(NSRect(origin: ShapeLayer.docRect(object.frame).origin, size: measured(text))) }
                _ = try? board.update(object.id, frame: frame, props: .object(["text": text.isEmpty ? .null : .string(text)]))
            }
        } else if !text.isEmpty {
            let rect = NSRect(origin: textOrigin, size: measured(text))
            let spec = ShapeSpec(kind: .text, text: text, color: shapeLayer.color)
            let created = board.create(type: .shape, props: spec.props, frame: ShapeLayer.canvasFrame(rect))
            shapeLayer.canvas.select(created.id, extend: false)
        }
        session.end(self, in: shapeLayer, restoreFocus: restoreFocus)
    }

    /// Esc keeps the text too: the only way to lose a note is to delete its text.
    func cancel() {
        commit()
    }

    /// Where the text starts, inside the box.
    private var textOrigin: NSPoint {
        NSPoint(x: frame.minX + Self.padding, y: frame.minY + Self.padding)
    }

    /// Size of the committed text shape at its wrap width.
    private func measured(_ text: String) -> NSSize {
        TextShapeLayout.size(text, textSize: textSize, wrapWidth: wrapWidth)
    }

    /// A text shape's box follows its text: the wrap width wide (else the text's width, at
    /// least a couple of characters), as tall as its lines.
    private func fitToText() {
        guard !isLabel else { return }
        let size = measured(string)
        let minimum = DrawingStyle.textPointSize * textSize * 2
        let width = wrapWidth ?? max(minimum, size.width)
        setFrameSize(NSSize(width: ceil(width) + 2 * Self.padding, height: ceil(size.height) + 2 * Self.padding))
    }

    func textDidChange(_ notification: Notification) {
        fitToText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)), #selector(cancelOperation(_:)):
            commit()
            return true
        default:
            return false
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Focus moved elsewhere (a new terminal, another window): keep what was typed, and leave
        // the keyboard where it went.
        if resigned, !session.finished {
            DispatchQueue.main.async { [weak self] in self?.save(restoreFocus: false) }
        }
        return resigned
    }
}

/// Double-click an arrow: its caption and its semantic relation (e.g. `calls`, `hypothesis_about`).
@MainActor
final class ArrowLabelEditor: NSView, ShapeEditing, NSTextFieldDelegate, NSComboBoxDelegate {
    static let relations = ["next_step", "calls", "depends_on", "hypothesis_about", "explains", "blocks", "relates_to"]

    unowned let shapeLayer: ShapeLayer
    let editing: ObjectID?
    private let arrow: CanvasObject
    private let labelField: NSTextField
    private let relationField = NSComboBox()
    private let session = EditorSession()

    init(layer: ShapeLayer, arrow: CanvasObject, spec: ArrowSpec, at point: NSPoint) {
        shapeLayer = layer
        self.arrow = arrow
        editing = nil
        labelField = NSTextField(string: spec.label ?? "")
        super.init(frame: NSRect(x: point.x - 120, y: point.y - 34, width: 240, height: 68))
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.layer?.cornerRadius = 8
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        labelField.placeholderString = "label"
        labelField.font = DrawingStyle.font(size: 14)
        labelField.frame = NSRect(x: 8, y: 8, width: 224, height: 24)
        labelField.delegate = self
        relationField.placeholderString = "relation"
        relationField.addItems(withObjectValues: Self.relations)
        relationField.stringValue = spec.relation ?? ""
        relationField.completes = true
        relationField.frame = NSRect(x: 8, y: 38, width: 224, height: 24)
        relationField.delegate = self
        addSubview(labelField)
        addSubview(relationField)
        labelField.nextKeyView = relationField
        relationField.nextKeyView = labelField
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    func begin() {
        session.begin(self, in: shapeLayer, focus: labelField)
    }

    /// Writes only what changed: an arrow whose `label` is explicitly empty (no caption) keeps
    /// it when only its relation is edited.
    func commit() {
        guard session.finish() else { return }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let relation = relationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch: [String: JSONValue] = [:]
        if label != (arrow.props["label"]?.string ?? "") { patch["label"] = label.isEmpty ? .null : .string(label) }
        if relation != (arrow.props["relation"]?.string ?? "") { patch["relation"] = relation.isEmpty ? .null : .string(relation) }
        if !patch.isEmpty { _ = try? shapeLayer.board.update(arrow.id, props: .object(patch)) }
        session.end(self, in: shapeLayer, restoreFocus: true)
    }

    func cancel() {
        guard session.finish() else { return }
        session.end(self, in: shapeLayer, restoreFocus: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
