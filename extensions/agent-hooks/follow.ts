// Where an agent's tool call looked or wrote, for its follow tile (`follow.report`): shared by
// the hook script (extensions/agent-hooks/hook.ts) and the opencode plugin (extensions/opencode).
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

export type Action = "read" | "edit" | "write";
export type Range = { start: number; end: number };
/** `changes`: an edit's hunks as lines of the file now; the app aims at the largest when `range` is omitted. */
export type Location = { path: string; range?: Range; changes?: Range[]; action: Action };

/** A changed line of a diff: an added one at its line in the new file, a removed one where it was (the line now after it). */
type Change = { added: boolean; line: number } | undefined;

/** Each run of consecutive changes (`undefined` ends one) as the new-file lines it covers: its added lines, or for a deletion the line after it. */
function runs(changes: Change[]): Range[] {
  const ranges: Range[] = [];
  let run: Array<{ added: boolean; line: number }> = [];
  for (const change of [...changes, undefined]) {
    if (change) {
      run.push(change);
      continue;
    }
    if (run.length === 0) continue;
    const added = run.filter((c) => c.added).map((c) => c.line);
    const start = Math.max(1, added.length ? Math.min(...added) : run[0].line);
    ranges.push({ start, end: Math.max(start, added.length ? Math.max(...added) : start) });
    run = [];
  }
  return ranges;
}

/** Claude Code's `structuredPatch` (hunks of ` `/`+`/`-` lines from `newStart`) as its runs of changes. */
export function structuredPatchChanges(patch: unknown): Range[] {
  if (!Array.isArray(patch)) return [];
  const changes: Change[] = [];
  for (const hunk of patch as Array<{ newStart?: unknown; lines?: unknown }>) {
    let line = typeof hunk?.newStart === "number" ? hunk.newStart : undefined;
    if (!line || !Array.isArray(hunk.lines)) continue;
    for (const text of hunk.lines) {
      if (typeof text !== "string") continue;
      if (text.startsWith("+")) changes.push({ added: true, line: line++ });
      else if (text.startsWith("-")) changes.push({ added: false, line });
      else if (text.startsWith(" ")) {
        changes.push(undefined);
        line += 1;
      }
    }
    changes.push(undefined);
  }
  return runs(changes);
}

/**
 * omp's edit diff (`details.diff`): ` N|context` and `-N|removed` by the old file's numbers,
 * `+N|added` by the new one's, blank lines between the hunks; as its runs of changes.
 */
export function numberedDiffChanges(diff: unknown): Range[] {
  if (typeof diff !== "string") return [];
  const changes: Change[] = [];
  let shift = 0; // new line number minus old one, past the changes so far
  for (const text of diff.split("\n")) {
    const row = /^([ +-])\s*(\d+)\|/.exec(text);
    if (row?.[1] === "+") {
      changes.push({ added: true, line: Number(row[2]) });
      shift += 1;
    } else if (row?.[1] === "-") {
      changes.push({ added: false, line: Number(row[2]) + shift });
      shift -= 1;
    } else {
      changes.push(undefined);
    }
  }
  return runs(changes);
}

export function absolute(path: string, cwd: string): string {
  return isAbsolute(path) ? path : resolve(cwd, path);
}

/**
 * A string replacement (`oldText` → `newText`) in `path`: at the first line the replacement
 * changed, found where the file now holds `newText` (the lines both texts start with are context).
 */
export function editLocation(path: string, oldText: string | undefined, newText: string | undefined): Location {
  let line: number | undefined;
  try {
    const content = newText ? readFileSync(path, "utf8") : "";
    const at = newText ? content.indexOf(newText) : -1;
    if (newText && at >= 0) {
      const before = oldText?.split("\n") ?? [];
      const after = newText.split("\n");
      let same = 0;
      while (same < after.length - 1 && same < before.length && after[same] === before[same]) same += 1;
      line = content.slice(0, at).split("\n").length + same;
    }
  } catch {
    line = undefined;
  }
  return { path, range: line ? { start: line, end: line } : undefined, action: "edit" };
}

