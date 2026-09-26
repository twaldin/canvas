# Canvas contracts

Interfaces every slice builds against. The API wire format and object model live in `schema/canvas-api.json`; this file covers what the schema can't express: sockets, environment, the Swift tile protocol, the mention context format, and ownership rules.

## Sockets

| Socket | Path | Speaks | Owner |
| --- | --- | --- | --- |
| Canvas API | `~/Library/Application Support/Canvas/canvas.sock` | `schema/canvas-api.json` | App |
| cmux browser subset | `~/Library/Application Support/Canvas/cmux.sock` | cmux v2 JSON lines, browser methods only | App (isolated, deletable) |

Both sockets are created with mode `0600`. The cmux subset lives on its own socket so it never shares method names with our API and can be removed in one step.

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

Integrations report only when `CANVAS_ENV=1` and the variables they need are present, so they are no-ops outside the app.

zmx session names: `canvas-<tileId>`, labelled `canvas.board=<boardId> canvas.tile=<tileId>`. Names stay short because zmx sockets live under `$TMPDIR/zmx-<uid>` (a long `/var/folders/…` path for GUI apps) and a socket path is capped at 104 bytes. Tiles inherit the app's `TMPDIR`, so `zmx list` inside a tile shows canvas sessions.

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

## Drawing layer

`.shape` and `.arrow` objects are drawn by `ShapeLayer` (`Sources/CanvasApp/Drawing/`), one view in document coordinates above every tile and below the Hyper outline. Geometry lives in `Sources/CanvasCore/Drawing*.swift`.

- A shape's `frame` is exactly its drawn box (no title bar). Ink `points` are relative to the frame origin; the frame is the painted stroke bounds.
- An arrow's route is derived, never stored: bound ends attach to the facing edge of the bound object's current outline (the tile including its title bar, a shape's frame, the curve of an ellipse), so arrows follow moves and resizes without writes. An arrow's `frame` records its route bounds when it was drawn. Free ends (`{"point": [x, y]}`) are canvas coordinates.
- Only strokes, text, labels, and fills (`fill: semi|solid`) take the mouse; an unfilled shape's interior passes clicks to the tiles beneath.
- `CanvasView` seams the layer sets: `shapeHitTest`, `shapeOutline`, `drawingOwnsPoint` (a drawing tool is active or the point is a resize handle), `moveProps` (an arrow's free ends move with it), `onSelectionDrag` (live move preview), `onSelectionChange`, and `installShapeLayer`.
- `object.get --as image` on a drawn object renders the canvas region under it (tiles, terminals, and ink included).

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
