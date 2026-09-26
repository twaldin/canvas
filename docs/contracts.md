# Canvas contracts

Interfaces every slice builds against. The API wire format and object model live in `schema/canvas-api.json`; this file covers what the schema can't express: sockets, environment, the Swift tile protocol, the mention context format, and ownership rules.

## Sockets

| Socket | Path | Speaks | Owner |
| --- | --- | --- | --- |
| Canvas API | `~/Library/Application Support/Canvas/canvas.sock` | `schema/canvas-api.json` | App |
| cmux browser subset | `~/Library/Application Support/Canvas/cmux.sock` | cmux v2 JSON lines, browser methods only | App (isolated, deletable) |

Both sockets are created with mode `0600`. The cmux subset lives on its own socket so it never shares method names with our API and can be removed in one step.

### cmux browser subset

Exactly what omp's cmux browser backend sends (`src/tools/browser/cmux/`), framed as cmux v2 JSON lines: requests `{"id","method","params"}`, replies `{"id","ok":true,"result"}` or `{"id","ok":false,"error":{"code","message"}}`. Surfaces are object ids: a terminal tile is the calling surface (`CMUX_SURFACE_ID`), a browser tile is a browser surface; workspaces are boards. Every browser result carries `surface_id`.

Surface and workspace ids stay `obj_…`/`brd_…` on the wire, which omp 18.3 accepts; omp ≤18.1's owner inspection (`surface.list` via its surface-observation module) requires UUID ids and is unsupported.

| Method | Params | Result |
| --- | --- | --- |
| `browser.open_split` | `url`, `surface_id` (caller), `workspace_id`, `focus` (ignored) | `surface_id`, `workspace_id`, `url`, `created_split`, `placement_strategy` — a browser tile beside the calling terminal |
| `browser.navigate` / `back` / `forward` / `reload` | `url` (navigate) | `url` |
| `browser.url.get` | — | `url`, `title` |
| `browser.eval` | `script` (an expression, page world) | `value` |
| `browser.snapshot` | `interactive`, `max_depth` | `snapshot` text, `refs` (`e1` → `{role,name}`), `page` (`title,url,ready_state`, plus `text,html` when not interactive) |
| `browser.screenshot` | — | `png_base64` (one pixel per CSS pixel), `width`, `height` |
| `browser.click` / `dblclick` / `hover` / `focus` / `check` / `uncheck` / `scroll_into_view` | `selector` (CSS or snapshot ref `@e3`) | — |
| `browser.type` / `browser.fill` | `selector`, `text` | — |
| `browser.press` | `key` (`Enter`, `Tab`, `Shift+Tab`, a character, …) | — |
| `browser.scroll` | `dx`, `dy` | `scroll_x`, `scroll_y` |
| `browser.wait` | one of `load_state` (`interactive`/`complete`), `url_contains`, `selector`; `timeout_ms` | `url` |
| `surface.list` | `surface_id` or `workspace_id` | `workspace_id`, `window_id` (null), `surfaces` (`id`, `type`, `title`, `url`) |
| `surface.close` | `surface_id` (browser only) | — |

Error codes: `invalid_params`, `not_found`, `method_not_found`, `unauthorized`, `timeout`, `js_error`, `unavailable`. The plain-text line `auth <password>` answers `OK: …` or `ERROR: …`.

## Terminal tile environment

Every terminal tile's process (inside zmx) gets:

| Variable | Value |
| --- | --- |
| `CANVAS_ENV` | `1` |
| `CANVAS_SOCKET` | Canvas API socket path |
| `CANVAS_TILE_ID` | This tile's object id |
| `CANVAS_BOARD_ID` | This board's id |
| `CANVAS_BOARD_ROOT` | Board root directory |
| `CMUX_SOCKET_PATH` | cmux subset socket path |
| `CMUX_SURFACE_ID` | This tile's object id |
| `CMUX_WORKSPACE_ID` | This board's id |
| `CMUX_SOCKET_PASSWORD` | Only when the app was launched with it; the cmux socket then requires `auth <password>` |

Integrations report only when `CANVAS_ENV=1` and the variables they need are present, so they are no-ops outside the app.

zmx session names: `canvas-<tileId>`, labelled `canvas.board=<boardId> canvas.tile=<tileId>`. Names stay short because zmx sockets live under `$TMPDIR/zmx-<uid>` (a long `/var/folders/…` path for GUI apps) and a socket path is capped at 104 bytes. Tiles inherit the app's `TMPDIR`, so `zmx list` inside a tile shows canvas sessions.

## On-disk locations

