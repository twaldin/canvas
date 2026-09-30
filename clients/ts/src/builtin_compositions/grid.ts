// Arrange objects in a tidy grid beside a terminal (yours by default), clear of other tiles.
import type { Composer, Frame } from "../index";

export const GAP = 24;
// Drawings never block placement (same rule as the canvas's own placement).
const NON_BLOCKING: Record<string, true> = { arrow: true, shape: true, group: true };

/** Move `ids` into a grid to the right of `beside` (default: the calling terminal, then the
 * objects' current top-left), sliding down past anything in the way. Returns id -> new frame.
 * Only arrange the user's own objects when they asked you to. */
export async function arrange(
  canvas: Composer,
  ids: string[],
  options: { beside?: string; columns?: number; gap?: number } = {},
): Promise<Record<string, Frame>> {
  if (ids.length === 0) return {};
  const objects = new Map((await canvas.board.get()).objects.map((o) => [o.id, o]));
  const missing = ids.filter((id) => !objects.has(id));
  if (missing.length > 0) throw new Error(`not on this board: ${missing.join(", ")}`);
  const anchorId = options.beside ?? process.env.CHALKWORK_TILE_ID;
  const anchor = anchorId && !ids.includes(anchorId) ? objects.get(anchorId)?.frame : undefined;
  const obstacles = [...objects.values()].filter((o) => !ids.includes(o.id) && !NON_BLOCKING[o.type]).map((o) => o.frame);
  const frames = plan(ids.map((id) => objects.get(id)!.frame), anchor, obstacles, options);
  const result: Record<string, Frame> = {};
  for (const [index, id] of ids.entries()) {
    await canvas.object.update({ id, frame: frames[index] });
    result[id] = frames[index];
  }
  return result;
}

/** Grid positions for objects of the given sizes, row-major, keeping each object's size. Starts
 * right of `anchor` (top-aligned) or at the objects' current top-left, then moves down until the
 * whole grid overlaps no obstacle. */
export function plan(frames: Frame[], anchor: Frame | undefined, obstacles: Frame[], options: { columns?: number; gap?: number } = {}): Frame[] {
  if (frames.length === 0) return [];
  const gap = options.gap ?? GAP;
  const columns = Math.max(1, Math.min(options.columns ?? Math.ceil(Math.sqrt(frames.length)), frames.length));
  const rows = Math.ceil(frames.length / columns);
  const widths = Array.from({ length: columns }, (_, c) => Math.max(...frames.filter((_, i) => i % columns === c).map((f) => f.w)));
  const heights = Array.from({ length: rows }, (_, r) => Math.max(...frames.slice(r * columns, (r + 1) * columns).map((f) => f.h)));
  const xs = widths.map((_, c) => widths.slice(0, c).reduce((a, b) => a + b, 0) + gap * c);
  const ys = heights.map((_, r) => heights.slice(0, r).reduce((a, b) => a + b, 0) + gap * r);
  const box: Frame = {
    x: anchor ? anchor.x + anchor.w + gap : Math.min(...frames.map((f) => f.x)),
    y: anchor ? anchor.y : Math.min(...frames.map((f) => f.y)),
    w: xs.at(-1)! + widths.at(-1)!,
    h: ys.at(-1)! + heights.at(-1)!,
  };
  for (;;) {
    const blocking = obstacles.filter((o) => o.x < box.x + box.w && box.x < o.x + o.w && o.y < box.y + box.h && box.y < o.y + o.h);
    if (blocking.length === 0) break;
    box.y = Math.max(...blocking.map((o) => o.y + o.h)) + gap;
  }
  return frames.map((f, i) => ({ x: box.x + xs[i % columns], y: box.y + ys[Math.floor(i / columns)], w: f.w, h: f.h }));
}
