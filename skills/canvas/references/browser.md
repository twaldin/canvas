# Browser tiles

How omp's browser tool and canvas browser tiles behave, beyond SKILL.md's summary.

omp's `browser` tool (its cmux backend is on automatically inside Canvas) opens a browser tile beside your terminal for each `browser.open({name})`;
`close` deletes it.

- The tool doesn't return the tile id. Find it with `canvas board.history --limit 5` (`agent:<your tile> created … browser <url>`)
  or `canvas board.get` (browser tiles whose `createdBy` is your tile).
  Tiles made with `object.create` or by the user can't be driven by the tool: change their `props.url` with `object.update` and look with `canvas render`.
- The page's viewport is the tile's body: `innerWidth` is the frame width, `innerHeight` the frame height minus 58 (26 pt title bar, 32 pt address bar), at any zoom.
  The tool's `viewport`/`emulate` options are ignored here. To test a width, resize the tile
  (`canvas object.update <id> --json '{"frame":{"w":390,"h":844}}'`); the user sees the same tile.
  A frame grows right and down from its corner, over whatever is there: grow away from the user's terminals (give `x`/`y` too, e.g. `x` = its right edge − the new width when a terminal sits to its right),
  or resize and then `canvas.layout.place(id=tile, near=<your terminal>, side="left")`. The update result's `overlaps` names what the new frame newly covers; never leave it covering a terminal.
- `tab.evaluate` must return plain values (omp rejects functions that return a promise on this backend); poll with `waitForFunction` for async state.
  On strict-CSP pages (e.g. GitHub) pass functions, not code strings: string code runs through the page's `eval`, which CSP blocks.
- A page you drive or render stays live for 60 s after your last command wherever its tile is (offscreen, window minimized, another Space):
  `visibilityState` is `visible` and timers and `requestAnimationFrame` run. Don't move tiles into the user's view to make them work.
- Before trusting frame or timer numbers, check `canvas get <tile>` → `page.visibility`:
  `visible` (on screen: rAF at the display's rate, 60/120 fps); `driven` (running for you though nobody sees it: rAF irregular and slower, 22–54 fps measured with the window minimized);
  `hidden` (nobody sees it and not driven: no rAF, timers throttled to 1/s and stretching to ~20 s the longer it stays hidden); `released` (no page: 2 min out of view, it is dropped and reloads from `props.url` when seen or driven; the game state is gone).
  Compare numbers only between runs in the same state.
- `canvas render <tile>` loads a page that was never shown and waits up to `--timeoutMs` (8 s).
  `--full` doesn't capture below the fold on browser tiles; make the tile taller instead.
- All browser tiles share one WebKit profile, separate from the user's own browser and signed out: use `gh` or APIs for logged-in state.
- The user can click links and buttons in a tile directly. `board.history` credits your terminal with the tiles you open and close
  and with URL changes your commands cause within 10 s (pushState and back included; a `_blank` link opens a tile beside the page, never moving the view);
  the user's clicks are `user`, changes the page makes later on its own `system`.

## Errors, requests and the dev server

- Tiles record what the page reports from its first line on: console messages, uncaught errors and unhandled rejections, and failed requests (HTTP 400 or more, network errors, images, scripts and styles that didn't load; the page's own document too).
  After an edit and reload, read them instead of assuming a clean page: `canvas get <tile>` → `page.errors`, `page.entries` (`level`, `text`, `source` `url:line:column`, `status`).
  Keep `page.cursor` and pass `canvas get <tile> --since <cursor>` next time to see only what came after (a reload returns all of the new page, `reloaded: true`).
  A page Canvas released keeps its last log in `page.previous` (`releasedAt`, `errors`, `entries`) until the page loads another document after coming back; `page.cursor` stays valid across the release.
  omp's `tab.console()`, `tab.errors()`, `tab.requests()` and `waitForResponse()` see page load too on tiles; `tab.clearConsole()` then reload is not needed.
- The server half is in the terminal running the dev server (`canvas agent.list`: its `program`, e.g. `next dev`, `vite`).
  After edits, read it too: `canvas agent.read --target <that tile> --lines 40` (or its `lastCommand`); compile errors, SSR exceptions and 500s show there, not in the page.
  It is the user's terminal: report what you find, don't restart it unasked.
- `page.vitals`: LCP, FCP, TTFB, DOMContentLoaded and load in ms. Tiles are WebKit (Safari 18 UA): CLS and long tasks are null and listed in `unsupported`; there's no throttling or Lighthouse.
  For those use omp's own headless Chromium browser, not a tile.
- The user sees a small red "N errors" badge in the tile's address bar while the page has errors; a Hyper-click on one in its list mentions it to you (`console` mention: the message, source, stack frames and page).
  A click on a row shows its stack, and a `file:line` served from a file under the board root opens that code; a grey "Reloaded" says the page was released and loaded again.
- Safari's Web Inspector is the user's (page or tile context menu, Inspect Element; ⌥⌘I). Don't open it yourself: its window can land on the user's screen.
