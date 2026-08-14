// The end-to-end scenario, emitting structured events as it goes.
//
// Shared by the CLI (`npm run demo`) and the dashboard's live feed, so what you
// watch in the browser is the same code path that prints to the terminal — there
// is no separate "demo mode" that could drift from the real one.

import { parseEventLogs, keccak256, toHex } from "viem";
import {
  deploy, contract, registryContract, agentId, accounts, signReceipt, ABI,
  parseEther, VENDOR,
} from "./chain/client.mjs";

/// Both demo agents run on the same base model. Correlated by construction —
/// which is exactly the exposure a per-agent pool cannot see.
const MODEL_FAMILY = keccak256(toHex("claude-sonnet-5"));
const TERM_DAYS = 30n;
import { AGENTS, POISONED_LISTING, LLM_AVAILABLE } from "./agents/agents.mjs";

const fmt = (wei) => `${Number(wei) / 1e18} ETH`;
const bps = (n) => `${(Number(n) / 100).toFixed(2)}%`;

export async function runScenario(emit = () => {}) {
  const say = (type, message, data = {}) => emit({ type, message, data, at: Date.now() });

  say("phase", "Deploying the ERC-8004 Validation Registry and Syndicate");
  const { address, deployTx, registry } = await deploy();
  say("deployed", `Validation Registry at ${registry} · Syndicate at ${address}`,
    { address, registry, tx: deployTx });

  const c = contract(address);
  const reg = registryContract(registry);
  const state = { address, registry, agents: {} };

  // 1. Register both agents against their ERC-8004 identity. The runtime key is
  //    bound here and never rotates, so an agent cannot outrun its own history.
  //    Both run on the same base model, which is what makes their risk correlated.
  let erc8004Id = 1n;
  for (const [name, meta] of Object.entries(AGENTS)) {
    const id = agentId(name);
    const runtimeKey = accounts[meta.runtimeKeyName].address;
    const { hash } = await c.write("deployer", "registerAgent",
      [id, erc8004Id, runtimeKey, MODEL_FAMILY, `https://agents.local/${name}`]);
    state.agents[name] = { id, label: meta.label, runtimeKey, erc8004Id };
    say("registered", `Registered ${meta.label} as ERC-8004 agent #${erc8004Id}`,
      { name, id, runtimeKey, erc8004Id: erc8004Id.toString(), tx: hash });
    erc8004Id += 1n;
  }

  // 2. Underwriters stake capital behind each agent — the junior tranche.
  for (const [name, a] of Object.entries(state.agents)) {
    await c.write("underwriterA", "underwrite", [a.id], parseEther("6"));
    const { hash } = await c.write("underwriterB", "underwrite", [a.id], parseEther("4"));
    say("underwritten", `Syndicate of 2 underwriters staked 10 ETH behind ${a.label}`, { name, tx: hash });
  }

  // 3. The shared reinsurance book: senior to every agent pool, diversified
  //    across all of them, and paid a 30% quota share of every premium.
  {
    const { hash } = await c.write("underwriterB", "depositReinsurance", [], parseEther("20"));
    const [capital] = await c.read("bookStats");
    say("reinsurance", `Reinsurance book capitalised with ${fmt(capital)} — 30% quota share of every policy`,
      { capital: capital.toString(), tx: hash });
  }

  // 3. Quote both agents cold. Neither has history, so both price at the
  //    unproven loading — being unknown is expensive, not free.
  const cover = parseEther("0.5");
  for (const [name, a] of Object.entries(state.agents)) {
    const rate = await c.read("rateBps", [a.id, cover, TERM_DAYS]);
    const premium = await c.read("quote", [a.id, cover, TERM_DAYS]);
    say("quote", `${a.label}: ${bps(rate)} on ${fmt(cover)} cover — premium ${fmt(premium)}`,
      { name, rateBps: Number(rate), premium: premium.toString(), phase: "cold" });
  }

  // 4. Both agents attempt the same order against the same poisoned listing.
  let nonce = 1n;
  for (const [name, meta] of Object.entries(AGENTS)) {
    const a = state.agents[name];

    const premium = await c.read("quote", [a.id, cover, TERM_DAYS]);
    const { receipt: bindReceipt } = await c.write(
      "buyer", "bindPolicy", [a.id, VENDOR, cover, TERM_DAYS], premium,
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

    // Read the verdict back out of the ERC-8004 registry rather than trusting
    // that our own write landed. This is the interoperability claim, verified.
    const requestHash = await c.read("validationRequestHash", [policyId]);
    const [validator, regAgentId, response] = await reg.read("getValidationStatus", [requestHash]);
    say("erc8004",
      `ERC-8004 Validation Registry: agent #${regAgentId} scored ${response}/100 by validator ${validator.slice(0, 10)}…`,
      { name, response: Number(response), erc8004Id: regAgentId.toString(), requestHash });
  }

  // 6. Re-quote. The price has moved, and the move is the whole point.
  for (const [name, a] of Object.entries(state.agents)) {
    const rate = await c.read("rateBps", [a.id, cover, TERM_DAYS]);
    const premium = await c.read("quote", [a.id, cover, TERM_DAYS]);
    say("quote", `${a.label}: ${bps(rate)} on ${fmt(cover)} cover — premium ${fmt(premium)}`,
      { name, rateBps: Number(rate), premium: premium.toString(), phase: "post" });
  }

  // 7. What each underwriter's stake is now worth.
  for (const [name, a] of Object.entries(state.agents)) {
    const value = await c.read("shareValue", [a.id, accounts.underwriterA.address]);
    say("underwriter", `Underwriter A's 6 ETH stake in ${a.label} is now worth ${fmt(value)}`,
      { name, value: value.toString() });
  }

  // 8. Correlation. Both agents run on the same base model, so cover written on
  //    one adds to the same concentration the other is priced against. A pool
  //    scoped to a single agent structurally cannot see this.
  {
    const [name, a] = Object.entries(state.agents)[1];
    const small = parseEther("0.5");
    const large = parseEther("4");
    const rSmall = await c.read("rateBps", [a.id, small, TERM_DAYS]);
    const rLarge = await c.read("rateBps", [a.id, large, TERM_DAYS]);
    say("correlation",
      `Concentration surcharge on ${a.label}: ${bps(rSmall)} for ${fmt(small)} cover vs ${bps(rLarge)} for ${fmt(large)} — same agent, same record, more correlated exposure to one model family`,
      { name, small: Number(rSmall), large: Number(rLarge) });
  }

  // 9. Term structure — risk accrues with exposure time, the floor does not.
  {
    const [name, a] = Object.entries(state.agents)[1];
    const r30 = await c.read("rateBps", [a.id, cover, 30n]);
    const r90 = await c.read("rateBps", [a.id, cover, 90n]);
    say("term", `Term structure on ${a.label}: ${bps(r30)} for 30 days vs ${bps(r90)} for 90 days`,
      { name, d30: Number(r30), d90: Number(r90) });
  }

  // 10. The reinsurance book's position after taking its quota share of both.
  {
    const [capital, exposure] = await c.read("bookStats");
    const value = await c.read("reinsuranceValue", [accounts.underwriterB.address]);
    say("reinsurance",
      `Reinsurance book: ${fmt(capital)} capital, ${fmt(exposure)} exposure — Underwriter B's 20 ETH cession stake now worth ${fmt(value)}`,
      { capital: capital.toString(), exposure: exposure.toString(), value: value.toString() });
  }

  say("done", "Scenario complete", { llm: LLM_AVAILABLE ? "live Claude agents" : "scripted stand-in agents" });
  return state;
}

export { LLM_AVAILABLE };
