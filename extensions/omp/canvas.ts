// Canvas integration for omp. Active only inside a Canvas terminal tile (CANVAS_ENV=1).
//  - drains the selection tray into the prompt you submit (hidden context, two-phase so a
//    cancelled prompt loses nothing)
//  - reports lifecycle (working / blocked / idle) and session identity for resume
//  - follow mode: forwards files the agent reads, edits, and writes to its follow tile
//  - provides the shipped `canvas` skill (skills/canvas) to the agent, only inside Canvas
// Load explicitly with `omp -e /path/to/canvas.ts`, or install into ~/.omp/agent/extensions.
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { CanvasClient } from "../../clients/ts/src/index";

const SOURCE = "canvas-omp";
const IDLE_DEBOUNCE_MS = 250;

type Staged = { prompt: string; ids: string[]; context: string; delivered: boolean };
type ToolCall = { name: string; args: Record<string, unknown> | undefined };
type Details = Record<string, any>;

export default function canvas(pi: ExtensionAPI): void {
  const tile = process.env.CANVAS_TILE_ID;
  if (process.env.CANVAS_ENV !== "1" || !tile || !process.env.CANVAS_SOCKET) return;

  const guidance = canvasGuidance(tile);

  // Short timeouts: a missing, wedged, or restarting app must never stall the user's prompt.
  const client = new CanvasClient({ timeoutMs: 1500, reconnectTimeoutMs: 0 });
  let seq = Date.now() * 1000;
  let active = false;
  // omp runs subagents in this process with this extension rebound to each, headless (no UI).
  // They share our tile, but only the session with a UI is the tile's agent: a subagent's
  // agent_end is not the tile going idle, and its session id is not the one to resume.
  let reporting = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  const blockers = new Map<string, string>();
  const calls = new Map<string, ToolCall>();
  let staged: Staged | undefined;

  const quietly = (work: Promise<unknown>) => work.catch(() => undefined);

  function publish(): void {
    if (!reporting) return;
    clearTimeout(idleTimer);
    const firstBlocker = blockers.values().next().value;
    const state = blockers.size > 0 ? "blocked" : active ? "working" : "idle";
    const send = () => quietly(client.api.agent.report({ tile: tile!, kind: "omp", state, message: firstBlocker, seq: ++seq, source: SOURCE }));
    // Debounce idle so retries and tool-only continuations don't flicker the badge.
    if (state === "idle") idleTimer = setTimeout(send, IDLE_DEBOUNCE_MS);
    else void send();
  }

  function reportSession(ctx: ExtensionContext): void {
    if (!reporting) return;
    void quietly(client.api.agent.report_session({ tile: tile!, kind: "omp", sessionId: ctx.sessionManager.getSessionId(), sessionPath: ctx.sessionManager.getSessionFile() }));
  }

  function commitStaged(): void {
    if (!staged?.delivered) return;
    void quietly(client.api.tray.commit({ ids: staged.ids }));
    staged = undefined;
  }

  pi.on("session_start", (_event, ctx) => {
    reporting = ctx.hasUI;
    active = !ctx.isIdle();
    blockers.clear();
    staged = undefined;
    reportSession(ctx);
    publish();
  });

  pi.on("session_switch", (_event, ctx) => {
    // A new or switched-to session starts settled; the old one's pending continuation is gone.
    active = !ctx.isIdle();
    reportSession(ctx);
    publish();
  });

  pi.on("session_shutdown", () => {
    if (reporting) void quietly(client.api.agent.release({ tile, kind: "omp", source: SOURCE }));
  });

  pi.on("agent_start", () => {
    active = true;
    commitStaged();
    publish();
  });

  // willContinue: omp already scheduled the next run (retry, compaction, todo or session_stop
  // continuation, or background jobs whose results will resume it), so this is not a settle.
  pi.on("agent_end", (event) => {
    active = event.willContinue === true;
    publish();
  });

  pi.on("tool_approval_requested", (event) => {
    blockers.set(`approval:${event.toolCallId}`, `approve ${event.toolName}?`);
    publish();
  });

  pi.on("tool_approval_resolved", (event) => {
    blockers.delete(`approval:${event.toolCallId}`);
    publish();
  });

  // Tray drain, phase 1: peek the tray when the user actually submits prose.
  pi.on("input", async (event) => {
    if (event.source !== "interactive") return;
    const text = event.text.trim();
    if (!text || /^[/!$]/.test(text)) return; // slash commands and shell escapes aren't prompts
    try {
      const drained = await client.api.tray.drain({ peek: true });
      staged = drained.context ? { prompt: text, ids: drained.mentions.map((m) => m.id), context: drained.context, delivered: false } : undefined;
    } catch {
      staged = undefined; // app not running: prompt proceeds untouched
    }
  });

  // Phase 2: attach the staged mentions as hidden, user-attributed context to that prompt.
  pi.on("before_agent_start", (event) => {
    const systemPrompt = [...event.systemPrompt, guidance];
    if (!staged || !event.prompt.includes(staged.prompt)) return { systemPrompt };
    staged.delivered = true;
    return {
      systemPrompt,
      message: { customType: "canvas.mentions", content: staged.context, display: false, attribution: "user", details: { ids: staged.ids } },
    };
  });

  // Follow mode and ask-blocking. Top-level xd:// writes wrap mounted tools such as ask and lsp.
  pi.on("tool_execution_start", (event) => {
    let call: ToolCall = { name: event.toolName, args: event.args as Record<string, unknown> | undefined };
    const path = call.args?.path;
    if (call.name === "write" && typeof path === "string" && path.startsWith("xd://")) {
      try {
        call = { name: path.slice(5), args: JSON.parse(String(call.args?.content)) };
      } catch {
        // help/doc read of a device, not an executable call
      }
    }
    calls.set(event.toolCallId, call);
    if (call.name === "ask") {
      const questions = call.args?.questions as Array<{ question?: string }> | undefined;
      blockers.set(`ask:${event.toolCallId}`, questions?.[0]?.question ?? "waiting for your answer");
      publish();
    }
    if (call.name === "lsp" && typeof call.args?.file === "string") {
      const line = typeof call.args.line === "number" ? call.args.line : undefined;
      follow(call.args.file, line, line, "lsp");
    }
  });

  pi.on("tool_execution_end", (event) => {
    const call = calls.get(event.toolCallId);
    calls.delete(event.toolCallId);
    if (blockers.delete(`ask:${event.toolCallId}`)) publish();
    if (event.isError) return;
    const outer = (event.result as { details?: Details } | undefined)?.details;
    const name: string = outer?.xdev?.tool ?? call?.name ?? event.toolName;
    const details: Details | undefined = outer?.xdev?.inner ?? outer;
    if (!details) return;
    if (name === "read" && !details.isDirectory) {
      const path = details.displayTarget ?? details.resolvedPath ?? (details.meta?.source?.type === "path" ? details.meta.source.value : undefined);
      const numbers = (details.displayContent?.lineNumbers as Array<number | null> | undefined)?.filter((n): n is number => typeof n === "number");
      const start = numbers?.[0] ?? details.displayContent?.startLine;
      if (typeof path === "string") follow(path, start, numbers?.at(-1) ?? start, "read");
    }
    if (name === "edit") {
      for (const file of (details.perFileResults as Details[] | undefined) ?? [details]) {
        if (typeof file.path === "string" && !file.isError) follow(file.path, file.firstChangedLine, file.firstChangedLine, "edit");
      }
    }
    // New files and overwrites: the tile jumps to what changed and flashes it.
    const written = call?.args?.path;
    if (name === "write" && typeof written === "string" && !written.startsWith("xd://")) follow(written, undefined, undefined, "write");
  });

  function follow(path: string, start: unknown, end: unknown, action: "read" | "edit" | "write" | "lsp"): void {
    // Subagents' reads (background scouts) would drag the tile's follow view around.
    if (!reporting) return;
    const absolute = isAbsolute(path) ? path : resolve(process.cwd(), path.replace(/:[\d+\-,]+$/, ""));
    const range = typeof start === "number" && start > 0 ? { start, end: typeof end === "number" && end >= start ? end : start } : undefined;
    void quietly(client.api.follow.report({ tile: tile!, path: absolute, range, action }));
  }
}

