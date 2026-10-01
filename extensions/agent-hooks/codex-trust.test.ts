// bun test extensions/agent-hooks — which folders Codex 0.155 asks about as it starts (observed
// in a pty with an isolated CODEX_HOME: see codex-trust.ts).
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexStartupQuestion, watchTrust } from "./codex-trust";

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

test("A trust override on the command line counts as Codex reads it: the -c level it keeps, merged over config.toml", () => {
  const top = realpathSync(mkdtempSync(join(tmpdir(), "canvas-codex-trust-")));
  try {
    const home = join(top, "home");
    for (const dir of ["home", "app", "other", "listed", "dot.d"]) mkdirSync(join(top, dir));
    writeFileSync(join(home, "config.toml"), `[projects."${top}/listed"]\ntrust_level = "trusted"\n[projects."${top}/other"]\ntrust_level = "untrusted"\n`);
    const ask = (dir: string, args: string[]) => codexStartupQuestion(args, join(top, dir), home);
    const table = (dir: string, level = "trusted") => `projects={"${top}/${dir}"={trust_level="${level}"}}`;
    const asks = "Codex asks whether to trust this folder";
    // The inline table, in every spelling of the option (each observed with Codex 0.155 in a pty).
    expect(ask("app", ["-c", table("app")])).toBeUndefined();
    expect(ask("app", ["--config", table("app")])).toBeUndefined();
    expect(ask("app", [`-c${table("app")}`])).toBeUndefined();
    expect(ask("app", [`--config=${table("app")}`])).toBeUndefined();
    expect(ask("app", [`-c=${table("app")}`])).toBeUndefined();
    expect(ask("app", ["-c=model=o3"])).toBe(asks); // the `=` is clap's separator, not an empty key
    expect(ask("app", ["-m", "o3", "-c", table("app"), "fix the build"])).toBeUndefined();
    // A resumed tile passes its own -c after `resume` (AgentResume), where Codex keeps them.
    expect(ask("app", ["resume", "-c", table("app"), "-m", "gpt-6", "019a"])).toBeUndefined();
    expect(ask("app", ["fork", "019a", "-c", table("app")])).toBeUndefined();
    expect(ask("app", ["-c", table("app"), "resume", "--last"])).toBeUndefined(); // no -c after resume: the top level's stay
    expect(ask("app", ["-c", table("app"), "resume", "--last", "-c", "model=o3"])).toBe(asks); // dropped for resume's own
    // A dotted key is split at every dot, as Codex splits it: unquoted it names the folder (one
    // without a dot in its path); quoted, the quotes are part of the key, and Codex still asks.
    expect(ask("app", ["-c", `projects.${top}/app.trust_level="trusted"`])).toBeUndefined();
    expect(ask("app", ["-c", `projects."${top}/app".trust_level="trusted"`])).toBe(asks);
    expect(ask("dot.d", ["-c", `projects.${top}/dot.d.trust_level="trusted"`])).toBe(asks);
    expect(ask("dot.d", ["-c", table("dot.d")])).toBeUndefined();
    // The override layer merges over config.toml: other folders keep theirs, the same folder's is replaced.
    expect(ask("listed", ["-c", table("app")])).toBeUndefined();
    expect(ask("other", ["-c", table("other")])).toBeUndefined();
    expect(ask("app", ["-c", table("app", "untrusted")])).toBe("Codex asks how to open this untrusted folder");
    // A key is literal text to Codex, `__proto__` too: it names no folder, and Codex asks.
    expect(ask("app", ["-c", `projects.__proto__.trust_level="trusted"`])).toBe(asks);
    expect(ask("app", ["-c", `__proto__.projects={"${top}/app"={trust_level="trusted"}}`])).toBe(asks);
    expect(Object.hasOwn(Object.prototype, "trust_level") || Object.hasOwn(Object.prototype, "projects")).toBe(false);
    // A later -c of the same key replaces the earlier one; another folder's trust is not this one's.
    expect(ask("app", ["-c", table("app"), "-c", table("other")])).toBe(asks);
    expect(ask("app", ["-c", table("other")])).toBe(asks);
    // After `--` it's the prompt's text.
    expect(ask("app", ["--", "-c", table("app")])).toBe(asks);
    // An override Codex can't read stops it before it asks anything.
    expect(ask("app", ["-c", "projects"])).toBeUndefined();
  } finally {
    rmSync(top, { recursive: true, force: true });
  }
});

test("Trusting the folder ends the wait; quitting Codex or trusting another folder doesn't", async () => {
  const top = realpathSync(mkdtempSync(join(tmpdir(), "canvas-codex-trust-")));
  try {
    const home = join(top, "home");
    mkdirSync(home);
    mkdirSync(join(top, "app"));
    mkdirSync(join(top, "other"));
    // Codex rewrites its config when the user answers "Trust and continue".
    const trust = (dir: string) => writeFileSync(join(home, "config.toml"), `[projects."${top}/${dir}"]\ntrust_level = "trusted"\n`);
    let polls = 0;
    const answered = watchTrust([], join(top, "app"), { alive: () => true, codexHome: home, wait: async () => { if (++polls === 3) trust("app"); } });
    expect(await answered).toBe(true);
    expect(polls).toBe(3);

    trust("other");
    polls = 0;
    const quit = await watchTrust([], join(top, "app"), { alive: () => polls < 4, codexHome: home, wait: async () => void polls++ });
    expect(quit).toBe(false);
  } finally {
    rmSync(top, { recursive: true, force: true });
  }
});
