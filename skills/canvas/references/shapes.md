# Shapes, arrows and groups

The full rules behind SKILL.md's summary.

- `shape`: `{"kind": "rect" | "ellipse" | "text" | "ink", "text": "…", "color": "…", "fill": "none" | "semi" | "solid"}` with a `frame`.
  A rect drawn around tiles *encloses* them.
  - `color`: `black` (the default ink, drawn to contrast with what is under it: dark over a white page, an image or the light canvas, light over the dark canvas or a dark page, on screen and in renders), `grey`, `blue`, `green`, `orange`, `red`, `violet`, or `#rrggbb`. Arrows take `color` too.
  - `fill` (rect/ellipse): `none` (default; the interior passes clicks through), `semi` (a 14% wash of the color, for regions), `solid` (85%).
  - Text sizing: a `text` shape draws its text in 20 pt handwriting from the frame's top-left, wrapping at the frame width;
    one line needs about 30 pt of height (`h ≈ 30 × lines`).
    A rect/ellipse `text` is an 18 pt label centered in the frame, wrapping at `w − 16`.
    Arrow labels are 15 pt, wrapping at 240 pt, centered on the shaft.
- `arrow`: `{"from": {"object": "obj_…"}, "to": {"object": "obj_…", "lines": {"start": 41, "end": 48}}, "relation": "calls", "label": "…", "route": "avoid"}`.
  - Endpoints bind to objects (optionally a line range or a DOM `selector`) or to a `{"point": [x, y]}`.
  - An end bound to `lines` of a code tile attaches to the tile's left or right edge at the row of `lines.start`
    (the right edge unless the other end lies wholly to the left), so call-site → callee arrows point at the lines.
    It follows the tile's scroll, and a line scrolled out of view pins the end to the top of the code or the bottom of the tile.
    On other tiles `lines` binds the whole tile.
  - `relation` is the machine-readable edge (`calls`, `depends_on`, `hypothesis_about`, …); `label` is what the user reads.
    Without a label the arrow shows its relation in a secondary color; `label: ""` shows no caption.
  - `route`: `straight` (default), `orthogonal`, or `avoid` (goes around tiles in the way).
    Arrows between the same two objects are drawn apart automatically, both directions.
- `group`: `{"members": [ids], "title": "…", "color": "blue", "padding": 24}` is a titled, tinted region whose frame always wraps its members
  (plus padding and a title band) as they move; use one per lane or cluster instead of a rect plus a text label.
