// Open a set of file:line locations (e.g. search hits, a stack trace) as code tiles in a grid.
import { isAbsolute, normalize, relative as relativeTo, sep } from "node:path";
import type { Composer, LineRange } from "../clients/ts/src/index";

// path, path:12, path:12-40, path:12:5 (column dropped), path#L12, path#L12-L40
const LOCATION = /^(?<path>.+?)(?:#L(?<a>\d+)(?:-L?(?<b>\d+))?|:(?<c>\d+)(?:-(?<d>\d+)|:\d+)?)?$/;

/** Create one code tile per location and arrange them in a grid beside `beside` (default: your
 * terminal). `mode` is "source" or "diff" (merge-base diff). Returns the new tile ids in order. */
export async function open(
  canvas: Composer,
  locations: string[],
  options: { beside?: string; mode?: "source" | "diff"; columns?: number } = {},
): Promise<string[]> {
  const { root } = await canvas.board.get();
  const ids: string[] = [];
  for (const location of locations) {
    const [path, range] = parse(location);
    const props: Record<string, unknown> = { path: relative(path, root), mode: options.mode ?? "source" };
    if (range) props.range = range;
    ids.push((await canvas.object.create({ type: "code", props })).object.id);
  }
  await canvas.compositions.grid.arrange(ids, { beside: options.beside, columns: options.columns });
  return ids;
}

/** `src/a.ts:12-40` -> ["src/a.ts", { start: 12, end: 40 }]; a bare path has no range. */
export function parse(location: string): [string, LineRange | undefined] {
  const match = LOCATION.exec(location.trim());
  if (!match?.groups?.path) throw new Error(`not a location: ${location}`);
  const { path, a, b, c, d } = match.groups;
  const start = a ?? c;
  if (start === undefined) return [path, undefined];
  return [path, { start: Number(start), end: Math.max(Number(start), Number(b ?? d ?? start)) }];
}

/** Code tiles store paths relative to the board root when the file lives under it. */
export function relative(path: string, root: string): string {
  if (!isAbsolute(path)) return path;
  const absolute = normalize(path);
  const base = normalize(root);
  return absolute.startsWith(base + sep) ? relativeTo(base, absolute) : absolute;
}
