// bun test extensions/agent-hooks — where bin/codex puts the hooks override in Codex's arguments.
// Codex's `-c` is a clap global option and clap keeps only the deepest command level's
// occurrences (seen with Codex 0.155: `codex -c hooks=… resume <id> -c x` ran no hook at all), so
// the override must sit at the level of the user's last `-c`.
import { expect, test } from "bun:test";
import { hooksAt } from "../codex/config";

/** The `-c` values Codex 0.155 keeps: those of the deepest command level that has any. */
function kept(args: string[]): string[] {
  const subcommands: Record<string, true> = { resume: true, fork: true, exec: true, e: true, review: true, mcp: true };
  const levels: string[][] = [[]];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--") break;
    if (arg === "-c" || arg === "--config") levels[levels.length - 1]!.push(args[++i]!);
    else if (arg.startsWith("--config=")) levels[levels.length - 1]!.push(arg.slice(9));
    else if (arg.startsWith("-c")) levels[levels.length - 1]!.push(arg.slice(2));
    else if (subcommands[arg] === true) levels.push([]);
  }
  return levels.findLast((level) => level.length > 0) ?? [];
}

const withHooks = (args: string[]) => {
  const at = hooksAt(args);
  return [...args.slice(0, at), "-c", "HOOKS", ...args.slice(at)];
};

test("Codex keeps the hooks override beside every -c the user gives, at whatever level", () => {
  const cases = [
    [],
    ["fix the bug"],
    ["resume", "01a0"],
    ["resume", "--last"],
    ["-c", "model=o3", "resume"],
    ["resume", "01a0", "-c", 'projects."/p".trust_level="trusted"'],
    ["-c", "model=o3", "resume", "01a0", "--config=x=1", "--last"],
    ["exec", "-cmodel=o3", "--", "-c", "not an option"],
  ];
  for (const args of cases) {
    const user = kept(args);
    expect(kept(withHooks(args)).sort()).toEqual([...user, "HOOKS"].sort());
  }
});
