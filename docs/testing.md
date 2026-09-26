# Testing Canvas

## Behavior tests

```sh
swift run -j 4 CanvasCoreTests        # swift-testing suites for CanvasCore
bun scripts/gen-clients.ts --check    # generated TS/Python clients match schema/canvas-api.json
(cd clients/python && python3 -m unittest)   # Python SDK: compositions loading, shipped compositions
```

`CanvasCoreTests` is an executable target, not a test target: with only the Command Line Tools installed, `swift test` doesn't discover swift-testing suites, so `main.swift` calls the swift-testing entry point. Tests drive real objects (boards, the socket server over a Unix socket), never mocks of our own code.

## Running the app on a shared machine

Tim's Mac runs many agents at once and he is using it while you test. The app must never take focus, never appear on the Space he's viewing, and must be quit when you're done.

`scripts/dev.sh` runs one isolated development instance per checkout:

```sh
scripts/dev.sh start [root]      # build, bundle, launch on the testing Space without activating
scripts/dev.sh cli board.get     # the canvas CLI against this instance (sets CANVAS_SOCKET)
scripts/dev.sh snapshot out.png  # what the window shows right now
scripts/dev.sh input click 400 300 --mods hyper
scripts/dev.sh restart           # rebuild + relaunch; terminal sessions keep running
scripts/dev.sh stop              # quit and kill this instance's terminal sessions
```

What it sets up:

- `CANVAS_HOME=<checkout>/.canvas-home` holds this instance's socket, boards, pid, and `app.log`, so it never touches the installed app's boards or another agent's instance.
- `CANVAS_NO_ACTIVATE=1`: the app refuses to activate (`CanvasApplication`), so it can't steal focus or switch Spaces.
- A yabai rule sends every `Canvas` window to Space 8 (`CANVAS_DEV_SPACE`), floating and maximized. Space 8 is reserved for Canvas testing; coordinate with other agents before using another.
- `CANVAS_DEV_INPUT=1` enables input replay (below).

### Seeing the window

A window on a Space nobody is viewing stops redrawing, so `screencapture` returns stale pixels. Use `view.snapshot` (`scripts/dev.sh snapshot`), which renders the window in-process. Terminal tiles are drawn from their session text because Ghostty renders through Metal.

Snapshots are at the display's backing scale (2× on this Mac): divide pixel coordinates by 2 to get window-content points for input replay.

### Input replay

Real mouse input can't reach an unviewed Space, and posting system events needs a TCC grant this process doesn't have. `scripts/dev.sh input` sends events into the instance's own event queue, so the Hyper monitor, hit testing, and responders run as they do for real input:

```sh
scripts/dev.sh input click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
scripts/dev.sh input drag <x> <y> <toX> <toY> [--mods …]
scripts/dev.sh input flags <x> <y> --mods hyper     # hold Hyper over x,y (hover outline); omit --mods to release
scripts/dev.sh input text "hello"                   # insert into the first responder
scripts/dev.sh input command insertNewline:
scripts/dev.sh input shortcut z --mods cmd
scripts/dev.sh input scroll <x> <y> <dx> <dy>
```

Coordinates are window-content points from the top-left. Prefer Hyper clicks and API calls: a plain click on a window of an inactive app is how macOS decides to activate it, and `CANVAS_NO_ACTIVATE` is the only thing standing between that and Tim's screen.

### Terminals and agents

- Terminal text: `TMPDIR=$(getconf DARWIN_USER_TEMP_DIR) zmx history canvas-<tileId> | tail -n 40` (zmx keys its socket directory off `TMPDIR`; the GUI app's differs from a herdr pane's).
- Create an omp tile: `scripts/dev.sh cli object.create --type terminal --json '{"props":{"cwd":"<repo>","command":["omp"]}}'`.
- Prompt it and wait: `scripts/dev.sh cli agent.prompt --target <tileId> --text "…"`, then `scripts/dev.sh cli agent.wait --target <tileId> --timeoutMs 300000`.
- Recent terminal text through the API: `scripts/dev.sh cli agent.read --target <tileId> --lines 40`.
- Reboot resume: quit the app (`kill $(cat .canvas-home/pid)`), `zmx kill canvas-<tileId> --force`, `scripts/dev.sh start`. A tile whose session is gone reruns `props.command`, or resumes its recorded omp session with `omp --resume=<sessionId>` (the original flags, e.g. `-e <checkout extension>`, are not replayed, so the resumed omp loads the globally installed extension).
- macOS notifications (agent done/blocked while the app is in the background) are never requested or posted with `CANVAS_NO_ACTIVATE=1`; `app.log` records "notification suppressed" instead.
- The omp extension is installed globally as a symlink to the main checkout (`~/.omp/agent/extensions/canvas.ts`). To test a modified extension from another checkout, launch omp with `["omp", "--no-extensions", "-e", "<checkout>/extensions/omp/canvas.ts"]`.

### Hygiene

- Gate builds with `machine-ok --wait`; when several agents build at once, use `swift build -j 2`.
- One instance per checkout, and at most one omp tile at a time unless the test needs more.
- `scripts/dev.sh stop` when the test is done, not at the end of the session. It also kills the instance's zmx sessions.
