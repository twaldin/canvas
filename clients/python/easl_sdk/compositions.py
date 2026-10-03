"""Compositions: reusable canvas helpers that agents write and improve.

A composition is a plain Python module in a compositions directory. Functions whose first
parameter is named `canvas` receive the connected client; `canvas.compositions.<module>.<fn>(...)`
passes it for you. Other attributes (pure helpers, constants) come through unchanged:

    # ~/.easl/compositions/review.py
    def pin_notes(canvas, texts):
        return [canvas.object.create(type="note", props={"markdown": t}) for t in texts]

    canvas.compositions.review.pin_notes(["one", "two"])

Search order (first match wins, so a helper you improve shadows the shipped one):
`~/.easl/compositions`, then the compositions shipped inside this package (`builtin_compositions/`).
"""

from __future__ import annotations

import functools
import inspect
import os
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

__all__ = ["Compositions", "default_dirs"]


def default_dirs() -> list[Path]:
    # Shipped as package files, so they come along with the checkout, the app bundle, or a wheel.
    return [Path.home() / ".canvas" / "compositions", Path(__file__).resolve().parent / "builtin_compositions"]


class Compositions:
    """Attribute access imports `<name>.py` from the first directory that has it."""

    def __init__(self, canvas: Any, dirs: list[str | os.PathLike[str]] | None = None) -> None:
        self._canvas = canvas
        self._dirs = [Path(d) for d in dirs] if dirs is not None else default_dirs()
        self._loaded: dict[str, _Bound] = {}

    def __getattr__(self, name: str) -> _Bound:
        if name.startswith("_"):
            raise AttributeError(name)
        bound = self._loaded.get(name)
        if bound is None:
            path = self._find(name)
            if path is None:
                available = ", ".join(sorted(self.available())) or "none"
                raise AttributeError(f"no composition {name!r} in {', '.join(map(str, self._dirs))} (available: {available})")
            bound = _Bound(self._canvas, _import(name, path))
            self._loaded[name] = bound
        return bound

    def __dir__(self) -> list[str]:
        return sorted(self.available())

    def available(self) -> dict[str, str]:
        """Composition name -> first line of its docstring, across all directories."""
        found: dict[str, str] = {}
        for directory in self._dirs:
            for path in sorted(directory.glob("*.py")) if directory.is_dir() else []:
                name = path.stem
                if name.startswith("_") or name in found:
                    continue
                found[name] = _summary(path)
        return found

    def reload(self) -> None:
        """Forget imported compositions so edited files are picked up on next access."""
        for name in self._loaded:
            sys.modules.pop(f"canvas_compositions.{name}", None)
        self._loaded.clear()

    def _find(self, name: str) -> Path | None:
        for directory in self._dirs:
            path = directory / f"{name}.py"
            if path.is_file():
                return path
        return None


class _Bound:
    """A composition module whose `canvas`-first functions receive the client."""

    def __init__(self, canvas: Any, module: ModuleType) -> None:
        self._canvas = canvas
        self._module = module

    def __getattr__(self, name: str) -> Any:
        value = getattr(self._module, name)
        if inspect.isfunction(value) and next(iter(inspect.signature(value).parameters), None) == "canvas":
            return functools.partial(value, self._canvas)
        return value

    def __dir__(self) -> list[str]:
        return [n for n in dir(self._module) if not n.startswith("_")]

    def __repr__(self) -> str:
        return f"<composition {self._module.__name__.split('.')[-1]} from {self._module.__file__}>"


def _import(name: str, path: Path) -> ModuleType:
    # Compiled from source on every load: no __pycache__ written into the signed app bundle or
    # the user's folder, and an edit is never masked by a same-second, same-size stale .pyc.
    qualified = f"canvas_compositions.{name}"
    module = ModuleType(qualified)
    module.__file__ = str(path)
    sys.modules[qualified] = module
    try:
        exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(qualified, None)
        raise
    return module


def _summary(path: Path) -> str:
    """The module docstring's first line, read without importing the module."""
    import ast

    try:
        doc = ast.get_docstring(ast.parse(path.read_text(encoding="utf-8")))
    except (OSError, SyntaxError, ValueError):
        return ""
    return doc.strip().splitlines()[0] if doc else ""
