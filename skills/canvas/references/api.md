# Canvas API from an agent

The method catalog is `schema/canvas-api.json`; `canvas methods` prints every method with its description, and in Python `help(canvas.<ns>.<method>)` shows the signature.
This page covers the conventions the catalog doesn't spell out.

## Calling conventions

| | Python SDK | CLI |
| --- | --- | --- |
| Call | `canvas.agent.read(target="obj_…", lines=50)` | `canvas agent.read --target obj_… --lines 50` |
| camelCase params | snake_case keywords: `timeout_ms`, `session_id` | as in the schema: `--timeoutMs` |
| Nested params | dicts: `props={"range": {"start": 1, "end": 9}}` | `--props.range.start 1`, `--json '{"props":{…}}'`, or `--json @params.json` (`@-`: stdin) |
| Result | the `result` object as a dict | pretty JSON on stdout; `object.create`/`update` print prop values over 1 KB elided (`--full` prints them) |
| Error | raises `CanvasError` (`.code`) | `code: message` on stderr, exit 1 |
| Props per type | `help(canvas.object.create)`; the schema's `CodeProps`, `NoteProps`, … | `canvas methods CodeProps` |

Error codes: `not_found` (no such object/agent/board; a code tile's file or `pinnedCommit` that isn't there), `conflict` (stale `rev`: re-read, re-apply, retry),
`invalid_params`, `unavailable` (e.g. a terminal without a running session, or the app isn't running), `unsupported`, `timeout` (`agent.wait`).

## Reading the board

- `board.get` returns every object with heavy props trimmed (long markdown, HTML source); `object.get` returns one object whole.
- Poll cheaply: keep `revision` from one `board.get` and pass it as `since` next time; `changed` lists ids created or changed after it.
- `object.get --as graph` gives `encloses`, `enclosedBy`, `overlaps`, `arrowsOut`, `arrowsIn`. To look at an object use `view.render` (`canvas render <id> --out file.png`).
- `tray.list` shows what the user has staged but not yet sent. Don't drain the tray yourself; your harness attaches it to the user's next prompt.
  The tray's mentions are for the terminal it shows (`view.get` `promptTarget`): `tray.drain` from any other terminal returns none (`held` says how many wait) and leaves them staged.
  A drawn shape's mention quotes its whole text, says `over <type> <id>` (or `partly over`, for a shape mostly on a tile) with the region in that tile's units, and for a shape on a browser or HTML tile lists the page elements under it (`<selector> "<text>"`, as the page is laid out when the prompt is sent). A Hyper-click on a drawing mentions the whole selection or drawing group it belongs to.
- An arrow's `frame` is the bounds of its routed line as drawn.

## Objects

- `frame` is `{x, y, w, h}` in canvas points (100% zoom): the whole box the object draws. A tile's 26 pt title bar is inside its frame, at the top.
  Omit it on create for automatic placement beside your terminal (in the user's view when your terminal is on screen and there's room). Without a calling terminal (a script outside any tile), it goes to the free spot nearest the view's center, clear of the window's toolbar and tray.
- `props` on `object.update` merge shallowly: `{"range": …}` replaces `range` and keeps other props. Set a prop to `null` to clear it.
  `frame` on `object.update` may give any of `x, y, w, h` (`{"frame": {"h": 420}}`); the rest stay. On create it needs all four, or `size: "fit"` (below).
- A prop the type doesn't define (a typo like `colour` or `markdwon`) is kept, but `object.create`/`object.update` (and each batch op's result) add `warnings`, one per unknown key naming the type's real props. No `warnings` key means every prop is known.
- Every change bumps `rev`. Pass `rev` on updates to objects the user may be editing; the `rev` a create or update returns is current.
  A note's line-range fences (`file=src/a.ts#L10-40`) come back with an `anchor="<first line>"` added, as the tile would write it.
