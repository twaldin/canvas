---
name: canvas
description: You are running inside Canvas (CANVAS_ENV=1), an infinite canvas where your terminal sits next to tiles and drawings the user also sees. Use before showing code/notes/HTML explainers/diagrams/changes on the canvas, reading or arranging what is on it, pointing the user at things, and talking to other agents. Answering a plain question or one about a mentioned item needs no skill.
---

# Working in Canvas

Your terminal is one tile on an infinite canvas the user is looking at.
Next to it live code tiles, changes (review) tiles, diagram tiles computed from the code, markdown notes, image tiles, browser tiles, sandboxed HTML tiles, and shapes/arrows/ink.
You and the user read and change the same objects: the canvas is the shared working state; your transcript stays in your terminal.

You are in Canvas when `CANVAS_ENV=1`. omp, Claude Code (`claude`) and Codex (`codex`) started in a tile all get the integration
(lifecycle, mentions, follow mode, this skill; `CANVAS_AGENT_HOOKS=0` turns it off for Claude and Codex).
Your tile's environment also has `CANVAS_TILE_ID` (you), `CANVAS_BOARD_ID`, `CANVAS_BOARD_ROOT` (the repo/worktree this canvas belongs to), and `CANVAS_SOCKET`.

## Known surprises

Read these before you build anything; each one cost earlier agents a round trip.

- **Start small.** A first draft is about one screen: one tile, or a few in a group.
  Split a long explainer into grouped tiles rather than one tall page, and expand when the user asks. A 20-object first draft overwhelms; a compact one gets read.
- **Let the canvas do the geometry.** Omit `frame` and a new object lands in the free spot nearest your terminal, clear of every tile and group (other agents' too),
  inside the user's view when there's room within ~600 pt, else beside you out of view: raise a marker (`view.attention`) on anything they should look at.
  `frame: {w, h}` alone places that size the same way. Read the returned frame to place related objects.
  For deliberate layouts use `size: "fit"` and the layout helpers (`layout.place`/`stack`/`grid`/`translate`, then `layout.check`), not hand-computed coordinates:
  those collided with the follow tile and other agents' tiles. When `object.update` returns `overlaps`, move the object or grow it the other way.
- **Renders go to a temp file.** `canvas render obj_…` without `--out` writes a new PNG under `$TMPDIR/canvas-renders/` and returns its `path`. Never pass an `--out` inside the repo: it shows up in `git status`.
- **Write locations as `path:line`.** The user can ⌘-click `src/a.ts:42`, `:42:7`, `:10-20` or `#L10-20` (and Python `File "x.py", line N` or pdb `x.py(N)` frames) in your terminal output to open that code beside your terminal,
  resolved from your shell's cwd, then the board root. A bare `core.py:42` opens only when that name is unique or clearly nearest the cwd; deploy paths from production stack traces (`file:///srv/app/server/x.ts:39:5` → the repo's `server/x.ts:39`) and file names without a line (`Applied edit to url.go`) open too; `/rustc/…` std frames aren't links.
  So write repo-relative (or deploy) `path:line`, not prose like "in the store module".
- **In a worktree, write paths relative to it.** If you work in a git worktree other than the board root, your notes and HTML tiles get your worktree as `root` automatically: write `tests/x.ts:16`, never `../wt-x/…`.
- **Name what the user will look for.** Go to (⌘P) matches every tile's caption and terminal name, and captions tell excerpts of one file apart (VoiceOver reads them first);
  the tray labels the terminal mentions go to by its `name`: caption your code tiles and name terminals you create.
