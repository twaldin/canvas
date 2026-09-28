// bun test extensions/agent-hooks — which folders Codex 0.155 asks about as it starts (observed
// in a pty with an isolated CODEX_HOME: see codex-trust.ts).
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexStartupQuestion } from "./codex-trust";

test("Codex asks at startup unless the folder, or its git repository, is trusted", () => {
  const top = mkdtempSync(join(tmpdir(), "canvas-codex-trust-"));
  const real = realpathSync(top);
  try {
    const home = join(top, "home");
    for (const dir of ["home", "trusted/sub", "untrusted", "plain", "repo/sub"]) mkdirSync(join(top, dir), { recursive: true });
    const git = (...args: string[]) => Bun.spawnSync(["git", "-C", join(top, "repo"), ...args], { stderr: "ignore" });
    git("init", "-q");
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x");
    git("worktree", "add", "-q", join(top, "wt"));
    writeFileSync(join(home, "config.toml"), [
      `model = "x"`,
      `[projects."${real}/trusted"]`, `trust_level = "trusted"`,
      `[projects."${real}/untrusted"]`, `trust_level = "untrusted"`,
      `[projects."${real}/repo"]`, `trust_level = "trusted"`,
    ].join("\n"));
    const ask = (dir: string, args: string[] = []) => codexStartupQuestion(args, join(top, dir), home);
    expect(ask("trusted")).toBeUndefined();
    expect(ask("trusted/sub")).toBe("Codex asks whether to trust this folder"); // outside git only the exact folder counts
    expect(ask("plain")).toBe("Codex asks whether to trust this folder");
    expect(ask("untrusted")).toBe("Codex asks how to open this untrusted folder");
    expect(ask("repo/sub")).toBeUndefined(); // a trusted repository's subfolder
    expect(ask("wt")).toBeUndefined(); // and its worktree
    expect(ask("plain", ["-a", "never", "-s", "workspace-write"])).toBe("Codex asks whether to trust this folder"); // flags don't skip it
    expect(ask("plain", ["-C", "../trusted"])).toBeUndefined(); // the folder `-C` names
    expect(ask("plain", ["exec", "fix it"])).toBeUndefined(); // no interactive session
    expect(ask("plain", ["-m", "exec"])).toBe("Codex asks whether to trust this folder"); // an option's value isn't a subcommand
    expect(ask("plain", ["resume", "--last"])).toBe("Codex asks whether to trust this folder");
    expect(codexStartupQuestion([], join(top, "plain"), join(top, "no-home"))).toBe("Codex asks whether to trust this folder"); // no config yet
  } finally {
    rmSync(top, { recursive: true, force: true });
  }
});
