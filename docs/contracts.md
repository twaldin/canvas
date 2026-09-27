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

A page an agent is driving stays visible to WebKit for 60 s after its last command, even when its tile is offscreen or the window is on another Space or covered: `requestAnimationFrame`, timers and `IntersectionObserver` run as they would for a user. Then the tile's normal detach/release policy resumes.

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

zmx session names: `canvas-<tileId>`, labelled `canvas.board=<boardId> canvas.tile=<tileId> canvas.home=<support dir path, every byte outside [A-Za-z0-9._-] as _>` (zmx label values allow only those characters). `canvas.home` names the instance that created the session: board copies in another home (replicas, dev instances) carry the same ids, so `scripts/dev.sh stop` kills only sessions labelled with its own home. Because `zmx attach --labels` relabels a session that already exists, a tile never attaches to or ends a session labelled for another home (`TerminalTile.ownerGuard` runs before `attach` and `kill`): the copy's tile says whose session it is instead of taking it over. `scripts/dev.sh` trusts a `pid` file only while that process owns the home's socket, since a copied home carries the original's pid file. Names stay short because zmx sockets live under `$TMPDIR/zmx-<uid>` (a long `/var/folders/…` path for GUI apps) and a socket path is capped at 104 bytes. Tiles inherit the app's `TMPDIR`, so `zmx list` inside a tile shows canvas sessions.

## Client connection

The Python SDK, TS client, and CLI find the socket in this order: an explicit value (`connect(socket=…)`, `new CanvasClient({ socketPath })`), then `CANVAS_SOCKET`, then `~/Library/Application Support/Canvas/canvas.sock` only if that file exists; otherwise they fail with `unavailable`, naming `CANVAS_SOCKET`, the path checked, and the explicit-connect fix. `caller` and `board` come from the client's own tile/board (explicit, else `CANVAS_TILE_ID`/`CANVAS_BOARD_ID` at construction). omp's `eval` Python kernel runs with an allowlisted environment that drops `CANVAS_*`, so the omp extension prints the explicit `connect(...)` line in the system prompt.

