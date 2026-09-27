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
scripts/dev.sh start [root]      # build, bundle, launch on the testing Space without activating (no root: the home's previous tabs)
scripts/dev.sh cli board.get     # the canvas CLI against this instance (sets CANVAS_SOCKET)
scripts/dev.sh shot out.png      # real pixels: what the screen shows (verification)
scripts/dev.sh snapshot out.png  # view.snapshot: what agents see (not verification)
scripts/dev.sh move 8            # put the window on Space 8 for Tim to watch; `move` alone returns it
CANVAS_DEV_SPACE=8 scripts/dev.sh restart   # relaunch straight onto Space 8 while Tim watches
scripts/dev.sh input click 400 300 --mods hyper
scripts/dev.sh restart           # rebuild + relaunch with the same tabs; terminal sessions keep running
scripts/dev.sh stop              # quit and kill this instance's terminal sessions
```

What it sets up:

- `CANVAS_HOME=<checkout>/.canvas-home` holds this instance's socket, boards, pid, and `app.log`, so it never touches the installed app's boards or another agent's instance.
- `CANVAS_NO_ACTIVATE=1`: the app refuses to activate (`CanvasApplication`), so it can't steal focus or switch Spaces.
- A one-shot yabai rule parks the launch's first `Canvas` window on Space 7 (floating, maximized) and is removed once `dev.sh` has moved the window to the testing Space. That Space is the first Space of the `CanvasTest` virtual screen (a BetterDisplay headless monitor placed diagonally below-right of the built-in display, touching it only at the corner), or `CANVAS_DEV_SPACE`. A standing rule on `app=Canvas` would also grab every later window (tabs, other instances, Tim's own boards) and hide them on Space 7. Agents working in parallel each create their own screen (`Agent-<name>`, per the global AGENTS.md) and select it with `CANVAS_DEV_DISPLAY=Agent-<name>`. A yabai rule can't place a window on another display's Space: the window lands on whatever Space Tim is viewing, so never point the rule at the virtual screen. Recreate the screen if it's gone: `betterdisplaycli create --type=VirtualScreen --virtualScreenName=CanvasTest --useResolutionList=on --resolutionList=1512x982 --virtualScreenHiDPI=on`, then `betterdisplaycli set --name=CanvasTest --connected=on --placement=1512x982`.
- Boards open as tabs of one window, and `open-boards.json` in the home reopens them at launch. The initial root (`dev.sh start <root>`) is the selected tab; without a root, `start` and `restart` reopen the tabs the home had open (the first one selected), or the checkout's board in a fresh home. yabai moves windows behind AppKit's back, so a tab selected through the API while the app is inactive (`board.open --select true`) can reappear on Space 7; `scripts/dev.sh move` puts it back. A board opened while the window is parked (minimized) joins it as a hidden tab; under `CANVAS_NO_ACTIVATE`, `--select true` doesn't bring the window back, so the tab is simply there when `stage.sh acquire` does.
- `CANVAS_DEV_INPUT=1` enables input replay (below).
- More instances of one checkout (parallel agents, user studies): `CANVAS_DEV_HOME=/tmp/study-a/home` gives an instance its own home (socket, boards, log, pid, and zmx session label, so `stop` kills only its sessions), and `CANVAS_DEV_APP=<bundle>` launches a prebuilt bundle without rebuilding: copy `.build/Canvas.app` once and every instance runs that frozen build while the checkout changes. Combine with `CANVAS_DEV_DISPLAY=Agent-<name>`.

### Seeing the window

Verify what the screen shows with `scripts/dev.sh shot`: a WindowServer capture of the window, the same pixels a person sees. Only a displayed Space is composited, and a window anywhere else keeps a stale frame, so `shot` refuses unless the window is on a displayed Space. The testing Space on the virtual screen is always displayed, so shots work while Tim is elsewhere.

`view.snapshot` (`scripts/dev.sh snapshot`) is the agents' view, not verification: it redraws the window in-process and substitutes stand-ins for content drawn outside AppKit (code tiles render their text themselves, terminals are drawn from zmx session text, web views show cached images). It hides compositor and layer bugs by construction: during the astra-skyblock run, code tiles that were blank or smeared on screen looked perfect in `view.snapshot`.

Shots are at the display's backing scale (2× on both displays): divide pixel coordinates by 2 for window-content points (subtract the 28 pt title bar, or 64 pt once a second board adds a tab bar; `shot` includes the window frame, `snapshot` doesn't).

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
scripts/dev.sh input shortcut z --mods cmd           # a key press by character: p, 9, =, +, $'\r'
scripts/dev.sh input key return                      # by name: return escape tab space delete forwarddelete up down left right home end pageup pagedown
scripts/dev.sh input scroll <x> <y> <dx> <dy>
scripts/dev.sh input magnify <x> <y> <amount>      # one pinch step: zoom × (1 + amount); 0.05 in, -0.05 out
```

