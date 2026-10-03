"""The `easl` CLI (cli/easl.ts, run with bun) against a fake app socket: what params it sends.
Run from clients/python: python3 -m unittest"""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

from tests.test_connection import EASL_ENV, FakeApp

CLI = Path(__file__).resolve().parents[3] / "cli" / "easl.ts"
CMUX_ENV = ("CMUX_SOCKET_PATH", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_SOCKET_PASSWORD")


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliParamsTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.app = FakeApp(str(self.dir / "easl.sock"))
        self.addCleanup(self.app.stop)

    def run_cli(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in EASL_ENV}
        env["EASL_SOCKET"] = self.app.path
        return subprocess.run(["bun", str(CLI), *args], input=stdin, capture_output=True, text=True, cwd=self.dir, env=env, timeout=30)

    def sent(self) -> dict:
        self.assertEqual(len(self.app.requests), 1)
        return self.app.requests[0][1]

    def test_json_at_file_reads_params_relative_to_the_cwd(self) -> None:
        html = "<h1>" + "x" * 5000 + "</h1>"
        (self.dir / "params.json").write_text(json.dumps({"type": "html", "props": {"html": html}}))
        result = self.run_cli("object.create", "--json", "@params.json", "--frame.x", "10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"type": "html", "props": {"html": html}, "frame": {"x": 10}})

    def test_json_at_dash_reads_params_from_stdin(self) -> None:
        result = self.run_cli("agent.prompt", "--json", "@-", stdin='{"target": "fees", "text": "review\\nthe diff"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "fees", "text": "review\nthe diff"})

    def test_later_arguments_override_the_file(self) -> None:
        (self.dir / "p.json").write_text('{"target": "a", "lines": 5}')
        result = self.run_cli("agent.read", "--json", "@p.json", "--target", "b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "b", "lines": 5})

    def test_string_params_keep_the_text_as_typed(self) -> None:
        # Answering Codex's "1. Trust and continue": text is a string param; lines stays a number.
        result = self.run_cli("agent.prompt", "--target", "codex", "--text", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "codex", "text": "1"})
        self.app.requests.clear()
        result = self.run_cli("agent.read", "--target", "2", "--lines", "40")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sent(), {"target": "2", "lines": 40})

    def test_array_params_take_one_item_a_list_or_repeated_flags(self) -> None:
        # `--until working` once went out as the string "working", and agent.wait fell back to its default states.
        cases = (
            (("agent.wait", "--target", "a", "--until", "working"), {"target": "a", "until": ["working"]}),
            (("agent.wait", "--target", "a", "--until", "working,blocked"), {"target": "a", "until": ["working", "blocked"]}),
            (("agent.wait", "--target", "a", "--until", "working", "--until", "idle"), {"target": "a", "until": ["working", "idle"]}),
            (("agent.wait", "--target", "a", "--until", '["done"]'), {"target": "a", "until": ["done"]}),
            (("agent.wait", "--json", '{"target": "a", "until": ["idle"]}', "--until", "working"), {"target": "a", "until": ["working"]}),
            (("layout.translate", "--ids", "obj_1,obj_2", "--dx", "5", "--dy", "0"), {"ids": ["obj_1", "obj_2"], "dx": 5, "dy": 0}),
            (("board.history", "--kinds", "created"), {"kinds": ["created"]}),
            (("view.render", "--target", "obj_1", "--exclude", "terminal"), {"target": "obj_1", "exclude": ["terminal"]}),
            (("agent.prompt", "--target", "a", "--text", "t", "--mentions", '{"object": "obj_1"}'), {"target": "a", "text": "t", "mentions": [{"object": "obj_1"}]}),
        )
        for args, params in cases:
            with self.subTest(args=args):
                self.app.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.sent(), params)

    def test_unreadable_or_invalid_files_fail_before_sending(self) -> None:
        (self.dir / "bad.json").write_text("{not json")
        (self.dir / "list.json").write_text("[1, 2]")
        for argument, message in (("@missing.json", "cannot read"), ("@bad.json", "not JSON"), ("@list.json", "params must be a JSON object")):
            with self.subTest(argument=argument):
                result = self.run_cli("board.get", "--json", argument)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"invalid_params: --json {argument}: {message}", result.stderr)
        self.assertEqual(self.app.requests, [])