Connection failures are always `unavailable`; clients never surface raw socket errors. A request that never left (connect failed, write failed, or its newline was unflushed when the connection closed) is sent once more on a fresh connection after waiting up to 15 s for the socket (an app restart). A request that left and lost its reply is not resent: `unavailable: … it may or may not have applied — re-read before retrying`. Image methods (`view.render`, `view.snapshot`) take `out` as an absolute path the app writes (format by extension, png or jpg); clients resolve a relative `out` against their cwd. Without `out` the app writes a new file under `$TMPDIR/canvas-renders/` (`ApiRouter.scratchImages`, out of the user's repo); the result's `path` names the file either way, and images never travel inline.

The app writes replies and events through a per-connection queue, in order, and never blocks on a slow reader. An `events.subscribe` client that stops reading can't freeze the canvas; one that falls more than 32 MB behind is disconnected.

## Activity log

`board.history` reads `Board.activity` (`Sources/CanvasCore/ActivityLog.swift`): in memory, the newest 2000 entries per board, restarted with a `restart` entry when the app opens the board. Board mutations log themselves with their actor (`caller` → `agent:<tile>`, none → `user`, the app's own write-backs → `system`; undo/redo → `user`, prefixed `undo:`/`redo:`). Cascades of a change (a group re-fit to its members, an arrow end freed because its bound object was deleted) are credited to that change's actor and carry a `cause`; within one revision each object gets one cascade entry, amended to its net change (dropped when the changes cancel out), so a batch that moves or deletes 40 members of a lane logs the lane once. Terminal bookkeeping (lifecycle, session, title) is never logged. Follow re-aims log one `follow` entry, not the create/update beneath. The canvas reports viewport and selection changes continuously; the log records them once they have been still for 0.8 s and differ from the last logged state.

## On-disk locations

| Path | Holds | Owner |
| --- | --- | --- |
| `~/Library/Application Support/Canvas/boards/<boardId>.json` | Stored boards (`CANVAS_HOME` relocates the whole directory) | App |
| `~/Library/Application Support/Canvas/open-boards.json` | Roots of the boards open as tabs, in tab order; reopened behind the initial board at launch (quitting keeps it; closing a tab removes its root) | App |
| `<board root>/.canvas/board.json` | `board.export` snapshot (default path), for committing with the repo | Written on request only |
| `clients/python/canvas_sdk/builtin_compositions/`, `clients/ts/src/builtin_compositions/` | Shipped compositions, installed with each client (wheel, bundle, checkout) | Canvas |
| `~/.canvas/compositions/` | The user's and agents' own compositions; searched first, so they shadow shipped ones | User/agents |
| `skills/canvas/` (repo, or the bundle's `Resources/`) | The shipped agent skill; the omp extension announces it only when `CANVAS_ENV=1` | Canvas |

## Compositions

A composition is a module in a compositions directory. Functions whose first parameter is named `canvas` receive the connected client (all API namespaces plus `compositions`); other exports pass through unchanged. Python: `canvas.compositions.<name>.<fn>(…)`, `available()`, `reload()`. TypeScript: `client.compositions.<name>.<fn>(…)` (same surface; a file added to an already-loaded directory needs a new process because Bun caches directory listings).

## Object model rules

- Ids are prefixed: `brd_` board, `obj_` object, `men_` mention.
- `frame` is in canvas coordinates (points at 100% zoom) and is the whole box the object draws: a tile's includes its `RenderMath.tileTitleHeight` (26 pt) title bar at the top, and its content (the body, what `TileRenderRequest.size` and `contentSize` describe) is the frame below it (`RenderMath.body`). Measure, fit, groups, placement, `layout.*`, arrow attachment, and `view.render` pixel rects all use this one box. `z` orders siblings.
- Stored boards carry `format` (`Board.format`, 2). A board without it (format 1 stored a tile's body, its title bar drawn above) loads with every tile frame 26 pt taller, the same box on screen; saving writes format 2.
- `rev` increments on every change; `object.update` with a stale `rev` fails with `conflict`.
- `createdBy`/`updatedBy` record the actor. An agent is identified by its terminal tile.
- Deleting an object removes every staged mention that targets it.
- A board belongs to one root directory; code paths are stored relative to it.
- `props.scale` (tiles and text shapes; `ObjectScale`, 0.25–8, absent = 1) magnifies the object's drawing inside its frame. A tile lays out at its natural frame (`CanvasObject.naturalFrame`, the frame ÷ scale; `RenderMath.body(of:)` is the natural body) and `TileFrameView` sets its bounds to frame ÷ scale, so title bar, content, hit testing, and mentions all work in natural points; renders draw the natural rect under the scale. A text shape's font is `DrawingStyle.textSize` × scale. What agents get is in canvas points: `object.measure` and `size: "fit"` (laid out at `width` ÷ scale, times scale), `layout.check` overflow, `view.render` `contentSize`/`overflow`, and line anchors (`CodeMetrics.lineY`). A mention's "over" region is in the host tile's own points. The user scales with ⌥-drag on a tile's corner, a text shape's corner, or the Scale menu (`CanvasView.scaleSelection`); each changes frame and scale together (`ObjectScale.rescaled`: natural size kept, top-left fixed) in one undo step. Liveness and zoomed-out handles use the effective zoom, magnification × scale.
- A group's `frame` is derived: its members' bounds (arrows excluded) plus `padding` and a `GroupSpec.titleHeight` title band, recomputed by `Board` in the same undo step as any change to a member's frame (nested groups outward), and on load. Frames written to a group are ignored. Stored groups labelled by the old `name` prop load with it as `title`.

## Layout

`object.measure`, `size: "fit"`, `layout.place`/`stack`/`translate`/`grid`, `object.batch`, and `layout.check` live in CanvasCore (`ObjectMeasure`, `Layout`, `Board.atomically`). Measured sizes are whole object frames, tile title bar included: code follows `CodeMetrics` (`ObjectMeasure.code`: as wide as the range's longest line up to the max width, `width` or `CodeMetrics.defaultFitWidth` = 960 pt, about 120 columns; longer lines wrap and count in the height; `layout.check` measures code at its frame's width), notes (an `object.create` of a note without a frame height is fitted like `size: "fit"`, at `frame.w` or `ObjectMeasure.defaultNoteWidth`; `title` only names the tile) lay out `NoteRenderer` output with TextKit 2 at the note tile's own insets (`ObjectMeasure.note`, `noteInset`; `NoteRenderer`, `NoteLayout`, and `DrawingStyle` are in CanvasCore for this), text shapes use `DrawingStyle`'s font. Measuring reads files, so `object.measure`, a `size: "fit"` create/update, `object.batch`, and `layout.check` are resolved asynchronously; a batch measures every op first, then applies all of them synchronously inside `Board.atomically`, so no other request interleaves with its writes. `Board.atomically { }` is one undo step and one board revision; when its body throws, the changes it made are reverted (announced as normal changes, not recorded) and the error is rethrown. Layout ops move objects through one private `Board.shift` (groups by their leaf members, each object once) inside `Board.deferringRefits { }`, which holds group re-fits until the op's end and then re-fits each affected group once; group frames are stale only inside that scope. Batch side effects stay per revision, not per op, in the app too: `avoid` arrows, whose routes depend on every tile, re-route once after a burst of changes (`ShapeLayer.rerouteAvoiding`: next main-queue turn or before the layer draws or renders), keeping the drawn route until then.

`layout.check` judges what is drawn: tile frames are whole tiles; arrows route with `BoardGeometry.routes(rows:)` (a value snapshot of the board taken when the call arrives, computed off the main actor) (line-bound ends by the model scroll rule, over each bound code tile's rows as it wraps them at its frame width: `CodeRows(file:width:)`); labels are placed exactly as the drawing layer places them (`DrawingStyle.arrowLabel` for the chip size, `DrawingGeometry.labelRect` against `BoardGeometry.blocksRoutes` objects, `BoardGeometry.labelRects`) and reported as `labelOverlaps` when they lie on a blocking object (their own ends included) or another label. Unfilled rects and ellipses are annotations (a box drawn around or across things): like ink and arrows they never take part in `overlaps`. Code overflow compares the range's rows (`ObjectMeasure.codeRows`) with the frame; a caption wider than the frame (`ObjectMeasure.captionWidth`, the header's own `CodeCaption.string` and `CodeMetrics.captionInset`) is `truncated`, not overflow; follow tiles (`followOf`) are fixed-size viewers and are skipped for both.

## Swift tile protocol

Every tile's content view conforms to `TileContent` (`Sources/CanvasApp/TileContent.swift`); `TileFrameView` supplies the shared chrome (title bar, drag, corner resize and ⌥-drag scale, lifecycle badge, zoomed-out card) and `TileFactory` maps an object type to its content view.

```swift
@MainActor
protocol TileContent: NSView {
    func setLive(_ live: Bool)                                  // false: detach heavy resources, show the card
    var liveZoom: CGFloat { get }                                // below this zoom the tile is its card (default 0.3; terminals 0.15)
    func render(_ request: TileRenderRequest) async -> TileRender   // offscreen image for view.render
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void)  // default: render at card scale
    func whenLiveReady(_ ready: @escaping @MainActor () -> Void)  // just made live: call once the live view is drawn (default: at once)
    func showSnapshot(_ show: Bool)                              // view.snapshot: cover Metal/WebKit content
    func mentionTarget(at point: NSPoint) -> MentionTarget?      // what a Hyper-click here mentions (element level)
    func outline(for target: MentionTarget) -> NSRect?           // hover highlight, in this view's coordinates
    var takesKeyboardFocus: Bool { get }                         // terminal, browser: true; code, note, HTML: false
    func update(_ object: CanvasObject)                          // a new revision of the backing object
}
```

`render` draws the content offscreen for `view.render`, independent of liveness, window, Space, and viewport: from the tile's model (or an AppKit view that draws itself anywhere, like a code tile's header, drawn offscreen), never by capturing what is on screen. `TileRenderRequest` = `size` (the body in points: the frame below the title bar), `scale` (pixels per point), `full` (the whole content, not the frame's window), `appearance` (resolve colors under it). `TileRender` = `image` (points, top-left at the body; `max(size, contentSize)` when full), `contentSize` (the content's extent at that width; overflow = content − size; a code tile's is its range, `CodeDocument.content`, which is what `size: "fit"` sizes), `state` (`rendered`, or `placeholder`/`failed` with a `reason`; never `rendered` with a blank image). The renderer cancels a render at the request's deadline (tiles should return what they have when cancelled) and reports a tile that still hasn't answered a second later as a placeholder. Tile chrome (title bar, border) is drawn around the image by the renderer; app chrome never is.

Zooming never redraws the scene: everything in the document (tiles, groups with their titles and borders, drawings, selection rings) is drawn in document coordinates and scales with the canvas, so its size relative to everything else never changes. Only window chrome (toolbar, tray, pills, edge chevrons), the dot grid, shape resize handles, and attention markers stay screen-sized. Markers (`AttentionMarker`) live in `AttentionLayer`, a window-space view over the scroll view that passes clicks through except on a bubble; `CanvasView.layoutMarkers` places each around its object's on-screen rect on every bounds change (each pan and live-pinch step), so a marker tracks the zoom continuously and keeps its fixed size. Cards are what the live tile shows: code cards draw the tile's own header view offscreen (`CodeHeaderBar.prepareForSnapshot`, its real controls) above rows drawn from the model at the tile's scroll; HTML cards are the live page's last capture. Going live, `TileFrameView` keeps the card over the content, which renders beneath it, until `whenLiveReady` fires (HTML: the page's first `view.rendered` after it attaches, once WebKit has presented that frame, `WebStage.afterNextPresentationUpdate`; browser: the page loaded and presented), at most `TileFrameView.revealLimit` (2 s).

Arrows, shapes, and groups have no tile; the canvas draws them.

Tiles never read or write the board store directly; they go through the board model on the main actor, which persists and broadcasts events.

### Code navigation

Code views get language features by conforming to `CodeNavigationHost` (`Sources/CanvasApp/CodeNavigation.swift`) and attaching a `CodeNavigation(host:board:tile:accessories:reservedWidth:)`:

```swift
@MainActor
protocol CodeNavigationHost: AnyObject {
    var navigationPath: String { get }                           // board-relative path of the file shown
    var navigationView: NSView { get }                           // the view showing rows; its coordinates are the host's document coordinates
    var navigationLineHeight: CGFloat { get }                    // row height, so panels open below the hovered line
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)?  // point in navigationView; 1-based line, 0-based UTF-16 column (a wrapped line's continuation rows map past the break); nil on peeked base rows/gutters
    func reveal(line: Int)                                       // scroll a 1-based line into view
    func aim(at lines: LineRange)                                // a same-file definition: the user's own re-aim (never held by the follow lock)
}
```

The controller adds a hover tracking area to the view only while `setActive(true)` (hosts deactivate it when the tile goes not live: tracking areas on hidden tiles are rebuilt on every frame of a pan), handles ⌘/⌥⌘-click and right-click on it through an app-level event monitor (Hyper stays with `HyperMonitor`), extends the view's own `menu(for:)` rather than replacing it, and places an Outline button in the host's header (`accessories:`), inside the trailing `reservedWidth` points the host keeps free (`CodeHeaderBar.reservedTrailing`). Hosts call `contentChanged()` when they scroll or show new content, which dismisses hover and panels.

### Code tiles

One view per tile, no modes: the whole file (the base version for a deleted file), scrolled to `props.range`, the range tinted only while the tile shows rows outside it (`CodeMetrics.tintsRange`: a tile fitted to its range, or a whole-file range, shows no tint; live, cards, and renders alike). Geometry is `CodeMetrics` (CanvasCore): fixed 16 pt rows, the 12 pt system monospaced font (every column `charAdvance` wide, tabs to 4 columns, East Asian wide characters and surrogate pairs 2), a gutter of line numbers plus a sign column, and header/caption/history strip heights; `object.measure` uses the same numbers. Rows soft-wrap at the tile's text width (`CodeMetrics.textColumns`, `CodeMetrics.wrap`): a line wider than the text column continues on rows with no line number (a faint ↪ instead), its gitsign continuing down the gutter, and its text indented by the line's own indentation plus 2 columns (at most half the row); tabs expand against the unwrapped line and breaks never split a surrogate pair. Nothing scrolls sideways. A resize by the user rewraps live, keeping the top line in place; any other change of the tile's natural size (an agent's `object.update` frame or `size: "fit"`, undo) re-aims the scroll at the range by `CodeMetrics.scrollOffset` (`CodeTile.resizedElsewhere`, called by `CanvasView` when the content's size changed under it), so a fitted tile shows exactly its range. The model is CanvasCore's `CodeDocument` (built off the main thread from `GitDiffEngine`'s `FileDiff`): `GitSign`s from the diff's change records (added bar, modified bar, deleted wedge on the top edge of the line after the deletion, `lineCount + 1` at the end of the file), per-line highlight runs (`SyntaxLines`) for both sides, and the header's status and warning (`noBase`: no commits yet / no default branch / no merge-base, `diffTooLarge`, deleted). `CodeRows` inserts peeked base lines above the lines that replaced them (entries: logical rows) and maps entries to visual rows (wrapped entries take several): `row(_:)`/`segment(_:)` give a visual row's logical line and slice, `index(ofLine:)` a line's first visual row, `rows(ofLine:)` all of them; `WrapText` measures each line's columns once per load so rewrapping skips lines that fit. Selections are `CodeRows.Position`s (entry + UTF-16 offset), so they survive rewraps and ⌘C copies logical lines; mentions, LSP positions, range tint, edit flash, peeks, hunk jumps, `reveal`, and `aim` all go through the same mapping, and cards, `render`, and the live view draw through one `CodePainter`. `CodeEdits.changes` diffs the texts of consecutive loads of the same file: those rows flash for 3 s (a follow tile also jumps to the first). A tile with `pinnedCommit` shows the file as of that commit instead (`GitDiffEngine.pinned`: `rev-parse` then `cat-file blob`, `FileDiff.State.pinned`, or `.pinUnavailable` with the reason as its notice): no signs, no base picker or change stepping, no Edit Here, header status `pinned at <sha7> (<revision>) · read-only`, and its mentions carry the commit (no side), so they quote those lines; `object.measure`, `layout.check`, and line anchors read the same text (`NoteSource.read` with the commit). `FollowLock` holds a follow tile's re-aims for 10 s after the user scrolls, clicks, or selects in it, counting them ("N new ▸"), then shows the newest.

The view draws only visible rows (a CTLine per visible row, cached only while visible) and scrolls itself, with no NSScrollView; not live, it keeps no line cache, layer contents, tracking areas, or views in the window, and cards, `snapshot()`, and `render(_:)` draw rows straight from the model.

Mentions: a row is the line on the side it shows; a sign in the gutter is the whole change (a deletion: its base lines, `side: old`); a peeked row is a base line (`side: old`, `commit` = the base). While a tile shows changes against a base, its new-side mentions carry `side: new` and that base's commit.

## Drawing layer

`.shape` and `.arrow` objects are drawn by `ShapeLayer` (`Sources/CanvasApp/Drawing/`), one view in document coordinates above every tile and below the Hyper outline. Geometry lives in `Sources/CanvasCore/Drawing*.swift`. Selection and moves of drawn objects are the scene's (see Scene seams); the layer supplies rendering, hit tests, outlines, resize handles, tools and editors, arrow routing, and region images.

- A shape's `frame` is exactly its drawn box (no title bar). Ink `points` are relative to the frame origin; the frame is the painted stroke bounds.
- An arrow's route is derived, never stored: bound ends attach to the facing edge of the bound object's current outline (a tile's frame, a shape's frame, the curve of an ellipse), so arrows follow moves and resizes without writes. An end bound to `lines` of a code tile is a row end (`ArrowEnd.row`): it attaches to the tile's left or right edge (right unless the other end lies wholly left) at the first visual row of `lines.start` (wrapped lines above it push it down), `CodeMetrics.lineY`: live, the tile's rows as scrolled (`CodeTile.lineY`; the tile posts `CodeTile.rowsMoved` and the layer re-routes), and in the model (`BoardGeometry.routes`, `layout.check`) the tile freshly aimed by `CodeMetrics.scrollOffset`, the same rule `CodeTile` scrolls by (range start with up to 3 rows of context, fewer when the viewport can't show them and the range). A line out of view clamps to the top of the rows or the bottom of the tile. Orthogonal routes with a row end leave sideways, looping around the right edges when the two tiles overlap horizontally; `avoid` uses only the two side ports. `lines` on other tiles binds the whole tile. `DrawingGeometry.path` (CanvasCore) routes by `props.route`: `straight`, `orthogonal` (one jog between facing sides), or `avoid` (an orthogonal grid search around every object `BoardGeometry.blocksRoutes`: tiles, text, filled shapes, keeping `avoidMargin`). Arrows bound to the same two objects in either direction get `parallelOffsets` (`parallelSpacing` apart, relative to each arrow's direction, so opposite arrows take opposite sides); labels go beside the route on the offset's side (`labelRect`), at the first spot clear of tiles. The caption is `label`, else `relation` in the secondary color when `label` is absent; `label: ""` draws none (`DrawingStyle.arrowLabel`). The layer draws, hit-tests, and selects the routed polyline; `BoardGeometry.routes()` computes the same routes from frames for `layout.check` and detaching. An arrow's `frame` records its route bounds when it was drawn. Free ends (`{"point": [x, y]}`) are canvas coordinates. Deleting a bound object turns that end into a free point where it last attached, in the delete's undo step, so the arrow keeps its direction and its other end keeps following.
- The layer never takes keyboard focus (it stays with the prompt-target terminal); tool keys V/R/O/A/T/P/Esc arrive as key equivalents and only act when no terminal or text view has the keyboard. Inline text and arrow editors take focus while open and give it back on Enter/Esc/click-away, never over a responder that took focus meanwhile.
- Only strokes, text, labels, and fills (`fill: semi|solid`) take the mouse; an unfilled shape's interior passes clicks to the tiles beneath.

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

Groups (`type: group`, props `{members, title?, color?, padding?}`, frame derived by the board, see Object model rules) are drawn by the scene as titled, tinted regions behind their members (`GroupView`), following members live mid-drag with the same `GroupSpec.frame`; only the title band takes the mouse. Title and border are in document space like everything else. `focus(tile:)` zooms a tile to 100%, centers, selects, and focuses it; `raiseAttention(_:message:)` backs `view.attention`. Every user viewport jump (`go(to:)`, `zoomToFit()`, `zoomToActualSize()`, `focus(tile:)`, `jumpToAttention(_:)`, `reveal(_:)`, entering a group, opening a board) aims at the clear area between the floating toolbar and the tray (`chromeInsets`, measured by the window controller, plus a 12 pt margin); the geometry is `Layout.fit`/`center`/`reveal` (CanvasCore).

## Undo

`Board.history` records every create, update, and delete from any actor; ⌘Z (`Board.undo()`) reverts the latest step even when an agent made it, and every undo or redo is a new revision, newer than any the object ever had, even across a delete and re-creation. Terminal bookkeeping props (`lifecycle`, `agent`, `title`) are never recorded and never rewound. Multi-object gestures wrap their updates in `Board.transaction { }` to form one step; API writes that must succeed or fail together (`object.batch`, `layout.*`) use `Board.atomically { }`, which also rolls back on error. Repeated updates of one object within a step collapse into one recorded change (first before, last after), never across an `atomically` mark. Undoing a delete restores the object with the same id and `z`; staged mentions of it are not restored. When undo/redo removes a terminal and later brings it back, it returns with the bookkeeping it last had. History lives in memory only.

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
[4] shape ellipse obj_… (drawn by user) · over browser obj_… at (240, 200) 125×120
Read more with the canvas SDK or CLI: canvas get <id> --as graph; look with canvas render <id>
</canvas-mentions>
```

Rules: numbered in staging order; each entry is one location line plus an optional short excerpt (at most 12 lines: mentioned lines marked `>`, with up to 3 unmarked lines of surrounding context while it fits); edited-since-staging entries are marked `(edited)`; the block is omitted entirely when the tray is empty. A shape drawn on top of something names the topmost object under it that contains it (`over <type> <id>`) and where, in that object's local board units (a browser tile's page starts below its 32 pt address bar).

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

Code mentions carry the commit their lines are read against (`MentionTarget.code.commit`, schema `MentionTarget`): with `side: old` or no side, the commit whose version of `path` holds the lines (peeked base rows, deleted files, pinned excerpts); with `side: new`, the base the working-tree lines were diffed against; absent, the working tree. The context line names it from the mention alone, never from what the tile shows at drain time: `· diff vs merge-base 1a2b3c4` (the kind word comes from the tile's `diffBase`), `· diff vs merge-base 1a2b3c4, old side` for peeked base rows with the excerpt read by `git cat-file blob <commit>:<path>`, and `· at 1a2b3c4` for a pinned excerpt without a side. `tray.drain` is therefore asynchronous.

## Git

All git in the app runs through `GitRunner.shared` (CanvasCore), which caps concurrent git processes at two, can cap stdout (`maxOutput`) and run time (`timeout`), stops git when the calling task is cancelled (a request still waiting for a slot just leaves the queue), and sets `GIT_OPTIONAL_LOCKS=0` so reads never contend with agents for the index lock. Git, file reads, and parsing run on GCD (`offPool`), never blocking a Swift concurrency thread. Code tiles diff through `GitDiffEngine.shared`: live tiles `retain(containing:)` their repository and `release` it when they go offscreen or away; held repositories keep resolved bases and an FSEvents stream that posts `Notification.Name.gitDiffBaseChanged` (object: the repository's top-level path) when a commit, checkout, rebase, or fetch moves a base.

## HTML tiles

- Each tile's page is `canvas-kit://html/<tileId>`, served by the tile's own scheme handler: the kit head (`resources/kit/canvas-kit.css`, `canvas-kit.js`, `vendor/tailwindcss-browser.js`) followed by `props.html`. `/kit/…` serves `resources/kit` (Mermaid loads from there only when a page has diagrams). DOM mentions of HTML tiles use that URL.
- Sandbox: non-persistent website data store per tile; a WKContentRuleList (WebKit's default rule list store, identifiers `canvas-html-<hash>`) blocks `http(s):`, `ws(s):`, and `file:` except `props.allowNetwork` hosts: `host` (any port), `host:port` (that port only; `:443`/`:80` also match the scheme's portless URL), `*.host` (the host and its subdomains). Exceptions pin the whole authority (no userinfo); other entries are ignored. A tile never loads with rules compiled for an allowlist that has since changed. The main frame never navigates away from its page; popups are refused.
- The only native access is the `canvas` script message handler (`window.webkit.messageHandlers.canvas.postMessage(msg)` → promise), accepted from the tile's own top-level page only. Each tile runs at most 4 messages at once with 64 more queued; beyond that a message is rejected (`too many outstanding requests`), and outstanding work is cancelled when the page re-renders or the tile detaches. Messages are strict (`Sources/CanvasCore/HtmlMessage.swift`: known `type`, only its fields, 64 KiB per message):

| `type` | Fields | Reply |
| --- | --- | --- |
| `code.excerpt` | `path`, `lines?` (`"N"`/`"N-M"`), `symbol?` | `SourceExcerpt` (`start`, `end`, `lines`, `language`, `stale`, `reason`, `truncated`) |
| `code.open` | `path`, `lines?`, `symbol?` | `{tile, created}`: re-aims the topmost non-follow code tile for `path`, else creates one beside the HTML tile; from the live page (a user's click), the canvas pans the least that shows that tile clear of the chrome |
| `state.get` | `key?` | `{value}` from `props.state` |
| `state.set` | `key` (`[A-Za-z0-9_.:-]{1,128}`), `value` (≤ 16 KiB, `null` deletes) | `{}`; `props.state` is capped at 256 KiB |
| `view.rendered` | `scrollY?` | `{}`; the tile refreshes its snapshot and remembers the scroll; the first after the page attaches lifts the card (`whenLiveReady`) |

- Paths are board-relative; absolute paths, `~`, `..`, and symlinks resolving outside the board root are rejected.
- `<canvas-code>` (canvas-kit.js/css) draws an excerpt's lines like a code tile: long lines soft-wrap at the element's width, continuation rows indented by the line's own indentation plus 2 columns (tabs as 4, at most half the row), never clipped or scrolled sideways.

## Lifecycle authority

- The omp extension is authoritative for omp tiles (`source: "canvas-omp"`).
- Claude Code and Codex hook scripts report with `source: "canvas-claude"` / `"canvas-codex"`.
- A report with a lower `seq` than the last accepted one from the same source is ignored.
- `done` is derived by the app: an `idle` report on a tile that has not been seen since it was last `working`.

## Ownership rules for slices

- The schema file is the only place API shape changes. Changing it means regenerating clients (`bun scripts/gen-clients.ts`) in the same change.
- Swift model types mirror the schema; a slice that needs a new field adds it to the schema first.
- No slice introduces a new socket, environment variable, or on-disk location without adding it here.
