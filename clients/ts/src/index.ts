import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { type Compositions, createCompositions } from "./compositions";
import { bindMethods, type CanvasApi } from "./generated";

export * from "./compositions";
export * from "./generated";

export const DEFAULT_SOCKET = join(homedir(), "Library/Application Support/Canvas/canvas.sock");

export class CanvasError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "CanvasError";
  }
}

type Pending = { resolve: (value: unknown) => void; reject: (error: unknown) => void; timer?: ReturnType<typeof setTimeout> };

type WireMessage = {
  id?: string;
  ok?: boolean;
  result?: unknown;
  error?: { code: string; message: string; data?: unknown };
  event?: string;
  data?: unknown;
};

export type CanvasClientOptions = {
  socketPath?: string;
  /** Per-call timeout. Omit for none (agent.wait can legitimately block for minutes). */
  timeoutMs?: number;
  /** Where `compositions` looks; default `~/.canvas/compositions`, then the shipped `builtin_compositions/`. */
  compositionsDirs?: string[];
};

/** Split a newline-delimited JSON stream into messages, keeping any partial trailing line. */
function drainLines(buffer: string, onMessage: (message: WireMessage) => void): string {
  let rest = buffer;
  let newline = rest.indexOf("\n");
  while (newline >= 0) {
    const line = rest.slice(0, newline);
    rest = rest.slice(newline + 1);
    newline = rest.indexOf("\n");
    if (line) onMessage(JSON.parse(line) as WireMessage);
  }
  return rest;
}

/** One persistent connection to the Canvas API socket. */
export class CanvasClient {
  readonly socketPath: string;
  readonly api: CanvasApi;
  readonly #timeoutMs: number | undefined;
  readonly #compositionsDirs: string[] | undefined;
  #compositions: Compositions | undefined;
  #socket: Promise<Socket> | undefined;
  #buffer = "";
  #nextId = 0;
  readonly #pending = new Map<string, Pending>();

  constructor(options: CanvasClientOptions = {}) {
    this.socketPath = options.socketPath ?? process.env.CANVAS_SOCKET ?? DEFAULT_SOCKET;
    this.#timeoutMs = options.timeoutMs;
    this.#compositionsDirs = options.compositionsDirs;
    this.api = bindMethods((method, params) => this.call(method, params));
  }

  /** Reusable helpers, loaded on first access: `client.compositions.grid.arrange(ids)`. */
  get compositions(): Compositions {
    this.#compositions ??= createCompositions(this.api, this.#compositionsDirs);
    return this.#compositions;
  }

  async call(method: string, params: object): Promise<unknown> {
    const socket = await this.#connect();
    const id = String(++this.#nextId);
    const { promise, resolve, reject } = Promise.withResolvers<unknown>();
    const pending: Pending = { resolve, reject };
    if (this.#timeoutMs !== undefined) {
      pending.timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new CanvasError("timeout", `${method} timed out after ${this.#timeoutMs}ms`));
      }, this.#timeoutMs);
    }
    this.#pending.set(id, pending);
    socket.write(`${JSON.stringify({ id, method, params })}\n`);
    return promise;
  }

  close(): void {
    void this.#socket?.then((s) => s.end());
    this.#socket = undefined;
  }

  #connect(): Promise<Socket> {
    if (this.#socket) return this.#socket;
    const { promise, resolve, reject } = Promise.withResolvers<Socket>();
    const socket = connect(this.socketPath);
    socket.setEncoding("utf8");
    socket.once("connect", () => resolve(socket));
    socket.once("error", (error) => {
      this.#socket = undefined;
      const failure = new CanvasError("unavailable", `Canvas socket ${this.socketPath}: ${error.message}`);
      reject(failure);
      this.#failAll(failure);
    });
    socket.on("close", () => {
      this.#socket = undefined;
      this.#failAll(new CanvasError("closed", "Canvas socket closed"));
    });
    socket.on("data", (chunk: string) => {
      this.#buffer = drainLines(this.#buffer + chunk, (message) => this.#settle(message));
    });
    this.#socket = promise;
    return promise;
  }

  #settle(message: WireMessage): void {
    const pending = message.id === undefined ? undefined : this.#pending.get(message.id);
    if (!pending) return;
    this.#pending.delete(message.id!);
    clearTimeout(pending.timer);
    if (message.ok) pending.resolve(message.result);
    else pending.reject(new CanvasError(message.error?.code ?? "internal", message.error?.message ?? "unknown error", message.error?.data));
  }

  #failAll(error: unknown): void {
    for (const [id, pending] of this.#pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      this.#pending.delete(id);
    }
  }
}

/** Open a dedicated connection that streams `{ event, data }` messages to `onEvent`. Returns a closer. */
export async function subscribe(
  onEvent: (event: string, data: unknown) => void,
  params: { board?: string; events?: string[] } = {},
  socketPath = process.env.CANVAS_SOCKET ?? DEFAULT_SOCKET,
): Promise<() => void> {
  const socket = connect(socketPath);
  socket.setEncoding("utf8");
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  socket.once("connect", () => resolve());
  socket.once("error", reject);
  await promise;
  let buffer = "";
  socket.on("data", (chunk: string) => {
    buffer = drainLines(buffer + chunk, (message) => {
      if (message.event) onEvent(message.event, message.data);
    });
  });
  socket.write(`${JSON.stringify({ id: "subscribe", method: "events.subscribe", params })}\n`);
  return () => socket.end();
}
