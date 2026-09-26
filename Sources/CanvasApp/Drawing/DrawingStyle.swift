import AppKit
import CoreText

/// Fonts and colors of the hand-drawn layer.
@MainActor
enum DrawingStyle {
    /// Shantell Sans 1.011 (arrowtype/shantell-sans, the Google Fonts variable TTF), SIL OFL 1.1:
    /// resources/fonts/OFL.txt. Registered for this process only, at launch.
    private static var family: NSFontDescriptor?

    static func registerFonts() {
        guard family == nil, let url = AppPaths.asset("fonts/ShantellSans-Variable.ttf") else { return }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            NSLog("Canvas: cannot register \(url.path): \(String(describing: error?.takeRetainedValue()))")
        }
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        family = descriptors?.first.map { $0 as NSFontDescriptor }
    }

    static func font(size: CGFloat) -> NSFont {
        family.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    static let textSize: CGFloat = 20
    static let labelSize: CGFloat = 18
    static let arrowLabelSize: CGFloat = 15

    /// Named palette (ShapeProps.color). Unknown names fall back to `#rrggbb`, then the default ink.
    static let palette: [(name: String, color: NSColor)] = [
        ("black", .labelColor), ("grey", .systemGray), ("blue", .systemBlue), ("green", .systemGreen),
        ("orange", .systemOrange), ("red", .systemRed), ("violet", .systemPurple),
    ]

    static func color(_ name: String?) -> NSColor {
        guard let name else { return .labelColor }
        if let named = palette.first(where: { $0.name == name }) { return named.color }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .labelColor }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func text(_ string: String, size: CGFloat, color: NSColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(string: string, attributes: [.font: font(size: size), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