class FakeCmux:
    """Stands in for the app's cmux socket: records requests; answers `auth` lines and each method from `replies`."""

    def __init__(self, path: str, password: str | None = None) -> None:
        self.path = path
        self.password = password
        self.lines: list[str] = []
        self.requests: list[tuple[str, dict]] = []
        # method -> ("ok", result) or ("error", {"code", "message"}); others answer {}.
        self.replies: dict[str, tuple[str, dict]] = {}
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(path)
        self._listener.listen()
        threading.Thread(target=self._accept, daemon=True).start()

    def stop(self) -> None:
        self._listener.close()

    def _accept(self) -> None:
        while True:
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        authenticated = self.password is None
        with conn, conn.makefile("r", encoding="utf-8") as reader:
            for line in reader:
                self.lines.append(line.rstrip("\n"))
                if line.startswith("auth "):
                    authenticated = line[5:].rstrip("\n") == self.password
                    conn.sendall(b"OK: Authenticated\n" if authenticated else b"ERROR: Invalid password\n")
                    continue
                request = json.loads(line)
                if not authenticated:
                    reply = {"id": request["id"], "ok": False, "error": {"code": "unauthorized", "message": "send `auth <password>` first"}}
                else:
                    self.requests.append((request["method"], request["params"]))
                    kind, body = self.replies.get(request["method"], ("ok", {}))
                    reply = {"id": request["id"], "ok": kind == "ok", ("result" if kind == "ok" else "error"): body}
                conn.sendall((json.dumps(reply) + "\n").encode())


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliBrowserTest(unittest.TestCase):
    """`easl browser <verb>`: requests on the cmux socket (docs/contracts.md, cmux browser subset)."""

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.serve()

    def serve(self, password: str | None = None) -> None:
        self.cmux = FakeCmux(str(self.dir / f"cmux-{password}.sock"), password)
        self.addCleanup(self.cmux.stop)

    def run_cli(self, *args: str, **env_overrides: str) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in EASL_ENV + CMUX_ENV}
        env.update({"CMUX_SOCKET_PATH": self.cmux.path, "CMUX_SURFACE_ID": "obj_term", "TMPDIR": str(self.dir)})
        env.update(env_overrides)
        return subprocess.run(["bun", str(CLI), "browser", *args], capture_output=True, text=True, cwd=self.dir, env=env, timeout=30)

    def test_verbs_map_to_cmux_methods_on_the_given_tile(self) -> None:
        cases = [
            (["open", "http://localhost:3000"], ("browser.open_split", {"url": "http://localhost:3000", "surface_id": "obj_term"})),
            (["list"], ("surface.list", {"surface_id": "obj_term"})),
            (["list", "--workspace_id", "brd_other"], ("surface.list", {"workspace_id": "brd_other"})),
            (["close", "obj_page"], ("surface.close", {"surface_id": "obj_page"})),
            (["click", "obj_page", "--selector", "@e2"], ("browser.click", {"surface_id": "obj_page", "selector": "@e2"})),
            (["url.get", "obj_page"], ("browser.url.get", {"surface_id": "obj_page"})),
            (["eval", "--json", '{"surface_id": "obj_page", "script": "document.title"}'], ("browser.eval", {"surface_id": "obj_page", "script": "document.title"})),
        ]
        for args, request in cases:
            with self.subTest(args=args):
                self.cmux.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.cmux.requests, [request])

    def test_string_params_keep_the_text_as_typed(self) -> None:
        for args, params in (
            (["type", "obj_page", "--selector", "#zip", "--text", "02139"], {"surface_id": "obj_page", "selector": "#zip", "text": "02139"}),
            (["press", "obj_page", "--key", "1"], {"surface_id": "obj_page", "key": "1"}),
            (["scroll", "obj_page", "--dy", "300"], {"surface_id": "obj_page", "dy": 300}),
            (["wait", "obj_page", "--load_state", "complete", "--timeout_ms", "5000"], {"surface_id": "obj_page", "load_state": "complete", "timeout_ms": 5000}),
            (["snapshot", "obj_page", "--interactive"], {"surface_id": "obj_page", "interactive": True}),
        ):
            with self.subTest(args=args):
                self.cmux.requests.clear()
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.cmux.requests[0][1], params)

    def test_a_password_is_sent_first_and_a_wrong_one_stops_the_request(self) -> None:
        self.serve(password="s3cret")
        result = self.run_cli("url.get", "obj_page", CMUX_SOCKET_PASSWORD="s3cret")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cmux.lines[0], "auth s3cret")
        self.assertEqual(self.cmux.requests, [("browser.url.get", {"surface_id": "obj_page"})])

        self.cmux.lines.clear()
        self.cmux.requests.clear()
        result = self.run_cli("url.get", "obj_page", CMUX_SOCKET_PASSWORD="wrong")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "unauthorized: Invalid password")
        self.assertEqual(self.cmux.lines, ["auth wrong"])

    def test_an_error_reply_prints_code_and_message_and_exits_1(self) -> None:
        self.cmux.replies["browser.click"] = ("error", {"code": "not_found", "message": "no element matches #missing"})
        result = self.run_cli("click", "obj_page", "--selector", "#missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "not_found: no element matches #missing")
        self.assertEqual(result.stdout, "")

    def test_screenshot_writes_the_png_and_prints_its_path(self) -> None:
        png = b"\x89PNG\r\n\x1a\nfake"
        self.cmux.replies["browser.screenshot"] = ("ok", {"png_base64": base64.b64encode(png).decode(), "width": 10, "height": 5, "surface_id": "obj_page"})
        result = self.run_cli("screenshot", "obj_page", "--out", "shot.png")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"width": 10, "height": 5, "surface_id": "obj_page", "path": str(self.dir.resolve() / "shot.png")})
        self.assertEqual((self.dir / "shot.png").read_bytes(), png)
        self.assertEqual(self.cmux.requests, [("browser.screenshot", {"surface_id": "obj_page"})])

        # Without --out, a new file under $TMPDIR/easl-renders/ (the app deletes it after a day).
        result = self.run_cli("screenshot", "obj_page")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(json.loads(result.stdout)["path"])
        self.assertEqual(path.parent.resolve(), self.dir.resolve() / "easl-renders")
        self.assertRegex(path.name, r"^screenshot-\d+-\d+\.png$")
        self.assertEqual(path.read_bytes(), png)


if __name__ == "__main__":
    unittest.main()
