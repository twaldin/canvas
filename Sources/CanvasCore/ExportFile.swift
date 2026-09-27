import Foundation

/// Where Save as PNG…, Save as HTML… and Export Selection put a file by default, and what they
/// call it. A picture of a board is shared, not versioned: the save sheet never starts in the
/// board's own directory (a security report saved into the repo it describes is one `git add -A`
/// from being pushed).
public enum ExportFile {
    /// The longest name kept before the extension.
    public static let maxNameLength = 80

    /// A file name for an export titled `title` (an object's title): path and drive separators
    /// (`/`, `:`, `\`) read as " - " ("Findings report: top 5" → "Findings report - top 5"),
    /// control characters as spaces, runs of spaces and dashes collapse, no leading dot (a hidden
    /// file) or trailing separator; at most `maxNameLength` characters, then `.ext`. `fallback`
    /// when the title is missing or leaves nothing.
    public static func name(_ title: String?, ext: String, fallback: String = "Canvas selection") -> String {
        var base = title ?? ""
        base = base.replacingOccurrences(of: #"(\s*[/:\\]\s*)+"#, with: " - ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"[\x00-\x1F\x7F]"#, with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"( - )+"#, with: " - ", options: .regularExpression)
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-"))
        base = base.trimmingCharacters(in: trim)
        while base.hasPrefix(".") { base = String(base.dropFirst()).trimmingCharacters(in: trim) }
        base = String(base.prefix(maxNameLength)).trimmingCharacters(in: trim)
        return "\(base.isEmpty ? fallback : base).\(ext)"
    }

    /// The folder a save sheet opens in: the one the user last saved an export into, unless it
    /// is gone or inside `boardRoot`; else `downloads`.
    public static func directory(lastUsed: URL?, boardRoot: URL, downloads: URL, exists: (URL) -> Bool) -> URL {
        guard let lastUsed, exists(lastUsed), !isInside(lastUsed, boardRoot) else { return downloads }
        return lastUsed
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