- **Your objects carry your name.** Tiles you create show "by <your terminal's name>" in their title bar, and the user's own Go to, definition jumps and changes-tile clicks never re-aim a tile you made, captioned, or grouped.
- **Code tiles tint their `range` only among other rows.** A `size: "fit"` tile shows exactly its range, untinted. To mark a few lines inside more context, give the tile a taller frame instead of fitting it.
- **Line-bound arrows pin when their line is out of view.** An arrow end bound to `lines` of a code tile attaches at that row only while the tile shows it; keep bound lines inside the rows the tile shows (fit the range, or bind to lines near its top).
- **Params are checked.** A param a method doesn't take (a typo, or `board` where the schema has none), or a missing required one, fails with `invalid_params` listing every param the method takes.
  Objects you create or change on another board (`board`) are credited to your terminal; placement there goes near the view's centre.

## Pick a client

- **You have a persistent Python REPL (e.g. an `eval` tool): use the Python SDK.** One connection, typed methods, compositions.
  ```python
  from canvas_sdk import canvas
  board = canvas.board.get()                      # manifest of every object
  note = canvas.object.create(type="note", props={"markdown": "# Plan"})["object"]
  canvas.agent.wait(target="reviewer", timeout_ms=600000)   # keywords are snake_case (CLI: --timeoutMs)
  ```
  omp's `eval` kernel does not inherit `CANVAS_*` (omp gives it an allowlisted environment), so connect explicitly there;
  your system prompt has the exact line, or read the values with `echo $CANVAS_SOCKET $CANVAS_TILE_ID $CANVAS_BOARD_ID` in bash:
  ```python
  from canvas_sdk import connect
  canvas = connect(socket="…/canvas.sock", tile="obj_…", board="brd_…")   # `from canvas_sdk import canvas` uses it too
  ```
- **Otherwise: the `canvas` CLI** (on PATH in every tile; it reads `CANVAS_SOCKET`, `CANVAS_TILE_ID`, `CANVAS_BOARD_ID`, so pass them through when you run it from a kernel that lacks them).
  Methods are `namespace.method`; params are `--key value` (values parse as JSON when they can), a bare `--flag` (true), or `--json '{…}'` (`--json @params.json`, or `@-` for stdin, for big HTML).
  ```sh
  canvas methods                                   # every method with its description
  canvas methods view.render                       # its params (types, defaults, required) and result
  canvas methods CodeProps                         # a type's props (any *Props: NoteProps, HtmlProps, …)
  canvas object.create --type note --json '{"props":{"markdown":"# Plan"}}'
  canvas get obj_… --as graph                      # object.get shorthand
  canvas render obj_…                              # view.render shorthand (also obj_a,obj_b or x,y,w,h); prints the PNG path
  ```
  "The socket exists but connecting to it failed … a sandbox may be blocking" means your sandbox blocks the unix socket, not that the app is down: run canvas commands outside it (Codex: escalated) or ask the user to allow the socket.

