import AppKit
import CanvasCore

/// An inline editor living in the shape layer (document coordinates). Enter or clicking away
/// commits, Escape cancels; keyboard focus goes back to whoever had it before.
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

/// Click-to-type text shapes, and labels inside rectangles and ellipses.
@MainActor
final class ShapeTextEditor: NSTextView, ShapeEditing, NSTextViewDelegate {
    unowned let shapeLayer: ShapeLayer
    let editing: ObjectID?
    private let object: CanvasObject?
    private let isLabel: Bool
    private let session = EditorSession()

    init(layer: ShapeLayer, origin: NSPoint, editing object: CanvasObject?, text: String) {
        shapeLayer = layer
        self.object = object
        editing = object?.id
        let spec = object.flatMap { ShapeSpec($0.props) }
        isLabel = spec.map { $0.kind == .rect || $0.kind == .ellipse } ?? false
        let size = isLabel ? DrawingStyle.labelSize : DrawingStyle.textSize
        let frame: NSRect
        if isLabel, let object {
            let shape = ShapeLayer.docRect(object.frame)
            frame = NSRect(x: shape.minX + 8, y: shape.midY - size * 0.8, width: max(40, shape.width - 16), height: size * 1.6)
        } else if let object {
            frame = NSRect(origin: ShapeLayer.docRect(object.frame).origin, size: NSSize(width: 40, height: size * 1.5))
        } else {
            // A click sets where the first line sits, like a text cursor.
            frame = NSRect(x: origin.x, y: origin.y - size * 0.7, width: 40, height: size * 1.5)
        }
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: isLabel ? frame.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = isLabel
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        font = DrawingStyle.font(size: size)
        textColor = DrawingStyle.color(spec?.color ?? layer.color)
        alignment = isLabel ? .center : .left
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = !isLabel
        isVerticallyResizable = true
        focusRingType = .none
        insertionPointColor = .controlAccentColor
        string = text
        delegate = self
        fitToText()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

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
            let rect = NSRect(origin: self.frame.origin, size: measured(text))
            let spec = ShapeSpec(kind: .text, text: text, color: shapeLayer.color)
            let created = board.create(type: .shape, props: spec.props, frame: ShapeLayer.canvasFrame(rect))
            shapeLayer.canvas.select(created.id, extend: false)
        }
        session.end(self, in: shapeLayer, restoreFocus: restoreFocus)
    }

    func cancel() {
        guard session.finish() else { return }
        session.end(self, in: shapeLayer, restoreFocus: true)
    }

    /// Size of the committed text shape: the laid-out text plus a little room for descenders.
    private func measured(_ text: String) -> NSSize {
        let attributed = DrawingStyle.text(text, size: DrawingStyle.textSize, color: .labelColor)
        let size = attributed.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        return NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4)
    }

    private func fitToText() {
        guard !isLabel, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        setFrameSize(NSSize(width: max(40, ceil(used.width) + 8), height: max(frame.height, ceil(used.height))))
    }

    func textDidChange(_ notification: Notification) {
        fitToText()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            commit()
            return true
        case #selector(cancelOperation(_:)):
            cancel()
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
    static let relations = ["calls", "depends_on", "hypothesis_about", "explains", "blocks", "relates_to"]

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

    override var isFlipped: Bool { true }

    func begin() {
        session.begin(self, in: shapeLayer, focus: labelField)
    }

    func commit() {
        guard session.finish() else { return }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let relation = relationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if label != (arrow.props["label"]?.string ?? "") || relation != (arrow.props["relation"]?.string ?? "") {
            _ = try? shapeLayer.board.update(arrow.id, props: .object([
                "label": label.isEmpty ? .null : .string(label),
                "relation": relation.isEmpty ? .null : .string(relation),
            ]))
        }
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
