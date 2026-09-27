---
name: canvas
description: You are running inside Canvas (CANVAS_ENV=1), an infinite canvas where your terminal sits next to tiles and drawings the user also sees. Use before showing code/notes/HTML explainers/diagrams/changes on the canvas, reading or arranging what is on it, pointing the user at things, and talking to other agents. Answering a plain question or one about a mentioned item needs no skill.
---

# Working in Canvas

Your terminal is one tile on an infinite canvas the user is looking at.
Next to it live code tiles, changes (review) tiles, markdown notes, image tiles, browser tiles, sandboxed HTML tiles, and shapes/arrows/ink.
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
  (resolved from your shell's cwd, then the board root; a bare `core.py:42` opens only when that name is unique or clearly nearest the cwd), so write repo-relative `path:line`, not bare names or prose like "in the store module".
- **Name what the user will look for.** Go to (⌘P) matches every tile's caption and terminal name and shows each code tile's caption under its path, so captions tell excerpts of one file apart;
  the tray labels the terminal mentions go to by its `name`: caption your code tiles and name terminals you create.
- **Code tiles tint their `range` only among other rows.** A `size: "fit"` tile shows exactly its range, untinted.
  To mark a few lines inside more context, give the tile a taller frame instead of fitting it.
- **Line-bound arrows pin when their line is out of view.** An arrow end bound to `lines` of a code tile attaches at that row only while the tile shows it;
  scrolled out, the end pins to the top of the code or the bottom of the tile.
  Keep bound lines inside the rows the tile shows (fit the range, or bind to lines near its top).
- **Attention markers stay until the user looks, across app restarts.** A marker clears when the user looks at the object in the active window, or when you `--clear` it.
  Your markers belong to your turn: the first one you raise after the user's next prompt clears the ones from your earlier turns (you don't need to), while markers raised in the same turn (approvals included) stay together.
- **Params are checked.** A param a method doesn't take (a typo, or `board` where the schema has none), or a missing required one, fails with `invalid_params` listing every param the method takes.
  Objects you create or change on another board (`board`) are credited to your terminal; placement there goes near the view's centre.

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
A shape `over` a tile lies wholly on it and marks a region, in the tile's local units (a browser page starts 32 pt below the title bar); `partly over` means more than half of it, the region clipped to the tile. Look at that part with `canvas render <tile>`.
On a browser or HTML tile the mention adds `page elements under it (<url>):` lines (`<selector> "<text>"`), read when the prompt was sent: re-check with the selectors or a render if the page may have changed.
A `group` mention covers the user's whole selection or a group of drawings; a shape's text is quoted whole (newlines as `\n`).
Arrows the user draws bind to the tile or shape their end was released on or near, like `{object}` ends from the API.
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

Python: `canvas.view.render(target="obj_…", full=True)["path"]` (`target` is an id, a list of ids, or `{"x","y","w","h"}`).
The result has `path` (a new PNG under `$TMPDIR/canvas-renders/`, or your `out`) and, per object drawn, its `pixelRect`, `state`, and `overflow`:
`state: placeholder` means it didn't paint in time (`reason` says why; raise `timeoutMs`); `overflow {x, y}` is content beyond the frame (resize by that much, or render `--full`).
App chrome (toolbar, tray, selection rings, markers) is never drawn.
`view.snapshot` is the window as the user sees it; `view.get` returns the viewport, `promptTarget`, `focused` and `selection`.
`canvas board.history --since <cursor>` lists who created, moved, and deleted what (`actor` `user`, `system` or `agent:<tile>`) since your last look.
Every result field, pixel-to-canvas mapping, and history detail: `references/rendering.md`.

## Show your work on the canvas

Create objects when a visual helps the user more than terminal text: a plan they will come back to, code they should look at, a comparison, a diagram.
Don't mirror your whole transcript onto the canvas.
Keep the first draft to about one screen (see Known surprises) and grow it when the user asks.

