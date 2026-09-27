"""The `canvas` CLI (cli/canvas.ts, run with bun) against a fake app socket: what params it sends.
Run from clients/python: python3 -m unittest"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.test_connection import CANVAS_ENV, FakeApp

CLI = Path(__file__).resolve().parents[3] / "cli" / "canvas.ts"


@unittest.skipUnless(shutil.which("bun"), "the CLI runs on bun")
class CliParamsTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.app = FakeApp(str(self.dir / "canvas.sock"))
        self.addCleanup(self.app.stop)

    def run_cli(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        env = {key: value for key, value in os.environ.items() if key not in CANVAS_ENV}
        env["CANVAS_SOCKET"] = self.app.path
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

    def test_unreadable_or_invalid_files_fail_before_sending(self) -> None:
        (self.dir / "bad.json").write_text("{not json")
        (self.dir / "list.json").write_text("[1, 2]")
        for argument, message in (("@missing.json", "cannot read"), ("@bad.json", "not JSON"), ("@list.json", "params must be a JSON object")):
            with self.subTest(argument=argument):
                result = self.run_cli("board.get", "--json", argument)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"invalid_params: --json {argument}: {message}", result.stderr)
        self.assertEqual(self.app.requests, [])


if __name__ == "__main__":
    unittest.main()
