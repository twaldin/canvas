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

    /// Settings Canvas owns: the tile's own command and directory, an opaque background (a
    /// see-through tile would show the canvas grid through the text), the font size (tile sizes
    /// are chosen for Ghostty's default and canvas zoom scales the text; a large size meant for a
    /// full-screen terminal would halve a tile's columns), and no background image (cards and
    /// renders can't draw it, so every live/card flip would change the tile). The user's are
    /// dropped.
    public static let ownedKeys: Set<String> = ["command", "initial-command", "working-directory", "wait-after-command", "background-opacity", "font-size", "background-image"]
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
    /// Canvas owns and the keybinds of app-level actions, `appKeybind`), then Canvas's overrides.
    public func settings(theme: [Entry]) -> [Entry] {
        (theme + entries).filter { !Self.ownedKeys.contains($0.key) && $0.key != "config-file" && $0.key != "theme" && Self.appKeybind($0) == nil } + Self.overrides
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

// MARK: Keybinds

/// Ghostty's embedded library hands window, tab, and split actions back to its host, and a key
/// bound to one is claimed by the terminal whether or not the host does anything with it: with
/// `keybind = super+t=new_window` imported, ⌘T in a focused terminal made no tile and the next
/// typing went to the agent. So the user's keybinds of those actions never reach the library:
/// new window, tab and split become Canvas's New Terminal beside the focused terminal, close
/// surface closes it (the close sheet), and the rest are dropped (the app logs them).
extension GhosttyConfig {
    public enum AppAction: String, Equatable, Sendable {
        case newTerminal, closeTerminal
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    /// A single key press: modifiers and a key, which is its unshifted character ("t", "=", "[")
    /// or a name for keys without one ("enter", "arrow_up", "f5").
    public struct KeyChord: Hashable, Sendable {
        public var modifiers: Modifiers
        public var key: String

        public init(_ modifiers: Modifiers, _ key: String) {
            self.modifiers = modifiers
            self.key = key
        }

        /// The chord a menu item's key equivalent is (`key`, with its modifier mask as
        /// `modifiers`), named as Ghostty keybinds name keys: AppKit's characters for keys without
        /// one of their own become their names (`"\t"` tab, `"\r"` enter, `"\u{1b}"` escape,
        /// `"\u{8}"` backspace, the function-key range's arrows, page keys and F-keys), an
        /// uppercase letter is the letter with Shift, a shifted symbol (`"{"` for ⇧⌘[) its key
        /// with Shift (US layout).
        public init(menuKey key: String, modifiers: Modifiers) {
            var modifiers = modifiers
            if let name = Self.menuKeyNames[key] {
                if key == "\u{19}" { modifiers.insert(.shift) }
                self.init(modifiers, name)
            } else if let unshifted = Self.unshiftedSymbols[key] {
                self.init(modifiers.union(.shift), unshifted)
            } else {
                if key != key.lowercased() { modifiers.insert(.shift) }
                self.init(modifiers, key.lowercased())
            }
        }

        /// AppKit's key-equivalent characters for named keys (NSEvent's function-key constants).
        private static let menuKeyNames: [String: String] = [
            "\t": "tab", "\u{19}": "tab", "\r": "enter", "\u{3}": "enter", " ": "space", "\u{8}": "backspace", "\u{7f}": "backspace",
            "\u{1b}": "escape", "\u{F728}": "delete", "\u{F729}": "home", "\u{F72B}": "end", "\u{F72C}": "page_up", "\u{F72D}": "page_down",
            "\u{F702}": "arrow_left", "\u{F703}": "arrow_right", "\u{F701}": "arrow_down", "\u{F700}": "arrow_up",
            "\u{F704}": "f1", "\u{F705}": "f2", "\u{F706}": "f3", "\u{F707}": "f4", "\u{F708}": "f5", "\u{F709}": "f6",
            "\u{F70A}": "f7", "\u{F70B}": "f8", "\u{F70C}": "f9", "\u{F70D}": "f10", "\u{F70E}": "f11", "\u{F70F}": "f12",
        ]

        /// US-layout shifted symbols menu items use as keys, and the keys that type them.
        private static let unshiftedSymbols: [String: String] = ["{": "[", "}": "]", "+": "=", "_": "-", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"]
    }

    /// A user keybind of an app-level action. `chord` is nil for a trigger Canvas can't match
    /// (a key sequence); `action` is nil for an action Canvas has no equivalent of (dropped).
    public struct AppKeybind: Equatable, Sendable {
        public var entry: Entry
        public var chord: KeyChord?
        public var action: AppAction?
    }

    public static let newTerminalActions: Set<String> = ["new_window", "new_tab", "new_split"]
    public static let closeTerminalActions: Set<String> = ["close_surface"]
    /// App-level actions without a Canvas equivalent: windows, tabs, splits, fullscreen, the
    /// app's own config, updates and undo. A bound key would do nothing and reach no program.
    public static let unsupportedActions: Set<String> = [
        "close_tab", "close_window", "close_all_windows", "goto_tab", "previous_tab", "next_tab", "last_tab", "move_tab",
        "toggle_tab_overview", "prompt_tab_title", "goto_split", "toggle_split_zoom", "resize_split", "equalize_splits",
        "goto_window", "toggle_fullscreen", "toggle_maximize", "toggle_window_decorations", "toggle_window_float_on_top",
        "toggle_quick_terminal", "toggle_visibility", "toggle_background_opacity", "toggle_command_palette",
        "toggle_secure_input", "reset_window_size", "float_window", "quit", "open_config", "reload_config", "inspector",
        "check_for_updates", "undo", "redo", "show_gtk_inspector", "show_on_screen_keyboard", "prompt_surface_title",
        "copy_title_to_clipboard",
    ]

    /// The user's keybinds of app-level actions, in load order.
    public var appKeybinds: [AppKeybind] { entries.compactMap(Self.appKeybind) }

    /// The chords Canvas performs for the user's bindings: a later binding of the same chord
    /// (another action, `unbind`) replaces one, and `keybind = clear` drops them all.
    public var remaps: [KeyChord: AppAction] {
        var remaps: [KeyChord: AppAction] = [:]
        for entry in entries where entry.key == "keybind" {
            if entry.value == "clear" {
                remaps.removeAll()
                continue
            }
            guard let (trigger, _) = Self.keybind(entry.value), let chord = Self.chord(trigger) else { continue }
            remaps[chord] = Self.appKeybind(entry)?.action
        }
        return remaps
    }

    /// `entry` when it is a keybind of an app-level action.
    public static func appKeybind(_ entry: Entry) -> AppKeybind? {
        guard entry.key == "keybind", let (trigger, action) = keybind(entry.value) else { return nil }
        let name = String(action.prefix { $0 != ":" })
        let mapped: AppAction? = newTerminalActions.contains(name) ? .newTerminal : closeTerminalActions.contains(name) ? .closeTerminal : nil
        guard mapped != nil || unsupportedActions.contains(name) else { return nil }
        return AppKeybind(entry: entry, chord: chord(trigger), action: mapped)
    }

    /// A `keybind` value's trigger and action. The separator is the first `=` that isn't itself a
    /// key (a key follows the start, `+`, `>` or a `prefix:`), so `super+==new_tab` binds ⌘=.
    public static func keybind(_ value: String) -> (trigger: String, action: String)? {
        let characters = Array(value)
        for index in characters.indices where characters[index] == "=" && index > 0 && !"+>:".contains(characters[index - 1]) {
            let trigger = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            let action = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            return trigger.isEmpty || action.isEmpty ? nil : (trigger, action)
        }
        return nil
    }

    /// A trigger's chord (`super+shift+t`, `ctrl+equal`, `global:cmd+key_t`); nil for a sequence
    /// (`ctrl+a>n`) or anything else Canvas can't match.
    public static func chord(_ trigger: String) -> KeyChord? {
        var rest = Substring(trigger)
        while let prefix = ["global:", "all:", "unconsumed:", "performable:"].first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(prefix.count) }
        guard !rest.contains(">") else { return nil }
        let rawKey: Substring
        let names: [Substring]
        if rest == "+" || rest.hasSuffix("++") {
            rawKey = "+"
            names = rest == "+" ? [] : rest.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
        } else {
            let parts = rest.split(separator: "+", omittingEmptySubsequences: false)
            rawKey = parts.last ?? ""
            names = parts.dropLast()
        }
        var modifiers: Modifiers = []
        for name in names {
            switch name.lowercased() {
            case "super", "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        guard let key = key(String(rawKey)) else { return nil }
        return KeyChord(modifiers, key)
    }

    private static let keyNames: [String: String] = [
        "equal": "=", "minus": "-", "plus": "+", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "apostrophe": "'", "backquote": "`", "grave": "`", "grave_accent": "`",
        "bracket_left": "[", "left_bracket": "[", "bracket_right": "]", "right_bracket": "]", "space": " ",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "return": "enter", "esc": "escape", "up": "arrow_up", "down": "arrow_down", "left": "arrow_left", "right": "arrow_right",
    ]

    private static func key(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.count == 1 { return raw.lowercased() }
        let name = raw.lowercased()
        if let mapped = keyNames[name] { return mapped }
        // Physical keys: `key_t`, `digit_1`.
        for prefix in ["key_", "digit_"] where name.hasPrefix(prefix) && name.count == prefix.count + 1 { return String(name.dropFirst(prefix.count)) }
        return name
    }
}
