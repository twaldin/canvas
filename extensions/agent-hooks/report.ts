// Lifecycle reports from the agent integrations (extensions/omp, the hooks, extensions/opencode),
// kept when Canvas isn't there to take them. A report that can't reach Canvas (quit, restarting,
// crashed) is written to `agent-reports/<tile>/` beside the socket, and Canvas replays the
// tile's reports when it opens the tile's board, oldest `seq` first (AgentReportSpool.swift), so
// an agent that finished meanwhile comes back `done` with its answer. Neither sending nor
// spooling ever throws or waits on anything but its own short IO: the agent carries on as if
// there were no hook.
import { randomBytes } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { CanvasError, type AgentReleaseParams, type AgentReportParams, type CanvasClient } from "../../clients/ts/src/index";

/** Where reports for `tile` wait while Canvas is away: `agent-reports/<tile>/` beside the socket. */
export function spoolDirectory(socketPath: string, tile: string): string {
  return join(dirname(socketPath), "agent-reports", tile);
}

/** `agent.report`; spooled when Canvas can't be reached. `params.seq` orders the replay. */
export function report(client: CanvasClient, params: AgentReportParams & { seq: number }): Promise<void> {
  return deliver(client, "agent.report", params, params.seq, () => client.api.agent.report(params));
}

/** `agent.release` (the agent exited); spooled when Canvas can't be reached, in `seq` order with the reports. */
export function release(client: CanvasClient, params: AgentReleaseParams, seq: number): Promise<void> {
  return deliver(client, "agent.release", params, seq, () => client.api.agent.release(params));
}

async function deliver(client: CanvasClient, method: string, params: { tile: string }, seq: number, send: () => Promise<unknown>): Promise<void> {
  try {
    await send();
  } catch (error) {
    // Canvas answered (it rejected the report): nothing to keep. Not there, or no answer in
    // time (it may be quitting): keep it; a replay of one it did apply is dropped as stale.
    if (error instanceof CanvasError && error.code !== "unavailable" && error.code !== "timeout") return;
    await spool(client.socketPath, params.tile, { seq, method, params }).catch(() => undefined);
  }
}

/** Written under a hidden name, then renamed: Canvas never reads half a report. */
async function spool(socketPath: string, tile: string, entry: { seq: number; method: string; params: object }): Promise<void> {
  if (!/^[\w-]+$/.test(tile)) return;
  const directory = spoolDirectory(socketPath, tile);
  await mkdir(directory, { recursive: true });
  const name = `${entry.seq}-${process.pid}-${randomBytes(4).toString("hex")}.json`;
  const temporary = join(directory, `.${name}`);
  await writeFile(temporary, JSON.stringify(entry));
  await rename(temporary, join(directory, name));
}
