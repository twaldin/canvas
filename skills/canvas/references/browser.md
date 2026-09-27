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
