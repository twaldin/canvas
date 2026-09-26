# Canvas API from an agent

The method catalog is `schema/canvas-api.json`; `canvas methods` prints every method with its description, and in Python `help(canvas.<ns>.<method>)` shows the signature. This page covers the conventions the catalog doesn't spell out.

## Calling conventions

| | Python SDK | CLI |
| --- | --- | --- |
| Call | `canvas.agent.read(target="obj_…", lines=50)` | `canvas agent.read --target obj_… --lines 50` |
| camelCase params | snake_case keywords: `timeout_ms`, `session_id` | as in the schema: `--timeoutMs` |
| Nested params | dicts: `props={"range": {"start": 1, "end": 9}}` | `--props.range.start 1` or `--json '{"props":{…}}'` |
| Result | the `result` object as a dict | pretty JSON on stdout |
| Error | raises `CanvasError` (`.code`) | `code: message` on stderr, exit 1 |

Error codes: `not_found` (no such object/agent/board), `conflict` (stale `rev`: re-read, re-apply, retry), `invalid_params`, `unavailable` (e.g. a terminal without a running session, or the app isn't running), `unsupported`, `timeout` (`agent.wait`).

## Reading the board

- `board.get` returns every object with heavy props trimmed (long markdown, HTML source); `object.get` returns one object whole.
- Poll cheaply: keep `revision` from one `board.get` and pass it as `since` next time; `changed` lists ids created or changed after it.
- `object.get --as graph` gives `encloses`, `enclosedBy`, `overlaps`, `arrowsOut`, `arrowsIn`; `--as image` a PNG (`--out file.png` with the CLI).
- `tray.list` shows what the user has staged but not yet sent. Don't drain the tray yourself; your harness attaches it to the user's next prompt.

## Objects

- `frame` is `{x, y, w, h}` in canvas points (100% zoom). Omit it on create for automatic placement beside your terminal.
- `props` on `object.update` merge shallowly: `{"range": …}` replaces `range` and keeps other props. Set a prop to `null` to clear it.
- Every change bumps `rev`. Pass `rev` on updates to objects the user may be editing.
- Terminal tiles: `{"cwd": "/path", "command": ["omp"]}` starts an agent in a new tile (its session survives app restarts). Only start agents the user asked for.

## Events

Long-running helpers can stream changes instead of polling: `events.subscribe` (TS: `subscribe(onEvent, {events: ["object.updated"]})`) turns a dedicated connection into a stream of `object.created`, `object.updated`, `object.deleted`, `tray.changed`, `agent.lifecycle`, `follow.updated`.

## Agents

`agent.list` covers every canvas in the app. `lifecycle.state` is `working`, `blocked` (waiting for its user: an approval or a question), `idle`, `done` (idle with results the user hasn't looked at yet), or `unknown` (no integration reporting). `agent.read` returns up to 2000 lines of the terminal's text, trailing blank lines removed.
