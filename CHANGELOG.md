# Changelog

Each version's section is its GitHub release's notes (release.yml puts it above the list of merged changes).

## 0.3.3

An agent's question shows as needing you even with approvals off, and opened from a worktree, Chalkwork reads that worktree's code.

**Still on Canvas 0.2?** Read the 0.3.0 notes' "Upgrading from Canvas" first: the first launch of Chalkwork moves your boards over, and agents started under Canvas need a restart.

### Fixed

- **An agent's question asks for you, in auto mode too.** When Claude Code or Codex asks you something mid-turn, the tile goes orange with the question in its bubble, and ⌘J and the edge pill find it, even with approvals off (`--dangerously-skip-permissions`, `--yolo`). Codex's questions (Plan mode, and the queued "? 1 question" in Default mode) left the tile working, then done, with the question unanswered. Claude Code's showed "approve AskUserQuestion?" and stayed orange after you answered, until the turn ended. Answering takes the tile back to working.
- **Opened from a worktree, Chalkwork reads that worktree's code.** The board stays the repository's, rooted at the main checkout, but ⌘P Go to now lists and opens the worktree's files and symbols, hover, ⌘-click and call graphs on a worktree's files ask a language server of that worktree's project (they said "No definition found"), and code, image, diagram and changes tiles an agent working in a worktree creates with relative paths read its worktree, not the main checkout.

### Install

Download `Chalkwork-0.3.3.zip`, unzip, move `Chalkwork.app` to `/Applications` (replacing the older one; quit Chalkwork first and choose Keep Running, and your terminals reattach). It's ad-hoc signed, not notarized: run `xattr -dr com.apple.quarantine /Applications/Chalkwork.app`, or open it once and choose Open Anyway in System Settings › Privacy & Security. Then `brew install neurosnap/tap/zmx oven-sh/bun/bun`. Requires macOS 14 or later on Apple silicon. Full steps in the README.

### Licensing

Chalkwork statically links GNU libintl (GNU gettext 0.24, LGPL-2.1-or-later) through libghostty. Its source, `gettext-0.24.tar.gz`, is attached to this release, and so is `THIRD_PARTY_NOTICES.md`, the list of third-party components and their licenses (the same file is inside `Chalkwork.app`). `THIRD_PARTY_NOTICES.md` also says how to relink Chalkwork with a modified libintl.

## 0.3.2

Codex asks once for Chalkwork's commands, a resumed Codex session keeps reporting its state, a second launch goes to the Chalkwork already running, and approval bubbles stay beside the agent that asks.

**Still on Canvas 0.2?** Read the 0.3.0 notes' "Upgrading from Canvas" first: the first launch of Chalkwork moves your boards over, and agents started under Canvas need a restart.

### Fixed

