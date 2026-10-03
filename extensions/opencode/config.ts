// Prints the OPENCODE_CONFIG_CONTENT the opencode wrapper (bin/opencode) runs opencode with, so an
// opencode session in an Easl tile loads the Easl plugin (extensions/opencode/easl.ts)
// without touching ~/.config/opencode. opencode merges this inline config over the user's global
// and project configs and concatenates plugin lists, so their own config keeps working; an inline
// config the user already set (bin/opencode passes it) is kept, with the plugin added to it.
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const plugin = pathToFileURL(resolve(import.meta.dir, "easl.ts")).href;
const own = process.argv[2] ? JSON.parse(process.argv[2]) : {};
const plugins = Array.isArray(own.plugin) ? own.plugin : [];
process.stdout.write(JSON.stringify({ ...own, plugin: [...plugins, plugin] }));
