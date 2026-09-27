---
name: canvas
description: You are running inside Canvas (CANVAS_ENV=1), an infinite canvas where your terminal sits next to code, note, browser, HTML, and drawn objects the user also sees. Use for reading <canvas-mentions>, showing code/notes/HTML explainers/diagrams on the canvas, pointing the user at things, and talking to other agents.
---

# Working in Canvas

Your terminal is one tile on an infinite canvas the user is looking at.
Next to it live code/diff tiles, markdown notes, browser tiles, sandboxed HTML tiles, and shapes/arrows/ink.
You and the user read and change the same objects.
The canvas is the shared working state; your transcript stays in your terminal.

You are in Canvas when `CANVAS_ENV=1`. omp, Claude Code (`claude`) and Codex (`codex`) started in a tile all get the integration
(lifecycle, mentions, follow mode, this skill; `CANVAS_AGENT_HOOKS=0` turns it off for Claude and Codex).
Your tile's environment also has `CANVAS_TILE_ID` (you), `CANVAS_BOARD_ID`,
`CANVAS_BOARD_ROOT` (the repo/worktree this canvas belongs to), and `CANVAS_SOCKET`.

## Known surprises

Read these before you build anything; each one cost earlier agents a round trip.

- **Start small.** A first draft is about one screen: one tile, or a few in a group.
  Split a long explainer into grouped tiles rather than one tall page, and expand when the user asks.
  A 20-object first draft overwhelms; a compact one gets read.
