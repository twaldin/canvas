// Compositions: reusable board helpers that agents write and improve (TypeScript side).
//
// A composition is a module (`<name>.ts` / `.js` / `.mjs`) in a compositions directory. Exported
// functions whose first parameter is named `canvas` receive the client (every API namespace plus
// `compositions`); `client.compositions.<name>.<fn>(...)` passes it for you. Other exports (pure
// helpers, constants) come through unchanged. Search order, first match wins, so a helper you
// improve shadows the shipped one: `~/.easl/compositions`, then `builtin_compositions/` next to
// this file (shipped with the client).
// Modules load lazily on first access (Bun's synchronous `require`), like the Python SDK.
// `reload()` picks up edited files. Bun caches directory listings in its resolver, so a file
// added to an already-loaded directory needs a new process (the Python SDK has no such limit).
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";
import type { CanvasApi } from "./generated";

const EXTENSIONS = [".ts", ".mjs", ".js"];
const require = createRequire(import.meta.url);

/** What a `canvas`-first composition function receives. */
export type Composer = CanvasApi & { compositions: Compositions };

export type Compositions = {
  /** Composition name -> first line of its leading comment, across all directories. */
  available(): Record<string, string>;
  /** Forget loaded modules so edited files are picked up on next access. */
  reload(): void;
} & Record<string, Record<string, any>>;

export function defaultCompositionDirs(): string[] {
  return [join(homedir(), ".easl/compositions"), join(import.meta.dir, "builtin_compositions")];
}

function files(dirs: string[]): Map<string, string> {
  const found = new Map<string, string>();
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    for (const entry of readdirSync(dir).sort()) {
      const ext = extname(entry);
      const name = basename(entry, ext);
      if (!EXTENSIONS.includes(ext) || entry.endsWith(".d.ts") || name.startsWith("_") || found.has(name)) continue;
      found.set(name, join(dir, entry));
    }
  }
  return found;
}

function summary(path: string): string {
  const text = readFileSync(path, "utf8");
  const comment = /^\s*(?:\/\/\s?(.*)|\/\*+\s*([^\n]*))/.exec(text);
  return (comment?.[1] ?? comment?.[2] ?? "").replace(/\*\/\s*$/, "").trim();
}

function takesCanvas(fn: Function): boolean {
  return /^(?:async\s+)?(?:function\b[^(]*)?\(?\s*canvas\s*[,):=]/.test(fn.toString());
}

/** `compositions.<name>` for `api`, loaded from `dirs` (default: user dir, then shipped dir). */
export function createCompositions(api: CanvasApi, dirs: string[] = defaultCompositionDirs()): Compositions {
  const loaded = new Map<string, Record<string, unknown>>();
  let composer: Composer;
  const methods = {
    available: () => Object.fromEntries([...files(dirs)].map(([name, path]) => [name, summary(path)])),
    reload: () => {
      // require.cache is keyed by real path (/tmp resolves to /private/tmp).
      for (const path of files(dirs).values()) delete require.cache[realpathSync(path)];
      loaded.clear();
    },
  };
  const compositions = new Proxy(methods, {
    get(target, name) {
      if (typeof name !== "string") return undefined;
      if (name in target) return target[name as keyof typeof target];
      const cached = loaded.get(name);
      if (cached) return cached;
      const available = files(dirs);
      const path = available.get(name);
      if (!path) {
        throw new Error(`no composition "${name}" in ${dirs.join(", ")} (available: ${[...available.keys()].join(", ") || "none"})`);
      }
      const module = require(path) as Record<string, unknown>;
      const bound = Object.fromEntries(
        Object.entries(module).map(([key, value]) => [
          key,
          typeof value === "function" && takesCanvas(value) ? (...args: unknown[]) => value(composer, ...args) : value,
        ]),
      );
      loaded.set(name, bound);
      return bound;
    },
  }) as Compositions;
  composer = { ...api, compositions };
  return compositions;
}
