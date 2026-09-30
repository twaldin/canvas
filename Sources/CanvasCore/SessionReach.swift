/// A terminal tile attaching to a zmx session whose daemon doesn't answer: stopped (SIGSTOP),
/// wedged, or paging. `zmx list` shows it as `err=Timeout status=unreachable`, and `zmx attach
/// --labels` to it fails at once ("does not support labels"), which would leave the tile detached
/// once the daemon answers again; so the tile waits for it first (docs/contracts.md "zmx sessions").
public enum SessionReach {
    /// How long a tile keeps checking before it gives up, in seconds of waiting between checks.
    public static let limit = 60 * 60
    /// The longest wait between two checks, in seconds.
    public static let longestDelay = 30

    /// A prologue for `sh -c` with $1 = zmx, $2 = session name: while zmx lists the session as
    /// unreachable it says so in the terminal and checks again, after 1 s, then twice as long each
    /// time up to `longestDelay`. After `limit` seconds of waiting it gives up (exit 1): the tile
    /// shows why, and a key press attaches again (`TerminalTile.surfaceClosed`, which starts over
    /// here). A session that answers, or that zmx doesn't list, goes on at once.
    public static func prologue(limit: Int = limit) -> String {
        #"""
        waited=0; delay=1
        while "$1" list 2>/dev/null | awk -F'\t' -v n="name=$2" '{ s = $1; sub(/^[ *]+/, "", s) } s == n { for (i = 2; i <= NF; i++) if ($i == "status=unreachable" || index($i, "err=") == 1) found = 1 } END { exit !found }'; do
          if [ "$waited" -ge \#(limit) ]; then printf '\r\033[KThis terminal session (%s) still is not answering. Press any key to try again.\n' "$2"; exit 1; fi
          printf '\r\033[KThis terminal session (%s) is not answering (its process may be stopped); retrying in %ss…' "$2" "$delay"
          sleep "$delay"; waited=$((waited + delay)); delay=$((delay * 2))
          if [ "$delay" -gt \#(longestDelay) ]; then delay=\#(longestDelay); fi
        done

        """#
    }
}
