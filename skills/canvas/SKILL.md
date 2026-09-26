---
name: canvas
description: You are running inside Canvas (CANVAS_ENV=1), an infinite canvas where your terminal sits next to code, note, browser, HTML, and drawn objects the user also sees. Use for reading <canvas-mentions>, showing code/notes/HTML explainers/diagrams on the canvas, pointing the user at things, and talking to other agents.
---

# Working in Canvas

Your terminal is one tile on an infinite canvas the user is looking at. Next to it live code/diff tiles, markdown notes, browser tiles, sandboxed HTML tiles, and shapes/arrows/ink. You and the user read and change the same objects. The canvas is the shared working state; your transcript stays in your terminal.

You are in Canvas when `CANVAS_ENV=1`. Your tile's environment also has `CANVAS_TILE_ID` (you), `CANVAS_BOARD_ID`, `CANVAS_BOARD_ROOT` (the repo/worktree this canvas belongs to), and `CANVAS_SOCKET`.

## Pick a client

- **You have a persistent Python REPL (e.g. an `eval` tool): use the Python SDK.** One connection, typed methods, compositions.
  ```python
  from canvas_sdk import canvas
  board = canvas.board.get()                      # manifest of every object
  note = canvas.object.create(type="note", props={"markdown": "# Plan"})["object"]
  ```
- **Otherwise: the `canvas` CLI** (on PATH in every tile). Methods are `namespace.method`; params are `--key value` (values parse as JSON when they can) or `--json '{…}'`.
  ```sh
  canvas methods                                   # every method with its description
  canvas board.get
  canvas object.create --type note --json '{"props":{"markdown":"# Plan"}}'
  canvas get obj_… --as graph                      # object.get shorthand
  ```
- TypeScript/Bun: `new CanvasClient()` from `clients/ts/src/index.ts`, methods under `client.api.<ns>.<method>({…})`.

`caller` (you) and `board` are filled from the environment, so objects you create are attributed to you and placed next to your terminal. Method reference with examples: `references/api.md` in this skill's directory.

## Read what the user points at

When the user Hyper-clicks things on the canvas and then prompts you, the prompt carries a hidden block:

```text
<canvas-mentions board="brd_…" root="/repo">
[1] code src/store.ts:41-48 (symbol restore) · tile obj_A · diff vs merge-base 1a2b3c4
  > 41   export async function restore(id: string) {
[2] dom http://localhost:3000/login · button#submit "Sign in" · browser tile obj_B
[3] shape rect obj_C "auth path?" (drawn by user) · encloses obj_A · arrow → obj_D (hypothesis_about)
</canvas-mentions>
```

"this", "these", "here", "that box" in the prompt refer to these entries, in order. Excerpts are short; read the real file or `canvas get <id>` for more. A drawn shape means nothing by itself: read what it encloses and connects (`canvas get <id> --as graph`) or look at it (`--as image`). An `(edited)` marker means the object changed after the user staged it.

To see the canvas as the user does: `canvas view.snapshot --out /tmp/canvas.png`, then read the PNG.

## Show your work on the canvas

Create objects when a visual helps the user more than terminal text: a plan they will come back to, code they should look at, a comparison, a diagram. Don't mirror your whole transcript onto the canvas.

Omit `frame` and the canvas places new objects beside your terminal without covering anything. Pass a frame only when you are deliberately laying things out (`canvas.compositions.grid.arrange(ids)` does it for you).

| Want | Create |
| --- | --- |
| Point at real code | `code` tile: `{"path": "src/store.ts", "range": {"start": 41, "end": 60}, "mode": "source"}` (or `"mode": "diff"` for the merge-base diff; `path` relative to the board root) |
| Several locations at once | `canvas.compositions.locations.open(["src/a.ts:10-40", "src/b.ts:7"])` |
| Durable notes, plans, findings | `note`: `{"markdown": "…"}` |
| A rich explainer, comparison, decision | `html` tile, see below |
| Structure: boxes, labels, relations | `shape` / `arrow`, see below |
| A web page | `browser`: `{"url": "http://localhost:3000"}` (your native browser tool also drives these) |

Update with `object.update` (props shallow-merge; pass `rev` from your last read to avoid clobbering a concurrent edit; `conflict` means re-read and retry). Delete with `object.delete`.

### Notes

Markdown. Code fences are live when anchored to real code, so prefer anchors over pasted code:

