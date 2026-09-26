import AppKit
import CanvasCore

/// Draws a terminal's screen from `zmx history --vt` text for renders, cards, and
/// `view.snapshot` covers (Ghostty draws through Metal, which AppKit can't capture): the
/// tile's own grid, the terminal theme's colors, and a Nerd Font so prompt glyphs render.
@MainActor
enum TerminalRender {
    /// Ghostty's defaults for the embedded surface (TerminalController.shared): 14 pt, 2 pt padding.
    static let defaultFontSize: CGFloat = 14
    static let padding: CGFloat = 2

    struct Theme {
        var background: NSColor
        var foreground: NSColor
        var palette: [NSColor]
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// The tile's theme: libghostty's default Afterglow (dark) / Alabaster (light).
    static func theme(for appearance: NSAppearance) -> Theme {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return Theme(background: hex(0x212121), foreground: hex(0xD0D0D0), palette: [
                0x151515, 0xAC4142, 0x7E8E50, 0xE4B567, 0x6C99BB, 0x9F4E86, 0x7DD5CF, 0xD0D0D0,
                0x505050, 0xAC4142, 0x7E8E50, 0xE4B567, 0x6C99BB, 0x9F4E86, 0x7DD5CF, 0xF5F5F5,
            ].map(hex))
        }
        return Theme(background: hex(0xF7F7F7), foreground: hex(0x000000), palette: [
            0x000000, 0xAA3731, 0x448C27, 0xCB8800, 0x325CC0, 0x7A3E9D, 0x0083B2, 0xF7F7F7,
            0x777777, 0xF03E31, 0x60CB00, 0xFFBC5D, 0x007ACC, 0xE64CE6, 0x00AACB, 0xF7F7F7,
        ].map(hex))
    }

    static func color(_ color: TerminalColor, theme: Theme, foreground: Bool) -> NSColor {
        switch color {
        case .standard: return foreground ? theme.foreground : theme.background
        case .indexed(let index) where index < 16: return theme.palette[Int(index)]
        case .indexed(let index):
            let rgb = TerminalColor.xterm(index) ?? (0, 0, 0)
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    // MARK: Font

    /// Font families, best first: the user's Ghostty `font-family` (matched loosely, preferring
    /// its single-width "Mono" Nerd Font variant), then any installed Nerd Font Mono, then the
    /// plain JetBrains Mono Ghostty embeds, then Menlo.
    static let families: [String] = {
        let installed = NSFontManager.shared.availableFontFamilies
        var wanted: [String] = []
        for configured in ghosttyFontFamilies() {
            if installed.contains(configured) { wanted.append(configured) }
            let tokens = configured.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let matches = installed.filter { family in
                let name = family.lowercased()
                return tokens.allSatisfy { name.contains($0) }
            }.sorted { ($0.hasSuffix(" Mono") ? 0 : 1, $0.count) < ($1.hasSuffix(" Mono") ? 0 : 1, $1.count) }
            wanted += matches
        }
        wanted += installed.filter { $0.hasSuffix("Nerd Font Mono") }.sorted { $0.count < $1.count }
        wanted += ["JetBrains Mono", "Menlo"].filter(installed.contains)
        var seen: Set<String> = []
        return wanted.filter { seen.insert($0).inserted }
    }()

    /// `font-family` values from the user's Ghostty config files, in order.
    static func ghosttyFontFamilies() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let files = [xdg.appendingPathComponent("ghostty/config"), home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")]
        var families: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "font-family" else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { families.append(value) }
            }
        }
        return families
    }

    struct Fonts {
        var regular: NSFont
        var bold: NSFont
        var italic: NSFont
        var boldItalic: NSFont
        /// Cell size in points.
        var cell: CGSize
        var ascent: CGFloat

