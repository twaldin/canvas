# Changelog

Each version's section is its GitHub release's notes (release.yml puts it above the list of merged changes).

## 0.3.0

Canvas is now Chalkwork: the same app under a new name. Its first launch brings a Canvas 0.2 install along.

Chalkwork has an app icon (Canvas had none): a chalk box whose stroke runs on as an arrow into a box of code, on slate.

### Upgrading from Canvas

1. Quit Canvas (its terminal sessions keep running), unzip `Chalkwork-0.3.0.zip`, move `Chalkwork.app` to `/Applications`, clear its quarantine flag (Install, below) and open it. The first launch moves `~/Library/Application Support/Canvas` to `~/Library/Application Support/Chalkwork` (every board, archived boards, the `pre-repo-migration/` backups, snapshots, open tabs) and `~/.canvas` (your compositions) to `~/.chalkwork`, moves the browser tiles' logins and site data, and brings over Canvas's settings and window frames. While Canvas is still running it moves nothing; quit Canvas and open Chalkwork again.
2. Your terminals come back attached: their sessions keep their `canvas-obj_…` names. Restart the agents in them (or end the sessions): an agent started under Canvas still has `CANVAS_SOCKET` pointing at `canvas.sock` and Canvas's `canvas` CLI on its PATH, so it can't reach Chalkwork until it restarts.
3. omp: point the extension at Chalkwork.
   ```sh
   rm -f ~/.omp/agent/extensions/canvas.ts
   ln -sf /Applications/Chalkwork.app/Contents/Resources/extensions/omp/chalkwork.ts ~/.omp/agent/extensions/chalkwork.ts
   ```
4. Every `CANVAS_*` variable is now `CHALKWORK_*`: rename `CANVAS_LSP_<LANGUAGE>` in your shell profile to `CHALKWORK_LSP_<LANGUAGE>`.
5. The CLI is `chalkwork` (there is no `canvas` alias), the Python package `chalkwork_sdk` (`from chalkwork_sdk import canvas` still gives you the client; its class is `Chalkwork`), the agent skill `chalkwork`, and `board.export` writes `.chalkwork/board.json` (import an older `.canvas/board.json` by its path).
6. Once your agents run under Chalkwork, delete `/Applications/Canvas.app`. Opened again, Canvas would start with no boards.
7. macOS asks again before a terminal program or page uses the microphone, the camera or another app: those permissions belonged to Canvas.

### New

- **Mention a whole group:** Hyper-click a group's title or empty interior (or select it and press ⇧⌘M) and the agent gets the group: each member with a short excerpt, plus the arrows among them. The innermost group under the pointer wins, and the chip shows the group's title.
- **Content zoom:** Object › Content Zoom (⌃⌘= / ⌃⌘- / ⌃⌘0) or the − % + control in a tile's title bar zooms its content in place. The tile keeps its size and its title bar; a terminal gets bigger text and fewer columns. It replaces Scale: saved boards' `scale` becomes `zoom` once, keeping the frame, and ⌥-drag resizes a tile keeping its proportions. For agents: `props.zoom`, a text shape's `props.textSize`; `props.scale` is refused, naming them.

### Improved

- **Readable arrows:** a board's avoid-routed arrows are routed together. No two share a segment, their ends spread along a box's side, a group can set a flow direction (`GroupProps.flow`), and each label stays by its own line, not by a bundle of others. Dragging a tile no longer makes labels jump when you drop it. `layout.check` reports `arrowOverlaps` and `arrowIntersections`.
- **Diagram tiles:** a bare symbol (`Type.method`, no `path`) is found through the language server's workspace symbols, and an ambiguous one lists its candidates. A growing diagram takes only free space instead of covering its neighbours, and opening a node pans the view (zoom unchanged) to the new nodes.
- **Development bundles:** an instance started with its own home runs from a copy of its bundle in that home, so macOS relaunching it at login brings it back on its own home, not beside your installed app.

### Fixed

- After a restart, a terminal whose zmx session didn't answer (its daemon stopped) stayed detached; it now waits for the session, saying so, and attaches when it answers.
- After a restart, a mid-turn omp or opencode agent stayed "restored" and refused prompts until its next event; they now report their state again when the app comes back (Claude Code and Codex at their next event).
- The CLI sent `--until working` as a bare string, so `agent.wait` waited for its default states. An array param now takes one item, a comma-separated string or a repeated flag, and `agent.wait` rejects an `until` that isn't a list of states.
- `board.get` with `branch` returns that branch's `regions` (`[]` when it has none).

### Install

Download `Chalkwork-0.3.0.zip`, unzip, move `Chalkwork.app` to `/Applications`. It's ad-hoc signed, not notarized: run `xattr -dr com.apple.quarantine /Applications/Chalkwork.app`, or open it once and choose Open Anyway in System Settings › Privacy & Security. Then `brew install neurosnap/tap/zmx oven-sh/bun/bun`. Requires macOS 14 or later on Apple silicon. Full steps in the README.

### Licensing

Chalkwork statically links GNU libintl (GNU gettext 0.24, LGPL-2.1-or-later) through libghostty. Its source, `gettext-0.24.tar.gz`, is attached to this release, and so is `THIRD_PARTY_NOTICES.md`, the list of third-party components and their licenses (the same file is inside `Chalkwork.app`). `THIRD_PARTY_NOTICES.md` also says how to relink Chalkwork with a modified libintl.