Coordinates are window-content points from the top-left: `shot` pixels / 2 (a Retina capture), minus the 28-point title bar (64 points while the window shows a tab bar, i.e. two or more boards are open). Prefer Hyper clicks and API calls: a plain click on a window of an inactive app is how macOS decides to activate it, and `CANVAS_NO_ACTIVATE` is the only thing standing between that and Tim's screen.

`shortcut` and `key` are real key presses (key down and up, with the US-layout virtual key code and characters a keyboard produces) posted into the app's event queue, so they go where a physical key goes: the window's key equivalents first (canvas navigation shortcuts, `CanvasWindow`), then the focused view's (Ghostty's bindings), the main menu, and finally `keyDown` to the first responder. `input key return` submits a shell command or an omp prompt in a terminal tile; `input text` alone only types. Since the app never activates, no window is key; `CanvasApplication` dispatches a replayed key press as for the key window and resolves untargeted menu actions (Select All, Copy) through that window's responder chain, as a real key press would. `command` calls `doCommand(by:)` on the first responder directly: the text system handles it, a terminal ignores it.

`text`, `command`, `shortcut`, and `key` go to an open sheet (e.g. the ⌘G group-name prompt) when the window has one, so `input text "Auth"` then `input key return` confirms it. Esc/Delete on the canvas: `input key escape` / `input key delete` (the canvas has keyboard focus unless a terminal does).

Any kind takes `--repeat N [--interval ms]` (default 8 ms apart) for a trackpad-rate burst, e.g. `input scroll 950 220 -40 -15 --repeat 120`; a `magnify` burst is one gesture (began, changed…, ended). A `scroll` burst sends continuous (trackpad-precise) steps without a gesture phase: on macOS 26 NSScrollView tracks a real phased scroll itself, and a replayed phased gesture only moved the view by its first step. A horizontal-dominant step (`|dx| > |dy|`) pans even over a code tile. When the burst ends, `app.log` records `longest gap … before step …, mean lateness …`. The longest gap between two steps is the longest stall a person sees, and it is the number to compare before and after a performance change. `scripts/perf-replica.sh start <board-id|file> [app]` copies a real board (terminals dropped) into a scratch home to measure against; `[app]` runs a given bundle, so two frozen builds can be measured in turns.

`magnify` is a real gesture event (CG type 29 with HID zoom type), so NSScrollView runs its own live magnification and the canvas's liveness pass runs at the end, exactly as for a trackpad pinch. Calling `setMagnification` per step instead measures a different thing. Live magnification anchors at the real pointer, so the replay moves the document back under the replayed point after each step. Put that point over empty canvas or a code tile: a note or terminal under it takes the gesture. On macOS 26 AppKit damps replayed steps after the first few (0.05 per step barely moves; `0.25 --repeat 45` goes from fit to 100% and `-0.25 --repeat 45` back out, rubber-banding at the limits).

