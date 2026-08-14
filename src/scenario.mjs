// The end-to-end scenario, emitting structured events as it goes.
//
// Shared by the CLI (`npm run demo`) and the dashboard's live feed, so what you
// watch in the browser is the same code path that prints to the terminal — there
// is no separate "demo mode" that could drift from the real one.

import { parseEventLogs } from "viem";
import {
  deploy, contract, agentId, accounts, signReceipt, ABI,
  parseEther, VENDOR,
} from "./chain/client.mjs";
import { AGENTS, POISONED_LISTING, LLM_AVAILABLE } from "./agents/agents.mjs";

const fmt = (wei) => `${Number(wei) / 1e18} ETH`;
const bps = (n) => `${(Number(n) / 100).toFixed(2)}%`;

export async function runScenario(emit = () => {}) {
  const say = (type, message, data = {}) => emit({ type, message, data, at: Date.now() });

  say("phase", "Deploying Syndicate to the local EVM");
  const { address, deployTx } = await deploy();
  say("deployed", `Syndicate live at ${address}`, { address, tx: deployTx });

  const c = contract(address);
  const state = { address, agents: {} };

  // 1. Register both agents. The runtime key is bound here and never rotates.
  for (const [name, meta] of Object.entries(AGENTS)) {
    const id = agentId(name);
    const runtimeKey = accounts[meta.runtimeKeyName].address;
    const { hash } = await c.write("deployer", "registerAgent", [id, runtimeKey, `https://agents.local/${name}`]);
    state.agents[name] = { id, label: meta.label, runtimeKey };
    say("registered", `Registered ${meta.label}`, { name, id, runtimeKey, tx: hash });
  }

  // 2. Underwriters stake capital behind each agent.
  for (const [name, a] of Object.entries(state.agents)) {
    await c.write("underwriterA", "underwrite", [a.id], parseEther("6"));
    const { hash } = await c.write("underwriterB", "underwrite", [a.id], parseEther("4"));
    say("underwritten", `Syndicate of 2 underwriters staked 10 ETH behind ${a.label}`, { name, tx: hash });
  }

  // 3. Quote both agents cold. Neither has history, so both price at the
  //    unproven loading — being unknown is expensive, not free.
  const cover = parseEther("0.5");
  for (const [name, a] of Object.entries(state.agents)) {
    const rate = await c.read("rateBps", [a.id, cover]);
    const premium = await c.read("quote", [a.id, cover]);
    say("quote", `${a.label}: ${bps(rate)} on ${fmt(cover)} cover — premium ${fmt(premium)}`,
      { name, rateBps: Number(rate), premium: premium.toString(), phase: "cold" });
  }

  // 4. Both agents attempt the same order against the same poisoned listing.
  let nonce = 1n;
  for (const [name, meta] of Object.entries(AGENTS)) {
    const a = state.agents[name];

    const premium = await c.read("quote", [a.id, cover]);
    const { receipt: bindReceipt } = await c.write(
      "buyer", "bindPolicy", [a.id, VENDOR, cover], premium,
    );
    const bound = parseEventLogs({ abi: ABI, eventName: "PolicyBound", logs: bindReceipt.logs })[0];
    const policyId = bound.args.policyId;
    say("bound", `Buyer bound ${fmt(cover)} of cover on ${a.label} for ${premium && fmt(premium)}`,
      { name, policyId: policyId.toString(), tx: bindReceipt.transactionHash });

    say("agent-run", `${a.label} is processing the order against the poisoned listing`, { name });
    const decision = await meta.run(POISONED_LISTING);
    const redirected = decision.recipient.toLowerCase() !== VENDOR.toLowerCase();
    say("agent-decision",
      redirected
        ? `${a.label} chose ${decision.recipient} — NOT the vendor of record`
        : `${a.label} held the address of record`,
      { name, ...decision, redirected, expected: VENDOR, mode: decision.mode });

    // 5. The agent signs a receipt for what it actually did. This is the only
    //    way loss experience is ever written on chain.
    const { signature } = await signReceipt({
      address, runtimeKeyName: meta.runtimeKeyName,
      policyId, actualRecipient: decision.recipient, amount: cover, nonce,
    });
    const { hash, receipt } = await c.write(
      "deployer", "submitReceipt", [policyId, decision.recipient, cover, nonce, signature],
    );
    nonce += 1n;

    // Read the outcome from the emitted events, not from what we expected to
    // happen. If the contract disagreed with the agent's decision, we want the
    // demo to say so rather than narrate the assumption.
    const events = parseEventLogs({ abi: ABI, logs: receipt.logs });
    const breachEvent = events.find((e) => e.eventName === "Breach");
    const paid = events.find((e) => e.eventName === "ClaimPaid");
    const slashed = events.find((e) => e.eventName === "PoolSlashed");

    say(breachEvent ? "breach" : "clean",
      breachEvent
        ? `Breach proven by the agent's own signature — ${fmt(paid.args.amount)} claim paid to the buyer, syndicate pool slashed to ${fmt(slashed.args.poolAfter)}`
        : `Receipt matches the policy — no claim, premium retained by the syndicate`,
      { name, tx: hash, redirected, breach: Boolean(breachEvent) });

    const [pool, exposure, trials, failures] = await c.read("agentStats", [a.id]);
    say("stats", `${a.label}: pool ${fmt(pool)}, trials ${trials}, failures ${failures}`,
      { name, pool: pool.toString(), exposure: exposure.toString(), trials: Number(trials), failures: Number(failures) });
  }

  // 6. Re-quote. The price has moved, and the move is the whole point.
  for (const [name, a] of Object.entries(state.agents)) {
    const rate = await c.read("rateBps", [a.id, cover]);
    const premium = await c.read("quote", [a.id, cover]);
    say("quote", `${a.label}: ${bps(rate)} on ${fmt(cover)} cover — premium ${fmt(premium)}`,
      { name, rateBps: Number(rate), premium: premium.toString(), phase: "post" });
  }

  // 7. What each underwriter's stake is now worth.
  for (const [name, a] of Object.entries(state.agents)) {
    const value = await c.read("shareValue", [a.id, accounts.underwriterA.address]);
    say("underwriter", `Underwriter A's 6 ETH stake in ${a.label} is now worth ${fmt(value)}`,
      { name, value: value.toString() });
  }

  say("done", "Scenario complete", { llm: LLM_AVAILABLE ? "live Claude agents" : "scripted stand-in agents" });
  return state;
}

export { LLM_AVAILABLE };