        func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
            switch (isBold, isItalic) {
            case (true, true): boldItalic
            case (true, false): bold
            case (false, true): italic
            default: regular
            }
        }
    }

    /// Fonts at a size whose advance fills `cellWidth` when the grid is known.
    static func fonts(cellWidth: CGFloat?) -> Fonts {
        let base = families.lazy.compactMap { NSFont(name: $0, size: defaultFontSize) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: defaultFontSize) }.first
            ?? NSFont.monospacedSystemFont(ofSize: defaultFontSize, weight: .regular)
        let advance = base.maximumAdvancement.width > 0 ? base.maximumAdvancement.width : base.advancement(forGlyph: base.glyph(withName: "M")).width
        let size = cellWidth.map { defaultFontSize * $0 / max(advance, 1) } ?? defaultFontSize
        let symbols = families.first { $0.contains("Nerd Font") }
        func variant(_ traits: NSFontTraitMask) -> NSFont {
            var font = NSFontManager.shared.convert(base, toSize: size)
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            // Prompt glyphs missing from the main face come from a Nerd Font.
            if let symbols, !(font.familyName ?? "").contains("Nerd Font") {
                let cascade = [NSFontDescriptor(fontAttributes: [.family: symbols])]
                font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? font
            }
            return font
        }
        let regular = variant([])
        let cellAdvance = regular.maximumAdvancement.width > 0 ? regular.maximumAdvancement.width : size * 0.6
        let height = (regular.ascender - regular.descender + regular.leading).rounded(.up)
        return Fonts(regular: regular, bold: variant(.boldFontMask), italic: variant(.italicFontMask), boldItalic: variant([.boldFontMask, .italicFontMask]),
                     cell: CGSize(width: cellWidth ?? cellAdvance, height: height), ascent: regular.ascender)
    }

    // MARK: Drawing

    /// The grid as the tile shows it: from Ghostty's metrics (points) when known, else from the
    /// default font filling the body.
    struct Grid {
        var columns: Int
        var rows: Int
        var cell: CGSize
    }

    static func grid(for size: CGSize, known: Grid?) -> Grid {
        if let known { return known }
        let cell = fonts(cellWidth: nil).cell
        return Grid(columns: max(1, Int((size.width - 2 * padding) / cell.width)), rows: max(1, Int((size.height - 2 * padding) / cell.height)), cell: cell)
    }

    /// What the screen shows: the output ends on the cursor's row, and rows below it are blank.
    static func screen(_ lines: [TerminalLine], cursorRow: Int?, rows: Int) -> [TerminalLine] {
        let shown = min(rows, max(1, cursorRow ?? rows))
        return Array(lines.suffix(shown))
    }

    static func draw(_ lines: [TerminalLine], grid: Grid, in bounds: CGRect, appearance: NSAppearance) {
        let theme = theme(for: appearance)
        theme.background.setFill()
        bounds.fill()
        let fonts = fonts(cellWidth: grid.cell.width)
        let cell = grid.cell
        for (row, line) in lines.enumerated() {
            let y = padding + CGFloat(row) * cell.height
            guard y < bounds.maxY else { break }
            var column = 0
            for run in line.runs {
                var foreground = color(run.style.foreground, theme: theme, foreground: true)
                var background = run.style.background == .standard ? nil : color(run.style.background, theme: theme, foreground: false)
                if run.style.inverse {
                    let swapped = background ?? theme.background
                    background = foreground
                    foreground = swapped
                }
                if run.style.faint { foreground = foreground.withAlphaComponent(0.6) }
                let font = fonts.font(bold: run.style.bold, italic: run.style.italic)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
                if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                for character in run.text {
                    let width = TerminalStyledTail.cellWidth(character)
                    guard width > 0 else { continue }
                    let x = padding + CGFloat(column) * cell.width
                    if let background {
                        background.setFill()
                        CGRect(x: x, y: y, width: cell.width * CGFloat(width), height: cell.height).fill()
                    }
                    if !run.style.invisible, character != " " {
                        NSAttributedString(string: String(character), attributes: attributes).draw(at: CGPoint(x: x, y: y))
                    }
                    column += width
                }
            }
        }
    }
}
