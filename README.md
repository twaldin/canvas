# Canvas

**Point at a line. Your agent gets the line.**

Canvas is a native macOS app where coding agents run unmodified in real terminals, and the things they work on sit beside them: the actual file, with your language server and a git gutter against your branch; the page, in a browser; notes whose code excerpts stay live against the files they quote. Hyper-click a line of code, a DOM element, a note paragraph or a command's output, and it goes with your next prompt to the agent working in that checkout. The agent points back the same way: it opens the exact code it means, draws arrows between things, and leaves notes and walkthroughs you can step through.

The terminal keeps the transcript. The canvas keeps the work.

[omp](https://github.com/can1357/oh-my-pi) is the first-class agent. Claude Code, Codex, opencode and Gemini CLI (before 0.60) get the same mentions inside Canvas, with no setup, and any terminal program runs in a tile.

## What's on the canvas

- **Mentions.** Hyper-click (⌃⌥⇧⌘-click) a line of code, a DOM element, a note paragraph, a command's output or a shape to stage a mention in the tray. It goes with the next prompt you submit to the terminal the tray targets; a mention from another worktree targets the agent working there. ⇧⌘M mentions whatever the keyboard is on.
- **Code tiles.** The whole file, scrolled to a range. A gitsigns-style gutter shows changes against the merge-base (or HEAD); click a sign to peek at the old lines. Language-server hover, go to definition, references, and outline. A follow tile tracks what an agent reads and edits, and flashes the lines it changed.
- **Notes.** Markdown with fences that stay live against the files they quote; a `propose` fence renders as a diff, and a fence whose code moved away says it's stale.
- **HTML tiles.** Sandboxed explainers with a bundled kit (Mermaid, code excerpts); agents chain them into walkthroughs you step through with ⌥⌘→.
- **Changes tiles.** Review an agent's work like a PR: stage, unstage or discard files, hunks and lines. ⌘Z undoes agents' changes too, and says what it undid.
- **Browser tiles.** omp's `browser` tool drives them; the page's errors show on the tile.
- **Terminal tiles.** Rendered by libghostty. Sessions live in [zmx](https://github.com/neurosnap/zmx), so they survive an app restart, and after a reboot omp, Claude Code and Codex tiles resume their recorded session. They use your Ghostty config (theme, colors, font family, keybinds; Canvas keeps its own font size, and zoom scales text), turn a program's notification or bell into an attention marker, and ⌘-click opens a `path:line` in the output as a code tile.
- **Several agents.** Each agent's state is on its tile: blue working, orange needs you, green done and not yet seen. ⌘J goes to whoever needs you next.
- **Drawing.** Shapes, arrows (straight, orthogonal, or routed around tiles), ink, and titled group regions.
- **Getting around.** Go to… (⌘P) searches every group and tile by title, path, or note heading and takes you to the one you pick. When you've panned into empty space, a "Back to content" pill brings you home, and Zoom to Fit (⌘9) frames the main cluster of work instead of shrinking to fit a few far-off strays.
- **Agent API.** A local socket with a JSON schema, a Python SDK, a TypeScript client, and a `canvas` CLI. Agents create and lay out objects in atomic batches, measure and fit content, render any region offscreen without moving your view, read the board's activity history, and hand each other board objects instead of re-describing them.

## Install

1. Download `Canvas-<version>.zip` from [Releases](../../releases), unzip it, and move `Canvas.app` to `/Applications`.
2. The app is ad-hoc signed, not notarized, so Gatekeeper blocks the first launch. Clear the quarantine flag:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Canvas.app
   ```
   Or open it once, then choose **Open Anyway** in System Settings › Privacy & Security. On macOS 14, right-clicking the app and choosing **Open** also works; macOS 15 removed that shortcut.
3. Install the runtime tools. Terminal tiles need zmx. The CLI and the omp extension need [bun](https://bun.sh).
   ```sh
   brew install neurosnap/tap/zmx oven-sh/bun/bun
   ```
4. Optional, for omp: install the Canvas extension. omp sessions started in a Canvas terminal tile then report their lifecycle, drive follow tiles, and get the canvas skill.
   ```sh
   mkdir -p ~/.omp/agent/extensions
   ln -sf /Applications/Canvas.app/Contents/Resources/extensions/omp/canvas.ts ~/.omp/agent/extensions/canvas.ts
   ```
5. Optional, for code navigation: install the language servers you want (sourcekit-lsp comes with Xcode or the Command Line Tools; `npm install -g pyright`, `npm install -g typescript-language-server typescript@5`, `go install golang.org/x/tools/gopls@latest`, `rustup component add rust-analyzer`). Without one, Go to Definition, Find References and Outline answer by text search. Canvas finds a server through your login shell:
   1. the path in `CANVAS_LSP_<LANGUAGE>` (`CANVAS_LSP_SWIFT`, `_PYTHON`, `_TYPESCRIPT`, `_GO`, `_RUST`), if set;
   2. the command on your login shell's PATH;
   3. nvim's mason (`~/.local/share/nvim/mason/bin`), and `~/go/bin` for gopls;
   4. `rustup which rust-analyzer` for rust-analyzer.

   A server elsewhere (Zed's, a custom build) needs the variable, e.g. in `~/.zprofile`: `export CANVAS_LSP_RUST=/path/to/rust-analyzer`. Canvas looks again 30 seconds after a miss, so a server installed while it runs is picked up without a restart; a navigation panel without a server says where Canvas looked.

Requires macOS 14 or later on Apple silicon.

Quitting Canvas, or closing a board's tab, doesn't stop your terminals: agents and shells keep running in their zmx sessions and are back when you open the folder again. Closing a terminal tile ends its session. To see or end them without the app: `zmx list` (Canvas's are named `canvas-obj_…`), `zmx kill <name>`.

## Uninstall

1. End the terminal sessions first, or they keep running: `zmx list`, then `zmx kill <name>` for each `canvas-obj_…` session.
2. Delete `/Applications/Canvas.app`.
3. Delete `~/Library/Application Support/Canvas/` (boards, including archived ones, `open-boards.json`).
4. Delete the browser profile: `~/Library/WebKit/net.waldin.canvas/`, `~/Library/Caches/net.waldin.canvas/`, `~/Library/HTTPStorages/net.waldin.canvas*` (or first use Canvas › Clear Browsing Data…).
5. `defaults delete net.waldin.canvas` (export folder, lasso setting, window frames).
6. Delete `$(getconf DARWIN_USER_CACHE_DIR)net.waldin.canvas` and, in `$(getconf DARWIN_USER_TEMP_DIR)`, `net.waldin.canvas`, `canvas-renders`, `canvas-exports`, `canvas-gemini`.
7. Delete `~/.local/state/zmx/logs/canvas-obj_*.log`.
8. Remove the omp extension symlink `~/.omp/agent/extensions/canvas.ts`, and `~/.claude/plugins/data/canvas-inline` if you used Claude Code.
9. Optional, the agents' own: Codex's `trust_level` entries for your repos in `~/.codex/config.toml`, and `~/.canvas/compositions` if you or your agents wrote any.

Canvas edits no shell, agent or Ghostty config: Codex's hooks are a per-session override, not written to `~/.codex`. [docs/contracts.md](docs/contracts.md) "On-disk locations" lists every path.

## Build from source

The Command Line Tools are enough; Xcode is not required.

```sh
swift build                    # debug build
scripts/bundle.sh release      # assemble .build/Canvas.app (ad-hoc signed)
swift run CanvasCoreTests      # test suite (an executable target; see Package.swift)
bun scripts/gen-clients.ts     # regenerate the Python/TS clients from schema/canvas-api.json
```

`scripts/dev.sh` runs an isolated development instance. See [docs/testing.md](docs/testing.md).

## Docs

- [docs/design.md](docs/design.md): the design record, covering principles, architecture, and decisions.
- [docs/contracts.md](docs/contracts.md): the API, tile, and scene contracts.
- [docs/releasing.md](docs/releasing.md): signing, notarizing, and publishing a release.
- [skills/canvas/SKILL.md](skills/canvas/SKILL.md): how agents work on the canvas.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
