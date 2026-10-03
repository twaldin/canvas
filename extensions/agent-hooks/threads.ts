// Which thread a hook event comes from. Claude Code and Codex run more than the tile's own
// session in one process, and fire the tile's hooks for them too:
//  - subagents (Claude's Task agents, Codex's spawn_agent threads) mark their events with
//    `agent_id`; their session_id is the parent's (Codex 0.155 fires SubagentStart/SubagentStop
//    for them, which Easl doesn't register, but their tool and prompt events come through);
//  - Codex's own internal sessions (memory consolidation, `memories` on) are separate ephemeral
//    threads: their own session_id, `transcript_path: null`, working in a directory under
//    CODEX_HOME (~/.codex/memories). They fire SessionStart, UserPromptSubmit, PostToolUse and
//    SessionEnd like the tile's session, which used to end the tile's turn mid-answer, replace
//    its recorded session (resume broke) and release it.
import { homedir } from "node:os";
import { resolve, sep } from "node:path";

export type Thread = "main" | "subagent" | "internal";

export function thread(kind: string, input: Record<string, unknown>, env: Record<string, string | undefined> = process.env): Thread {
  if (typeof input.agent_id === "string" && input.agent_id.length > 0) return "subagent";
  if (kind === "codex" && input.transcript_path === null && typeof input.cwd === "string") {
    // macOS reports /tmp paths as /private/tmp: compare without that prefix.
    const home = resolve(env.CODEX_HOME || `${env.HOME || homedir()}/.codex`).replace(/^\/private\//, "/");
    const cwd = resolve(input.cwd).replace(/^\/private\//, "/");
    if (cwd === home || cwd.startsWith(home + sep)) return "internal";
  }
  return "main";
}
