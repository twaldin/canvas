// How the hooks name a tool call and read the question an agent puts to the user.
//
// An agent in auto mode (Claude Code's bypass/auto, Codex's --yolo/--full-auto) asks for no
// approvals: the only time it waits for the user is a question from its ask tool. hook.ts
// reports those from PreToolUse, blocked with the question:
//  - Claude Code's `AskUserQuestion` (it also asks permission for it, in every mode);
//  - Codex's `request_user_input` (Plan mode): the turn waits for the answer;
//  - Codex's `request_user_input_async` (Default mode, Codex 0.155): the question is queued
//    ("? 1 question, ⌥ + ↑ to answer") and the turn goes on, so its finished call is no answer.
//    The answer arrives as a prompt, `> <question>\n\n<answer>`, mid-turn or after it.
import { createHash } from "node:crypto";

type Json = Record<string, unknown>;

/** Tools that ask the user something, not to be approved. */
const ASK_TOOLS: Record<string, true> = { AskUserQuestion: true, request_user_input: true, request_user_input_async: true };

/** Codex's queued question: its call finishes at once, unanswered. */
export const QUEUED_ASK_TOOL = "request_user_input_async";

/**
 * The question an ask tool call puts to the user, for the tile's message ("Which name? (+1 more)"),
 * or undefined for any other tool.
 */
export function askedQuestion(input: Json): string | undefined {
  const tool = typeof input.tool_name === "string" ? input.tool_name : "";
  if (ASK_TOOLS[tool] !== true) return undefined;
  const questions = questionTexts(input);
  if (questions.length === 0) return "waiting for your answer";
  return questions.length > 1 ? `${questions[0]} (+${questions.length - 1} more)` : questions[0];
}

/**
 * Names a tool call the same in its PreToolUse or PermissionRequest (which carry no call id in
 * every agent) and its PostToolUse: the tool and its input. Codex adds the approval's
 * `description` only to the request, so that is left out; an ask tool is named by its questions
 * alone, since Claude Code hands the answers back in the finished call's input.
 */
export function toolCall(input: Json): string {
  const tool = typeof input.tool_name === "string" ? input.tool_name : "";
  const { description: _, ...args } = record(input.tool_input) ?? {};
  const identity = JSON.stringify([tool, ASK_TOOLS[tool] === true ? questionTexts(input) : canonical(args)]);
  return createHash("sha256").update(identity).digest("hex").slice(0, 16);
}

/** The questions' text: `question` (AskUserQuestion, request_user_input) or `title` (request_user_input_async). */
function questionTexts(input: Json): string[] {
  const questions = record(input.tool_input)?.questions;
  if (!Array.isArray(questions)) return [];
  return questions.flatMap((question) => {
    const text = record(question)?.question ?? record(question)?.title;
    return typeof text === "string" && text.trim() ? [text.trim()] : [];
  });
}

/**
 * The queued question (`request_user_input_async`) Codex asked in turn `turnId` that no prompt of
 * that turn answered, as its PreToolUse input; read from the session's rollout (JSON lines) at the
 * turn's end. Undefined when there is none.
 */
export function unansweredQuestion(rollout: string, turnId: string): Json | undefined {
  let inTurn = false;
  const asked: Json[] = [];
  const answers: string[] = [];
  for (const line of rollout.split("\n")) {
    if (!line.includes(turnId) && !inTurn) continue;
    let entry: Json;
    try {
      entry = JSON.parse(line) as Json;
    } catch {
      continue;
    }
    const payload = record(entry.payload) ?? {};
    if (payload.type === "task_started") inTurn = payload.turn_id === turnId;
    if (!inTurn || entry.type !== "response_item") continue;
    if (payload.type === "function_call" && payload.name === QUEUED_ASK_TOOL && typeof payload.arguments === "string") {
      try {
        asked.push({ tool_name: QUEUED_ASK_TOOL, tool_input: JSON.parse(payload.arguments) });
      } catch {}
    } else if (payload.type === "message" && payload.role === "user" && Array.isArray(payload.content)) {
      for (const part of payload.content) {
        const text = record(part)?.text;
        if (typeof text === "string" && text.startsWith("> ")) answers.push(text);
      }
    }
  }
  return asked.findLast((call) => !questionTexts(call).every((question) => answers.some((answer) => answer.startsWith(`> ${question}`))));
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  const object = record(value);
  return object ? Object.fromEntries(Object.keys(object).sort().map((key) => [key, canonical(object[key])])) : value;
}

function record(value: unknown): Json | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
}
