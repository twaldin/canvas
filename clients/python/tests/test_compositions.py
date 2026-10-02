"""Compositions load from real directories. Run from clients/python: python3 -m unittest"""

from __future__ import annotations

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from canvas_sdk import Canvas  # noqa: E402
from canvas_sdk.compositions import default_dirs  # noqa: E402


def write(directory: Path, name: str, source: str) -> None:
    (directory / f"{name}.py").write_text(textwrap.dedent(source), encoding="utf-8")


class CompositionsTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.user = Path(temp.name, "user")
        self.shipped = Path(temp.name, "shipped")
        self.user.mkdir()
        self.shipped.mkdir()
        # Never connects: these compositions don't call the socket.
        self.canvas = Canvas(socket_path=str(Path(temp.name, "none.sock")), compositions_dirs=[self.user, self.shipped])

    def test_canvas_first_functions_receive_the_client(self) -> None:
        write(self.shipped, "tools", '''
            """Small tools."""
            SCALE = 3
            def whoami(canvas, suffix):
                return (canvas, suffix)
            def triple(value):
                return value * SCALE
        ''')
        tools = self.canvas.compositions.tools
        self.assertEqual(tools.whoami("!"), (self.canvas, "!"))
        self.assertEqual(tools.triple(2), 6, "pure helpers are not bound")
        self.assertEqual(tools.SCALE, 3)

    def test_user_directory_shadows_shipped_compositions(self) -> None:
        write(self.shipped, "layout", '"""Shipped."""\ndef name(canvas):\n    return "shipped"\n')
        write(self.user, "layout", '"""Improved."""\ndef name(canvas):\n    return "improved"\n')
        self.assertEqual(self.canvas.compositions.layout.name(), "improved")
        self.assertEqual(self.canvas.compositions.available(), {"layout": "Improved."})

    def test_reload_picks_up_edited_files(self) -> None:
        write(self.user, "counter", "def value(canvas):\n    return 1\n")
        self.assertEqual(self.canvas.compositions.counter.value(), 1)
        write(self.user, "counter", "def value(canvas):\n    return 2\n")
        self.assertEqual(self.canvas.compositions.counter.value(), 1, "imported once until reload")
        self.canvas.compositions.reload()
        self.assertEqual(self.canvas.compositions.counter.value(), 2)

    def test_compositions_can_use_each_other(self) -> None:
        write(self.shipped, "base", "def double(canvas, x):\n    return 2 * x\n")
        write(self.user, "derived", "def quadruple(canvas, x):\n    return canvas.compositions.base.double(canvas.compositions.base.double(x))\n")
        self.assertEqual(self.canvas.compositions.derived.quadruple(3), 12)

    def test_unknown_names_list_what_is_available_without_importing(self) -> None:
        write(self.user, "broken", '"""Fails at import."""\nraise RuntimeError("boom")\n')
        write(self.user, "_private", "x = 1\n")
        with self.assertRaises(AttributeError) as caught:
            self.canvas.compositions.missing
        self.assertIn("broken", str(caught.exception))
        self.assertEqual(self.canvas.compositions.available(), {"broken": "Fails at import."})
        with self.assertRaises(RuntimeError):
            self.canvas.compositions.broken
        self.assertNotIn("canvas_compositions.broken", sys.modules, "no half-loaded module left behind")


class ShippedCompositionsTest(unittest.TestCase):
    def setUp(self) -> None:
        shipped = default_dirs()[-1]
        self.canvas = Canvas(socket_path="/nonexistent.sock", compositions_dirs=[shipped])

    def test_shipped_directory_has_the_documented_compositions(self) -> None:
        self.assertLessEqual({"grid", "locations"}, set(self.canvas.compositions.available()))

    def test_grid_sits_beside_the_anchor_and_clears_obstacles(self) -> None:
        plan = self.canvas.compositions.grid.plan
        terminal = {"x": 0, "y": 0, "w": 800, "h": 500}
        follow = {"x": 824, "y": 0, "w": 640, "h": 420}  # already beside the terminal
        sizes = [{"x": 0, "y": 0, "w": 640, "h": 420}] * 3 + [{"x": 0, "y": 0, "w": 320, "h": 200}]
        frames = plan(sizes, terminal, [terminal, follow])
        self.assertEqual(frames[0]["x"], 824)
        self.assertEqual(frames[0]["y"], 444, "slid below the follow tile")
        self.assertEqual([(f["x"], f["y"]) for f in frames[1:]], [(1488, 444), (824, 888), (1488, 888)])
        self.assertEqual((frames[3]["w"], frames[3]["h"]), (320, 200), "sizes are kept")
        for frame in frames:
            for obstacle in (terminal, follow):
                overlap = frame["x"] < obstacle["x"] + obstacle["w"] and obstacle["x"] < frame["x"] + frame["w"] and frame["y"] < obstacle["y"] + obstacle["h"] and obstacle["y"] < frame["y"] + frame["h"]
                self.assertFalse(overlap)

    def test_grid_without_anchor_keeps_the_current_top_left(self) -> None:
        frames = self.canvas.compositions.grid.plan([{"x": 50, "y": 70, "w": 100, "h": 100}, {"x": 400, "y": 10, "w": 100, "h": 100}], None, [], columns=1)
        self.assertEqual([(f["x"], f["y"]) for f in frames], [(50, 10), (50, 134)])

    def test_location_forms(self) -> None:
        parse = self.canvas.compositions.locations.parse
        self.assertEqual(parse("src/a.py"), ("src/a.py", None))
        self.assertEqual(parse("src/a.py:12"), ("src/a.py", {"start": 12, "end": 12}))
        self.assertEqual(parse("src/a.py:12-40"), ("src/a.py", {"start": 12, "end": 40}))
        self.assertEqual(parse("src/a.py:12:5"), ("src/a.py", {"start": 12, "end": 12}), "column dropped")
        self.assertEqual(parse("src/a.py#L3-L9"), ("src/a.py", {"start": 3, "end": 9}))
        self.assertEqual(self.canvas.compositions.locations.relative("/repo/src/a.py", "/repo"), "src/a.py")
        self.assertEqual(self.canvas.compositions.locations.relative("/elsewhere/a.py", "/repo"), "/elsewhere/a.py")


if __name__ == "__main__":
    unittest.main()