Omit `frame` and the canvas places new objects in the free spot nearest your terminal (see Known surprises); within 10 minutes of your last object, the next one stacks below it (else right of it) instead.
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
| A chart or figure | `image`: `{"path": "out/fig.png", "caption": "…"}`: save the figure to a file and show it; re-save to the same path and the tile reloads. No base64 PNGs in HTML |
| A rich explainer, comparison, decision | `html` tile, see below |
| Structure: boxes, labels, relations | `shape` / `arrow`, see below |
| A web page | `browser`: `{"url": "http://localhost:3000"}` (your browser tool opens its own; see Browser tiles) |

Code paths may point outside the board root (`../other-repo/src/x.ts` or an absolute path, e.g. a worktree); the tile reads git from that file's own repository, `pinnedCommit` included.
A path or commit that doesn't exist is `not_found`.

Any tile or text shape takes `scale` in its props (0.25–8, default 1): it draws everything inside bigger or smaller while laying out as if its frame were frame ÷ scale.
To make a tile readable from further out without changing what it shows, set `scale` and multiply `w`/`h` by the same factor (or use `size: "fit"`, which measures at the scale).
Users scale objects with ⌥-drag on a corner or the Scale menu; leave their scale alone unless asked.

Update with `object.update` (props shallow-merge; `frame` may give any of x, y, w, h; pass `rev` from your last read or create to avoid clobbering a concurrent edit; `conflict` means re-read and retry).
After changing a note's markdown or an HTML tile's html, refit in the same call: `object.update` with `"size": "fit"`.
Before styling a chart or page, read `view.get` `appearance` (`dark`|`light`); for dark, e.g. matplotlib `plt.style.use("dark_background")` and `savefig(…, transparent=True)`, not white slabs.
The user can share without you: the object menu has Copy as Image, Save as PNG…, and for HTML tiles Save as HTML… and Open in Browser. Don't rebuild an export by hand unless they ask for another format.
Delete with `object.delete`; deleting a terminal tile ends its session and whatever runs in it.

### Notes

A note created without a frame height fits its markdown (at `frame.w`, default 280), so `frame` can be just `{x, y, w}`.
`title` sets its title bar (default "Note").
Markdown code fences are live when anchored to real code, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ````
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence.
- Plain fences are free-written snippets; `file:line` references in notes become links; `![alt](out/fig.png)` shows an image (board-relative, or absolute inside the board root or the temp dir).

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

### Changes tiles

