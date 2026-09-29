// Watches one Codex turn to its end in the session's rollout, for the one ending no hook reports:
// a turn that fails (the usage limit, an API error). Codex fires `Stop` only when a turn
// finishes and `Interrupt` when the user stops it; a failed turn fires neither, and its tile
// stayed blue "working" until the next prompt. Codex does record every turn's end in the rollout
// (`transcript_path`): an `event_msg` `task_complete` (with `error: {message, codex_error_info}`
// when it failed) or `turn_aborted`, naming the turn by `turn_id`.
//
// hook.ts starts this, detached, at `UserPromptSubmit`:
//   bun codex-turn.ts <tile> <transcript_path> <turn_id> <byte offset to read from> <codex pid>
// It reads what Codex appends from the offset (the rollout's size when the prompt was
// submitted), and exits at that turn's end, when Codex exits, or after `WATCH_LIMIT_MS`. Only a
// failed turn is reported: `idle` with its error (the tile's message; never `done`). A finished
// turn is `Stop`'s to report, with its answer, and an interrupted one `Interrupt`'s.
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { CanvasClient } from "../../clients/ts/src/index";
import { report } from "./report";

/** How a turn ended, as its rollout records it. */
export type TurnEnd = { kind: "complete"; error?: string } | { kind: "aborted" };

/** The end of turn `turnId` if rollout line `line` records it. */
export function turnEnd(line: string, turnId: string): TurnEnd | undefined {
  if (!line.includes(turnId)) return undefined;
  let entry: unknown;
  try {
    entry = JSON.parse(line);
  } catch {
    return undefined;
  }
  const record = entry && typeof entry === "object" ? (entry as Record<string, unknown>) : {};
  const payload = record.payload && typeof record.payload === "object" ? (record.payload as Record<string, unknown>) : {};
  if (record.type !== "event_msg" || payload.turn_id !== turnId) return undefined;
  if (payload.type === "turn_aborted") return { kind: "aborted" };
  if (payload.type !== "task_complete") return undefined;
  const error = payload.error && typeof payload.error === "object" ? (payload.error as Record<string, unknown>) : undefined;
  const message = typeof error?.message === "string" && error.message.trim() ? error.message.trim() : error ? "the turn failed" : undefined;
  return message ? { kind: "complete", error: message } : { kind: "complete" };
}

export const WATCH_LIMIT_MS = 12 * 60 * 60 * 1000;

/**
 * Reads what is appended to `path` from byte `offset` until a line records the end of `turnId`;
 * undefined when `alive()` turns false (Codex exited mid-turn) or `limitMs` passes first.
 * `wait` paces the polls (default 250 ms).
 */
export async function watchTurn(path: string, turnId: string, offset: number, options: { alive: () => boolean; wait?: () => Promise<unknown>; limitMs?: number }): Promise<TurnEnd | undefined> {
  const wait = options.wait ?? (() => Bun.sleep(250));
  const deadline = Date.now() + (options.limitMs ?? WATCH_LIMIT_MS);
  let position = offset;
  let pending = "";
  const buffer = Buffer.alloc(64 * 1024);
  while (Date.now() < deadline) {
    let size = 0;
    try {
      size = statSync(path).size;
    } catch {
      size = position;
    }
    if (size > position) {
      const fd = openSync(path, "r");
      try {
        while (position < size) {
          const read = readSync(fd, buffer, 0, Math.min(buffer.length, size - position), position);
          if (read <= 0) break;
          position += read;
          pending += buffer.toString("utf8", 0, read);
          const lines = pending.split("\n");
          pending = lines.pop() ?? "";
          for (const line of lines) {
            const end = turnEnd(line, turnId);
            if (end) return end;
          }
        }
      } finally {
        closeSync(fd);
      }
    } else if (!options.alive()) {
      return undefined;
    }
    await wait();
  }
  return undefined;
}

if (import.meta.main) {
  const [tile, path, turnId, offset, pid] = process.argv.slice(2);
  const codex = Number(pid);
  const alive = () => {
    try {
      process.kill(codex, 0);
      return true;
    } catch {
      return false;
    }
  };
  if (tile && path && turnId && Number.isInteger(codex) && codex > 1) {
    const end = await watchTurn(path, turnId, Number(offset) || 0, { alive }).catch(() => undefined);
    if (end?.kind === "complete" && end.error) {
      const client = new CanvasClient({ timeoutMs: 1000, reconnectTimeoutMs: 0 });
      const seq = Math.floor((performance.timeOrigin + performance.now()) * 1000);
      await report(client, { tile, kind: "codex", state: "idle", error: end.error, seq, source: "canvas-codex" }).catch(() => undefined);
    }
  }
  process.exit(0);
}
