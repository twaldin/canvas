/// What a fresh login session starts with before the user's startup files run: what a terminal
/// opened from the Dock gets. Terminal tiles and the login-shell lookups start from it rather
/// than from the app's own environment, which carries whatever launched the app: another
/// terminal's session state, or an agent's tool shell (omp's sets `CI`, `NO_COLOR`, `EDITOR=true`,
/// `GIT_EDITOR=true`, pagers set to `cat`, and `CLAUDECODE`, which makes Claude Code refuse to
/// start). The user's startup files set their own variables again.
public enum LoginSession {
    public static let variables: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]

    /// Also passed to tiles: the agent that holds the user's SSH keys, and what Ghostty sets on
    /// the child itself (unsetting an inherited `TERM` would undo Ghostty's `xterm-ghostty`).
    static let tilePassthrough: Set<String> = ["SSH_AUTH_SOCK", "TERM", "TERMINFO", "COLORTERM"]
    static let tilePassthroughPrefixes = ["XDG_", "LC_", "GHOSTTY_"]

    /// The variables of `inherited` (the app's environment) to unset for a terminal tile's shell,
    /// sorted: all but the session variables and the passthrough above. `keep` are the tile's
    /// own variables (`PATH`, `CANVAS_*`, …), set before the unset runs.
    public static func strippedForTile(_ inherited: [String: String], keep: Set<String>) -> [String] {
        inherited.keys.filter { key in
            !keep.contains(key) && !variables.contains(key) && !tilePassthrough.contains(key)
                && !tilePassthroughPrefixes.contains { key.hasPrefix($0) }
        }.sorted()
    }
}
