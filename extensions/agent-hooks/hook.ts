// Canvas integration for Claude Code and Codex, run as their lifecycle hooks:
//   bun hook.ts <claude|codex> <HookEvent>   (the agent's hook JSON on stdin)
// The claude/codex wrappers in bin/ install these hooks for one session (Claude: the plugin in
// extensions/claude; Codex: `-c hooks=…` from extensions/codex/config.ts) and only inside a Canvas
// terminal tile. Mirrors extensions/omp/canvas.ts:
//  - lifecycle (working / blocked / idle) and session identity for resume
//  - the canvas-awareness block (extensions/guidance.ts) as session context
//  - the selection tray drained into the prompt you submit, as hidden context
//  - follow mode: files the agent reads, edits, and writes re-aim its follow tile
// A hook never fails or stalls the agent: every Canvas call has a short timeout, errors are
// swallowed, and the process exits by a hard deadline.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { CanvasClient } from "../../clients/ts/src/index";
import { canvasGuidance } from "../guidance";

type Kind = "claude" | "codex";
type Json = Record<string, unknown>;
type Action = "read" | "edit" | "write";
type Range = { start: number; end: number };
type Location = { path: string; range?: Range; action: Action };

const HARD_DEADLINE_MS = 2500;

const kind = process.argv[2];
const event = process.argv[3] ?? "";
const tile = process.env.CANVAS_TILE_ID;
if ((kind === "claude" || kind === "codex") && process.env.CANVAS_ENV === "1" && tile && process.env.CANVAS_SOCKET && process.env.CANVAS_AGENT_HOOKS !== "0") {
  setTimeout(() => process.exit(0), HARD_DEADLINE_MS).unref();
  try {
    const input = JSON.parse(await Bun.stdin.text()) as Json;
    const output = await handle(kind, tile, event, input);
    if (output) await Bun.write(Bun.stdout, output);
  } catch {
    // Canvas unreachable or unexpected input: the agent carries on as if there were no hook.
  }
}
process.exit(0);

async function handle(kind: Kind, tile: string, event: string, input: Json): Promise<string | undefined> {
  const source = `canvas-${kind}`;
  const client = new CanvasClient({ timeoutMs: 1000, reconnectTimeoutMs: 0 });
  const quietly = (work: Promise<unknown>) => work.catch(() => undefined);
  // Hooks are separate processes that can finish out of order (async ones especially); the
  // process start time orders their reports the way the agent fired them.
  const seq = Math.floor(performance.timeOrigin * 1000);
  const report = (state: "working" | "blocked" | "idle", message?: string, call?: string) =>
    quietly(client.api.agent.report({ tile, kind, state, message, seq, source, call }));
  const context = (text: string) => JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: text } });
  // Claude and Codex mark events from inside a subagent with its id.
  const subagent = typeof input.agent_id === "string" && input.agent_id.length > 0;

  switch (event) {
    case "Launch": {
      // bin/codex, as Codex starts: it fires SessionStart only with the first prompt.
      await report("idle");
      return undefined;
    }
    case "SessionStart": {
      const sessionId = str(input.session_id);
      const started = str(input.source);
      await Promise.all([
        sessionId ? quietly(client.api.agent.report_session({ tile, kind, sessionId, sessionPath: str(input.transcript_path) })) : undefined,
        // A compaction restarts the session mid-turn; anything else starts it waiting for you.
        started === "compact" ? undefined : report("idle"),
      ]);
      return context(canvasGuidance(kind, tile));
    }
    case "UserPromptSubmit": {
      // A subagent's task arrives as its prompt: the user's turn goes on, and the tray is theirs.
      if (subagent) return undefined;
      const prompt = str(input.prompt)?.trim() ?? "";
      if (!prompt || /^[/!]/.test(prompt)) return undefined; // slash commands and shell escapes aren't prompts
      await report("working");
      // Peek, hand the context to the agent, then commit: a hook killed before its output
      // reached the agent leaves the tray intact. Only the tray's prompt target gets mentions.
      const drained = await client.api.tray.drain({ peek: true });
      if (!drained.context) return undefined;
      await Bun.write(Bun.stdout, context(drained.context));
      await quietly(client.api.tray.commit({ ids: drained.mentions.map((m) => m.id) }));
      return undefined;
    }
    case "PermissionRequest": {
      // Canvas keeps the tile blocked until this call finishes (its PostToolUse), whatever other
      // calls (parallel siblings, subagents) finish meanwhile.
      const tool = str(input.tool_name) ?? "tool";
      const description = str(obj(input.tool_input)?.description);
      await report("blocked", description ?? `approve ${tool}?`, toolCall(input));
      return undefined;
    }
    case "Notification": {
      // Claude Code: an MCP server asks for input, or the prompt has sat idle. Permission dialogs
      // are reported by PermissionRequest, which names the tool.
      const type = str(input.notification_type);
      if (type === "elicitation_dialog") await report("blocked", str(input.message));
      else if (type === "idle_prompt") await report("idle");
      return undefined;
    }
    case "PostToolUse":
    case "PostToolUseFailure": {
      // A finished call: the turn runs on (an approval of it was answered), unless other calls
      // still wait for approval. Claude reports a failed call separately; an Esc during it ends
      // the turn, with no Stop.
      if (input.is_interrupt === true) {
        await report("idle");
        return undefined;
      }
      // Subagents' reads would drag the follow tile around.
      const location = subagent || event === "PostToolUseFailure" ? undefined : kind === "claude" ? claudeLocation(input) : codexLocation(input);
      await Promise.all([
        report("working", undefined, toolCall(input)),
        location ? quietly(client.api.follow.report({ tile, path: location.path, range: location.range, action: location.action })) : undefined,
      ]);
      return undefined;
    }
    case "Stop":
    case "Interrupt":
      await report("idle");
      return undefined;
    case "SessionEnd":
      await quietly(client.api.agent.release({ tile, kind, source }));
      return undefined;
  }
  return undefined;
}