Results are objects, never bare values: `object.create`/`update`/`get` return `{object}` (the new id is `result["object"]["id"]`), and create/update add `warnings` for a prop key the type doesn't know (a typo like `colour`): fix it.
`caller` (you) and `board` are filled from the client's tile and board, so objects you create are attributed to you and placed next to your terminal.
Every result shape, the TypeScript client, error codes and reconnects: `references/api.md` in this skill's directory.

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
Mentions arrive only in prompts submitted in the terminal the tray shows (`view.get` `promptTarget`); to see what is staged use `tray.list`, never `tray.drain`.
Excerpts are short; read the real file or `canvas get <id>` for more.
A drawn shape means nothing by itself: read what it encloses and connects (`canvas get <id> --as graph`) or look at it (`canvas render <id>`).
A shape `over` a tile marks a region in the tile's local units (`partly over`: more than half of it, clipped to the tile); look at that part with `canvas render <tile>`.
On a browser or HTML tile the mention adds `page elements under it (<url>):` lines (`<selector> "<text>"`), read when the prompt was sent: re-check with the selectors or a render if the page may have changed.
A Hyper-click on a page's `<canvas>`, `<video>` or `<img>` carries `pixel (x, y) of W×H` in the element's own pixels: use it directly instead of mapping a drawn shape's region.
A terminal mention quotes its screen (one over 41 lines keeps 40: the first 3, the last 10 and failure lines).
A command's output (``[n] command `go test ./...` · exit 1``) ends `· read it: canvas agent.read --target <id> --block -N` while that block can still be read (after `clear` the mention's own lines are all there is): run exactly that to read the block (up to its last 2000 lines).
Whether the user's last command passed: `lastCommand` (`{command, exit, durationMs}`) in `agent.list`/`object.get`, not the screen.
An `(edited)` marker means what the mention holds changed after the user staged it (a note's text, a page's address, a Stage/Unstage/Discard of that code mention's own lines): re-read it.
Every mention kind and field: `references/api.md` "Reading the board".

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

Per object drawn the result has `state` (`placeholder`: it didn't paint in time, `reason` says why) and `overflow {x, y}` (content beyond the frame: resize by that much, or render `--full`).
`canvas board.history --since <cursor>` lists who created, moved, and deleted what (`actor` `user`, `system` or `agent:<tile>`) since your last look.
Every result field, pixel-to-canvas mapping, and history detail: `references/rendering.md`.

## Show your work on the canvas

Create objects when a visual helps the user more than terminal text: a plan they will come back to, code they should look at, a comparison, a diagram.
Don't mirror your whole transcript onto the canvas.
Within 10 minutes of your last object, the next one without a `frame` stacks below it (else right of it).
When you lay things out deliberately:

- `size: "fit"` sizes a tile to its content.
- `layout.place`/`layout.stack`/`layout.grid` position objects (groups move whole; `grid` lines up columns across lanes), and `layout.translate` moves a finished build into place.
- `object.batch` applies a whole layout as one ⌘Z step with `"$0"` references to objects it creates.
- `layout.check` reports overlaps, arrows through tiles, arrow labels on tiles or each other, content that doesn't fit (HTML pages too), code tiles that scroll, and cut-off captions and note tables.
  It judges what is drawn, so an empty report means the picture is clean. Unfilled rects and ellipses are annotations and never count as overlaps.

Details and an example: `references/api.md` "Layout".

| Want | Create |
| --- | --- |
| Point at real code | `code` tile: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "caption": "restore replays the log"}` (`path` relative to the board root; see Code tiles) |
| Several locations at once | `canvas.compositions.locations.open(["src/a.ts:10-40", "src/b.ts:7"])` |
| Durable notes, plans, findings | `note`: `{"markdown": "…"}` |
| Who calls a function, what it calls | `diagram`: `{"symbol": "SocketServer.start", "direction": "incoming"}`, see Diagram tiles |
| A chart or figure | `image`: `{"path": "out/fig.png", "caption": "…"}`: save the figure to a file and show it; re-save to the same path and the tile reloads. No base64 PNGs in HTML |
| A rich explainer, comparison, decision | `html` tile, see below |
| Structure: boxes, labels, relations | `shape` / `arrow`, see below |
| A web page | `browser`: `{"url": "http://localhost:3000"}` (your browser tool opens its own; see Browser tiles) |

Any tile or text shape takes `scale` in its props (0.25–8, default 1): it draws everything bigger or smaller while laying out as if its frame were frame ÷ scale.
To make a tile readable from further out without changing what it shows, set `scale` and multiply `w`/`h` by the same factor, giving no `x`/`y`: it never covers neighbours (it grows up or left, else moves nearby, else to the nearest free spot farther off), so read the frame in the result to see where it went.
Users scale objects themselves (Object › Scale); leave their scale alone unless asked.

Update with `object.update` (props shallow-merge; `frame` may give any of x, y, w, h; pass `rev` from your last read or create to avoid clobbering a concurrent edit; `conflict` means re-read and retry).
After changing a note's markdown or an HTML tile's html, refit in the same call: `object.update` with `"size": "fit"`.
Don't rewrite a note the user is editing (`view.get` `focused` is that note): they get a conflict banner, and Esc keeps theirs with yours one ⌘Z away, where it can silently vanish. Wait until they leave it, or add a separate note.
Before styling a chart or page, read `view.get` `appearance` (`dark`|`light`); for dark, e.g. matplotlib `plt.style.use("dark_background")` and `savefig(…, transparent=True)`, not white slabs.
The user can share without you: the object menu has Copy as Image and Save as PNG…, an HTML tile's Save as HTML… and Open in Browser, a note's Copy as Markdown and Save as Markdown… (its markdown as written, links and fences intact), and a browser tile's Snapshot to Image (the page frozen as an image tile kept with the board, for before/after evidence).
Don't rebuild an export by hand (a note as an HTML tile, say) unless they ask for another format.
Delete with `object.delete`; deleting a terminal tile ends its session and whatever runs in it.

### Notes

A note created without a frame height fits its markdown (at `frame.w`, default 280), so `frame` can be just `{x, y, w}`.
Markdown code fences are live when anchored to real code, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ```` (`symbol=Class.method` finds methods deep in long classes: prefer it for whole functions).
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence. An applied one shows "✓ applied"; no need to delete it.
- Plain fences are free-written snippets; `file:line` references anywhere in a note become links; `![alt](out/fig.png)` shows an image (board-relative, or absolute inside the board root or the temp dir).

Whether excerpts are still true: `canvas get <note>` → `fences` (per fence `state` live|relocated|stale|applied|missing, `range`, `reason`), not a render searched for badges.
Table cells wrap to the note's width, so keep evidence timelines as `| time | event | evidence |` tables; `layout.check` `truncated` `{what: "table", x}` means too many columns: widen the note by `x` or split the table.

### Code tiles

A code tile shows the whole current file, scrolled so `range` sits a few rows below the top, with `range` tinted among the rows around it.
Its gutter shows changes against `diffBase` (default `merge-base`: the whole branch; `head` for uncommitted work only; or a commit sha).
A header "⚠ git failed: …" means git couldn't answer (cancelled, timed out, failed), not that the repo lacks commits; it clears on the next load. Don't work around a base warning with `diffBase: "head"` or a hand-picked sha unless the user asked for that base.

- **`caption`** is one line under the header (plain text, `inline code`, never wraps), so a tile doesn't need a separate note for its one-line explanation.
- **`size: "fit"`** sizes a tile to exactly its range (up to 960 pt wide; longer lines soft-wrap, so keep them in the range). Pass the `range` even when `symbol` is set.
- **`pinnedCommit`** (a sha, tag, branch, or `HEAD~N`) shows the file as of that commit, read-only: for old-vs-new comparisons, or a PR head you fetched. `null` goes back to the working tree; for "what changed since X" use `diffBase: "<sha>"` instead.
- **`ref`** (a branch) anchors the tile to the branch, not one checkout: while a worktree has it checked out the tile reads that worktree live (gutter, edits); otherwise the branch's commit, read-only; after the worktree and branch are deleted it keeps showing the merge commit ("merged in <sha>") or, for a squash merge, the branch's last commit ("branch gone, showing <sha>"). Use it for tiles about a PR lane whose worktree will go away; `path` stays repo-relative. `pinnedCommit` wins if both are set. Notes and HTML take `ref` too: their excerpts and links read at the branch (the body stays inline).
- **Ranges stay on their code** as lines move (the app rewrites `range`), so don't retarget evidence tiles by hand; `canvas get` → `rangeStatus` `stale` means the code is gone.

Paths may point outside the board root (another repo, a worktree); a path or commit that doesn't exist is `not_found`. Every code-tile prop: `references/api.md` "Objects".
Code navigation (Go to Definition, Find References, Outline) needs the language's server; if a panel says it wasn't found, answers are text search: tell the user where Canvas looked (`references/ui.md` "Zoom and keys") rather than suggesting PATH edits.

### Changes tiles

To show the user what you changed, create a changes tile instead of an HTML diff: `canvas object.create --type changes --json '{"props":{},"size":"fit"}'`.
Props: `base` (default `HEAD`: uncommitted work; `merge-base`: everything the branch changed, a PR's view; or a commit), optional `root` (another worktree of the board's repo, e.g. `"../wt-agent"`), `paths` and `title`. Creating it again with the same props returns your existing tile (`reused: true`).
A branch's or PR's diff without checking it out: `{"base": "origin/main", "head": "<branch or pull/N/head>"}`, read-only from git objects (head vs its merge-base with base; renames and deletions shown; no Stage/Discard; a line click opens a code tile pinned to that side's commit). A ref the repo lacks shows the exact `git fetch` to run: Canvas never fetches, so fetch first.
`{"ref": "<branch>"}` instead of `root`: the worktree that has that branch checked out while one does (live, stageable), else its commits as with `head`; once the branch is deleted it keeps showing the last commit it read (`props.refSha`), marked `merged in <sha>` or `branch gone`.
The user stages, unstages or discards per file, hunk, or selected lines; Stage/Unstage never change files: tell a user unsure of git so when they review your work.
Read what they kept with `object.get` (`changes.files[].hunks[]` with `status` and `lines`; `props.reviewed[]`), no render needed. Every field: `references/api.md` "Objects".

### Diagram tiles

For "show me who calls X" (or what X calls), create a live call graph from the language server instead of drawing one:
`canvas object.create --type diagram --json '{"props": {"symbol": "AgentReportSpool.read", "direction": "incoming", "depth": 2}}'`.

- `symbol` is `Type.member` or a bare name (labels optional); add `path` when the name is ambiguous or `line` instead of `symbol`. `direction`: `incoming` (callers), `outgoing` (callees) or `both`; `depth` 1–4 (default 2).
- The graph is computed by the language server (sourcekit-lsp answers from the index of the user's last `swift build`; its first answer in a project takes ~20 s). `canvas object.reload --id <tile>` computes it again and waits (up to 60 s); then read `props.graph` with `object.get`: `nodes[]` (`id`, `name`, `container`, `path`, `line`, `lines`, `excerpt`, `level`, `stale`, `expandable`), `edges[]` (`from` caller → `to` callee, call `lines`), `error`.
- It stays live: a file it shows changing recomputes it; nodes are re-found by symbol, and one whose symbol was deleted stays with a stale badge (`stale: true`). Only functions in the board's files are nodes.
- Open a node's next level by adding its id to `props.expanded` (the user clicks the node's +). The tile sizes itself to its first graph and grows when a node opens; `size: "fit"` works once it has one.
- Bind an arrow to a node with `{"object": "<diagram>", "node": "<node id>"}` (e.g. from a note explaining that caller).
- `error` says why a graph is empty or old (no server for the language, the symbol isn't declared there, an unindexed project); the last good graph stays.

### HTML explainers

`object.create --type html` with `{"html": "…", "title": "…"}` and `"size": "fit"` (with `frame` `{x, y, w}`, default width 640).
Tiles are sandboxed (no network unless you list hosts in `allowNetwork`) and preload Tailwind themed to the app, Mermaid, and grounded components (`<canvas-code>`, `<canvas-link>`, `<canvas-decisions>`, `<canvas-compare>`).
Ground every code claim with `<canvas-code>`/`<canvas-link>` instead of pasting code.
Read `references/html-explainers.md` before building an explainer: components, playbooks for plans, walkthroughs, comparisons and decisions, and Mermaid pitfalls.

### Shapes and arrows

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "blue", "fill": "none" | "semi" | "solid"}` with a `frame`; a rect drawn around tiles *encloses* them.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`; `relation` is the machine-readable edge, `label` what the user reads.
  For a walkthrough, join the stops with `"relation": "next_step"` arrows (label them "1 · parse"): ⌥⌘→/⌥⌘← step along them, centring each stop.
- `group`: `{"members": [ids], "title": "…", "color": "blue"}` is a titled, tinted region that always wraps its members; use one per lane or cluster instead of a rect plus a label.

Colors, fills, text sizes, arrow routing and binding rules: `references/shapes.md`.
`canvas get <id> --as graph` returns what an object encloses, overlaps, and connects to, so diagrams you draw are readable by other agents too.

### Boards a script keeps current

A script that rebuilds part of the board from elsewhere (a region per Linear ticket or PR, its status, its diff) names what it makes with `props.key` instead of keeping ids: any object takes one, unique on its board.
`object.upsert` finds the object holding the key and updates it (props merge; it stays where the user moved it unless you pass `frame`), or creates it when none does; `created` in the result says which.
Run the same batch every time; the second run changes only what changed, with the same ids, one ⌘Z:

```python
for t in tickets:  # e.g. from Linear
    k = t["id"]    # "REL-12389"
    canvas.object.batch(ops=[
        {"method": "object.upsert", "params": {"key": f"{k}/status", "type": "note", "props": {"markdown": f"**{t['state']}** · CI {t['ci']}"}, "size": "fit", "frame": {"x": 0, "y": 0, "w": 320}}},
        {"method": "object.upsert", "params": {"key": f"{k}/diff", "type": "changes", "props": {"root": t["worktree"]}}},
        {"method": "object.upsert", "params": {"key": k, "type": "group", "props": {"members": ["$0", "$1"], "title": f"{k} {t['title']}"}}},
    ])
```

`"$0"` is op 0's object whether it was created or updated. A frame given to an upsert applies on every run, so leave it out (or out of the batch after the first run) where the user may rearrange.
`object.find(key="REL-12389")` returns that object as `object.get` does (`not_found` when none holds it); `object.find(key_prefix="REL-")` lists every keyed object whose key starts with it, e.g. to delete regions of tickets that closed.
Taking a key another object holds, or upserting it as another type, is `conflict` naming the holder.

## Browser tiles

omp's `browser` tool opens a browser tile beside your terminal for each `browser.open` (find its id with `canvas board.history --limit 5`); `close` deletes it.
To drive a tile it didn't open, `browser.open({name: "<new tab name>", url: "canvas:obj_…"})` attaches to that tile at its current page; `browser.close` then lets go and leaves the tile on the board.
Without omp's tool (Claude Code, Codex, a script), drive tiles with `canvas browser <verb> <tile> [--key value]`, one call per step; every browser tile works, the user's too.
`canvas browser open <url>` opens one beside your terminal and prints its `surface_id`; `canvas browser list` lists the board's.
Loop: `canvas browser snapshot <tile> --interactive` (refs `e1`…), then `click <tile> --selector @e2`, `fill <tile> --selector @e1 --text "…"` (or `type`), `press <tile> --key Enter`, `wait <tile> --load_state complete`, `eval <tile> --script "document.title"`; refs last until the next snapshot or navigation, so snapshot again after the page changes.
`canvas browser screenshot <tile> --out shot.png` writes the PNG and prints its `path`. `close <tile>` deletes the tile: close only tiles you opened. Verbs and params: `references/browser.md`.
Codex runs these escalated, like every canvas command. Playwright, browser-use and Chrome DevTools MCP can't reach tiles: they are WebKit, with no CDP endpoint.
The page's viewport is the tile's body; the tool's `viewport` and emulation don't reach it: for a phone width resize the tile (`object.update` frame `{"w": 390, "h": 902}`).
Pages you drive stay live for 60 s wherever the tile is; 2 min after the tile leaves view the page is released (in-page state gone), so finish multi-step page work without long pauses.
Before trusting rAF or timer numbers, check `canvas get <tile>` → `page.visibility` (visible/hidden/driven/released).
After editing a page, reload any browser tile (the user's too) with `canvas object.reload --id <tile>` (it waits for the load), then read `canvas get <tile> --since <cursor>` → `page.errors`/`page.entries` before calling it clean; never change `props.url` to a dummy query to force a reload.
A released page's last log is in `page.previous`, and `page.cursor` stays valid across the release.
Also read a dev-server terminal on the board after edits (`agent.list` program `next dev`, `vite`…): `canvas agent.read --target <it> --lines 40`. Compile errors and 500s show there. Report, don't restart it unasked.
Leave tiles and servers the user is looking at until they say they're done with them ("looks good" isn't done). Don't promise a page refreshes by itself after you change what it shows: reload or render it and check.
Never open the Web Inspector yourself. Eval and CSP limits, visibility states, rendering unloaded pages, and history credit: `references/browser.md`.

## Follow mode

Your terminal has one follow tile: the canvas re-aims it at every source file in the project you read, edit, or write, and flashes the lines each edit changed.
It happens automatically and is on by default (never tell the user to turn it on); don't create code tiles just to show what you are reading, and don't resize it or lay out around its size.
If the user closes it, your terminal stops following until they turn Follow Files back on in your terminal's menu: don't re-create it or turn following back on yourself.
Create code tiles for code you want the user to keep looking at.

## Getting the user's attention

Never move the user's viewport (no panning or zooming to your objects) unless they ask. To point at something, raise an attention marker:

```sh
canvas view.attention --id obj_… --message "The race is here"   # → {"id": "obj_…", "active": true}
canvas view.attention --id obj_… --clear                         # take it back
```

Markers are keyed by the object (raising again replaces the message) and stay until the user looks at the object, even across app restarts.
A marker's bubble is at most the object's width (240–480 pt), so put the point of `--message` in its first ~40 characters.
Raise one marker per thing your answer points at. Your first marker after the user's next prompt clears your earlier turns' markers (the result lists them in `cleared`), while markers of the same turn stay together:
don't clear old ones yourself, and never re-raise the cleared ones; the user saw them with your last answer.

## Whose objects are whose

Every object records who created and last changed it (`createdBy`/`updatedBy`: `user` or an agent's tile).
Objects you created are yours to update, rearrange, and delete.
Touch the user's objects (their notes, drawings, tile layout) only when the user is collaborating with you on them: they asked, or they mentioned the object in this request.
Every agent change is undoable with ⌘Z, but that is a safety net, not a license.

## Other agents

Agents in other terminal tiles (any canvas in the app) are reachable by tile id or tile name:

```sh
canvas agent.list                                    # every terminal: tile, kind, name, lifecycle, board, root, `program` (foreground program) and `title` (its OSC title)
canvas agent.prompt --target reviewer --text "Review the diff in src/store.ts"   # → waitable, submittedAt
canvas agent.wait --target reviewer --timeoutMs 600000   # until idle/done/blocked; `until` narrows it
canvas agent.read --target reviewer --since prompt   # only what came after your last agent.prompt
```

When `agent.prompt` returns `waitable`, call `agent.wait` right away: it waits for the work you just asked for, not the previous idle.
Then `agent.read --since prompt` returns what followed your prompt (its echo, then the reply), and `agent.read --final true` only its last answer (`unavailable` mid-turn or for opencode: use `--since prompt`; `cutOff` means the turn died on that error: say so, don't treat it as done).
A prompt sent while the agent is `working` joins that turn: `agent.wait` returns at its end. The last answer survives an app restart, and an agent that finished while Canvas was closed comes back `done` with it.
Hand over board objects instead of describing them: `agent.prompt` `mentions=[{"object": id}, {"object": code_id, "lines": {"start": 41, "end": 48}}]` reach the receiver as hidden context naming your terminal.
Kind `omp`, `claude`, `codex`, `gemini` (before 0.60) or `opencode` reports a lifecycle (a Codex tile is `blocked` at launch while Codex asks whether to trust the folder).
Agents without an integration (aider via Canvas's `aider` wrapper, any CLI's OSC 9/777 or bell) have their program as `kind` and `lifecycle.via: "notifications"`: `done` when they last said they wait, `unknown` after a prompt, never working/blocked; `agent.wait` returns at their next notification (give it `timeout_ms`), and `mentions` can't go to them.
Kind `unknown` (a shell, another CLI) has none: `agent.wait` fails once 15 s pass without a first report, so poll `agent.read --since prompt`; `program` and `title` still hint at its state.
A `conflict` saying the agent was working when Canvas last closed and hasn't reported since (`lifecycle.restored`) means read its screen (`agent.read --lines 40`) before deciding; never `force` it if the screen shows a question or approval.
Don't prompt an agent that is `blocked`; it is waiting for its user. `agent.prompt` to one fails with `conflict` quoting what it waits on, and so does one whose foreground program isn't its agent (nvim, another tmux pane): tell the user.
Never answer another agent's approval with `force: true`: it types into the dialog and presses Return, which in an approval menu picks the highlighted option (usually allow). Force only when you know the dialog is gone.

## Compositions

Reusable helpers come built into the SDKs, plus your own in `~/.canvas/compositions` (yours shadow built-in ones of the same name). In Python:

```python
canvas.compositions.available()                              # name -> summary
canvas.compositions.grid.arrange([id1, id2, id3])            # grid beside your terminal, clear of other tiles
canvas.compositions.locations.open(["src/a.ts:12-40", "src/b.ts#L7"])
```

A composition is a plain module; functions whose first parameter is named `canvas` receive the client.
When you catch yourself repeating a multi-call canvas pattern, write it as a composition in `~/.canvas/compositions/<name>.py`
(and `.ts` for the TS client, `client.compositions.<name>`), then `canvas.compositions.reload()`. Improve existing ones rather than forking them.

## Boards

One canvas per directory (repo or worktree, keyed by branch). Boards open as tabs of one window.
`canvas board.open --root <absolute dir>` opens a directory's board as a tab (creating it if new) behind the user's current tab; pass `--select true` only when the user asked to see it.
Then address it with `board: <id>` (from the result) on every call, and start agents there by creating terminal tiles on that board.
`canvas board.list` shows every stored board, including archived ones whose worktree is gone.
`canvas board.export` writes a readable snapshot to `<root>/.canvas/board.json` for committing when the user asks to save the board with the repo.

## When the user asks how to use Canvas

Help › Canvas Basics ⌥⌘/ is the user's legend of everything on screen (dots, rings, markers, follow tile, tray, keys); `references/ui.md` has the same text: answer "what is this?" and "which key?" from it, not from Canvas's source.
⌘P goes to any tile or opens a repo file (`core.py:120` opens at a line, `@name` finds a symbol); ⌥⌘-arrows (all four) move between tiles; Return gives the selected tile the keyboard, Esc gives it back (in a terminal or a web page Esc stays with the program or page: ⌘Esc leaves any tile).
⌘J goes to the next thing that needs the user; ⌘[ / ⌘] go back and forward; ⌘9 fits everything; ⌘Z undoes the user's last change or an agent's, and a notice names what it undid.
Hyper-click (⌃⌥⇧⌘-click) or Edit › Mention ⇧⌘M stages a mention for the terminal the tray shows ("→ name ▾" picks another); Hyper-V pastes staged mentions into the terminal the user is typing in (else that one), for agents without an integration.
Mouse users: the wheel pans, ⌘-scroll zooms around the pointer, ⇧-scroll pans sideways; don't tell a user without a trackpad that zooming needs a pinch.
On a PC keyboard ⌘ is the Windows key and does what Ctrl does elsewhere, ⌥ is Alt (`macos-option-as-alt = true` in their Ghostty config for Meta), and Hyper is Ctrl+Alt+Shift+Win: point them at Canvas Basics' "Coming from Linux or Windows" section.
Every action is also in the menu bar (Help › search).
