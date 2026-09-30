"""Arrange objects in a tidy grid beside a terminal (yours by default), clear of other tiles."""

from __future__ import annotations

import math
import os
from typing import Any

GAP = 24.0
# Drawings never block placement (same rule as the canvas's own placement).
_NON_BLOCKING = {"arrow", "shape", "group"}


def arrange(canvas: Any, ids: list[str], beside: str | None = None, columns: int | None = None, gap: float = GAP) -> dict[str, dict[str, float]]:
    """Move `ids` into a grid to the right of `beside` (default: the calling terminal, then the
    objects' current top-left), sliding down past anything in the way. Returns id -> new frame.
    Only arrange the user's own objects when they asked you to."""
    if not ids:
        return {}
    objects = {o["id"]: o for o in canvas.board.get()["objects"]}
    missing = [i for i in ids if i not in objects]
    if missing:
        raise ValueError(f"not on this board: {', '.join(missing)}")
    anchor_id = beside or os.environ.get("CHALKWORK_TILE_ID")
    anchor = objects[anchor_id]["frame"] if anchor_id in objects and anchor_id not in ids else None
    moving = set(ids)
    obstacles = [o["frame"] for o in objects.values() if o["id"] not in moving and o["type"] not in _NON_BLOCKING]
    frames = plan([objects[i]["frame"] for i in ids], anchor, obstacles, columns=columns, gap=gap)
    result = {}
    for object_id, frame in zip(ids, frames):
        canvas.object.update(id=object_id, frame=frame)
        result[object_id] = frame
    return result


def plan(frames: list[dict[str, float]], anchor: dict[str, float] | None, obstacles: list[dict[str, float]], columns: int | None = None, gap: float = GAP) -> list[dict[str, float]]:
    """Grid positions for objects of the given sizes, row-major, keeping each object's size.
    Starts right of `anchor` (top-aligned) or at the objects' current top-left, then moves down
    until the whole grid overlaps no obstacle."""
    count = len(frames)
    if count == 0:
        return []
    columns = max(1, min(columns or math.ceil(math.sqrt(count)), count))
    rows = math.ceil(count / columns)
    widths = [max(f["w"] for f in frames[c::columns]) for c in range(columns)]
    heights = [max(f["h"] for f in frames[r * columns:(r + 1) * columns]) for r in range(rows)]
    xs = [sum(widths[:c]) + gap * c for c in range(columns)]
    ys = [sum(heights[:r]) + gap * r for r in range(rows)]
    box = {"w": xs[-1] + widths[-1], "h": ys[-1] + heights[-1]}
    if anchor is not None:
        box["x"], box["y"] = anchor["x"] + anchor["w"] + gap, anchor["y"]
    else:
        box["x"], box["y"] = min(f["x"] for f in frames), min(f["y"] for f in frames)
    while True:
        blocking = [o for o in obstacles if _intersects(o, box)]
        if not blocking:
            break
        box["y"] = max(o["y"] + o["h"] for o in blocking) + gap
    return [
        {"x": box["x"] + xs[i % columns], "y": box["y"] + ys[i // columns], "w": f["w"], "h": f["h"]}
        for i, f in enumerate(frames)
    ]


def _intersects(a: dict[str, float], b: dict[str, float]) -> bool:
    return a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]
