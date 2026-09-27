# What the user sees

The legend behind Help › Canvas Basics, so you can answer "what is this?" without reading Canvas's source.
Point the user at Help › Canvas Basics for the same text in the app.

## Reading a board

- Scroll pans, pinch zooms; ⌘9 shows everything, ⌘0 is 100%.
- **Groups** are tinted, titled regions of tiles that belong together; an **arrow**'s label says how two things relate, and one into a code tile points at its lines.
  A code tile's **caption** (the line under its header) says why those lines matter.
- **⌥⌘→ / ⌥⌘←** step to the next or previous stop: along the selected tile's `relation: "next_step"` arrows when it has one, else to the nearest tile that way.
  A stop not wholly in view is centered (fitted when larger than the view); "Last step" / "First step" ends a sequence. Each step is a Back entry.
- **⌘P** finds a tile by title or caption.
- **Links**: a `path:line` link in a note or page, Go to, a definition and a terminal ⌘-click go to the code tile already showing those lines (exactly, or a captioned tile whose range holds them) wherever it is, else open them beside the source.
- **⌘[ / ⌘]**: back and forward through steps, links, Go to, definitions, ⌘J, Review Changes' jump and edge-pill jumps.
- **View › Hide Canvas Chrome** (also a button in Canvas Basics), for presenting: hides the toolbar, tray, selection rings and handles, author marks, code tiles' header rows (captions stay) and agents' attention markers; a blocked agent's ring and pill stay.
  Esc on the canvas or the item again brings them back.

## Agents

- **Lifecycle dot** in a terminal's title bar (its tooltip says the same):
  blue *working* (busy), orange *blocked* (waits for the user to approve or answer), green *done* (finished, not seen yet), grey *idle* (waiting for the next prompt).
  No dot: no agent reports a lifecycle in that terminal.
- **Blocked**: the terminal also gets an orange ring and a bubble with a raised hand and the approval text; clicking the bubble puts the keyboard in the terminal.
  Off screen, an orange pill at the edge of the view points at it.
- **Tab dot** on a board's tab: orange, an agent there is blocked; green, one finished unseen.
- Zoomed far out, tiles become cards tinted with their agent's state.

## Needs you

- **Pink ring and bubble**: an attention marker (`view.attention`, or a terminal's bell or notification): "look here".
  It clears when the user selects the tile, types in it, or looks at it for a few seconds; View › Clear Attention Markers clears them all.
  Bubbles sit beside their tile, off other tiles' title bars and never over the terminal the user is typing in.
- **Edge pill** (arrow + the start of the message; the whole message in its tooltip): something that needs the user is off screen that way; clicking it goes there.
  It sits on a stretch of the view's edge with no tile under it; when the edge is covered, it is a chip in the toolbar row beside the drawing toolbar.
- **⌘J**: the next thing that needs the user, blocked agents first, then markers, then agents that finished unseen; "Nothing needs you" when there's nothing.

## Agents' tiles

- **Follow tile**: each agent terminal's code tile that follows the file and line the agent last read or edited (on by default; it appears on the first file read).
  The strip under its header lists recent places, newest first; a pencil marks an edit.
  "N new ▸" catches up after the user scrolled; Pin keeps the current view as its own tile; right-click the terminal › Follow Files turns it off.
- **Where your objects land**: next to your terminal, clear of other tiles, inside the user's view when there's room within ~600 pt of it; they show "by <your terminal's name>" in their title bar.
  The view never moves for you: when the view is full, what you made may be off screen; raise a marker, or tell the user ⌘9 (Zoom to Fit).
- **Undo**: ⌘Z undoes the last change, the user's or an agent's (an agent's batch is one step, and a notice names the agent; undoing a changes tile's Stage, Unstage, or Discard names it too); ⇧⌘Z redoes. While a terminal has the keyboard, ⌘Z goes to the terminal, never the canvas.
  Navigation and bookkeeping nobody chose (a follow tile re-aiming) aren't undo steps; ⌘[ / ⌘] go back and forward through the user's navigation.

## Pointing an agent at things

- **Hyper-click** (⌃⌥⇧⌘-click; Caps Lock mapped to Hyper): stages a mention of a code line, page element, drawing, image pixel, or tile in the **tray**, the bar at the bottom of the window.
  Hyper-drag on empty canvas mentions everything inside the box as one group.
- **⇧⌘M** (Edit › Mention) stages a mention from the keyboard, of what the user is on in the tile that has the keyboard: the current hunk or selected lines of a changes tile (`m` there too), a code tile's selected text or else its range, the block of a note being edited, a page's text selection, a terminal's selection or else its last command's block; with the canvas's keyboard, the selected tiles.
- **Tray**: chips are the staged mentions; "→ name" on the right is the terminal they go to with the user's next prompt there (hover says so): the terminal the user last typed in that runs an agent, else the board's only agent terminal (a dev-server shell beside it never takes it), else the last terminal typed in.
  Clicking "→ name" opens a menu of the board's terminals (agents first) to pick another; it is kept across restarts. ⌃⌥⇧⌘V pastes them into a terminal without an agent integration.
- **Drawing toolbar** at the top: select (V), rectangle (R), ellipse (O), arrow (A), text (T), ink (P), colors, fill.
  The default ink (Black) is drawn dark over light pages and images and light over the dark canvas; other colors stay as chosen.

## Zoom and keys

- ⌘9 fits everything (or the largest cluster); ⌘0 is 100% (the selection at 100%); ⌘= and ⌘- step 10–100%.
  Below about 30% (terminals 15%) tiles show as cards; zooming in brings them back live. ⌥-drag a corner scales a tile.
- ⌘P Go to (tiles, files, `@symbols`); ⌘T new terminal; ⌘W close the selection; ⌘G group; ⌘F find in a code tile; ⌥⌘-arrows step (see Reading a board).
- Return enters the selected tile (a terminal, a code tile's rows, a changes tile, a note, a page); Esc gives the keyboard back to the canvas.
  In a terminal Esc belongs to the program: ⌘Esc (View › Leave Tile) leaves any tile.
- A code tile without changes shows a quiet "no changes"; its diff-base picker appears when the pointer is over the header.
- Save as PNG…, Save as HTML… and Export Selection (⇧⌘E) open in the folder last saved into, else Downloads, never the board's repo.
  Export Selection keeps the titles and borders of groups whose tiles are all selected; a marquee around groups selects them and the arrows between what it selects.
  Its picture is at most 8000 px on its longest side, named after the one tile or group selected.
