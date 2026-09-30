import CoreGraphics

/// Columns and rows a terminal tile's grid has: its body in the content's own points (the frame
/// below the title bar divided by `props.zoom`, `RenderMath.body`) filled with cells, less the
/// padding on each side. Zooming the content in gives fewer, bigger cells in the same frame, and
/// the program in the terminal is told the new size (as Ghostty's own font-size change does).
public enum TerminalGrid {
    public static func size(of body: CGSize, cell: CGSize, padding: CGSize) -> (columns: Int, rows: Int) {
        guard cell.width > 0, cell.height > 0 else { return (1, 1) }
        return (max(1, Int((body.width - 2 * padding.width) / cell.width)), max(1, Int((body.height - 2 * padding.height) / cell.height)))
    }

    public static func size(of object: CanvasObject, cell: CGSize, padding: CGSize) -> (columns: Int, rows: Int) {
        size(of: RenderMath.body(of: object), cell: cell, padding: padding)
    }
}
