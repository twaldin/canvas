// bun test extensions/agent-hooks — edits as omp, Claude Code and Codex report them.
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { numberedDiffChanges, patchLocation, structuredPatchChanges } from "./follow";

test("omp's numbered diff: each hunk in new-file lines, deletions where they were", () => {
  // The debugger study's fix: CUT 28, CUT 64, then the reversal at 108-110 (a replaced line).
  const diff = [
    " 27|import os",
    "-28|import sys",
    " 29|import re",
    "",
    " 63|    x = 1",
    "-64|    log(x)",
    " 65|    y = 2",
    "",
    " 107|    spos = 1",
    "-108|    a = 1",
    "-109|    rv[spos + 2 :] = b",
    "+106|    rv[spos + 1 :] = b",
    "-110|    c = 3",
    " 111|    return rv",
  ].join("\n");
  expect(numberedDiffChanges(diff)).toEqual([{ start: 28, end: 28 }, { start: 63, end: 63 }, { start: 106, end: 106 }]);
  // Additions shift what follows.
  const grown = [" 204|}) {", "-205|  if (a) return null;", "+205|  const first = s[0];", "+206|  const last = s.at(-1);", "+207|  if (a || !first) return null;", " 206|  const min = 0;", "", "-212|  const up = x;", "+214|  const up = last;"].join("\n");
  expect(numberedDiffChanges(grown)).toEqual([{ start: 205, end: 207 }, { start: 214, end: 214 }]);
  expect(numberedDiffChanges("@@ -88,5 +88,6 @@\n-\tconst a = 1;\n+\tconst a = 2;")).toEqual([]);
});

test("Claude Code's structuredPatch: each run of changes, several per hunk", () => {
  const patch = [
    { newStart: 10, lines: [" a", "-b", "+B", " c", " d", "+e", " f"] },
    { newStart: 40, lines: [" x", "-y", " z"] },
  ];
  expect(structuredPatchChanges(patch)).toEqual([{ start: 11, end: 11 }, { start: 14, end: 14 }, { start: 41, end: 41 }]);
  expect(structuredPatchChanges(undefined)).toEqual([]);
});

test("Codex's apply_patch: each hunk's added lines found in the file, in order", () => {
  const dir = mkdtempSync(join(tmpdir(), "canvas-follow-"));
  try {
    writeFileSync(join(dir, "a.py"), ["import os", "", "def f():", "    return 2", "", "def g():", "    return 2", ""].join("\n"));
    const patch = [
      "*** Begin Patch",
      "*** Update File: a.py",
      "@@",
      "-import sys",
      " import os",
      "@@ def g():",
      "-    return 1",
      "+    return 2",
      "*** End Patch",
    ].join("\n");
    expect(patchLocation(patch, dir)).toEqual({ path: join(dir, "a.py"), changes: [{ start: 7, end: 7 }], action: "edit" });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
