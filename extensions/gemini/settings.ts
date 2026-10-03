// Prints the path of the Gemini CLI system settings file the gemini wrapper (bin/gemini) points
// GEMINI_CLI_SYSTEM_SETTINGS_PATH at, so a Gemini session in an Easl tile runs
// extensions/agent-hooks/hook.ts without touching ~/.gemini.
//
// Gemini reads settings from system defaults, ~/.gemini/settings.json, the project's
// .gemini/settings.json, then the system settings file, which overrides the rest; hook lists
// are concatenated across all of them, and hooks from the system layer are not listed as the
// user's own. The file written here is the user's own system settings (the file the variable
// named before, else Gemini's default path) with Easl's hooks appended and self-update turned
// off (a tile is no place for an `npm install -g` or its prompt). Everything else the user set
// in any layer keeps working. Gemini lists running hooks in its status line (from every layer):
// Easl's are hidden unless the user has hooks of their own or chose to see hooks run.
// Content-addressed, so concurrent sessions never race on it.
//
// Gemini 0.60 and later skip a system settings file whose directory isn't owned by root (with a
// warning on screen), so for those this exits non-zero and the wrapper runs Gemini plain.
//
//   bun settings.ts <the user's GEMINI_CLI_SYSTEM_SETTINGS_PATH or ""> <the real gemini>
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

type Json = Record<string, unknown>;

const RUN = resolve(import.meta.dir, "../agent-hooks/run");
/** The user's own system settings file (bin/gemini passes the variable's value from before). */
const userPath = process.argv[2] || "/Library/Application Support/GeminiCli/settings.json";
/** The first Gemini CLI version that refuses a system settings file the user owns. */
const REFUSING = [0, 60];

/** Event → timeout (ms). SessionEnd isn't waited for; the rest bound how long a hook may stall Gemini. */
const EVENTS: Array<[event: string, timeout: number]> = [
  ["SessionStart", 5000],
  ["BeforeAgent", 5000],
  ["Notification", 5000],
  ["AfterTool", 5000],
  ["AfterAgent", 5000],
  ["SessionEnd", 3000],
];

const record = (value: unknown): Json => (value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : {});

/**
 * A settings file (Gemini allows comments); empty when there is none. One that doesn't parse is
 * left to Gemini to report: throwing makes the wrapper run Gemini without Easl's layer.
 */
function load(path: string): Json {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return {};
  }
  return record(typeof Bun.JSONC?.parse === "function" ? Bun.JSONC.parse(text) : JSON.parse(text));
}

// The real gemini is its package's bin script (bundle/gemini.js), usually through a symlink.
let version: number[] | undefined;
let bundle = dirname(realpathSync(process.argv[3] ?? ""));
for (let depth = 0; depth < 3 && !version; depth++, bundle = dirname(bundle)) {
  const manifest = load(join(bundle, "package.json"));
  if (manifest.name === "@google/gemini-cli" && typeof manifest.version === "string") version = manifest.version.split(".").map(Number);
}
if (!version || version[0] > REFUSING[0] || (version[0] === REFUSING[0] && version[1] >= REFUSING[1])) process.exit(2);

const user = load(userPath);
const layers = [user, load(join(homedir(), ".gemini/settings.json")), load(join(process.cwd(), ".gemini/settings.json"))];
const ownHooks = layers.some((layer) => Object.values(record(layer.hooks)).some((list) => Array.isArray(list) && list.length > 0));
const shown = layers.map((layer) => record(layer.hooksConfig).notifications).find((value) => typeof value === "boolean");

const hooks = { ...record(user.hooks) };
for (const [event, timeout] of EVENTS) {
  const own = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
  hooks[event] = [...own, { hooks: [{ type: "command", name: `canvas-${event}`, command: `'${RUN.replaceAll("'", `'"'"'`)}' gemini ${event}`, timeout }] }];
}
const general = { ...record(user.general), enableAutoUpdate: false, enableAutoUpdateNotification: false };
const hooksConfig = { ...record(user.hooksConfig), notifications: shown ?? ownHooks };
const settings = JSON.stringify({ ...user, general, hooksConfig, hooks }, null, 2);

const dir = join(process.env.TMPDIR || tmpdir(), "canvas-gemini");
const path = join(dir, `settings-${createHash("sha256").update(settings).digest("hex").slice(0, 16)}.json`);
mkdirSync(dir, { recursive: true });
const partial = `${path}.${process.pid}`;
writeFileSync(partial, settings);
renameSync(partial, path);
process.stdout.write(path);