- **Let the canvas do the geometry.** Omit `frame` and a new object lands in the free spot nearest your terminal:
  clear of every tile and group (other agents' too), inside the user's view when there's room. Read the returned frame to place related objects.
  From a script outside any tile, it lands nearest the centre of the user's view instead.
  For deliberate layouts use `size: "fit"` and the layout helpers (`layout.place`/`stack`/`grid`/`translate`, then `layout.check`), not hand-computed coordinates:
  those collided with the follow tile and other agents' tiles.
- **Renders go to a temp file.** `canvas render obj_…` without `--out` writes a new PNG under `$TMPDIR/canvas-renders/` and returns its `path`.
  Never pass an `--out` inside the repo: it shows up in `git status`.
- **Write locations as `path:line`.** The user can ⌘-click `src/a.ts:42`, `:42:7`, `:10-20` or `#L10-20` in your terminal output to open that code beside your terminal
  (resolved from your shell's cwd, then the board root), so prefer repo-relative `path:line` over prose like "in the store module".
- **Name what the user will look for.** Go to (⌘P) matches every tile's caption and terminal name,
  and the tray labels the terminal mentions go to by its `name`: caption your code tiles and name terminals you create.
- **Code tiles tint their `range` only among other rows.** A `size: "fit"` tile shows exactly its range, untinted.
  To mark a few lines inside more context, give the tile a taller frame instead of fitting it.
- **Line-bound arrows pin when their line is out of view.** An arrow end bound to `lines` of a code tile attaches at that row only while the tile shows it;
  scrolled out, the end pins to the top of the code or the bottom of the tile.
  Keep bound lines inside the rows the tile shows (fit the range, or bind to lines near its top).
- **Attention markers stay until the user looks, across app restarts.** A marker clears when the user looks at the object in the active window, or when you `--clear` it.
  Your markers belong to your turn: the first one you raise after the user's next prompt clears the ones from your earlier turns (you don't need to), while markers raised in the same turn (approvals included) stay together.

## Pick a client

- **You have a persistent Python REPL (e.g. an `eval` tool): use the Python SDK.** One connection, typed methods, compositions.
  ```python
  from canvas_sdk import canvas
  board = canvas.board.get()                      # manifest of every object
  note = canvas.object.create(type="note", props={"markdown": "# Plan"})["object"]
  canvas.object.get(id=note["id"], as_="graph")   # reserved words take a trailing underscore
  canvas.agent.wait(target="reviewer", timeout_ms=600000)   # Python keywords are snake_case (CLI: --timeoutMs)
  ```
  omp's `eval` kernel does not inherit `CANVAS_*` (omp gives it an allowlisted environment), so connect explicitly there.
  Your system prompt has the exact line, or read the values with `echo $CANVAS_SOCKET $CANVAS_TILE_ID $CANVAS_BOARD_ID` in bash:
  ```python
  from canvas_sdk import connect
  canvas = connect(socket="…/canvas.sock", tile="obj_…", board="brd_…")   # `from canvas_sdk import canvas` uses it too
  ```
  Without a socket the SDK raises `CanvasError('unavailable')` saying so; it never guesses.
- **Otherwise: the `canvas` CLI** (on PATH in every tile; it reads `CANVAS_SOCKET`, `CANVAS_TILE_ID`, `CANVAS_BOARD_ID`,
  so pass them through when you run it from a kernel that lacks them).
  Methods are `namespace.method`; params are `--key value` (values parse as JSON when they can), a bare `--flag` (true), or `--json '{…}'`.
  ```sh
  canvas methods                                   # every method with its description
  canvas methods view.render                       # its params (types, defaults, required) and result
  canvas methods CodeProps                         # a type's props (any *Props: NoteProps, HtmlProps, …)
  canvas board.get
  canvas object.create --type note --json '{"props":{"markdown":"# Plan"}}'
  canvas get obj_… --as graph                      # object.get shorthand
  canvas render obj_…                              # view.render shorthand (also obj_a,obj_b or x,y,w,h); prints the PNG path
  ```
  `--json @params.json` (or `@-` for stdin) reads params from a file, handy for big HTML.
  object.create/update print prop values over 1 KB elided (`--full` prints everything; the API result is whole).
  Errors print `code: message` and exit 1. "The socket exists but connecting to it failed … a sandbox may be blocking" means your sandbox blocks the unix socket, not that the app is down:
  run canvas commands outside it (Codex: escalated) or ask the user to allow the socket.
- TypeScript/Bun: `new CanvasClient({ socketPath?, tile?, board? })` from `clients/ts/src/index.ts`, methods under `client.api.<ns>.<method>({…})`.

Results are objects, never bare values:

| Call | Returns |
| --- | --- |
| `object.create`, `object.update`, `object.get` | `{object}` (so the new id is `result["object"]["id"]`); `object.get --as graph` adds `graph`; create/update add `warnings` when a prop key is unknown for the type (a typo like `colour`): fix it |
| `object.batch` | `{results, revision}`: each op's result in order (`results[0]["object"]["id"]`) |
| `layout.place`/`stack`/`translate` | `{frames: {id: frame}}`; `layout.grid` adds `columns` and `rows` |
| `layout.check` | `{overlaps, arrowCrossings, labelOverlaps, overflow, truncated}` |
| `view.render`, `view.snapshot` | `{path, width, height, scale, objects}` plus `canvasRect` (render) or `viewport` (snapshot) |
| `agent.prompt` | `{agent, waitable, submittedAt}`; `agent.wait` → `{agent}`; `agent.read` → `{agent, text, lines}` (`truncated` with `since`) |

`caller` (you) and `board` are filled from the client's tile and board (explicit, else `CANVAS_TILE_ID`/`CANVAS_BOARD_ID`),
so objects you create are attributed to you and placed next to your terminal.
If the app restarts, the next call reconnects on its own (waiting up to 15 s), and an `agent.wait` in progress is asked again with the time it has left.
`unavailable` with "may or may not have applied" means your request was sent but its reply was lost: re-read (`board.get`) before retrying.
Method reference with examples: `references/api.md` in this skill's directory.

## Read what the user points at

When the user Hyper-clicks things on the canvas and then prompts you, the prompt carries a hidden block:

```text
<canvas-mentions board="brd_…" root="/repo">
[1] code src/store.ts:41-48 (symbol restore) · tile obj_A · diff vs merge-base 1a2b3c4
  > 41   export async function restore(id: string) {
[2] dom http://localhost:3000/login · button#submit "Sign in" · browser tile obj_B
[3] shape rect obj_C "auth path?" (drawn by user) · encloses obj_A · arrow → obj_D (hypothesis_about)
[4] shape ellipse obj_E (drawn by user) · over browser obj_B at (240, 200) 125×120
</canvas-mentions>
```

"this", "these", "here", "that box" in the prompt refer to these entries, in order.
A mention of your own terminal says `(your terminal)`; other terminals are named, so "this terminal" means the one mentioned, not yours.
Mentions arrive only in prompts submitted in the terminal the tray shows (`view.get` `promptTarget`);
`tray.drain` from any other terminal returns nothing but `held` and `target`, so never call it to check the tray: use `tray.list`.
Excerpts are short; read the real file or `canvas get <id>` for more.
A drawn shape means nothing by itself: read what it encloses and connects (`canvas get <id> --as graph`) or look at it (`canvas render <id>`).
A shape `over` a tile marks a region of it, in the tile's local units: look at that part with `canvas render <tile>`.
An `(edited)` marker means the object changed after the user staged it.

## See the board

| Want | Call |
| --- | --- |
| Look at objects or a region, wherever the user is | `view.render` |
| What the user is looking at right now, as pixels | `view.snapshot` |
| Where the user is looking, without pixels | `view.get` |
| What happened since you last looked (who made, moved, deleted what; where the user went) | `board.history` |

**`view.render`** draws part of the board offscreen at a fixed scale.
It never moves the user's view and doesn't depend on it, so never put probe objects in the user's view to look at them.

```sh
canvas render obj_…                                  # one object (the canvas region under it)
canvas render obj_a,obj_b --scale 2                  # the region covering several
canvas render 0,1200,2400,1600 --exclude '["terminal"]'   # a canvas rect x,y,w,h
canvas render obj_… --full                           # a note/HTML tile's whole content (code: its whole range), below its frame too
```

Python: `canvas.view.render(target="obj_…", full=True)["path"]`
(`target` is an id, a list of ids, or `{"x","y","w","h"}`).
The app writes a new file under `$TMPDIR/canvas-renders/` (or `out` if you pass one: png or jpg by extension; clients resolve relative paths), and `path` in the result is that file.
The result maps pixels to the canvas: pixel `(px, py)` is canvas `(canvasRect.x + px / scale, canvasRect.y + py / scale)`,
and `objects` lists every object drawn with its `pixelRect`
(a tile's is exactly its frame: a tile's `frame` is its whole drawn box, 26 pt title bar included), `state`, and `overflow`:

- `state: rendered` means the content painted.
  `placeholder` means it didn't in time or can't be rendered here (`reason` says why; the image shows an orange "not rendered" tag instead of a silent blank).
  A browser tile that isn't loaded (offscreen, never shown) is loaded for the render.
  Content waits up to `timeoutMs` (8 s) for HTML and browser pages and file reads to settle.
- `overflow: {x, y}`: canvas points of content beyond the tile's frame
  (a note taller than its box, a code range longer than the tile; code wraps at the tile's width, so it only overflows downward).
  Absent when the content fits. Resize the frame by that much to fit it, or render with `full`.
- `contentSize`: the content's own extent at the tile's width, below its title bar.
  For code it is the range (its rows, wrapped at the tile's width, and longest line under the header), not the whole file: what `size: "fit"` shows.

Terminals are drawn from their session text in the terminal's font and colors.
App chrome (toolbar, tray, hints, selection rings, attention markers) is never drawn; leave out object types with `exclude`.

**`view.snapshot`** is the window as the user sees it now, toolbar and all.
Its result includes `viewport {rect, zoom}`, `scale`, and visible `objects` with `pixelRect`s, so you never need pixel math against a known tile.

**`view.get`** returns `viewport {rect, zoom}` (the visible canvas rect in canvas coordinates), `promptTarget`, `focused`, `selection`, and whether the window is `visible`.

**`board.history`** is a plain request/response log, cheap to poll from a REPL:
`canvas board.history --since 42` (the `cursor` from your last call; or an ISO time) → `entries` oldest first, each `{seq, rev, at, actor, kind, id?, type?, summary}`.

- `actor` is `user`, `system`, or `agent:<tile>`.
  A side effect of someone's change (a group re-fit to its members, an arrow end freed because what it pointed at was deleted) is credited to them and has a `cause`,
  logged once per object per revision at its net change.
- `kind` is `created`, `updated`, `deleted`, `viewport` (logged once the view comes to rest), `selection`, `follow` (your follow tile re-aimed, and by whom),
  or `restart` (the app started; if your `since` is from before a restart the result says `restarted: true` and returns everything).
  `kinds: ["created","deleted"]` narrows it.
- Objects that existed for only seconds are in it too.
  The log is in memory: the newest 2000 entries per board (`truncated: true` when entries you hadn't seen were dropped).

## Show your work on the canvas

Create objects when a visual helps the user more than terminal text: a plan they will come back to, code they should look at, a comparison, a diagram.
Don't mirror your whole transcript onto the canvas.
Keep the first draft to about one screen (see Known surprises) and grow it when the user asks.

Omit `frame` and the canvas places new objects in the free spot nearest your terminal (see Known surprises).
When you lay things out deliberately, let the canvas do the geometry:

- `size: "fit"` sizes a tile to its content.
- `layout.place`/`layout.stack`/`layout.grid` position objects (groups move whole; `grid` lines up columns across lanes),
  and `layout.translate` moves a finished build into place.
- `object.batch` applies a whole layout as one ⌘Z step with `"$0"` references to objects it creates.
- `layout.check` reports overlaps, arrows through tiles, arrow labels lying on tiles or on each other, content that doesn't fit (HTML pages too), and cut-off captions.
  It judges what is drawn: frames are whole tiles, and arrows route as drawn. When it reports nothing, the picture is clean.
  Unfilled rects and ellipses are annotations and never count as overlaps.

Details and an example: `references/api.md` "Layout".

| Want | Create |
| --- | --- |
| Point at real code | `code` tile: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "caption": "restore replays the log"}` (`path` relative to the board root; see Code tiles) |
| Several locations at once | `canvas.compositions.locations.open(["src/a.ts:10-40", "src/b.ts:7"])` |
| Durable notes, plans, findings | `note`: `{"markdown": "…"}` |
| A rich explainer, comparison, decision | `html` tile, see below |
| Structure: boxes, labels, relations | `shape` / `arrow`, see below |
| A web page | `browser`: `{"url": "http://localhost:3000"}` (your browser tool opens its own; see Browser tiles) |

Code paths may point outside the board root (`../other-repo/src/x.ts` or an absolute path, e.g. a worktree); the tile reads git from that file's own repository, `pinnedCommit` included.
A path or commit that doesn't exist is `not_found`.

Any tile or text shape takes `scale` in its props (0.25–8, default 1): it draws everything inside bigger or smaller while laying out as if its frame were frame ÷ scale.
To make a tile readable from further out without changing what it shows, set `scale` and multiply `w`/`h` by the same factor (or use `size: "fit"`, which measures at the scale).
Users scale objects with ⌥-drag on a corner or the Scale menu; leave their scale alone unless asked.

Update with `object.update` (props shallow-merge; pass `rev` from your last read to avoid clobbering a concurrent edit; `conflict` means re-read and retry).
Delete with `object.delete`; deleting a terminal tile ends its session and whatever runs in it.

### Notes

A note created without a frame height fits its markdown (at `frame.w`, default 280), so `frame` can be just `{x, y, w}`.
`title` sets its title bar (default "Note").
Markdown code fences are live when anchored to real code, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ````
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence.
- Plain fences are free-written snippets; `file:line` references in notes become links.

Anchors prefer symbols (they survive edits); line anchors are re-found by content and show a stale badge when lost.

### Code tiles

A code tile shows the whole current file, scrolled so `range` sits a few rows below the top, with `range` tinted among the rows around it.

- **Gutter.** Signs show changes against `diffBase` (default `merge-base`: the whole branch; `head` for uncommitted work only; or a commit sha) like gitsigns:
  green bar added, blue bar modified, red wedge where lines were deleted; the user can click a sign to see the old lines inline.
  A repo with no commits or no default branch shows plain source with a header warning, as do diffs too large to compute; a deleted file shows its base version.
- **`caption`** is one line under the header (plain text, `inline code`), so a tile doesn't need a separate note for its one-line explanation. `caption` never wraps.
- **`size: "fit"`** sizes a tile to exactly its range: the tile then shows those lines and nothing around them.
  It gets as wide as the range's longest line up to 960 pt (pass `frame.w` for another maximum),
  and longer lines soft-wrap onto indented continuation rows, so keep long lines in the range rather than trimming around them.
  It is at least as wide as its caption, up to the same maximum.
  With a `range`, fit sizes the range even when `symbol` is set; `symbol` alone fits the declaration but the tile still shows the file from the top, so pass the range.
- **`pinnedCommit`** (a sha, tag, branch, or `HEAD~N`) shows the file as of that commit, read-only: no gutter signs, and working-tree edits don't change it.
  The header says "pinned at <sha>". Use it for old-vs-new comparisons (a pinned tile next to a live one of the same path)
  and for a PR head you haven't checked out: `git fetch origin pull/<n>/head`, then pin to the fetched sha (`git rev-parse FETCH_HEAD`).
  Mentions of a pinned tile quote the lines at that commit. Set it to `null` to go back to the working tree.
  For "what changed since X" in the working tree, use `diffBase: "<sha>"` instead.
- Follow tiles are fixed-size viewers; `layout.check` never counts them.

### HTML explainers

`object.create --type html` with `{"html": "…", "title": "…"}`.
Add `"size": "fit"` (with `frame` `{x, y, w}`, default width 640) to make the tile exactly as tall as the rendered page at that width, up to 4000 pt; `object.measure --type html` gives the same size without creating it.
Tiles are sandboxed: no network unless you list hosts in `allowNetwork`, no native access.
Every tile preloads Tailwind (themed to the app: `bg-background text-foreground bg-muted bg-card border-border text-muted-foreground bg-accent bg-code text-warn text-ok`, dark mode automatic),
Mermaid (`<pre class="mermaid">`), and grounded components:

- `<canvas-code path="src/x.ts" lines="10-40" symbol="Name">` — a live excerpt from the real file; click opens a code tile.
  Long lines soft-wrap with a hanging indent, so don't widen the tile for them.
- `<canvas-link path="src/x.ts" line="42">text</canvas-link>` — a file:line link that opens a code tile.
- `<canvas-decisions key="…" question="…"><canvas-option value="…" label="…">…</canvas-option></canvas-decisions>` —
  the user's pick lands in the tile's `props.state[key]`; read it back with `object.get`.
- `<canvas-compare><canvas-pane label="Before">…</canvas-pane><canvas-pane label="After">…</canvas-pane></canvas-compare>` — side-by-side panes.

Ground every code claim with `<canvas-code>`/`<canvas-link>` instead of pasting code.
Playbooks for plans, walkthroughs, comparisons, decisions, and architecture diagrams, plus Mermaid pitfalls: `references/html-explainers.md`.
Read it before building an explainer.

### Shapes and arrows

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "…", "fill": "none" | "semi" | "solid"}` with a `frame`.
  A rect drawn around tiles *encloses* them.
  - `color`: `black` (the default ink; white in dark mode), `grey`, `blue`, `green`, `orange`, `red`, `violet`, or `#rrggbb`. Arrows take `color` too.
  - `fill` (rect/ellipse): `none` (default; the interior passes clicks through), `semi` (a 14% wash of the color, for regions), `solid` (85%).
  - Text sizing: a `text` shape draws its text in 20 pt handwriting from the frame's top-left, wrapping at the frame width;
    one line needs about 30 pt of height (`h ≈ 30 × lines`).
    A rect/ellipse `text` is an 18 pt label centered in the frame, wrapping at `w − 16`.
    Arrow labels are 15 pt, wrapping at 240 pt, centered on the shaft.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`.
  - Endpoints bind to objects (optionally a line range or a DOM `selector`) or to a `{"point": [x, y]}`.
  - An end bound to `lines` of a code tile attaches to the tile's left or right edge at the row of `lines.start`
    (the right edge unless the other end lies wholly to the left), so call-site → callee arrows point at the lines.
    It follows the tile's scroll, and a line scrolled out of view pins the end to the top of the code or the bottom of the tile.
    On other tiles `lines` binds the whole tile.
  - `relation` is the machine-readable edge (`calls`, `depends_on`, `hypothesis_about`, …); `label` is what the user reads.
    Without a label the arrow shows its relation in a secondary color; `label: ""` shows no caption.
  - `route`: `straight` (default), `orthogonal`, or `avoid` (goes around tiles in the way).
    Arrows between the same two objects are drawn apart automatically, both directions.
- `group`: `{"members": [ids], "title": "…", "color": "blue", "padding": 24}` is a titled, tinted region whose frame always wraps its members
  (plus padding and a title band) as they move; use one per lane or cluster instead of a rect plus a text label.

`canvas get <id> --as graph` returns what an object encloses, overlaps, and connects to, so diagrams you draw are readable by other agents too.

## Browser tiles

omp's `browser` tool (its cmux backend is on automatically inside Canvas) opens a browser tile beside your terminal for each `browser.open({name})`;
`close` deletes it.

- The tool doesn't return the tile id. Find it with `canvas board.history --limit 5` (`agent:<your tile> created … browser <url>`)
  or `canvas board.get` (browser tiles whose `createdBy` is your tile).
  Tiles made with `object.create` or by the user can't be driven by the tool: change their `props.url` with `object.update` and look with `canvas render`.
- The page's viewport is the tile's body: `innerWidth` is the frame width, `innerHeight` the frame height minus 58 (26 pt title bar, 32 pt address bar), at any zoom.
  The tool's `viewport`/`emulate` options are ignored here. To test a width, resize the tile
  (`canvas object.update <id> --json '{"frame":{"w":390,"h":844}}'`); the user sees the same tile.
- `tab.evaluate` must return plain values (omp rejects functions that return a promise on this backend); poll with `waitForFunction` for async state.
  On strict-CSP pages (e.g. GitHub) pass functions, not code strings: string code runs through the page's `eval`, which CSP blocks.
- A page you drive or render stays live for 60 s after your last command wherever its tile is (offscreen, window minimized, another Space):
  `visibilityState` is `visible` and timers and `requestAnimationFrame` run. Don't move tiles into the user's view to make them work.
- `canvas render <tile>` loads a page that was never shown and waits up to `--timeoutMs` (8 s).
  `--full` doesn't capture below the fold on browser tiles; make the tile taller instead.
- All browser tiles share one WebKit profile, separate from the user's own browser and signed out: use `gh` or APIs for logged-in state.
- The user can click links and buttons in a tile directly. `board.history` credits your terminal with the tiles you open and close
  and with URL changes your commands cause within 10 s (pushState and back included; a `_blank` link opens a tile beside the page, never moving the view);
  the user's clicks are `user`, changes the page makes later on its own `system`.

## Follow mode

Your terminal has one follow tile: the canvas re-aims it at every source file in the project you read, edit, or write,
flashes the lines each edit or write changed, and keeps a short history.
Files in another worktree of the board's repository count too (the tile shows the absolute path with that worktree's changes).
Images, PDFs and other binaries, files under the temp dir, and files that no longer exist never re-aim it.
While the user scrolls or clicks in it, it holds still for ~10 s and counts what it missed ("N new ▸") before following again.
If the user closes it, your terminal stops following until they turn "Follow Files" back on in your terminal's menu:
don't re-create it or turn following back on yourself. Closing your terminal closes its follow tile.
It happens automatically; don't create code tiles just to show what you are reading.
Create code tiles for code you want the user to keep looking at.

## Getting the user's attention

Never move the user's viewport (no panning or zooming to your objects) unless they ask. To point at something, raise an attention marker:

```sh
canvas view.attention --id obj_… --message "The race is here"   # → {"id": "obj_…", "active": true}
canvas view.attention --id obj_… --clear                         # take it back
```

Markers are keyed by the object (raising again replaces the message); the user selecting or looking at the object, or clicking the marker, clears it too.
A marker's bubble is cut to the object's width (240–480 pt), so put the point of `--message` in its first ~40 characters.
The user can clear every marker at once (right-click the canvas); markers aren't undo history.
Raise one marker per thing your answer points at; they stay together until the user looks, even across app restarts.
A job in a terminal with no agent integration can flag it without the API: `printf '\e]777;notify;Build;done\a'` (or OSC 9, or a bell) raises a marker there unless the user is typing in it.
Terminals whose agent reports a lifecycle (omp, Claude Code, Codex) show done and blocked themselves, so their notifications raise nothing.
Your next marker after the user's next prompt clears your earlier turns' markers (the result lists them in `cleared`): don't clear old ones yourself, and never re-raise the cleared ones.
The user saw them with your last answer; markers left from old turns pile up into clutter.

## Whose objects are whose

Every object records who created and last changed it (`createdBy`/`updatedBy`: `user` or an agent's tile).
Objects you created are yours to update, rearrange, and delete.
Touch the user's objects (their notes, drawings, tile layout) only when the user is collaborating with you on them:
they asked, or they mentioned the object in this request.
Every agent change is undoable with ⌘Z, but that is a safety net, not a license.

## Other agents

Agents in other terminal tiles (any canvas in the app) are reachable by tile id or tile name:

```sh
canvas agent.list                                    # every terminal: tile, kind, name, lifecycle, board and root (its repo/worktree)
canvas agent.prompt --target reviewer --text "Review the diff in src/store.ts"   # → waitable, submittedAt
canvas agent.wait --target reviewer --timeoutMs 600000   # until idle/done/blocked; `until` narrows it
canvas agent.read --target reviewer --since prompt   # only what came after your last agent.prompt (inline images read as [image])
```

When `agent.prompt` returns `waitable`, call `agent.wait` right away: it waits for the work you just asked for, not the previous idle.
Then `agent.read --since prompt` returns just the reply (`--lines N` gives the plain tail).
Kind `omp`, `claude` or `codex` reports a lifecycle (a fresh Codex from its first prompt). Kind `unknown` (a shell, aider, another CLI) has none:
`agent.prompt` works, `agent.wait` fails once 15 s pass without a first report (enough for an agent you just started), so poll `agent.read --since prompt`.
Claude Code runs no hook when its user presses Esc or denies an approval, so its tile keeps its last state until the next prompt.
Don't prompt an agent that is `blocked`; it is waiting for its user (omp reports every approval prompt as blocked, nested ones included, and the user sees it on the tab and an edge pill).

## Compositions

Reusable helpers come built into the SDKs, plus your own in `~/.canvas/compositions` (yours shadow built-in ones of the same name). In Python:

```python
canvas.compositions.available()                              # name -> summary
canvas.compositions.grid.arrange([id1, id2, id3])            # grid beside your terminal, clear of other tiles
canvas.compositions.locations.open(["src/a.ts:12-40", "src/b.ts#L7"])
```

A composition is a plain module; functions whose first parameter is named `canvas` receive the client.
When you catch yourself repeating a multi-call canvas pattern, write it as a composition in `~/.canvas/compositions/<name>.py`
(and `.ts` for the TS client, `client.compositions.<name>`), then `canvas.compositions.reload()`.
Improve existing ones rather than forking them.

## Boards

One canvas per directory (repo or worktree, keyed by branch). Boards open as tabs of one window.
`canvas board.open --root <absolute dir>` opens a directory's board as a tab (creating it if new) behind the user's current tab;
pass `--select true` only when the user asked to see it.
Then address it with `board: <id>` (from the result) on every call, and start agents there by creating terminal tiles on that board.
`canvas board.list` shows every stored board, including archived ones whose worktree is gone.
`canvas board.export` writes a readable snapshot to `<root>/.canvas/board.json` for committing when the user asks to save the board with the repo.

## When the user asks how to use Canvas

⌘P goes to any tile or opens a repo file; ⌥⌘-arrows move between tiles; ⌘W closes the selected tile or focused terminal; ⌘F finds in a code tile;
⌘9 fits everything, ⌘0 is 100%, ⌘=/⌘- zoom; ⌘T opens a terminal; ⌘G groups the selection; ⌘Z undoes any change, agents' included.
Hyper-click (⌃⌥⇧⌘-click) stages a mention for the terminal the tray shows; Hyper-V pastes staged mentions into a terminal whose agent has no integration.
⌘-click a `path:line` in terminal output to open it. Right-click empty canvas for New Terminal/Note/Browser Here; right-click a terminal for Follow Files.
