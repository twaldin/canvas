import Foundation

/// The user's Ghostty configuration, read the way Ghostty reads it, so terminal tiles look and
/// type like the user's Ghostty (colors and theme, font, keybinds, selection) and cards match.
///
/// Ghostty's embedded library loads only the config text it is handed: it follows no
/// `config-file` includes and finds no themes (the package bundles none). So the app flattens
/// the files here, resolves the theme to its file, and hands the library one text per color
/// scheme: the theme's settings, the user's (a setting in the config beats the theme's), then
/// the few settings Canvas owns for embedding.
public struct GhosttyConfig: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }

        public var line: String { "\(key) = \(value)" }
    }

    /// The user's settings in load order: each file's own lines, then the files it includes.
    /// `theme` and `config-file` lines are consumed, not kept.
    public var entries: [Entry]
    /// The last `theme` setting, per scheme: one name for both, or `light:A,dark:B`.
    public var lightTheme: String?
    public var darkTheme: String?

    public init(entries: [Entry] = [], lightTheme: String? = nil, darkTheme: String? = nil) {
        self.entries = entries
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
    }

    /// Settings Canvas owns: the tile's own command and directory, and an opaque background (a
    /// see-through tile would show the canvas grid through the text). The user's are dropped.
    public static let ownedKeys: Set<String> = ["command", "initial-command", "working-directory", "wait-after-command", "background-opacity"]
    public static let overrides: [Entry] = [Entry("background-opacity", "1")]

    /// Ghostty's default config files, in the order it loads them on macOS: the XDG config
    /// directory, then Application Support; `config.ghostty` after the legacy `config` in each.
    public static func defaultFiles(home: URL, environment: [String: String]) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let directories = [xdg.appendingPathComponent("ghostty"), home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        return directories.flatMap { [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")] }
    }

    /// Where themes are looked up by name: the user's themes directory, then an installed
    /// Ghostty.app's bundled themes.
    public static func themeDirectories(home: URL, environment: [String: String]) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return [
            xdg.appendingPathComponent("ghostty/themes"),
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
            home.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
        ]
    }

    /// Loads `files` (missing ones are skipped), then the files they include. Like Ghostty,
    /// `config-file` lines queue their file to load after every file loaded so far, in order,
    /// relative to the including file's directory; `?path` marks an optional include. Each file
    /// loads at most once.
    public static func load(files: [URL], read: (URL) -> String?) -> GhosttyConfig {
        var config = GhosttyConfig()
        var loaded: Set<String> = []
        var queue = files
        var next = 0
        while next < queue.count {
            let file = queue[next]
            next += 1
            guard loaded.insert(file.standardizedFileURL.path).inserted, let text = read(file) else { continue }
            for entry in parse(text) {
                switch entry.key {
                case "config-file":
                    var target = unquoted(entry.value)
                    if target.hasPrefix("?") { target.removeFirst() }
                    guard !target.isEmpty else { continue }
                    if target.hasPrefix("~/") { target = FileManager.default.homeDirectoryForCurrentUser.path + target.dropFirst() }
                    queue.append(target.hasPrefix("/") ? URL(fileURLWithPath: target) : file.deletingLastPathComponent().appendingPathComponent(target))
                case "theme":
                    (config.lightTheme, config.darkTheme) = themes(entry.value)
                default:
                    config.entries.append(entry)
                }
            }
        }
        return config
    }

    /// `key = value` lines; blank lines and `#` comment lines are skipped. A bare `key` is a
    /// boolean flag set to true.
    public static func parse(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let equals = line.firstIndex(of: "=") else { return Entry(line, "true") }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return Entry(key, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// `theme` values: `Name` for both schemes, or `light:A,dark:B` (either order).
    public static func themes(_ value: String) -> (light: String?, dark: String?) {
        let value = unquoted(value)
        guard value.contains("light:") || value.contains("dark:") else { return value.isEmpty ? (nil, nil) : (value, value) }
        var light: String?, dark: String?
        for part in value.split(separator: ",") {
            let part = part.trimmingCharacters(in: .whitespaces)
            if part.hasPrefix("light:") { light = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if part.hasPrefix("dark:") { dark = String(part.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }
        return (light ?? dark, dark ?? light)
    }

    /// A theme's file: an absolute path as is, else the first `directories` entry holding it.
    public static func themeFile(_ name: String, directories: [URL], isFile: (String) -> Bool) -> URL? {
        if name.hasPrefix("/") { return isFile(name) ? URL(fileURLWithPath: name) : nil }
        return directories.map { $0.appendingPathComponent(name) }.first { isFile($0.path) }
    }

    /// What a tile loads under one scheme: the theme's settings, the user's (without the keys
    /// Canvas owns), then Canvas's overrides.
    public func settings(theme: [Entry]) -> [Entry] {
        (theme + entries).filter { !Self.ownedKeys.contains($0.key) && $0.key != "config-file" && $0.key != "theme" } + Self.overrides
    }

    /// The last value set for `key` in `settings`; an empty value resets it to the default.
    public static func value(_ key: String, in settings: [Entry]) -> String? {
        guard let value = settings.last(where: { $0.key == key })?.value else { return nil }
        return value.isEmpty ? nil : unquoted(value)
    }

    /// Every value of a repeatable key (`font-family`), honoring resets (an empty value clears the list).
    public static func values(_ key: String, in settings: [Entry]) -> [String] {
        settings.filter { $0.key == key }.reduce(into: []) { list, entry in
            if entry.value.isEmpty { list = [] } else { list.append(unquoted(entry.value)) }
        }
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
