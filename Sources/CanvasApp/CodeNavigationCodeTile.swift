import AppKit

/// Rows in CodeTile are "<padded number>  <source line>", so a source column is the character
/// offset within the row minus the gutter width.
extension CodeTile: CodeNavigationHost {
    var navigationPath: String { path }

    var navigationTextView: NSTextView { text }

    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)? {
        let string = text.string as NSString
        var index = NSNotFound
        if let window = text.window {
            // The character whose glyph is under the point (not the nearest caret position).
            index = text.characterIndex(for: window.convertPoint(toScreen: text.convert(point, to: nil)))
        }
        if index == NSNotFound { index = text.characterIndexForInsertion(at: point) }
        guard index != NSNotFound, index < string.length, string.character(at: index) != 0x0A, !lineStarts.isEmpty else { return nil }
        let line = line(atCharacter: index)
        let column = index - lineStarts[line - 1] - (numberWidth + 2)
        return column >= 0 ? (line, column) : nil
    }

    func reveal(line: Int) {
        scrollTo(line: line)
    }
}
