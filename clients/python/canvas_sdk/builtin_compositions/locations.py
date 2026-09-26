"""Open a set of file:line locations (e.g. search hits, a stack trace) as code tiles in a grid."""

from __future__ import annotations

import os
import re
from typing import Any

# path, path:12, path:12-40, path:12:5 (column ignored), path#L12, path#L12-L40
_LOCATION = re.compile(r"^(?P<path>.+?)(?:#L(?P<a>\d+)(?:-L?(?P<b>\d+))?|:(?P<c>\d+)(?:-(?P<d>\d+)|:\d+)?)?$")


def open(canvas: Any, locations: list[str], beside: str | None = None, columns: int | None = None) -> list[str]:
    """Create one code tile per location (`path`, `path:12`, `path:12-40`, `path#L12-L40`) and
    arrange them in a grid beside `beside` (default: your terminal). Each tile shows its whole
    file scrolled to the location, with changes against the merge-base in the gutter. Returns the
    new tile ids in input order."""
    root = canvas.board.get()["root"]
    ids = []
    for location in locations:
        path, line_range = parse(location)
        props: dict[str, Any] = {"path": relative(path, root)}
        if line_range is not None:
            props["range"] = line_range
        ids.append(canvas.object.create(type="code", props=props)["object"]["id"])
    canvas.compositions.grid.arrange(ids, beside=beside, columns=columns)
    return ids


def parse(location: str) -> tuple[str, dict[str, int] | None]:
    """`src/a.py:12-40` -> ("src/a.py", {"start": 12, "end": 40}); a bare path has no range.
    `path:12:5` is a line and column (compiler/grep style); the column is dropped."""
    match = _LOCATION.match(location.strip())
    if match is None or not match["path"]:
        raise ValueError(f"not a location: {location!r}")
    start = match["a"] or match["c"]
    if start is None:
        return match["path"], None
    end = match["b"] or match["d"] or start
    return match["path"], {"start": int(start), "end": max(int(start), int(end))}


def relative(path: str, root: str) -> str:
    """Code tiles store paths relative to the board root when the file lives under it."""
    if not os.path.isabs(path):
        return path
    absolute, base = os.path.normpath(path), os.path.normpath(root)
    return os.path.relpath(absolute, base) if absolute.startswith(base + os.sep) else absolute
