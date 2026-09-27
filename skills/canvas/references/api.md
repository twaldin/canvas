# Canvas API from an agent

The method catalog is `schema/canvas-api.json`; `canvas methods` prints every method with its description, and in Python `help(canvas.<ns>.<method>)` shows the signature.
This page covers the conventions the catalog doesn't spell out.

## Calling conventions

| | Python SDK | CLI |
| --- | --- | --- |
| Call | `canvas.agent.read(target="obj_…", lines=50)` | `canvas agent.read --target obj_… --lines 50` |
| camelCase params | snake_case keywords: `timeout_ms`, `session_id` | as in the schema: `--timeoutMs` |
| Nested params | dicts: `props={"range": {"start": 1, "end": 9}}` | `--props.range.start 1` or `--json '{"props":{…}}'` |
| Result | the `result` object as a dict | pretty JSON on stdout |
| Error | raises `CanvasError` (`.code`) | `code: message` on stderr, exit 1 |

Error codes: `not_found` (no such object/agent/board), `conflict` (stale `rev`: re-read, re-apply, retry),
`invalid_params`, `unavailable` (e.g. a terminal without a running session, or the app isn't running), `unsupported`, `timeout` (`agent.wait`).

## Reading the board

- `board.get` returns every object with heavy props trimmed (long markdown, HTML source); `object.get` returns one object whole.
- Poll cheaply: keep `revision` from one `board.get` and pass it as `since` next time; `changed` lists ids created or changed after it.
- `object.get --as graph` gives `encloses`, `enclosedBy`, `overlaps`, `arrowsOut`, `arrowsIn`. To look at an object use `view.render` (`canvas render <id> --out file.png`).
- `tray.list` shows what the user has staged but not yet sent. Don't drain the tray yourself; your harness attaches it to the user's next prompt.

## Objects

- `frame` is `{x, y, w, h}` in canvas points (100% zoom): the whole box the object draws. A tile's 26 pt title bar is inside its frame, at the top.
  Omit it on create for automatic placement beside your terminal.
- `props` on `object.update` merge shallowly: `{"range": …}` replaces `range` and keeps other props. Set a prop to `null` to clear it.
- Every change bumps `rev`. Pass `rev` on updates to objects the user may be editing.
- `props.scale` on any tile or text shape (0.25–8, default 1) magnifies what it draws:
  a tile lays out at frame ÷ scale (a 1200×800 tile at scale 2 shows what a 600×400 one does, twice as big), a text shape's font scales.
  Measure, fit, `layout.check`, `view.render` sizes, and line anchors account for it; everything you get back is in canvas points.
- Terminal tiles: `{"cwd": "/path", "command": ["omp"]}` starts an agent in a new tile (its session survives app restarts). Only start agents the user asked for.
  Deleting a terminal tile (`object.delete`, or in a batch that succeeds) ends its session and whatever runs in it, as closing it does for the user.

## Layout

Sizes, positions, and checks, so you never measure tiles by hand or move 40 objects one call at a time:

- `object.measure(type, props, width?)` → `{w, h}`: the whole frame (title bar included) that shows the content without scrolling.
  Code: exactly `range` (the tile shows no extra context and no neighbouring lines), plus 20 pt when `caption` is set, and at least as wide as the whole caption;
  `width` is the maximum width (default 960 pt, about 120 columns):
  a range whose longest line fits stays exactly that narrow, longer lines soft-wrap and the height counts their extra rows, and a caption wider than that truncates.
  Notes: the rendered markdown, live fences resolved, at `width` (default 280). Text shapes: at `width`, or one unwrapped line per paragraph. HTML and browser tiles are `unsupported`.
- `size: "fit"` on `object.create`/`object.update` measures instead of taking `w`/`h`: `frame` then needs only `x, y` (plus `w` to wrap a note or text, or to cap a code tile's width);
  an update re-measures at the object's current position and width (code: at `frame.w` or the 960 pt default, never its current width, so a re-fit can widen it).
- `layout.place(id, near, side=right|left|above|below, gap=40, align=start|center|end)` and `layout.stack(ids, direction=row|column, gap=40, wrapAt?, align?, origin?)` move objects in one undo step and return the new frames.
  Groups move with their members, so `layout.stack([lane1, lane2], direction="column")` lays out lanes; bound arrows follow.
- `layout.translate(ids, dx, dy)` moves objects by an offset in one undo step (groups with their members, free arrow ends along, bound arrows follow).
  Build a layout offscreen (e.g. at x + 12000) in one batch, check it, then translate its groups into place.
- `layout.grid(cells=[{id, row, col}], colGap=40, rowGap=40, colAlign?, rowAlign?, origin?)` puts cells in shared columns and rows:
  each column is as wide as its widest cell, each row as tall as its tallest, so a column lines up across lanes (cells in different groups; the groups re-fit).
  Unused row/col numbers take no space; `origin` defaults to the cells' current top-left.
  Between rows of different groups leave `rowGap` for both groups' padding plus the 32 pt title band (e.g. 24 + 24 + 32 + your gap).
  Returns `frames`, `columns` `[{col, x, w}]`, and `rows` `[{row, y, h}]`.
- `object.batch(ops)`: `[{method, params}]` with `object.create/update/delete` and `layout.place/stack/translate/grid`, applied as one revision and one ⌘Z, or not at all (the error names the failing op).
  `"$0"` anywhere in a later op's params is the id op 0 created:
  ```python
  canvas.object.batch(ops=[
      {"method": "object.create", "params": {"type": "code", "props": {"path": "src/a.ts", "range": {"start": 10, "end": 30}}, "size": "fit", "frame": {"x": 0, "y": 0}}},
      {"method": "object.create", "params": {"type": "note", "props": {"markdown": "Why this matters"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
      {"method": "layout.place", "params": {"id": "$1", "near": "$0", "side": "below", "gap": 14}},
      {"method": "object.create", "params": {"type": "group", "props": {"members": ["$0", "$1"], "title": "Request path", "color": "blue"}}},
  ])
  ```
- `layout.check(ids? | rect?)` → `overlaps` (pairs),
  `arrowCrossings` (`{arrow, crosses}`: routes through tiles, text, or filled shapes other than the arrow's own ends),
  `labelOverlaps` (`{arrow, overlaps}`: the arrow's label, placed as drawn, lies on these tiles, text, or filled shapes, its own ends included, or on these arrows' labels; widen the gap or shorten the label),
  `overflow` (`{id, x, y}`: points of code/note/text content beyond the frame; for code, its range's rows and longest line),
  `truncated` (`{id, what: "caption", x}`: a code caption the frame cuts off, `x` points short).
  A group and its members, and an unfilled rect around what it contains, are not overlaps. Follow tiles are fixed-size viewers and never overflow or truncate.
  It judges what is drawn (whole tile frames, routes and line-bound ends as drawn), so an empty report means a clean picture. Run it after a layout pass instead of screenshots.
- Groups are regions: `{"members": [...], "title": "…", "color": "blue", "padding": 24}`. The frame is always the members' bounds plus padding and a 32 pt title band, updated as members move;
  it is what `encloses` uses. One group per lane replaces a rect + title text + group.
- Arrows: `route: "straight"` (default), `"orthogonal"` (horizontal/vertical with one jog), or `"avoid"` (horizontal/vertical around every tile in the way).
  Arrows between the same two objects, in either direction, are drawn apart automatically, and labels sit beside the route, clear of boxes where there is room (`labelOverlaps` says where there wasn't).
  An end bound to `{object, lines}` on a code tile attaches to its left or right edge at the row of `lines.start`, where the tile shows it:
  scrolled to its range with up to 3 rows of context above (none in a fit tile); a line scrolled out of view pins to the top of the code or the bottom of the tile.
- Colors (`color` on shapes, arrows, groups): `black`, `grey`, `blue`, `green`, `orange`, `red`, `violet`, or `#rrggbb`.
  Shapes: `fill: none|semi|solid` (only filled shapes block clicks and arrow routes).

## Events

Long-running helpers can stream changes instead of polling: `events.subscribe` (TS: `subscribe(onEvent, {events: ["object.updated"]})`)
turns a dedicated connection into a stream of `object.created`, `object.updated`, `object.deleted`, `tray.changed`, `agent.lifecycle`, `follow.updated`.

## Agents

`agent.list` covers every canvas in the app. `lifecycle.state` is `working`, `blocked` (waiting for its user: an approval or a question),
`idle`, `done` (idle with results the user hasn't looked at yet), or `unknown` (no integration reporting).
`agent.read` returns up to 2000 lines of the terminal's text, trailing blank lines removed.
