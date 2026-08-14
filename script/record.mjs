// Record a real scenario run to JSON for the hosted demo.
//
// The hosted page has no EVM behind it, so it replays this recording rather than
// executing. That is a weaker artefact than a live run and the page says so
// plainly — but the events are genuine output from `runScenario` against a real
// chain, not hand-written fixtures.

import { writeFileSync, mkdirSync } from "node:fs";
import { runScenario, LLM_AVAILABLE } from "../src/scenario.mjs";

const events = [];
await runScenario((e) => {
  events.push(e);
  process.stdout.write(`\r  ${events.length} events recorded`);
});

const out = {
  recordedAt: new Date().toISOString(),
  mode: LLM_AVAILABLE ? "live-claude" : "stand-in",
  chain: "anvil (local EVM)",
  events,
};

mkdirSync(new URL("../web/", import.meta.url), { recursive: true });
writeFileSync(
  new URL("../web/run.json", import.meta.url),
  JSON.stringify(out, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n",
);

console.log(`\n\nrecorded ${events.length} events in ${out.mode} mode → web/run.json`);
