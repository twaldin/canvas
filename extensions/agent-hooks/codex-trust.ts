// What Codex stops on as it starts, before any hook of its fires: its folder question
// (bin/codex's launch report). As Codex 0.155 decides it: an interactive session asks unless
// `projects."<folder>".trust_level = "trusted"` in `$CODEX_HOME/config.toml` names the folder it
// runs in (its real path, `-C` applied) or, inside a git checkout, the main repository's folder
// (a worktree or subfolder of a trusted repository doesn't ask). Only the exact folder counts:
// a subfolder of a trusted folder outside git asks. Approval and sandbox flags don't skip it.
//
// Answering "Trust and continue" fires no hook either (SessionStart waits for the first prompt),
// but Codex writes the folder's `trust_level = "trusted"` right away. So hook.ts starts this file,
// detached, at `Launch` when it reported the question:
//   bun codex-trust.ts <tile> <seq> <codex pid> <codex's arguments…>   (in Codex's folder)
// It reports `idle` once the config trusts the folder, and exits then, when Codex exits (Quit),
// or after `TRUST_WATCH_LIMIT_MS`. Its `seq` is the launch report's plus one: any hook Codex fires
// later is newer, so a prompt submitted first is never overwritten by this idle.
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { CanvasClient } from "../../clients/ts/src/index";
import { report } from "./report";

/** `codex --help`'s subcommands that start no interactive session (`resume`, `fork` and a bare prompt do). */
const NON_INTERACTIVE: Record<string, true> = {
  "agents": true, "exec": true, "e": true, "review": true, "login": true, "logout": true, "mcp": true, "plugin": true,
  "app-server": true, "remote-control": true, "app": true, "completion": true, "update": true, "doctor": true, "sandbox": true,
  "debug": true, "apply": true, "a": true, "queue": true, "archive": true, "delete": true, "migrate-rollouts": true,
  "unarchive": true, "cloud": true, "exec-server": true, "features": true, "help": true,
};
/** Options before the subcommand that take a value (`-m gpt`, `-C dir`). */
const VALUED: Record<string, true> = {
  "-c": true, "--config": true, "--enable": true, "--disable": true, "--remote": true, "--remote-auth-token-env": true,
  "-i": true, "--image": true, "-m": true, "--model": true, "--local-provider": true, "-p": true, "--profile": true, "-s": true,
  "--sandbox": true, "-C": true, "--cd": true, "--add-dir": true, "-a": true, "--ask-for-approval": true,
};

/**
 * The question Codex started with `args` in `cwd` waits on before its first prompt, for the tile's
 * `blocked` message; undefined when it asks none (a trusted folder, a non-interactive subcommand,
 * a config it can't read).
 */
export function codexStartupQuestion(args: string[], cwd: string, codexHome = process.env.CODEX_HOME || join(homedir(), ".codex")): string | undefined {
  let folder = cwd;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "-h" || arg === "--help" || arg === "-V" || arg === "--version") return undefined;
    if (arg === "-C" || arg === "--cd") folder = resolve(cwd, args[i + 1] ?? ".");
    else if (arg.startsWith("--cd=")) folder = resolve(cwd, arg.slice(5));
    if (VALUED[arg] === true) i++;
    else if (!arg.startsWith("-")) {
      if (NON_INTERACTIVE[arg] === true) return undefined;
      break; // `resume`, `fork` or the prompt: the rest is theirs
    }
  }
  let projects: Record<string, { trust_level?: unknown } | undefined>;
  let real: string;
  try {
    const path = join(codexHome, "config.toml");
    let text = "";
    try {
      text = readFileSync(path, "utf8");
    } catch {
      // No config yet: nothing is trusted.
    }
    projects = ((text ? Bun.TOML.parse(text) : {}) as { projects?: typeof projects }).projects ?? {};
    real = realpathSync(folder);
  } catch {
    return undefined; // Codex refuses a config it can't parse, and a missing folder, before asking anything
  }
  let level = projects[real]?.trust_level;
  if (level === undefined) {
    const root = repositoryRoot(real);
    level = root ? projects[root]?.trust_level : undefined;
  }
  if (level === "trusted") return undefined;
  return level === "untrusted" ? "Codex asks how to open this untrusted folder" : "Codex asks whether to trust this folder";
}

/** The main repository's folder of the git checkout `folder` is in (a worktree's too); undefined outside git. */
function repositoryRoot(folder: string): string | undefined {
  const git = Bun.spawnSync(["git", "-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stderr: "ignore" });
  const common = git.success ? git.stdout.toString().trim() : "";
  if (!common) return undefined;
  try {
    return dirname(realpathSync(common));
  } catch {
    return undefined;
  }
}

export const TRUST_WATCH_LIMIT_MS = 30 * 60 * 1000;

/**
 * Waits until Codex, started with `args` in `cwd`, no longer has a question to ask (the user
 * trusted the folder): true then; false when `alive()` turns false (Codex quit) or `limitMs`
 * passes first. `wait` paces the polls (default 500 ms).
 */
export async function watchTrust(args: string[], cwd: string, options: { alive: () => boolean; wait?: () => Promise<unknown>; limitMs?: number; codexHome?: string }): Promise<boolean> {
  const wait = options.wait ?? (() => Bun.sleep(500));
  const deadline = Date.now() + (options.limitMs ?? TRUST_WATCH_LIMIT_MS);
  while (Date.now() < deadline) {
    if (codexStartupQuestion(args, cwd, options.codexHome) === undefined) return true;
    if (!options.alive()) return false;
    await wait();
  }
  return false;
}

if (import.meta.main) {
  const [tile, seq, pid, ...args] = process.argv.slice(2);
  const codex = Number(pid);
  const alive = () => {
    try {
      process.kill(codex, 0);
      return true;
    } catch {
      return false;
    }
  };
  if (tile && Number.isInteger(Number(seq)) && Number.isInteger(codex) && codex > 1) {
    if (await watchTrust(args, process.cwd(), { alive }).catch(() => false)) {
      const client = new CanvasClient({ timeoutMs: 1000, reconnectTimeoutMs: 0 });
      await report(client, { tile, kind: "codex", state: "idle", seq: Number(seq), source: "canvas-codex" }).catch(() => undefined);
    }
  }
  process.exit(0);
}