- **An approval bubble stays beside the agent that asks.** Zoomed out to fit on a packed board, a blocked terminal's ✋ bubble could land far across the board beside an unrelated tile, so it read as that tile's question. It now stays within 200 pt of the terminal's ring, covering part of a neighbour or cut short if it must.
- **One Chalkwork per home.** Opening Chalkwork while it already runs on the same boards (a second `open -n`, a login restore beside the running app) no longer starts a second instance that takes over the first one's socket, leaving one of them with no API (`chalkwork` CLI calls failing `unavailable`): the new launch asks the running one to open its folder's board and bring it forward, then exits. Development homes each run their own instance, as before.
- **Codex asks once for canvas commands, not on every call.** Chalkwork told Codex to pass payloads as `--json @"$TMPDIR/…"`, and Codex can't match a command with `$TMPDIR` in it to "don't ask again for commands that start with `chalkwork`", so every draw stopped on an approval again, even after you allowed `chalkwork`. Codex now gets the temp directory's real path and asks to allow every `chalkwork` command, so a new Codex user answers one approval, once; the HTML explainer guide no longer renders to `--out "$TMPDIR/…"` either.
- **A resumed Codex session reports like a fresh one when you pass it `-c`.** `codex resume <id> -c …` in a tile (for example with the folder's `trust_level` for a session you started outside Chalkwork) dropped Chalkwork's hooks: Codex keeps only the `-c` options given after `resume`, and the wrapper put its own before it. The tile stayed idle through the whole turn, with no ring and nothing for ⌘J while Codex waited on an approval. The wrapper now puts its `-c` beside yours, after `resume` or `fork` too.

### Install

Download `Chalkwork-0.3.2.zip`, unzip, move `Chalkwork.app` to `/Applications` (replacing the older one; quit Chalkwork first and choose Keep Running, and your terminals reattach). It's ad-hoc signed, not notarized: run `xattr -dr com.apple.quarantine /Applications/Chalkwork.app`, or open it once and choose Open Anyway in System Settings › Privacy & Security. Then `brew install neurosnap/tap/zmx oven-sh/bun/bun`. Requires macOS 14 or later on Apple silicon. Full steps in the README.

### Licensing

Chalkwork statically links GNU libintl (GNU gettext 0.24, LGPL-2.1-or-later) through libghostty. Its source, `gettext-0.24.tar.gz`, is attached to this release, and so is `THIRD_PARTY_NOTICES.md`, the list of third-party components and their licenses (the same file is inside `Chalkwork.app`). `THIRD_PARTY_NOTICES.md` also says how to relink Chalkwork with a modified libintl.

## 0.3.1

Fixes from watching people use Chalkwork for the first time: typing goes where you aimed, the tray says what each chip is and where it goes, mentions follow the worktree an agent works in, and a finished agent stays green until you look.

**Still on Canvas 0.2?** Read the 0.3.0 notes' "Upgrading from Canvas" first: the first launch of Chalkwork moves your boards over, and agents started under Canvas need a restart.

### Fixed

- **A reply that lands while you look elsewhere stays green.** Looking at an agent (or typing in it) while it still works no longer counts as seeing its answer: a turn that ends after you moved on is done and unseen until you look at it, and ⌘J goes there. ⌘J covers the board you're on; the README said "whoever".
- **Mentions route by worktree after `cd ../wt && codex`.** A terminal's `worktree` and `branch` follow where its program (else its shell) works, read from the process table, not only where the tile started: a line from that worktree goes to the agent working there, as the README promised, and `board.get` files the terminal under that branch.
- **Review Changes (⇧⌘R) and Review Branch review the focused or selected terminal's worktree,** not always the board's checkout ("Changes: main"). With no terminal to go by, Review Branch on the default branch offers the repository's worktrees.
- **Typing goes where you aimed.** A press anywhere on a tile's title bar (but its buttons) takes the tile and the keyboard, the first click included. The tray says "→ codex · you're typing in zsh" when the keyboard isn't in the terminal it will send to. Tab never types into a selected tile, and Esc and Tab reach Get Started. Go to (⌘P) selects the lines it showed, so ⇧⌘M mentions just those, and clicking a row goes there.
- **Discard from the keyboard asks first:** in a changes tile `r` only asks, and ⌘⌫ confirms, so prose typed into the wrong tile can't discard your work. The question and its hint agree, and it stays until you answer or do something else.
- **Tray chips are numbered** [1], [2]… as the agent receives them, so "[2]" in your prompt is the second chip. Clicking a chip shows what it points at: it selects it, brings it into view, and scrolls to and flashes code lines and note blocks. A chip whose page navigated says "page changed", and a second Hyper-click that takes something out of the tray says so.
- **The tray never widens the window.** Its "→ target" label stays whole; chips shrink (a code chip keeps its lines: the directory goes first, then the symbol, then the middle of the file name) and then scroll sideways.
- **⌘Z brings back chips** a tile delete or Hyper-V (⌃⌥⇧⌘V) took out of the tray, in their old places and numbers. The Edit menu has the tray's commands: Remove Last Mention (⌥⇧⌘M), Remove Mention ▸, Clear Mentions and Send Mentions To ▸, and tile context menus lead with Mention (⇧⌘M).
- **Browser tiles:** ⌘A selects the address you're typing in, ⌥⌘I shows and hides the Web Inspector docked under the address bar, ⌘R (View › Reload Page) reloads, and Back no longer shows the previous page's error badge.
- **Walkthroughs start at their first stop:** ⌥⌘→ on the walkthrough's group, or with nothing selected, goes to the first stop, and a stop stepped to from far out is framed readably. A Start here marker's edge pill selects its walkthrough.
- **A growing changes tile never covers its neighbours.**

### Install

Download `Chalkwork-0.3.1.zip`, unzip, move `Chalkwork.app` to `/Applications` (replacing 0.3.0; quit Chalkwork first and choose Keep Running, and your terminals reattach). It's ad-hoc signed, not notarized: run `xattr -dr com.apple.quarantine /Applications/Chalkwork.app`, or open it once and choose Open Anyway in System Settings › Privacy & Security. Then `brew install neurosnap/tap/zmx oven-sh/bun/bun`. Requires macOS 14 or later on Apple silicon. Full steps in the README.

### Licensing

Chalkwork statically links GNU libintl (GNU gettext 0.24, LGPL-2.1-or-later) through libghostty. Its source, `gettext-0.24.tar.gz`, is attached to this release, and so is `THIRD_PARTY_NOTICES.md`, the list of third-party components and their licenses (the same file is inside `Chalkwork.app`). `THIRD_PARTY_NOTICES.md` also says how to relink Chalkwork with a modified libintl.

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