- Excerpt, rendered from disk: ```` ```ts file=src/store.ts#L41-60 ```` or ```` ```ts file=src/store.ts symbol=restore ````
- Proposed change, rendered as a diff against the real range: add `propose` (```` ```ts file=src/store.ts#L41-48 propose ````) and write the new code in the fence.
- Plain fences are free-written snippets; `file:line` references in notes become links.

Anchors prefer symbols (they survive edits); line anchors are re-found by content and show a stale badge when lost.

### HTML explainers

`object.create --type html` with `{"html": "…", "title": "…"}`. Tiles are sandboxed: no network unless you list hosts in `allowNetwork`, no native access. Every tile preloads Tailwind (themed to the app: `bg-background text-foreground bg-muted bg-card border-border text-muted-foreground bg-accent bg-code text-warn text-ok`, dark mode automatic), Mermaid (`<pre class="mermaid">`), and grounded components:

- `<canvas-code path="src/x.ts" lines="10-40" symbol="Name">` — a live excerpt from the real file; click opens a code tile.
- `<canvas-link path="src/x.ts" line="42">text</canvas-link>` — a file:line link that opens a code tile.
- `<canvas-decisions key="…" question="…"><canvas-option value="…" label="…">…</canvas-option></canvas-decisions>` — the user's pick lands in the tile's `props.state[key]`; read it back with `object.get`.
- `<canvas-compare><canvas-pane label="Before">…</canvas-pane><canvas-pane label="After">…</canvas-pane></canvas-compare>` — side-by-side panes.

Ground every code claim with `<canvas-code>`/`<canvas-link>` instead of pasting code. Playbooks for plans, walkthroughs, comparisons, decisions, and architecture diagrams: `references/html-explainers.md`. Read it before building an explainer.

### Shapes and arrows

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "…"}` with a `frame`. A rect drawn around tiles *encloses* them.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…"}`. Endpoints bind to objects (optionally a line range or a DOM `selector`) or to a `{"point": [x, y]}`. `relation` is the machine-readable edge (`calls`, `depends_on`, `hypothesis_about`, …); `label` is what the user reads.
- `group`: `{"members": [ids], "name": "…"}`.

`canvas get <id> --as graph` returns what an object encloses, overlaps, and connects to, so diagrams you draw are readable by other agents too.

## Follow mode

Your terminal has one follow tile: the canvas re-aims it at every file you read or edit (shown as a merge-base diff, with a short history). It happens automatically; don't create code tiles just to show what you are reading. Create code tiles for code you want the user to keep looking at.

## Getting the user's attention

Never move the user's viewport (no panning or zooming to your objects) unless they ask. To point at something, raise an attention marker:

```sh
canvas view.attention --id obj_… --message "The race is here"
```

## Whose objects are whose

Every object records who created and last changed it (`createdBy`/`updatedBy`: `user` or an agent's tile). Objects you created are yours to update, rearrange, and delete. Touch the user's objects (their notes, drawings, tile layout) only when the user is collaborating with you on them: they asked, or they mentioned the object in this request. Every agent change is undoable with ⌘Z, but that is a safety net, not a license.

## Other agents

Agents in other terminal tiles (any canvas in the app) are reachable by tile id or tile name:

```sh
canvas agent.list                                    # tile, kind, name, lifecycle (working/blocked/idle/done)
canvas agent.prompt --target reviewer --text "Review the diff in src/store.ts"
canvas agent.wait --target reviewer --timeoutMs 600000   # until idle/done/blocked; `until` narrows it
canvas agent.read --target reviewer --lines 80       # the tail of its terminal text
```

`agent.wait` after `agent.prompt` waits for the work you just asked for, not the previous idle. Read the result with `agent.read` (or have the other agent write a note). Don't prompt an agent that is `blocked`; it is waiting for its user.

## Compositions

Reusable helpers come built into the SDKs, plus your own in `~/.canvas/compositions` (yours shadow built-in ones of the same name). In Python:

```python
canvas.compositions.available()                              # name -> summary
canvas.compositions.grid.arrange([id1, id2, id3])            # grid beside your terminal, clear of other tiles
canvas.compositions.locations.open(["src/a.ts:12-40", "src/b.ts#L7"], mode="diff")
```

A composition is a plain module; functions whose first parameter is named `canvas` receive the client. When you catch yourself repeating a multi-call canvas pattern, write it as a composition in `~/.canvas/compositions/<name>.py` (and `.ts` for the TS client, `client.compositions.<name>`), then `canvas.compositions.reload()`. Improve existing ones rather than forking them.

## Boards

One canvas per directory (repo or worktree, keyed by branch). `canvas board.list` shows every stored board, including archived ones whose worktree is gone. `canvas board.export` writes a readable snapshot to `<root>/.canvas/board.json` for committing when the user asks to save the board with the repo.
