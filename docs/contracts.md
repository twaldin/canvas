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

## Drawing layer

`.shape` and `.arrow` objects are drawn by `ShapeLayer` (`Sources/CanvasApp/Drawing/`), one view in document coordinates above every tile and below the Hyper outline. Geometry lives in `Sources/CanvasCore/Drawing*.swift`. Selection and moves of drawn objects are the scene's (see Scene seams); the layer supplies rendering, hit tests, outlines, resize handles, tools and editors, arrow routing, and region images.

- A shape's `frame` is exactly its drawn box (no title bar). Ink `points` are relative to the frame origin; the frame is the painted stroke bounds.
- An arrow's route is derived, never stored: bound ends attach to the facing edge of the bound object's current outline (the tile including its title bar, a shape's frame, the curve of an ellipse), so arrows follow moves and resizes without writes. An arrow's `frame` records its route bounds when it was drawn. Free ends (`{"point": [x, y]}`) are canvas coordinates. Deleting a bound object turns that end into a free point where it last attached, in the delete's undo step, so the arrow keeps its direction and its other end keeps following.
- The layer never takes keyboard focus (it stays with the prompt-target terminal); tool keys V/R/O/A/T/P/Esc arrive as key equivalents and only act when no terminal or text view has the keyboard. Inline text and arrow editors take focus while open and give it back on Enter/Esc/click-away, never over a responder that took focus meanwhile.
- Only strokes, text, labels, and fills (`fill: semi|solid`) take the mouse; an unfilled shape's interior passes clicks to the tiles beneath.
- `object.get --as image` on a drawn object renders the canvas region under it (tiles, terminals, and ink included).

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

## Note fences

A note's `markdown` is plain markdown; the code fence info string selects how the tile renders a fence (parsed by `NoteFence` in CanvasCore):

| Info string | Renders |
| --- | --- |
| `ts file=src/app.ts#L10-40` (`#L10`, `#L10-L40`; no range = whole file) | Live excerpt of the file with line numbers |
| `ts symbol=restoreSnapshot` / `swift file=Sources/Board.swift symbol=Board.update` | Live excerpt of the declaration (best-effort, language-agnostic; `Outer.inner` searches inside `Outer`; without `file=`, the first tracked file that declares it) |
| `… file=src/app.ts@1a2b3c4#L10-40` | Excerpt pinned to a commit (`git show`) |
| any anchored form plus `propose` | The fence body as a diff against the resolved range |
| anything else | Free-written (authored) code; `path:line` references in it open code tiles |

Anchor resolution, in order: a symbol that resolves wins; otherwise the line range is re-found by its first line (`anchor="first line text"`, or the text the tile captured when it first resolved the range), preferring the candidate whose following lines match best and the written position on ties, else by the fence body (a proposal's own lines vote for where they sit). A range that moved renders with "moved from L…"; one that can't be found renders a **stale** badge over the last text it showed.

The tile writes anchors back: when a line-range fence without `anchor=`, `symbol=`, or a pinned commit first resolves, it appends ` anchor="<first line>"` to the fence's info string in one `object.update`, so anchors survive restarts and agents see them. It skips first lines that can't be written (blank, or a backtick inside a backtick fence) and falls back to the in-memory capture. `commit=` must name a revision (`abc1234`, `HEAD~2`, `v1.0`); anything shaped like an option makes the fence stale.

Hyper-click on an excerpt or proposal row mentions `code` (object = the note, the row's real path and line, and `commit` for a pinned fence; an added proposal row mentions the line it would be inserted before, or the file's last line when appended at the end of the file); anywhere else mentions the note.

Code mentions carry the commit their lines are read against (`MentionTarget.code.commit`, schema `MentionTarget`): with `side: old` or no side, the commit whose version of `path` holds the lines (deleted diff rows, pinned excerpts); with `side: new`, the base the working-tree lines were diffed against; absent, the working tree. The context line names it from the mention alone, never from what the tile shows at drain time: `· diff vs merge-base 1a2b3c4` (the kind word comes from the tile's `diffBase`), `· diff vs merge-base 1a2b3c4, old side` for deleted rows with the excerpt read by `git cat-file blob <commit>:<path>`, and `· at 1a2b3c4` for a pinned excerpt without a side. `tray.drain` is therefore asynchronous.

## Git

All git in the app runs through `GitRunner.shared` (CanvasCore), which caps concurrent git processes at two, can cap stdout (`maxOutput`) and run time (`timeout`), stops git when the calling task is cancelled (a request still waiting for a slot just leaves the queue), and sets `GIT_OPTIONAL_LOCKS=0` so reads never contend with agents for the index lock. Git, file reads, and parsing run on GCD (`offPool`), never blocking a Swift concurrency thread. Code tiles diff through `GitDiffEngine.shared`: live tiles `retain(containing:)` their repository and `release` it when they go offscreen or away; held repositories keep resolved bases and an FSEvents stream that posts `Notification.Name.gitDiffBaseChanged` (object: the repository's top-level path) when a commit, checkout, rebase, or fetch moves a base.

## HTML tiles

- Each tile's page is `canvas-kit://html/<tileId>`, served by the tile's own scheme handler: the kit head (`resources/kit/canvas-kit.css`, `canvas-kit.js`, `vendor/tailwindcss-browser.js`) followed by `props.html`. `/kit/…` serves `resources/kit` (Mermaid loads from there only when a page has diagrams). DOM mentions of HTML tiles use that URL.
- Sandbox: non-persistent website data store per tile; a WKContentRuleList (WebKit's default rule list store, identifiers `canvas-html-<hash>`) blocks `http(s):`, `ws(s):`, and `file:` except `props.allowNetwork` hosts: `host` (any port), `host:port` (that port only; `:443`/`:80` also match the scheme's portless URL), `*.host` (the host and its subdomains). Exceptions pin the whole authority (no userinfo); other entries are ignored. A tile never loads with rules compiled for an allowlist that has since changed. The main frame never navigates away from its page; popups are refused.
- The only native access is the `canvas` script message handler (`window.webkit.messageHandlers.canvas.postMessage(msg)` → promise), accepted from the tile's own top-level page only. Each tile runs at most 4 messages at once with 64 more queued; beyond that a message is rejected (`too many outstanding requests`), and outstanding work is cancelled when the page re-renders or the tile detaches. Messages are strict (`Sources/CanvasCore/HtmlMessage.swift`: known `type`, only its fields, 64 KiB per message):

| `type` | Fields | Reply |
| --- | --- | --- |
| `code.excerpt` | `path`, `lines?` (`"N"`/`"N-M"`), `symbol?` | `SourceExcerpt` (`start`, `end`, `lines`, `language`, `stale`, `reason`, `truncated`) |
| `code.open` | `path`, `lines?`, `symbol?` | `{tile, created}`: re-aims the topmost non-follow code tile for `path`, else creates one beside the HTML tile |
| `state.get` | `key?` | `{value}` from `props.state` |
| `state.set` | `key` (`[A-Za-z0-9_.:-]{1,128}`), `value` (≤ 16 KiB, `null` deletes) | `{}`; `props.state` is capped at 256 KiB |
| `view.rendered` | `scrollY?` | `{}`; the tile refreshes its snapshot and remembers the scroll |

- Paths are board-relative; absolute paths, `~`, `..`, and symlinks resolving outside the board root are rejected.

## Lifecycle authority

- The omp extension is authoritative for omp tiles (`source: "canvas-omp"`).
- Claude Code and Codex hook scripts report with `source: "canvas-claude"` / `"canvas-codex"`.
- A report with a lower `seq` than the last accepted one from the same source is ignored.
- `done` is derived by the app: an `idle` report on a tile that has not been seen since it was last `working`.

## Ownership rules for slices

- The schema file is the only place API shape changes. Changing it means regenerating clients (`bun scripts/gen-clients.ts`) in the same change.
- Swift model types mirror the schema; a slice that needs a new field adds it to the schema first.
- No slice introduces a new socket, environment variable, or on-disk location without adding it here.
