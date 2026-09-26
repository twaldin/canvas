#!/usr/bin/env bun
// canvas CLI: a thin, schema-driven client for agents without a persistent REPL.
//   canvas methods
//   canvas <namespace>.<method> [--json '{...}'] [--key value] [--nested.key value]
//   canvas <namespace> <method> ...
//   canvas get <id> [--as raw|graph|image]
//   --out <file.png>   write a `pngBase64` result (view.snapshot, get --as image) to a file
import catalog from "../schema/canvas-api.json";
import { CanvasClient, CanvasError, withEnv, ENV_DEFAULTS } from "../clients/ts/src/index";

type MethodSpec = { description: string; params: { properties?: Record<string, unknown>; required?: string[] } };
const methods = catalog.methods as Record<string, MethodSpec>;

function usage(): never {
  console.error("usage: canvas methods | canvas <namespace>.<method> [--json '{...}'] [--key value] [--out file.png] | canvas get <id> [--as graph]");
  process.exit(2);
}

function setPath(target: Record<string, unknown>, path: string, value: unknown): void {
  const keys = path.split(".");
  let node = target;
  for (const key of keys.slice(0, -1)) {
    node[key] ??= {};
    node = node[key] as Record<string, unknown>;
  }
  node[keys.at(-1)!] = value;
}

function parseArgs(args: string[]): { positional: string[]; params: Record<string, unknown> } {
  const positional: string[] = [];
  let params: Record<string, unknown> = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith("--")) {
      positional.push(arg);
      continue;
    }
    const value = args[++i];
    if (value === undefined) usage();
    if (arg === "--json") {
      params = { ...params, ...(JSON.parse(value) as Record<string, unknown>) };
      continue;
    }
    let parsed: unknown = value;
    try {
      parsed = JSON.parse(value);
    } catch {
      // plain string
    }
    setPath(params, arg.slice(2), parsed);
  }
  return { positional, params };
}

const argv = process.argv.slice(2);
if (argv.length === 0) usage();

if (argv[0] === "methods") {
  for (const [name, spec] of Object.entries(methods)) console.log(`${name.padEnd(22)} ${spec.description}`);
  process.exit(0);
}

let method: string;
let rest: string[];
if (argv[0] === "get") {
  method = "object.get";
  rest = ["--id", argv[1] ?? usage(), ...argv.slice(2)];
} else if (argv[0].includes(".")) {
  method = argv[0];
  rest = argv.slice(1);
} else {
  method = `${argv[0]}.${argv[1] ?? usage()}`;
  rest = argv.slice(2);
}

const spec = methods[method];
if (!spec) {
  console.error(`unknown method: ${method} (run \`canvas methods\`)`);
  process.exit(2);
}

const { params } = parseArgs(rest);
const out = typeof params.out === "string" ? params.out : undefined;
delete params.out;
const envKeys = Object.keys(spec.params.properties ?? {}).filter((k) => k in ENV_DEFAULTS);
const client = new CanvasClient();
try {
  const result = (await client.call(method, withEnv(params, envKeys))) as Record<string, unknown>;
  if (out && typeof result.pngBase64 === "string") {
    await Bun.write(out, Buffer.from(result.pngBase64, "base64"));
    result.pngBase64 = `(written to ${out})`;
  }
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
  else console.error(error);
  process.exitCode = 1;
} finally {
  client.close();
}