- `props.scale` on any tile or text shape (0.25–8, default 1) magnifies what it draws:
  a tile lays out at frame ÷ scale (a 1200×800 tile at scale 2 shows what a 600×400 one does, twice as big), a text shape's font scales.
  Measure, fit, `layout.check`, `view.render` sizes, and line anchors account for it; everything you get back is in canvas points.
- Terminal tiles: `{"cwd": "/path", "command": ["omp"]}` starts an agent in a new tile (its session survives app restarts). Only start agents the user asked for.
  Deleting a terminal tile (`object.delete`, or in a batch that succeeds) ends its session and whatever runs in it, as closing it does for the user.
- Changes tiles (`type: changes`, `ChangesProps`): `{"base": "HEAD"}` (the default: uncommitted work, staged or not; also `merge-base` or a commit), optional `paths` (files or dirs) and `title`.
  The user reviews there: hunks as a unified diff, Stage and Revert per hunk and per file, each one ⌘Z. To show them what you changed, create one (`size: "fit"` sizes it to every hunk, at most 4000 pt tall) rather than an HTML diff.
  `object.get` adds `changes`: `files` (board-relative `path`, `status` added/modified/deleted/renamed, `added`/`removed`, `hunks` with `header`, `old`/`new` `{start, count}`, and `status` unstaged/staged/committed) as git has them now, so hunks the user reverted are gone and staged ones say so;
  `props.reviewed` lists what they staged or reverted (`action`, `path`, `scope`, `header`). The tile writes `reviewed`; changing it yourself does nothing to git.

## Layout

Sizes, positions, and checks, so you never measure tiles by hand or move 40 objects one call at a time:

