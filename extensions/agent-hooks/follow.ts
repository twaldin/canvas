// Where an agent's tool call looked or wrote, for its follow tile (`follow.report`): shared by
// the hook script (extensions/agent-hooks/hook.ts) and the opencode plugin (extensions/opencode).
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

export type Action = "read" | "edit" | "write";
export type Range = { start: number; end: number };
export type Location = { path: string; range?: Range; action: Action };

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

/** The first file an apply_patch touched, at its first added line. */
export function patchLocation(patch: string, cwd: string): Location | undefined {
  const header = /^\*\*\* (Add|Update) File: (.+)$/m.exec(patch);
  if (!header) return undefined;
  const moved = /^\*\*\* Move to: (.+)$/m.exec(patch.slice(header.index))?.[1];
  const path = absolute((moved ?? header[2]).trim(), cwd);
  if (header[1] === "Add") return { path, action: "write" };
  const added = /^\+(.*\S.*)$/m.exec(patch.slice(header.index))?.[1];
  let line: number | undefined;
  if (added) {
    try {
      const index = readFileSync(path, "utf8").split("\n").indexOf(added);
      line = index >= 0 ? index + 1 : undefined;
    } catch {
      line = undefined;
    }
  }
  return { path, range: line ? { start: line, end: line } : undefined, action: "edit" };
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