### Performance probes

`CANVAS_DEV_PERF=1` (set by `dev.sh` and `perf-replica.sh`) turns on `DevPerf` (`Sources/CanvasApp/DevPerf.swift`). Every input burst becomes a span with a `gesture` phase and a 1.5 s `settle` phase (the liveness pass, card and live flips, and the redraws they cause); `input perf [ms]` is an idle span (default 5000 ms), which also works while the window is minimized. At the end of a span `app.log` gets one line per phase:

```text
DevPerf: burst of 45 magnify settle 1574 ms: frames 89 missed 6 (vsync 16.7 ms, longest frame 62.9 ms), main busy 278 ms, hitches 3 (longest 46.3 ms); counts: …; timings (n/total/max ms): card.call.CodeTile=9/46.1/5.9 draw.GroupView=220/11.4/0.1 scene.pass=23/48.0/46.2 …
```

- `frames`/`missed`/`longest frame`: a display link on the window; a missed vsync is one the main thread was too busy to serve (a dropped frame for anything the main thread draws).
- `main busy`/`hitches`: a main run-loop observer times each stretch from waking to sleeping; a stretch longer than one vsync is a hitch.
- `timings`: count, total, and longest milliseconds per probe: `draw.<View>` (every `draw(_:)` of our views), `scene.pass` (the liveness pass), `scene.boundsChanged` (per pan/pinch step), `content.live.<Tile>`/`content.unlive.<Tile>` (live/card flips), `card.call`/`card.latency`/`card.install.<Tile>` (card snapshots), `live.reveal.<Tile>` (card lifted after going live).

For CPU and wakeups, measure the process from outside: `/usr/bin/top -l 5 -s 3 -stats pid,cpu,idlew,power -pid <pid>` (`IDLEW`: idle wakeups per 3 s interval; skip the first sample) and `/bin/ps -o time= -p <pid>` before and after a fixed interval (the shell's `ps` may be another tool); `sample <pid> 5` shows where the main thread spends it.

### Terminals and agents

- Terminal text: `TMPDIR=$(getconf DARWIN_USER_TEMP_DIR) zmx history canvas-<tileId> | tail -n 40` (zmx keys its socket directory off `TMPDIR`; the GUI app's differs from a herdr pane's).
- Create an omp tile: `scripts/dev.sh cli object.create --type terminal --json '{"props":{"cwd":"<repo>","command":["omp"]}}'`.
- Prompt it and wait: `scripts/dev.sh cli agent.prompt --target <tileId> --text "…"`, then `scripts/dev.sh cli agent.wait --target <tileId> --timeoutMs 300000`.
- Recent terminal text through the API: `scripts/dev.sh cli agent.read --target <tileId> --lines 40`; `--since prompt` gives only the reply to the last `agent.prompt`.
- Reboot resume: quit the app (`kill $(cat .canvas-home/pid)`), `zmx kill canvas-<tileId> --force`, `scripts/dev.sh start`. A tile whose session is gone reruns `props.command`, or resumes its recorded omp session with `omp --resume=<sessionId>` (the original flags, e.g. `-e <checkout extension>`, are not replayed, so the resumed omp loads the globally installed extension).
- macOS notifications (agent done/blocked while the app is in the background) are never requested or posted with `CANVAS_NO_ACTIVATE=1`; `app.log` records "notification suppressed" instead.
- The omp extension is installed globally as a symlink to the main checkout (`~/.omp/agent/extensions/canvas.ts`). To test a modified extension from another checkout, launch omp with `["omp", "--no-extensions", "-e", "<checkout>/extensions/omp/canvas.ts"]`.

### Hygiene

- Gate builds with `machine-ok --wait`; when several agents build at once, use `swift build -j 2`.
- One instance per checkout, and at most one omp tile at a time unless the test needs more.
- `scripts/dev.sh stop` when the test is done, not at the end of the session. It also kills the instance's zmx sessions.
