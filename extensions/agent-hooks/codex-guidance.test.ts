// bun test extensions/agent-hooks — the easl commands the Codex awareness block (SessionStart
// context) shows are ones an `easl` prefix rule covers. Codex 0.155 matches rules only against
// commands made of literal words (codex-rs/shell-command/src/bash.rs,
// `try_parse_word_only_commands_sequence`, `is_literal_word_or_number`); one `$TMPDIR` in the
// command made it ask again on every call.
import { afterEach, expect, test } from "bun:test";
import { canvasGuidance } from "../guidance";

const saved = process.env.TMPDIR;
afterEach(() => {
  if (saved === undefined) delete process.env.TMPDIR;
  else process.env.TMPDIR = saved;
});

/** A word Codex takes as literal: no expansion, quoting, glob, escape or shell operator. */
const literalWord = (word: string) => !word.startsWith("=") && !/[{}*?[\]\\~^#$`'"<>|&;()]/.test(word);

test("Codex's example easl commands are plain words, with the payload at this session's temp dir", () => {
  process.env.TMPDIR = "/var/folders/zz/abc123_def/T/";
  const commands = [...canvasGuidance("codex", "obj_tile").matchAll(/`(easl [^`]*)`/g)].map((match) => match[1]!);
  const payloads = commands.flatMap((command) => /--json @(\S+)/.exec(command)?.[1] ?? []);
  expect(payloads.length).toBeGreaterThan(0);
  for (const command of commands) expect(command.split(/\s+/).filter((word) => !literalWord(word))).toEqual([]);
  for (const payload of payloads) expect(payload.startsWith("/var/folders/zz/abc123_def/T/")).toBe(true);
});
