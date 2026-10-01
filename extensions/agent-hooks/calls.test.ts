// bun test extensions/agent-hooks — a question from an agent's ask tool: what the tile says, and
// that its answer (PostToolUse) ends the same wait its PreToolUse started.
import { expect, test } from "bun:test";
import { askedQuestion, toolCall, unansweredQuestion } from "./calls";

// Codex 0.155 `request_user_input` (Plan mode), as its PreToolUse hook receives it.
const codexAsk = {
  tool_name: "request_user_input",
  tool_input: {
    questions: [{ header: "New name", id: "new_name", question: "Should add be renamed to sum or plus?", options: [{ label: "sum", description: "" }, { label: "plus", description: "" }] }],
  },
};

test("an ask tool's call shows its question; other tools show none", () => {
  expect(askedQuestion(codexAsk)).toBe("Should add be renamed to sum or plus?");
  const two = { tool_name: "AskUserQuestion", tool_input: { questions: [{ question: "Which name?" }, { question: "Keep the alias?" }] } };
  expect(askedQuestion(two)).toBe("Which name? (+1 more)");
  expect(askedQuestion({ tool_name: "AskUserQuestion", tool_input: {} })).toBe("waiting for your answer");
  expect(askedQuestion({ tool_name: "Bash", tool_input: { questions: [{ question: "not one" }] } })).toBeUndefined();
});

test("the answered question is the same call as the one asked, even with its answers in the input", () => {
  const asked = { tool_name: "AskUserQuestion", tool_input: { questions: [{ question: "Which name?", options: [{ label: "sum" }] }] } };
  const answered = { ...asked, tool_input: { ...asked.tool_input, answers: { "Which name?": "sum" } } };
  expect(toolCall(answered)).toBe(toolCall(asked));
  const other = { tool_name: "AskUserQuestion", tool_input: { questions: [{ question: "Keep the alias?" }] } };
  expect(toolCall(other)).not.toBe(toolCall(asked));
  // Other tools are still named by their whole input, the approval's description left out.
  expect(toolCall({ tool_name: "Bash", tool_input: { command: "ls", description: "List" } })).toBe(toolCall({ tool_name: "Bash", tool_input: { command: "ls" } }));
  expect(toolCall({ tool_name: "Bash", tool_input: { command: "ls" } })).not.toBe(toolCall({ tool_name: "Bash", tool_input: { command: "pwd" } }));
});

// Rollout lines as Codex 0.155 writes them (cut to the fields read).
const line = (value: unknown) => JSON.stringify(value);
const turn = (id: string) => line({ type: "event_msg", payload: { type: "task_started", turn_id: id } });
const queued = (title: string) =>
  line({ type: "response_item", payload: { type: "function_call", name: "request_user_input_async", arguments: JSON.stringify({ questions: [{ title, options: ["yes", "no"] }] }) } });
const prompt = (text: string) => line({ type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text }] } });

test("a question Codex queued in the turn is still waiting at its end unless a prompt of that turn answered it", () => {
  const rollout = (...lines: string[]) => lines.join("\n");
  const asked = unansweredQuestion(rollout(turn("t1"), prompt("plan it"), queued("Keep an alias?")), "t1");
  expect(asked && askedQuestion(asked)).toBe("Keep an alias?");
  // The same question's call as its PreToolUse named it, so the answer ends that wait.
  expect(asked && toolCall(asked)).toBe(toolCall({ tool_name: "request_user_input_async", tool_input: { questions: [{ title: "Keep an alias?", options: ["yes", "no"] }] } }));
  expect(unansweredQuestion(rollout(turn("t1"), queued("Keep an alias?"), prompt("> Keep an alias?\n\nyes")), "t1")).toBeUndefined();
  // Only this turn's questions: an earlier turn's, or the next turn's, don't keep it waiting.
  expect(unansweredQuestion(rollout(turn("t0"), queued("Old?"), turn("t1"), prompt("go on")), "t1")).toBeUndefined();
  expect(unansweredQuestion(rollout(turn("t1"), prompt("go"), turn("t2"), queued("Later?")), "t1")).toBeUndefined();
  // Of two, the one left unanswered.
  const second = unansweredQuestion(rollout(turn("t1"), queued("First?"), queued("Second?"), prompt("> First?\n\nyes")), "t1");
  expect(second && askedQuestion(second)).toBe("Second?");
});
