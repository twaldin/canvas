// Prints the `hooks={…}` override the codex wrapper (bin/codex) passes as `codex -c`, so a Codex
// session in a Chalkwork tile runs extensions/agent-hooks/hook.ts without touching ~/.codex.
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

/** Event → Codex's key label, timeout (s; SessionEnd and Interrupt allow at most 3), async. */
const EVENTS: Array<[event: string, label: string, timeout: number, async: boolean]> = [
  ["SessionStart", "session_start", 5, false],
  ["UserPromptSubmit", "user_prompt_submit", 5, false],
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
for (const [event, label, timeout, runsAsync] of EVENTS) {
  const handler = { type: "command", command: `${quote(RUN)} codex ${event}`, timeout, async: runsAsync };
  const identity = { event_name: label, hooks: [handler] };
  const hash = `sha256:${createHash("sha256").update(JSON.stringify(canonical(identity))).digest("hex")}`;
  // TOML basic strings accept JSON string escapes.
  groups.push(`${event}=[{hooks=[{type="command",command=${JSON.stringify(handler.command)},timeout=${timeout},async=${runsAsync}}]}]`);
  state.push(`${JSON.stringify(`/<session-flags>/config.toml:${label}:0:0`)}={trusted_hash=${JSON.stringify(hash)}}`);
}
process.stdout.write(`hooks={${groups.join(",")},state={${state.join(",")}}}`);