To show the user what you changed, create a changes tile instead of an HTML diff: `canvas object.create --type changes --json '{"props":{},"size":"fit"}'`.
Props: `base` (default `HEAD`: uncommitted work, staged or not; also `merge-base` or a commit), optional `root` (another worktree of the board's repo, e.g. `"../wt-agent"`: review your worktree on the board where your terminal is), `paths` (files/dirs in it) and `title`.
Creating it again with the same `root`/`base`/`paths` returns your existing tile (`reused: true`); a fitted tile grows as hunks are added.
The user stages or discards per file, hunk, or selected lines (each one ⌘Z), marks files Viewed, clicks a line to open a code tile, and Hyper-clicks a line to mention it (the mention says its side, added/removed/context, and the hunk's state).
Read what they kept with `object.get`: `changes.files[]` (path, status, added/removed, `viewed`, `hunks[]` with a stable `id`, header, old/new ranges, `status` unstaged|partial|staged|committed, and `lines`, the unified text, at most 200) as git has it now, so no render is needed;
`partial` means staged, then changed again. `props.reviewed[]` lists what the user staged or discarded (`action` stage|revert, `scope` file|hunk|lines, `hunk`, `patch` applied, reversed for a discard). Editing `reviewed` does nothing to git.

### HTML explainers

`object.create --type html` with `{"html": "…", "title": "…"}`.
Add `"size": "fit"` (with `frame` `{x, y, w}`, default width 640) to make the tile exactly as tall as the rendered page at that width, up to 4000 pt; `object.measure --type html` gives the same size without creating it.
Tiles are sandboxed: no network unless you list hosts in `allowNetwork`, no native access; `<img src="out/fig.png">` loads images from the board root or the temp dir (no `file://`).
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

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "blue", "fill": "none" | "semi" | "solid"}` with a `frame`; a rect drawn around tiles *encloses* them.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`;
  an end bound to a code tile's `lines` attaches at that row (see Known surprises). `relation` is the machine-readable edge, `label` what the user reads.
- `group`: `{"members": [ids], "title": "…", "color": "blue"}` is a titled, tinted region that always wraps its members; use one per lane or cluster instead of a rect plus a label.

Colors, fills, text sizes, arrow routing and binding rules: `references/shapes.md`.

`canvas get <id> --as graph` returns what an object encloses, overlaps, and connects to, so diagrams you draw are readable by other agents too.

## Browser tiles

omp's `browser` tool opens a browser tile beside your terminal for each `browser.open` (find its id with `canvas board.history --limit 5`); `close` deletes it.
The page's viewport is the tile's body (`innerWidth` = frame width, `innerHeight` = frame height − 58). The tool's `viewport`, `tab.setViewport`, `tab.emulate` and `tab.devices()` don't reach it: for a phone width resize the tile (`object.update` frame `{"w": 390, "h": 902}`).
A browser tile's `title` is yours and never overwritten; the page's own title is `props.pageTitle` and doesn't bump `rev`.
Pages you drive stay live for 60 s wherever the tile is; all tiles share one signed-out WebKit profile.
Eval and CSP limits, rendering unloaded pages, and history credit: `references/browser.md`.

## Follow mode

Your terminal has one follow tile: the canvas re-aims it at every source file in the project you read, edit, or write,
flashes the lines each edit or write changed, and keeps a short history (edited locations marked with a pencil, kept longer than reads).
Files in another worktree of the board's repository count too (the tile shows the absolute path with that worktree's changes).
Images, PDFs and other binaries, files under the temp dir, and files that no longer exist never re-aim it.
While the user scrolls or clicks in it, it holds still for ~10 s and counts what it missed ("N new ▸") before following again.
If the user closes it, your terminal stops following until they turn "Follow Files" back on in your terminal's menu:
don't re-create it or turn following back on yourself. Closing your terminal closes its follow tile.
It happens automatically; don't create code tiles just to show what you are reading. It may be narrower than 640 pt so it fits in the user's view: don't resize it or lay out around its size.
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
Don't prompt an agent that is `blocked`; it is waiting for its user (omp reports every approval prompt as blocked, nested ones included, and the user sees it as a ring and bubble on its terminal, on the tab, and as an edge pill when off screen).
`agent.prompt` to a `blocked` agent fails with `conflict` quoting what it waits on; pass `force: true` only when you know the dialog is gone (e.g. Claude Code after Esc on an approval).

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

⌘P goes to any tile or opens a repo file (`core.py:120` opens at a line, `@name` finds a symbol); ⌥⌘-arrows move between tiles; Return gives the selected tile the keyboard, Esc gives it back;
⌘J goes to the next thing that needs the user (blocked agents, then marked tiles); ⌘W closes the selected tile or focused terminal; ⌘F finds in a code tile;
⌘9 fits everything, ⌘0 is 100%, ⌘=/⌘- zoom; ⌘T opens a terminal; ⌘G groups the selection; ⌘Z undoes the user's last change or an agent's (never follow re-aims or the app's own bookkeeping).
Hyper-click (⌃⌥⇧⌘-click) stages a mention for the terminal the tray shows; Hyper-V pastes staged mentions into a terminal whose agent has no integration.
⌘-click a `path:line` in terminal output to open it in the terminal's preview tile (⌥⌘-click keeps a separate tile). Code › Go to Definition ⌃⌘J, Find References ⌃⌘R (Open All lays them out as excerpts), Outline ⌃⌘O (type to filter).
File › Review Changes ⇧⌘R; right-click empty canvas for New Terminal/Note/Browser Here; right-click a terminal for Follow Files. Every action is also in the menu bar (Help › search).
