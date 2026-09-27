# Canvas

A native macOS infinite canvas for coding agents. Agents run unmodified in real terminal tiles, and next to them sit code, note, browser, HTML, and drawing tiles. You and the agents read and change the same objects: the canvas holds the current working state, while each agent's transcript stays in its own terminal.

[omp](https://github.com/can1357/oh-my-pi) is the first-class agent. Any terminal program runs in a tile.

## What's on the canvas

- **Terminal tiles.** Rendered by libghostty. Sessions live in [zmx](https://github.com/neurosnap/zmx), so they survive an app restart, and after a reboot omp, Claude Code and Codex tiles resume their recorded session. They use your Ghostty config (theme, colors, font family, keybinds; Canvas keeps its own font size, and zoom scales text), turn a program's notification or bell into an attention marker, and ⌘-click opens a `path:line` in the output as a code tile.
- **Code tiles.** The whole file, scrolled to a range. A gitsigns-style gutter shows changes against the merge-base (or HEAD); click a sign to peek at the old lines. Language-server hover, go to definition, references, and outline. A follow tile tracks what an agent reads and edits.
- **Notes.** Markdown with fences that stay live against the files they quote.
- **HTML tiles.** Sandboxed explainers with a bundled kit (Mermaid, code excerpts).
- **Browser tiles.** omp's `browser` tool drives them.
- **Drawing.** Shapes, arrows (straight, orthogonal, or routed around tiles), ink, and titled group regions.
- **Mentions.** Hyper-click anything (a line of code, a note paragraph, a shape) to stage a mention into the prompt of the terminal you're targeting.
- **Getting around.** Go to… (⌘P) searches every group and tile by title, path, or note heading and takes you to the one you pick. When you've panned into empty space, a "Back to content" pill brings you home, and Zoom to Fit (⌘9) frames the main cluster of work instead of shrinking to fit a few far-off strays.
- **Agent API.** A local socket with a JSON schema, a Python SDK, a TypeScript client, and a `canvas` CLI. Agents create and lay out objects in atomic batches, measure and fit content, render any region offscreen without moving your view, and read the board's activity history.

## Install

1. Download `Canvas-<version>.zip` from [Releases](../../releases), unzip it, and move `Canvas.app` to `/Applications`.
2. The app is ad-hoc signed, not notarized, so Gatekeeper blocks the first launch. Right-click the app and choose **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Canvas.app
   ```
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
- [skills/canvas/SKILL.md](skills/canvas/SKILL.md): how agents work on the canvas.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
