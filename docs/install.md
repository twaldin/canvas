# Installing and uninstalling Canvas

Reference for the README's [Install](../README.md#install) and [Uninstall](../README.md#uninstall) sections.

## Language servers

Code tiles get hover, Go to Definition, Find References and Outline from a language server. Install the ones you want:

| Language | Server | Install |
| --- | --- | --- |
| Swift | sourcekit-lsp | Comes with Xcode or the Command Line Tools |
| Python | pyright | `npm install -g pyright` |
| TypeScript, JavaScript | typescript-language-server | `npm install -g typescript-language-server typescript@5` |
| Go | gopls | `go install golang.org/x/tools/gopls@latest` |
| Rust | rust-analyzer | `rustup component add rust-analyzer` |

Without one, Go to Definition, Find References and Outline answer by text search.

Canvas finds a server through your login shell, in this order:

1. the path in `CANVAS_LSP_<LANGUAGE>` (`CANVAS_LSP_SWIFT`, `_PYTHON`, `_TYPESCRIPT`, `_GO`, `_RUST`), if set;
2. the command on your login shell's PATH;
3. nvim's mason (`~/.local/share/nvim/mason/bin`), and `~/go/bin` for gopls;
4. `rustup which rust-analyzer` for rust-analyzer.

A server elsewhere (Zed's, a custom build) needs the variable, e.g. in `~/.zprofile`: `export CANVAS_LSP_RUST=/path/to/rust-analyzer`. Canvas looks again 30 seconds after a miss, so a server installed while it runs is picked up without a restart; a navigation panel without a server says where Canvas looked.

## Uninstall

1. End the terminal sessions first, or they keep running: `zmx list`, then `zmx kill <name>` for each `canvas-obj_…` session.
2. Delete `/Applications/Canvas.app`.
3. Delete `~/Library/Application Support/Canvas/` (boards, including archived ones, `open-boards.json`, `get-started.json`).
4. Delete the browser profile: `~/Library/WebKit/net.waldin.canvas/`, `~/Library/Caches/net.waldin.canvas/`, `~/Library/HTTPStorages/net.waldin.canvas*` (or first use Canvas › Clear Browsing Data…).
5. `defaults delete net.waldin.canvas` (export folder, lasso setting, window frames).
6. Delete `$(getconf DARWIN_USER_CACHE_DIR)net.waldin.canvas` and, in `$(getconf DARWIN_USER_TEMP_DIR)`, `net.waldin.canvas`, `canvas-renders`, `canvas-exports`, `canvas-gemini`.
7. Delete `~/.local/state/zmx/logs/canvas-obj_*.log`.
8. Remove the omp extension symlink `~/.omp/agent/extensions/canvas.ts`, and `~/.claude/plugins/data/canvas-inline` if you used Claude Code.
9. Optional, the agents' own: Codex's `trust_level` entries for your repos in `~/.codex/config.toml`, and `~/.canvas/compositions` if you or your agents wrote any.

Canvas edits no shell, agent or Ghostty config: Codex's hooks are a per-session override, not written to `~/.codex`. [contracts.md](contracts.md) "On-disk locations" lists every path.
