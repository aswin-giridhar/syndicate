import { runScenario, LLM_AVAILABLE } from "../app/scenario.mjs";

const COLOR = {
  phase: "\x1b[1;36m", deployed: "\x1b[36m", registered: "\x1b[90m",
  underwritten: "\x1b[34m", quote: "\x1b[1;33m", bound: "\x1b[35m",
  "agent-run": "\x1b[90m", "agent-decision": "\x1b[1;37m",
  breach: "\x1b[1;31m", clean: "\x1b[1;32m", stats: "\x1b[90m",
  underwriter: "\x1b[36m", done: "\x1b[1;32m",
};

console.log(`\n\x1b[1mSyndicate\x1b[0m — counterparty insurance for autonomous agents`);
console.log(`agents: ${LLM_AVAILABLE ? "live Claude" : "scripted stand-in (no ANTHROPIC_API_KEY found)"}\n`);

await runScenario((e) => {
  const c = COLOR[e.type] ?? "";
  console.log(`${c}${e.type.padEnd(15)}\x1b[0m ${e.message}`);
});
