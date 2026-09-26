"""Canvas Python SDK.

Recommended surface for agents with a persistent REPL:

    from canvas_sdk import canvas
    board = canvas.board.get()
    canvas.object.create(type="note", props={"markdown": "# Hypothesis"})

Every method mirrors schema/canvas-api.json. `caller` and `board` are filled
from CANVAS_TILE_ID / CANVAS_BOARD_ID when the call runs inside a terminal tile.

Reusable helpers live in compositions directories and load on first use:

    canvas.compositions.grid.arrange(["obj_…", "obj_…"])
    canvas.compositions.available()   # name -> summary
"""

from __future__ import annotations

import json
import os
import socket
import threading
from typing import Any

from ._generated import METHODS, SCHEMA_VERSION, GeneratedApi
from .compositions import Compositions

DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/Canvas/canvas.sock")

__all__ = ["Canvas", "CanvasError", "Compositions", "canvas", "METHODS", "SCHEMA_VERSION", "DEFAULT_SOCKET"]


class CanvasError(Exception):
    def __init__(self, code: str, message: str, data: Any = None) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.data = data


class Canvas(GeneratedApi):
    """One persistent, thread-safe connection to the Canvas API socket."""

    def __init__(self, socket_path: str | None = None, timeout: float | None = None, compositions_dirs: list[str | os.PathLike[str]] | None = None) -> None:
        self.socket_path = socket_path or os.environ.get("CANVAS_SOCKET") or DEFAULT_SOCKET
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._reader: Any = None
        self._lock = threading.Lock()
        self._next_id = 0
        super().__init__(self.call)
        self.compositions = Compositions(self, compositions_dirs)

    def call(self, method: str, params: dict[str, Any]) -> Any:
        with self._lock:
            reader, sock = self._connect()
            self._next_id += 1
            request_id = str(self._next_id)
            try:
                sock.sendall((json.dumps({"id": request_id, "method": method, "params": params}) + "\n").encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise CanvasError("closed", "Canvas socket closed")
                    message = json.loads(line)
                    if message.get("id") == request_id:
                        break
            except (OSError, CanvasError):
                self.close()
                raise
        if message.get("ok"):
            return message.get("result")
        error = message.get("error") or {}
        raise CanvasError(error.get("code", "internal"), error.get("message", "unknown error"), error.get("data"))

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
        self._sock = None
        self._reader = None

    def _connect(self) -> tuple[Any, socket.socket]:
        if self._sock is None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            try:
                sock.connect(self.socket_path)
            except OSError as error:
                sock.close()
                raise CanvasError("unavailable", f"Canvas socket {self.socket_path}: {error}") from error
            self._sock = sock
            self._reader = sock.makefile("r", encoding="utf-8")
        return self._reader, self._sock


class _LazyCanvas:
    """Module-level `canvas` that connects on first use."""

    _instance: Canvas | None = None

    def __getattr__(self, name: str) -> Any:
        if _LazyCanvas._instance is None:
            _LazyCanvas._instance = Canvas()
        return getattr(_LazyCanvas._instance, name)


canvas: Canvas = _LazyCanvas()  # type: ignore[assignment]