/**
 * Names a tool call the same in its PermissionRequest (which carries no call id) and its
 * PostToolUse: the tool and its input. Codex adds the approval's `description` only to the
 * request, so that is left out.
 */
function toolCall(input: Json): string {
  const { description: _, ...args } = obj(input.tool_input) ?? {};
  const identity = JSON.stringify([str(input.tool_name) ?? "", canonical(args)]);
  return createHash("sha256").update(identity).digest("hex").slice(0, 16);
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  const record = obj(value);
  return record ? Object.fromEntries(Object.keys(record).sort().map((key) => [key, canonical(record[key])])) : value;
}

// MARK: Follow

function claudeLocation(input: Json): Location | undefined {
  const tool = str(input.tool_name);
  const args = obj(input.tool_input) ?? {};
  const response = obj(input.tool_response) ?? {};
  const cwd = str(input.cwd) ?? process.cwd();
  if (tool === "Read") {
    const file = obj(response.file);
    const path = str(args.file_path);
    if (!path) return undefined;
    const start = num(file?.startLine);
    const lines = num(file?.numLines);
    return { path: absolute(path, cwd), range: start && lines ? { start, end: start + lines - 1 } : undefined, action: "read" };
  }
  if (tool === "Edit" || tool === "MultiEdit" || tool === "Write" || tool === "NotebookEdit") {
    const path = str(args.file_path) ?? str(args.notebook_path);
    if (!path) return undefined;
    const line = firstChangedLine(response.structuredPatch);
    const created = tool === "Write" && str(response.type) === "create";
    return { path: absolute(path, cwd), range: line ? { start: line, end: line } : undefined, action: tool === "Write" && (created || !line) ? "write" : "edit" };
  }
  return undefined;
}

/** First added or removed line of Claude Code's `structuredPatch` hunks, in the new file. */
function firstChangedLine(patch: unknown): number | undefined {
  const hunk = Array.isArray(patch) ? obj(patch[0]) : undefined;
  const start = num(hunk?.newStart);
  const lines = hunk?.lines;
  if (!start || !Array.isArray(lines)) return undefined;
  const offset = lines.findIndex((line) => typeof line === "string" && (line.startsWith("+") || line.startsWith("-")));
  return start + Math.max(0, offset);
}

function codexLocation(input: Json): Location | undefined {
  const tool = str(input.tool_name);
  const command = str(obj(input.tool_input)?.command);
  const cwd = str(input.cwd) ?? process.cwd();
  if (!command) return undefined;
  if (tool === "apply_patch") return patchLocation(command, cwd);
  if (tool === "Bash") return readLocation(command, cwd);
  return undefined;
}

/** The first file an apply_patch touched, at its first added line. */
function patchLocation(patch: string, cwd: string): Location | undefined {
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

/** Codex reads files through the shell: `sed -n 'A,Bp' f`, `nl -ba f | sed -n 'A,Bp'`, `cat f`, `head -n N f`. */
function readLocation(command: string, cwd: string): Location | undefined {
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

// MARK: Input helpers

function absolute(path: string, cwd: string): string {
  return isAbsolute(path) ? path : resolve(cwd, path);
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

function obj(value: unknown): Json | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
}
