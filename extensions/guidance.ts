// The canvas-awareness block every agent integration gives its agent (omp's system prompt,
// Claude Code's and Codex's SessionStart context). One text; only how the agent loads the
// shipped skill and reaches the socket differs per agent.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type GuidanceAgent = "omp" | "claude" | "codex";

/** The skill shipped with Canvas (skills/canvas, beside extensions/ in the repo and the bundle). */
export const SKILL_PATH = resolve(import.meta.dir, "../skills/canvas/SKILL.md");

export function canvasGuidance(agent: GuidanceAgent, tile: string): string {
  const socket = process.env.CANVAS_SOCKET ?? "";
  const board = process.env.CANVAS_BOARD_ID ?? "";
  return [
    `You are running in a Canvas terminal tile (${tile}). Mentions the user staged on the canvas arrive as <canvas-mentions>.`,
    ...skillLines(agent),
    "When your answer is something the user will come back to (a plan, a walkthrough across several files, a comparison), put it on the canvas or offer to; one-off answers stay in the terminal.",
    "To show the user code, a page, or a diagram beside this terminal, use the canvas (skill, `canvas` CLI, SDK). Never drive the Canvas app with GUI automation (Computer Use, AppleScript) and never publish it elsewhere (artifacts, gists) instead.",
    ...connectionLines(agent, socket, tile, board),
  ].join("\n");
}

function skillLines(agent: GuidanceAgent): string[] {
  if (agent === "claude") {
    // The Claude Code plugin (extensions/claude) ships the skill itself.
    return ["Before reading or changing the canvas, or when the user refers to things on it, you MUST load the `canvas:canvas` skill."];
  }
  // omp's skill discovery isn't extensible from an extension and Codex has no per-session skill
  // root, so the skill is announced the way they list skills and read on demand from its path.
  const description = /^description:\s*(.+)$/m.exec(readFileSync(SKILL_PATH, "utf8"))?.[1]?.trim() ?? "";
  const how = agent === "omp" ? "with the read tool" : "(e.g. `cat` it)";
  return [
    `Canvas provides this skill for the session${agent === "omp" ? " (not reachable through skill://)" : ""}:`,
    "<skills>",
    `- canvas: ${description}`,
    "</skills>",
    `Before reading or changing the canvas, or when the user refers to things on it, you MUST read ${SKILL_PATH} ${how}. Its relative references (e.g. references/html-explainers.md) live in ${dirname(SKILL_PATH)}/.`,
  ];
}

function connectionLines(agent: GuidanceAgent, socket: string, tile: string, board: string): string[] {
  const connection = `Canvas connection: CANVAS_SOCKET=${socket} CANVAS_TILE_ID=${tile} CANVAS_BOARD_ID=${board}.`;
  if (agent === "omp") {
    // omp starts its eval Python kernel with an allowlisted environment (PATH, HOME, PYTHONPATH,
    // LC_/XDG_/PI_ …) that drops CANVAS_*, so the connection values are spelled out.
    return [
      `${connection} The bash tool inherits these; the eval Python kernel does not, so connect there explicitly:`,
      `  from canvas_sdk import connect; canvas = connect(socket=${JSON.stringify(socket)}, tile=${JSON.stringify(tile)}, board=${JSON.stringify(board)})`,
      "Subprocesses started from eval (e.g. the `canvas` CLI) need those three variables in their env.",
    ];
  }
  if (agent === "codex") {
    // Codex's workspace-write sandbox denies unix-socket connects (docs/contracts.md).
    return [`${connection} Shell commands inherit these. The \`canvas\` CLI talks to that unix socket, which Codex's sandbox blocks: run canvas commands with escalated permissions (outside the sandbox) instead of retrying them sandboxed.`];
  }
  return [`${connection} Shell commands inherit these.`];
}
