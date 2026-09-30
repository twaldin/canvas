# Changelog

Each version's section is its GitHub release's notes (release.yml puts it above the list of merged changes).

## 0.3.0 (unreleased)

Canvas is now Chalkwork: the same app under a new name. Its first launch brings a Canvas 0.2 install along.

### Upgrading from Canvas

1. Quit Canvas (its terminal sessions keep running), unzip `Chalkwork-0.3.0.zip`, move `Chalkwork.app` to `/Applications` and open it. The first launch moves `~/Library/Application Support/Canvas` to `~/Library/Application Support/Chalkwork` (every board, archived boards, the `pre-repo-migration/` backups, snapshots, open tabs) and `~/.canvas` (your compositions) to `~/.chalkwork`, moves the browser tiles' logins and site data, and brings over Canvas's settings and window frames. While Canvas is still running it moves nothing; quit Canvas and open Chalkwork again.
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
