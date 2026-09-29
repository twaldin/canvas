// bun test extensions/agent-hooks — a Codex turn's end, read from its rollout (codex-turn.ts).
import { afterEach, expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { turnEnd, watchTurn } from "./codex-turn";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const TURN = "01a0eb64-e18b-7902-b8e6-804e525df7a3";
const line = (payload: object) => `${JSON.stringify({ timestamp: "2026-09-29T04:20:55.268Z", type: "event_msg", payload })}\n`;
// As Codex 0.155 wrote them in a real session that hit the usage limit.
const started = line({ type: "task_started", turn_id: TURN, started_at: 1790655652 });
const limited = line({
  type: "task_complete", turn_id: TURN, last_agent_message: null, started_at: 1790655652, completed_at: 1790655655, duration_ms: 3026,
  error: { message: "You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 3rd, 2026 10:34 AM.", codex_error_info: "usage_limit_exceeded" },
});

test("a turn that failed ends with its error; a finished or interrupted one without", () => {
  expect(turnEnd(limited, TURN)).toEqual({ kind: "complete", error: expect.stringMatching(/^You’ve hit your usage limit\./) });
  expect(turnEnd(line({ type: "task_complete", turn_id: TURN, last_agent_message: "Fixed." }), TURN)).toEqual({ kind: "complete" });
  expect(turnEnd(line({ type: "turn_aborted", turn_id: TURN, reason: "interrupted" }), TURN)).toEqual({ kind: "aborted" });
  expect(turnEnd(started, TURN)).toBeUndefined();
  expect(turnEnd(limited, "another-turn")).toBeUndefined();
  expect(turnEnd(limited.replace('"event_msg"', '"response_item"'), TURN)).toBeUndefined();
  expect(turnEnd(`{"type":"event_msg","payload":{"type":"task_complete","turn_id":"${TURN}"`, TURN)).toBeUndefined();
});

test("the watch reads what Codex appends after the prompt, across partial writes, to this turn's end", async () => {
  const dir = mkdtempSync(join(tmpdir(), "canvas-codex-turn-"));
  dirs.push(dir);
  const rollout = join(dir, "rollout.jsonl");
  // An earlier turn that failed the same way is before the offset: not this turn's end.
  writeFileSync(rollout, limited.replaceAll(TURN, "earlier-turn"));
  const offset = statSync(rollout).size;
  // Each poll finds Codex has written a little more: the turn starts, then its end in two writes.
  const writes = [started, limited.slice(0, 40), limited.slice(40)];
  const wait = async () => appendFileSync(rollout, writes.shift() ?? "");
  expect(await watchTurn(rollout, TURN, offset, { alive: () => true, wait })).toEqual({ kind: "complete", error: expect.stringContaining("usage limit") });
});

test("the watch ends without a verdict when Codex exits mid-turn", async () => {
  const dir = mkdtempSync(join(tmpdir(), "canvas-codex-turn-"));
  dirs.push(dir);
  const rollout = join(dir, "rollout.jsonl");
  writeFileSync(rollout, started);
  let polls = 0;
  const wait = async () => polls++;
  expect(await watchTurn(rollout, TURN, 0, { alive: () => polls < 3, wait })).toBeUndefined();
  expect(polls).toBe(3);
});