/**
 * The first file an apply_patch touched, with the lines each run of changes added (`changes`),
 * found as apply_patch finds its hunks: a hunk's context and added lines together, in order,
 * after its `@@ anchor` line. A run that only removes lines isn't placed.
 */
export function patchLocation(patch: string, cwd: string): Location | undefined {
  const header = /^\*\*\* (Add|Update) File: (.+)$/m.exec(patch);
  if (!header) return undefined;
  const moved = /^\*\*\* Move to: (.+)$/m.exec(patch.slice(header.index))?.[1];
  const path = absolute((moved ?? header[2]).trim(), cwd);
  if (header[1] === "Add") return { path, action: "write" };
  const section = patch.slice(header.index + header[0].length).split("\n");
  const end = section.findIndex((line) => line.startsWith("*** ") && !line.startsWith("*** Move to:"));
  // Each hunk: its anchor, the lines it leaves (context and added), and which of them it added.
  const hunks: Array<{ anchor: string; kept: string[]; added: boolean[] }> = [];
  for (const line of end >= 0 ? section.slice(0, end) : section) {
    if (line.startsWith("@@")) hunks.push({ anchor: line.slice(2).trim(), kept: [], added: [] });
    else if (line.startsWith("+") || line.startsWith(" ")) {
      if (!hunks.length) hunks.push({ anchor: "", kept: [], added: [] });
      hunks[hunks.length - 1].kept.push(line.slice(1));
      hunks[hunks.length - 1].added.push(line.startsWith("+"));
    }
  }
  const changes: Range[] = [];
  try {
    const lines = readFileSync(path, "utf8").split("\n");
    let from = 0;
    for (const hunk of hunks) {
      if (!hunk.added.includes(true)) continue;
      const anchor = hunk.anchor ? lines.findIndex((line, i) => i >= from && line.trim() === hunk.anchor) : -1;
      const after = anchor >= 0 ? anchor + 1 : from;
      const at = lines.findIndex((_, i) => i >= after && hunk.kept.every((text, j) => lines[i + j] === text));
      if (at < 0) continue;
      hunk.added.forEach((added, j) => {
        if (!added) return;
        const last = changes.at(-1);
        if (last && last.end === at + j) last.end = at + j + 1;
        else changes.push({ start: at + j + 1, end: at + j + 1 });
      });
      from = at + hunk.kept.length;
    }
  } catch {
    // unreadable: no location
  }
  return { path, changes: changes.length ? changes : undefined, action: "edit" };
}

/** Reads through the shell (Codex's way): `sed -n 'A,Bp' f`, `nl -ba f | sed -n 'A,Bp'`, `cat f`, `head -n N f`. */
export function readLocation(command: string, cwd: string): Location | undefined {
  for (const pipeline of command.split(/&&|;|\n/)) {
    let file: string | undefined;
    let range: Range | undefined;
    for (const stage of pipeline.split("|")) {
      const [program, ...args] = shellWords(stage);
      const operands = args.filter((a) => !a.startsWith("-"));
      const lines = program === "sed" && args[0] === "-n" ? /^(\d+)(?:,(\d+))?p$/.exec(args[1] ?? "") : null;
      if (lines) {
        range = { start: Number(lines[1]), end: Number(lines[2] ?? lines[1]) };
        file = args[2] ?? file;
      } else if ((program === "nl" || program === "cat") && operands.length === 1) {
        file = operands[0];
      } else if (program === "head" && args.length >= 2 && operands.length >= 1) {
        const count = Number(args[0] === "-n" ? args[1] : args[0].slice(1));
        file = args.at(-1);
        range = count > 0 ? { start: 1, end: count } : undefined;
      }
    }
    if (file) return { path: absolute(file, cwd), range, action: "read" };
  }
  return undefined;
}

/** Splits a simple shell command into words (quotes, no expansions). */
function shellWords(text: string): string[] {
  const words: string[] = [];
  const pattern = /'([^']*)'|"((?:\\.|[^"\\])*)"|(\S+)/g;
  for (let m = pattern.exec(text); m; m = pattern.exec(text)) words.push(m[1] ?? m[2]?.replace(/\\(.)/g, "$1") ?? m[3]);
  return words;
}
