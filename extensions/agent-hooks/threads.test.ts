// bun test extensions/agent-hooks — payloads as Codex 0.155 and Claude Code send them.
import { expect, test } from "bun:test";
import { thread } from "./threads";

const env = { HOME: "/Users/me" };
const session = "01a0e347-5419-7ea2-815c-96c0ab89cb4e";

test("the tile's own Codex session, ephemeral or not, is the main thread", () => {
  expect(thread("codex", { session_id: session, transcript_path: "/Users/me/.codex/sessions/r.jsonl", cwd: "/private/tmp/repo" }, env)).toBe("main");
  // `codex --ephemeral` in the tile: no transcript, but working in the user's directory.
  expect(thread("codex", { session_id: session, transcript_path: null, cwd: "/private/tmp/repo" }, env)).toBe("main");
});

test("a spawned subagent's events are the subagent's, in Codex and Claude Code", () => {
  const codex = { session_id: session, agent_id: "01a0e347-804a-7b61-b22d-796f8824bbff", agent_type: "default", transcript_path: "/Users/me/.codex/sessions/sub.jsonl", cwd: "/tmp/repo" };
  expect(thread("codex", codex, env)).toBe("subagent");
  expect(thread("claude", { session_id: "abc", agent_id: "a1b2", agent_type: "Explore", cwd: "/tmp/repo" }, env)).toBe("subagent");
  // `claude --agent`: agent_type alone is the main session.
  expect(thread("claude", { session_id: "abc", agent_type: "reviewer", cwd: "/tmp/repo" }, env)).toBe("main");
});

test("Codex's memory consolidation session is internal, under the default or a custom CODEX_HOME", () => {
  const consolidation = { session_id: "01a0e303-16a5-7000-8000-000000000000", transcript_path: null, cwd: "/Users/me/.codex/memories", source: "startup" };
  expect(thread("codex", consolidation, env)).toBe("internal");
  expect(thread("codex", { ...consolidation, cwd: "/private/tmp/ch/memories_v2" }, { CODEX_HOME: "/tmp/ch" })).toBe("internal");
  // Persisted (it has a transcript): a session the user runs in ~/.codex is still theirs.
  expect(thread("codex", { ...consolidation, transcript_path: "/Users/me/.codex/sessions/r.jsonl" }, env)).toBe("main");
  // Other agents never have Codex's internal sessions.
  expect(thread("claude", consolidation, env)).toBe("main");
});
