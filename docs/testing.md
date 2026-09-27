# Testing Canvas

## Behavior tests

```sh
swift run -j 4 CanvasCoreTests        # swift-testing suites for CanvasCore
bun scripts/gen-clients.ts --check    # generated TS/Python clients match schema/canvas-api.json
(cd clients/python && python3 -m unittest)   # Python SDK: compositions loading, shipped compositions, connection config/reconnect against a fake socket
```

`CanvasCoreTests` is an executable target, not a test target: with only the Command Line Tools installed, `swift test` doesn't discover swift-testing suites, so `main.swift` calls the swift-testing entry point. Tests drive real objects (boards, the socket server over a Unix socket), never mocks of our own code.

## Running the app on a shared machine

Tim's Mac runs many agents at once and he is using it while you test. The app must never take focus, never appear on the Space he's viewing, and must be quit when you're done.

`scripts/dev.sh` runs one isolated development instance per checkout:

```sh
scripts/dev.sh start [root]      # build, bundle, launch on the testing Space without activating
scripts/dev.sh cli board.get     # the canvas CLI against this instance (sets CANVAS_SOCKET)
scripts/dev.sh shot out.png      # real pixels: what the screen shows (verification)
scripts/dev.sh snapshot out.png  # view.snapshot: what agents see (not verification)
scripts/dev.sh move 8            # put the window on Space 8 for Tim to watch; `move` alone returns it
CANVAS_DEV_SPACE=8 scripts/dev.sh restart   # relaunch straight onto Space 8 while Tim watches
scripts/dev.sh input click 400 300 --mods hyper
scripts/dev.sh restart           # rebuild + relaunch; terminal sessions keep running
scripts/dev.sh stop              # quit and kill this instance's terminal sessions
```

What it sets up:

- `CANVAS_HOME=<checkout>/.canvas-home` holds this instance's socket, boards, pid, and `app.log`, so it never touches the installed app's boards or another agent's instance.
- `CANVAS_NO_ACTIVATE=1`: the app refuses to activate (`CanvasApplication`), so it can't steal focus or switch Spaces.
- A one-shot yabai rule parks the launch's first `Canvas` window on Space 7 (floating, maximized) and is removed once `dev.sh` has moved the window to the testing Space. That Space is the first Space of the `CanvasTest` virtual screen (a BetterDisplay headless monitor placed diagonally below-right of the built-in display, touching it only at the corner), or `CANVAS_DEV_SPACE`. A standing rule on `app=Canvas` would also grab every later window (tabs, other instances, Tim's own boards) and hide them on Space 7. Agents working in parallel each create their own screen (`Agent-<name>`, per the global AGENTS.md) and select it with `CANVAS_DEV_DISPLAY=Agent-<name>`. A yabai rule can't place a window on another display's Space: the window lands on whatever Space Tim is viewing, so never point the rule at the virtual screen. Recreate the screen if it's gone: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=CanvasTest --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=CanvasTest --connected=on --placement=1512x982`.
- Boards open as tabs of one window, and `open-boards.json` in the home reopens them at launch. The initial root (`dev.sh start <root>`) is the selected tab. yabai moves windows behind AppKit's back, so a tab selected through the API while the app is inactive (`board.open --select true`) can reappear on Space 7; `scripts/dev.sh move` puts it back.
- `CANVAS_DEV_INPUT=1` enables input replay (below).

### Seeing the window

Verify what the screen shows with `scripts/dev.sh shot`: a WindowServer capture of the window, the same pixels a person sees. Only a displayed Space is composited, and a window anywhere else keeps a stale frame, so `shot` refuses unless the window is on a displayed Space. The testing Space on the virtual screen is always displayed, so shots work while Tim is elsewhere.

`view.snapshot` (`scripts/dev.sh snapshot`) is the agents' view, not verification: it redraws the window in-process and substitutes stand-ins for content drawn outside AppKit (code tiles render their text themselves, terminals are drawn from zmx session text, web views show cached images). It hides compositor and layer bugs by construction: during the astra-skyblock run, code tiles that were blank or smeared on screen looked perfect in `view.snapshot`.

Shots are at the display's backing scale (2× on both displays): divide pixel coordinates by 2 for window-content points (subtract the 28 pt title bar; `shot` includes the window frame, `snapshot` doesn't).

### Input replay

Real mouse input can't reach an unviewed Space, and posting system events needs a TCC grant this process doesn't have. `scripts/dev.sh input` sends events into the instance's own event queue, so the Hyper monitor, hit testing, and responders run as they do for real input:

```sh
scripts/dev.sh input click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
scripts/dev.sh input drag <x> <y> <toX> <toY> [--mods …]
scripts/dev.sh input rightclick <x> <y>             # opens the context menu on screen
scripts/dev.sh input menu <x> <y> "Scale/150%"      # performs that context-menu item without opening the menu
scripts/dev.sh input flags <x> <y> --mods hyper     # hold Hyper over x,y (hover outline); omit --mods to release
scripts/dev.sh input move <x> <y>                   # pointer move over tracking areas (code navigation hover)
scripts/dev.sh input text "hello"                   # insert into the first responder
scripts/dev.sh input command insertNewline:
scripts/dev.sh input shortcut z --mods cmd
scripts/dev.sh input scroll <x> <y> <dx> <dy>
scripts/dev.sh input magnify <x> <y> <amount>      # one pinch step: zoom × (1 + amount); 0.05 in, -0.05 out
```

Coordinates are window-content points from the top-left: `shot` pixels / 2 (a Retina capture), minus the 28-point title bar. Prefer Hyper clicks and API calls: a plain click on a window of an inactive app is how macOS decides to activate it, and `CANVAS_NO_ACTIVATE` is the only thing standing between that and Tim's screen.

`text`, `command`, and `shortcut` go to an open sheet (e.g. the ⌘G group-name prompt) when the window has one, so `input text "Auth"` then `input shortcut $'\r'` confirms it. Esc/Delete on the canvas: `input command cancelOperation:` / `input command deleteBackward:` (the canvas has keyboard focus unless a terminal does).

Any kind takes `--repeat N [--interval ms]` (default 8 ms apart) for a trackpad-rate burst, e.g. `input scroll 950 220 -40 -15 --repeat 120`; a `scroll` or `magnify` burst is one gesture (began, changed…, ended). When the burst ends, `app.log` records `longest gap … before step …, mean lateness …`. The longest gap between two steps is the longest stall a person sees, and it is the number to compare before and after a performance change. `scripts/perf-replica.sh start <board-id|file>` copies a real board (terminals dropped) into a scratch home to measure against.

`magnify` is a real gesture event (CG type 29 with HID zoom type), so NSScrollView runs its own live magnification: layers scale mid-gesture and the canvas's liveness pass runs at the end, exactly as for a trackpad pinch. Calling `setMagnification` per step instead redraws everything at every step and measures a different, slower thing. Live magnification anchors at the real pointer, so the replay moves the document back under the replayed point after each step. Put that point over empty canvas or a code tile: a note or terminal under it takes the gesture.

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
