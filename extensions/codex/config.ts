// The `hooks={…}` override the codex wrapper (bin/codex) passes as `codex -c`, so a Codex session
// in an easl tile runs extensions/agent-hooks/hook.ts without touching ~/.codex.
//   bun config.ts <codex's arguments…>
// prints where in those arguments the `-c` goes (an index, see `hooksAt`), a newline, and the override.
//
// Codex skips a non-managed hook until its exact definition is trusted, recording
// `hooks.state."<key>".trusted_hash` in config. Session flags (`-c`) are a config layer whose
// hook state Codex honors, so the override trusts exactly the hooks it defines, and nothing else.
// Key and hash follow codex-rs/hooks (engine/discovery.rs `hook_hash`, lib.rs `hook_key`):
//   key  = "/<session-flags>/config.toml:<event_label>:<group>:<handler>"
//   hash = "sha256:" + hex(sha256(canonical JSON of { event_name, matcher?, hooks: [normalized handler] })),
// with keys sorted, absent options omitted, and `timeout` normalized. Verified against Codex
// 0.155 (docs/testing.md); a Codex that hashes differently lists the hooks under /hooks as needing
// review instead of running them.
import { createHash } from "node:crypto";
import { resolve } from "node:path";

const RUN = resolve(import.meta.dir, "../agent-hooks/run");

/**
 * Event → Codex's key label, timeout (s; SessionEnd and Interrupt allow at most 3), async, and
 * matcher (tool names). PreToolUse only for Codex's questions to the user, `request_user_input`
 * (Plan mode) and `request_user_input_async` (Default mode), which no other hook announces.
 */
const EVENTS: Array<[event: string, label: string, timeout: number, async: boolean, matcher?: string]> = [
  ["SessionStart", "session_start", 5, false],
  ["UserPromptSubmit", "user_prompt_submit", 5, false],
  ["PreToolUse", "pre_tool_use", 5, false, "request_user_input|request_user_input_async"],
  ["PermissionRequest", "permission_request", 5, false],
  ["PostToolUse", "post_tool_use", 5, true],
  ["Stop", "stop", 5, false],
  ["Interrupt", "interrupt", 3, false],
  ["SessionEnd", "session_end", 3, false],
];

const quote = (word: string) => `'${word.replaceAll("'", `'"'"'`)}'`;

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return Object.fromEntries(Object.keys(record).sort().map((key) => [key, canonical(record[key])]));
  }
  return value;
}

const groups: string[] = [];
const state: string[] = [];
for (const [event, label, timeout, runsAsync, matcher] of EVENTS) {
  const handler = { type: "command", command: `${quote(RUN)} codex ${event}`, timeout, async: runsAsync };
  const identity = { event_name: label, ...(matcher ? { matcher } : {}), hooks: [handler] };
  const hash = `sha256:${createHash("sha256").update(JSON.stringify(canonical(identity))).digest("hex")}`;
  // TOML basic strings accept JSON string escapes.
  const group = `${matcher ? `matcher=${JSON.stringify(matcher)},` : ""}hooks=[{type="command",command=${JSON.stringify(handler.command)},timeout=${timeout},async=${runsAsync}}]`;
  groups.push(`${event}=[{${group}}]`);
  state.push(`${JSON.stringify(`/<session-flags>/config.toml:${label}:0:0`)}={trusted_hash=${JSON.stringify(hash)}}`);
}
export const hooksOverride = `hooks={${groups.join(",")},state={${state.join(",")}}}`;

/**
 * The index in Codex's arguments to insert `-c <hooks>` before, so Codex keeps it.
 *
 * `-c` is a clap global option, and clap keeps only the deepest command level's occurrences: in
 * `codex -c A resume <id> -c B` Codex sees `-c B` alone (A is dropped; clap 4.5 `propagate_globals`,
 * codex-rs/utils/cli/src/config_override.rs). So the override goes beside the user's last `-c`
 * (the deepest level that has one), or first when there is none. Arguments after `--` are the
 * prompt's.
 */
export function hooksAt(args: string[]): number {
  let at = 0;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--") break;
    if (arg === "-c" || arg === "--config") {
      at = i;
      i++; // its value
    } else if (arg.startsWith("--config=") || (arg.startsWith("-c") && !arg.startsWith("--"))) {
      at = i;
    }
  }
  return at;
}

if (import.meta.main) process.stdout.write(`${hooksAt(process.argv.slice(2))}\n${hooksOverride}`);
