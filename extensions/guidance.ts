// The canvas-awareness block every agent integration gives its agent (omp's system prompt,
// Claude Code's, Codex's and Gemini CLI's SessionStart context, opencode's system prompt). One
// text; only how the agent loads the shipped skill and reaches the socket differs per agent.
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";

export type GuidanceAgent = "omp" | "claude" | "codex" | "gemini" | "opencode";

/** The skill shipped with Canvas (skills/canvas, beside extensions/ in the repo and the bundle). */
export const SKILL_PATH = resolve(import.meta.dir, "../skills/canvas/SKILL.md");

export function canvasGuidance(agent: GuidanceAgent, tile: string): string {
  const socket = process.env.CANVAS_SOCKET ?? "";
  const board = process.env.CANVAS_BOARD_ID ?? "";
  return [
    `You are running in a Canvas terminal tile (${tile}). Mentions the user staged on the canvas arrive as <canvas-mentions>, with each item's location and excerpt.`,
    ...skillLines(agent),
    "Write code references as repo-relative `path:line` (`src/app.ts:42`, `src/app.ts:42-60`): the user ⌘-clicks them to open the code beside you.",
    "When your answer is something the user will come back to (a plan, a walkthrough across several files, a comparison), put it on the canvas or offer to; one-off answers stay in the terminal.",
    "To show the user code, a page, or a diagram beside this terminal, use the canvas (skill, `canvas` CLI, SDK). Never drive the Canvas app with GUI automation (Computer Use, AppleScript) and never publish it elsewhere (artifacts, gists) instead.",
    ...browserLines(agent),
    "Canvas's scratch output (renders under $TMPDIR/canvas-renders/, JSON payload files for the `canvas` CLI) belongs in $TMPDIR, never in the repo: writing there is not touching the user's files, even under an instruction to stay in this directory.",
    "Never answer another agent's approval with `agent.prompt` `force`: it types into whatever dialog is open and presses Return, which in an approval menu picks the highlighted option (usually allow). Tell the user it waits instead. `board.open` with `select: true` switches the user's tab: only when they asked to see that board.",
    ...connectionLines(agent, socket, tile, board),
  ].join("\n");
}

/** omp's `browser` drives Canvas browser tiles here (the cmux backend), which it can't resize. */
function browserLines(agent: GuidanceAgent): string[] {
  if (agent !== "omp") return [];
  return [
    "Your `browser` opens its page in a Canvas browser tile beside you, and the tile is the viewport: `viewport`, `tab.setViewport` and `tab.emulate` don't change it and `tab.devices()` is unsupported. For a phone or tablet width, keep that tile (the user sees it; don't switch to a headless browser) and resize it: `canvas object.update --id <tile> --json '{\"frame\":{\"w\":390,\"h\":902}}'` (w = the CSS width; h = the height + 58 for the title and address bars; the tile is your newest browser object in `canvas board.get`), then read innerWidth again.",
  ];
}

function skillLines(agent: GuidanceAgent): string[] {
  const when = "before you create, change, arrange, or inspect canvas objects. A plain question, or one about a mentioned item, needs no skill: answer it from the code and the <canvas-mentions> block.";
  if (agent === "claude") {
    // The Claude Code plugin (extensions/claude) ships the skill itself.
    return [`You MUST load the \`canvas:canvas\` skill ${when}`];
  }
  // omp's skill discovery isn't extensible from an extension, and Codex, Gemini CLI and opencode
  // have no per-session skill root, so the skill is announced the way they list skills and read
  // on demand from its path.
  const description = /^description:\s*(.+)$/m.exec(readFileSync(SKILL_PATH, "utf8"))?.[1]?.trim() ?? "";
  const how = agent === "omp" ? "with the read tool" : agent === "codex" ? "(e.g. `cat` it)" : "with your file-reading tool";
  return [
    `Canvas provides this skill for the session${agent === "omp" ? " (not reachable through skill://)" : ""}:`,
    "<skills>",
    `- canvas: ${description}`,
    "</skills>",
    `You MUST read ${SKILL_PATH} ${how} ${when} Its relative references (e.g. references/html-explainers.md) live in ${dirname(SKILL_PATH)}/.`,
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
    // Codex's workspace-write sandbox denies unix-socket connects (docs/contracts.md), so each
    // canvas call asks for approval until the user allows every command starting `canvas`.
    // Codex matches that rule, and offers it, only for commands of plain words: `$TMPDIR`, `$(…)`,
    // a heredoc or a redirect makes it ask again every time. So payloads go by their literal path.
    const dir = tmpdir();
    return [
      `${connection} Shell commands inherit these. The \`canvas\` CLI talks to that unix socket, which Codex's sandbox blocks: run canvas commands with escalated permissions (outside the sandbox) and \`prefix_rule: ["canvas"]\` instead of retrying them sandboxed, so the user can allow every \`canvas\` command once.`,
      `Write canvas JSON payloads to a file in ${dir}/ first, then pass it by that literal path, never inline JSON: \`canvas object.create --json @${dir}/canvas-box.json\`. Keep each canvas command plain words: a variable (\`$TMPDIR\`), \`$(…)\`, heredoc or redirect in it makes Codex ask the user again for every call.`,
    ];
  }
  if (agent === "gemini") {
    // Gemini CLI asks before each shell command whose root command wasn't allowed yet; one
    // `canvas …` approval "for this session" covers every later canvas call.
    return [
      `${connection} Shell commands inherit these. Use the \`canvas\` CLI for canvas calls: the user can allow \`canvas\` once for the session.`,
      "Write canvas JSON payloads to a file in $TMPDIR and pass `--json @<file>`, never inline JSON, so each call stays one short `canvas …` command.",
    ];
  }
  return [`${connection} Shell commands inherit these.`];
}