| Path | Holds | Owner |
| --- | --- | --- |
| `~/Library/Application Support/Canvas/boards/<boardId>.json` | Stored boards (`CANVAS_HOME` relocates the whole directory) | App |
| `<board root>/.canvas/board.json` | `board.export` snapshot (default path), for committing with the repo | Written on request only |
| `clients/python/canvas_sdk/builtin_compositions/`, `clients/ts/src/builtin_compositions/` | Shipped compositions, installed with each client (wheel, bundle, checkout) | Canvas |
| `~/.canvas/compositions/` | The user's and agents' own compositions; searched first, so they shadow shipped ones | User/agents |
| `skills/canvas/` (repo, or the bundle's `Resources/`) | The shipped agent skill; the omp extension announces it only when `CANVAS_ENV=1` | Canvas |

## Compositions

A composition is a module in a compositions directory. Functions whose first parameter is named `canvas` receive the connected client (all API namespaces plus `compositions`); other exports pass through unchanged. Python: `canvas.compositions.<name>.<fn>(…)`, `available()`, `reload()`. TypeScript: `client.compositions.<name>.<fn>(…)` (same surface; a file added to an already-loaded directory needs a new process because Bun caches directory listings).

## Object model rules

- Ids are prefixed: `brd_` board, `obj_` object, `men_` mention.
- `frame` is in canvas coordinates (points at 100% zoom). `z` orders siblings.
- `rev` increments on every change; `object.update` with a stale `rev` fails with `conflict`.
- `createdBy`/`updatedBy` record the actor. An agent is identified by its terminal tile.
- Deleting an object removes every staged mention that targets it.
- A board belongs to one root directory; code paths are stored relative to it.

## Swift tile protocol

Every tile's content view conforms to `TileContent` (`Sources/CanvasApp/TileContent.swift`); `TileFrameView` supplies the shared chrome (title bar, drag, resize, lifecycle badge, zoomed-out card) and `TileFactory` maps an object type to its content view.

```swift
@MainActor
protocol TileContent: NSView {
    func setLive(_ live: Bool)                                  // false: detach heavy resources, show snapshot()
    func snapshot() -> NSImage?                                  // cheap image for zoomed-out cards; nil draws a title card
    func mentionTarget(at point: NSPoint) -> MentionTarget?      // what a Hyper-click here mentions (element level)
    func outline(for target: MentionTarget) -> NSRect?           // hover highlight, in this view's coordinates
    var takesKeyboardFocus: Bool { get }                         // terminal, browser: true; code, note, HTML: false
    func update(_ object: CanvasObject)                          // a new revision of the backing object
}
```

Arrows, shapes, and groups have no tile; the canvas draws them.

Tiles never read or write the board store directly; they go through the board model on the main actor, which persists and broadcasts events.

## Scene seams

`CanvasView` (`Sources/CanvasApp/CanvasView.swift`) owns selection, moves, groups, attention markers, and the viewport. Drawn objects (shapes, arrows) have no view of their own; the drawing layer plugs in through:

| Seam | Direction | Meaning |
| --- | --- | --- |
| `installShapeLayer(_:)` | drawing → scene | Adds the drawing layer above tiles, below attention markers and the overlay; restacking keeps it there. |
| `shapeHitTest(docPoint) -> ObjectID?` | drawing → scene | Drawn object under a point (strokes, text, fills). Plain clicks there select it and drag the selection; Hyper-clicks mention it. |
| `shapeOutline(id) -> NSRect?` | drawing → scene | Committed document rect, for rings and hover outlines. |
| `drawingOwnsPoint(docPoint) -> Bool` | drawing → scene | True while a tool is active or over a shape handle; scene selection, marquee, and moves stand down. |
| `moveProps(object, dx, dy) -> JSONValue?` | drawing → scene | Props merged into a drawn object's move update (e.g. free arrow endpoints). |
| `onSelectionDrag(ids, offset)` | scene → drawing | Live drag offset in document points; `.zero` just before the move commits. |
| `selection`, `onSelectionChange` | scene → all | Current selection (tiles, drawn objects, groups). |

Groups (`type: group`, props `{members, name?}`, frame = union of member frames) are drawn by the scene as regions behind their members. `focus(tile:)` zooms a tile to 100%, centers, selects, and focuses it; `raiseAttention(_:message:)` backs `view.attention`.

## Undo

`Board.history` records every create, update, and delete from any actor; ⌘Z (`Board.undo()`) reverts the latest step even when an agent made it, and every undo or redo is a new revision, newer than any the object ever had, even across a delete and re-creation. Terminal bookkeeping props (`lifecycle`, `agent`, `title`) are never recorded and never rewound. Multi-object gestures wrap their updates in `Board.transaction { }` to form one step. Undoing a delete restores the object with the same id and `z`; staged mentions of it are not restored. When undo/redo removes a terminal and later brings it back, it returns with the bookkeeping it last had. History lives in memory only.

## Mention context format

`tray.drain` returns a `context` string that the omp extension injects as hidden context with the submitted prompt. Shape:

```text
<canvas-mentions board="brd_…" root="/path/to/repo">
[1] code src/snapshot/restore.ts:41-48 (symbol restoreSnapshot) · tile obj_… · diff vs merge-base 1a2b3c4
    39   
    40   /** Rehydrates a board from its saved snapshot. */
  > 41   export async function restoreSnapshot(id: string) {
  > 42     const snapshot = await loadSnapshot(id);
    …
[2] dom http://localhost:3000/login · button#submit "Sign in" · browser tile obj_…
[3] shape rect obj_… "auth path?" (drawn by user) · encloses obj_…, obj_… · arrow → obj_… (hypothesis_about)
Read more with the canvas SDK or CLI: canvas get <id> --as graph|image
</canvas-mentions>
```

Rules: numbered in staging order; each entry is one location line plus an optional short excerpt (at most 12 lines: mentioned lines marked `>`, with up to 3 unmarked lines of surrounding context while it fits); edited-since-staging entries are marked `(edited)`; the block is omitted entirely when the tray is empty.

## Lifecycle authority

- The omp extension is authoritative for omp tiles (`source: "canvas-omp"`).
- Claude Code and Codex hook scripts report with `source: "canvas-claude"` / `"canvas-codex"`.
- A report with a lower `seq` than the last accepted one from the same source is ignored.
- `done` is derived by the app: an `idle` report on a tile that has not been seen since it was last `working`.

## Ownership rules for slices

- The schema file is the only place API shape changes. Changing it means regenerating clients (`bun scripts/gen-clients.ts`) in the same change.
- Swift model types mirror the schema; a slice that needs a new field adds it to the schema first.
- No slice introduces a new socket, environment variable, or on-disk location without adding it here.