- `canvas.object.measure(type="code", props={…}, width=960)` → `{w, h}` (`width` optional): the whole frame (title bar included) that shows the content without scrolling.
  Code: exactly `range` (the tile shows no extra context and no neighbouring lines; with no range, the `symbol`'s declaration), plus 20 pt when `caption` is set, and at least as wide as the whole caption;
  `width` is the maximum width (default 960 pt, about 120 columns):
  a range whose longest line fits stays exactly that narrow, longer lines soft-wrap and the height counts their extra rows, and a caption wider than that truncates.
  Notes: the rendered markdown, live fences resolved, at `width` (default 280). Text shapes: at `width`, or one unwrapped line per paragraph.
  HTML: the page laid out `width` wide (default 640) once it has rendered (Mermaid, `<canvas-code>` excerpts), as tall as its document, at most 4000 pt (a longer page scrolls in the tile).
  Changes: every file and hunk row, as wide as the longest line up to `width` (default 960, at least 480), at most 4000 pt. Browser tiles are `unsupported`.
- `size: "fit"` on `object.create`/`object.update` measures instead of taking `w`/`h`: `frame` then needs only `x, y` (plus `w` to wrap a note, text, or an HTML page, or to cap a code tile's width);
  an update re-measures at the object's current position and width (code: at `frame.w` or the 960 pt default, never its current width, so a re-fit can widen it).
- `canvas.layout.place(id=a, near=b, side="right", gap=40, align="start")` (`side`: right, left, above, below; `align`: start, center, end)
  and `canvas.layout.stack(ids=[a, b, c], direction="row", gap=40, wrap_at=2400, align="start", origin={"x": 0, "y": 0})` (all but `ids` optional) move objects in one undo step and return the new frames.
  Groups move with their members, so `canvas.layout.stack(ids=[lane1, lane2], direction="column")` lays out lanes; bound arrows follow.
- `canvas.layout.translate(ids=[…], dx=12000, dy=0)` moves objects by an offset in one undo step (groups with their members, free arrow ends along, bound arrows follow).
  Build a layout offscreen (e.g. at x + 12000) in one batch, check it, then translate its groups into place.
- `canvas.layout.grid(cells=[{"id": a, "row": 0, "col": 0}, …], col_gap=40, row_gap=40, col_align="start", row_align="start", origin={"x": 0, "y": 0})` (all but `cells` optional) puts cells in shared columns and rows:
  each column is as wide as its widest cell, each row as tall as its tallest, so a column lines up across lanes (cells in different groups; the groups re-fit).
  Unused row/col numbers take no space; `origin` defaults to the cells' current top-left.
  Between rows of different groups leave `row_gap` for both groups' padding plus the 32 pt title band (e.g. 24 + 24 + 32 + your gap).
  Returns `frames`, `columns` `[{col, x, w}]`, and `rows` `[{row, y, h}]`.
- `object.batch(ops)`: `[{method, params}]` with `object.create/update/delete` and `layout.place/stack/translate/grid`, applied as one revision and one ⌘Z, or not at all (the error names the failing op).
  `"$0"` anywhere in a later op's params is the id op 0 created. Op params are the schema's own names (`colGap`, not `col_gap`):
  ```python
  canvas.object.batch(ops=[
      {"method": "object.create", "params": {"type": "code", "props": {"path": "src/a.ts", "range": {"start": 10, "end": 30}}, "size": "fit", "frame": {"x": 0, "y": 0}}},
      {"method": "object.create", "params": {"type": "note", "props": {"markdown": "Why this matters"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
      {"method": "layout.place", "params": {"id": "$1", "near": "$0", "side": "below", "gap": 14}},
      {"method": "object.create", "params": {"type": "group", "props": {"members": ["$0", "$1"], "title": "Request path", "color": "blue"}}},
  ])
  ```
- `canvas.layout.check(ids=[…])`, `canvas.layout.check(rect={"x": 0, "y": 0, "w": 4000, "h": 3000})`, or the whole board with neither → `overlaps` (pairs),
  `arrowCrossings` (`{arrow, crosses}`: routes through tiles, text, or filled shapes other than the arrow's own ends),
  `labelOverlaps` (`{arrow, overlaps}`: the arrow's label, placed as drawn, lies on these tiles, text, or filled shapes, its own ends included, or on these arrows' labels; widen the gap or shorten the label),
  `overflow` (`{id, x, y}`: points of code/note/text/HTML content beyond the frame; for code, its range's rows and longest line; for HTML, its page laid out at the frame's width),
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
turns a dedicated connection into a stream of `object.created`, `object.updated`, `object.deleted`, `tray.changed`, `agent.lifecycle`, `follow.updated`,
and `attention.changed` (`{id, active, message?, raisedBy?}`: a marker raised, or gone because the user saw it, someone cleared it, or its object was deleted).

## Agents

`agent.list` lists every terminal tile in the app; each entry names its `board` and that board's `root` directory, so you can tell which repo or worktree an agent works in. `lifecycle.state` is `working`, `blocked` (waiting for its user: an approval or a question),
`idle`, `done` (idle with results the user hasn't looked at yet), or `unknown` (no integration reporting: a shell, aider, a CLI without Canvas hooks; its `kind` is `unknown` too).
`agent.read` returns up to 2000 lines of the terminal's text, trailing blank lines removed; `since="prompt"` returns only what followed your last `agent.prompt` to it (`truncated` when there was more).
`agent.prompt` returns `waitable`: then `agent.wait` right after it waits for that prompt's turn (it ignores the state from before the prompt), so wait for `done` directly:
```python
canvas.agent.prompt(target="fees", text="review the diff, read-only")
canvas.agent.wait(target="fees", timeout_ms=900_000)      # done, idle, or blocked
reply = canvas.agent.read(target="fees", since="prompt")["text"]
```
On a terminal whose lifecycle is `unknown` (`waitable` false) `agent.wait` gives it 15 s to report (an agent you just launched there) and then fails with `unavailable`; for a shell or a CLI without integration, poll `agent.read(since="prompt")` instead.
`agent.prompt` to a `blocked` agent fails with `conflict` naming what it waits on (an approval or a question on its screen would take your text): tell the user, or `agent.wait` for it to move on.
`force=True` sends anyway, e.g. to a Claude Code agent that stays `blocked` after the user pressed Esc on an approval.
`agent.wait` survives an app restart: the SDKs and CLI ask again once the app is back, with `timeoutMs` reduced by the time already waited.