/** The skill shipped with Canvas, next to this extension. */
const SKILL_PATH = resolve(import.meta.dir, "../../skills/canvas/SKILL.md");

/** System-prompt text for a Canvas tile. The shipped skill is announced the way omp lists
 * skills (name + description) and read on demand from its absolute path: omp's skill discovery
 * isn't extensible from an extension, and global skill config would leak outside Canvas.
 * The connection values are spelled out because omp starts its eval Python kernel with an
 * allowlisted environment (PATH, HOME, PYTHONPATH, LC_/XDG_/PI_ …) that drops CANVAS_*. */
function canvasGuidance(tile: string): string {
  const description = /^description:\s*(.+)$/m.exec(readFileSync(SKILL_PATH, "utf8"))?.[1]?.trim() ?? "";
  const socket = process.env.CANVAS_SOCKET ?? "";
  const board = process.env.CANVAS_BOARD_ID ?? "";
  return [
    `You are running in a Canvas terminal tile (${tile}). Mentions the user staged on the canvas arrive as <canvas-mentions>.`,
    "Canvas provides this skill for the session (not reachable through skill://):",
    "<skills>",
    `- canvas: ${description}`,
    "</skills>",
    `Before reading or changing the canvas, or when the user refers to things on it, you MUST read ${SKILL_PATH} with the read tool. Its relative references (e.g. references/html-explainers.md) live in ${dirname(SKILL_PATH)}/.`,
    `Canvas connection: CANVAS_SOCKET=${socket} CANVAS_TILE_ID=${tile} CANVAS_BOARD_ID=${board}. The bash tool inherits these; the eval Python kernel does not, so connect there explicitly:`,
    `  from canvas_sdk import connect; canvas = connect(socket=${JSON.stringify(socket)}, tile=${JSON.stringify(tile)}, board=${JSON.stringify(board)})`,
    "Subprocesses started from eval (e.g. the `canvas` CLI) need those three variables in their env.",
  ].join("\n");
}
