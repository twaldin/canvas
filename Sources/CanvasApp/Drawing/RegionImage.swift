import AppKit
import CanvasCore

extension CanvasView {
    /// Largest crop in pixels; bigger regions render at a reduced scale.
    static let regionPixelBudget: CGFloat = 4_000_000

    /// PNG of the canvas under a drawn object (a shape's frame, an arrow's route) as the user sees
    /// it: tiles, ink, and text inside it. Content drawn outside AppKit (terminals, web views) is
    /// swapped for images of itself while rendering, as `view.snapshot` does.
    func drawnObjectPNG(_ id: ObjectID) -> Data? {
        let rect: NSRect
        if let outline = shapeOutline?(id) {
            rect = outline.insetBy(dx: -4, dy: -4)
        } else if let object = board.objects[id], object.frame.w > 0, object.frame.h > 0 {
            rect = ShapeLayer.docRect(object.frame)
        } else {
            return nil
        }
        return regionPNG(rect.integral)
    }

    func regionPNG(_ rect: NSRect) -> Data? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let backing = window?.backingScaleFactor ?? 2
        let scale = min(backing, (Self.regionPixelBudget / (rect.width * rect.height)).squareRoot())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        let covered = tiles.values.filter { $0.isLive && $0.frame.intersects(rect) }.map(\.content)
        let layer = shapeLayer as? ShapeLayer
        let outline = overlay.isHidden
        covered.forEach { $0.showSnapshot(true) }
        layer?.exporting = true
        overlay.isHidden = true
        document.cacheDisplay(in: rect, to: rep)
        overlay.isHidden = outline
        layer?.exporting = false
        covered.forEach { $0.showSnapshot(false) }
        return rep.representation(using: .png, properties: [:])
    }
}
