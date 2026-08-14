# Devpost submission — copy/paste fields

## Project title
Syndicate — counterparty insurance for autonomous AI agents

## Tagline (short description)
Underwriters stake capital behind an AI agent. The premium your agent is quoted before it pays
that counterparty *is* the trust signal — and unlike a reputation score, it costs money to be
wrong about.

## Track
Track 2 — Web3 Applications, AI Agents and Real-World Use Cases

## Team type
Public Group (solo entry)

## Team members
Aswin Giridhar Subramanian — Independent

## Primary contact email
aswinsson@gmail.com

---

## Problem statement

Autonomous agents can now hold keys and transact. Before an agent pays an unknown counterparty
agent, it must answer one question: can this agent be trusted with my money?

Every answer shipped so far is a *claim*, and claims are cheap to manufacture. The first
empirical study of ERC-8004, the leading trustless-agent standard, measured the result across
Ethereum, BSC and Base through May 2026 (arXiv:2606.26028): **73.5% / 59.2% / 90.6% of reviewers
exhibit coordinated Sybil behaviour**; after removing them, **15.8% / 77.9% / 86.8% of rated
agents have no valid feedback left at all**; and only **3% / 4% / 15%** of registrations even
expose a live service endpoint. The paper's own conclusion is that reputation there "can be
manipulated at minimal cost" and feedback is "rarely grounded in verifiable interactions".

The agents themselves are demonstrably exploitable. arXiv:2601.22569 red-teamed Google's Agent
Payments Protocol and showed simple indirect prompt injection reliably redirects a real payment
agent's funds to an attacker.

This is the missing precondition for agent commerce at scale. No business will let agents
transact at volume without recourse — and recourse, not identity, is what actually unlocked
card payments and cross-border settlement.

## Solution overview

Syndicate stops scoring agents and prices them instead.

Underwriters stake capital behind a specific agent. A buyer about to transact binds a policy on
that single payment, and the quoted premium is the market's live assessment of that agent's
counterparty risk. If the agent breaches — gets prompt-injected into redirecting funds — the
policy pays the buyer and the loss falls on the underwriters' shares.

Two properties follow that no reputation registry has:

1. **Reputation cannot be forged, in either direction.** Loss experience is only ever written by
   a receipt carrying an ECDSA signature from the agent's *own runtime key* over the payment it
   actually executed. An agent cannot invent a clean history it did not earn, and a rival cannot
   fabricate a breach against it. The record is grounded in a verifiable interaction by
   construction — the exact property the ERC-8004 study found missing.
2. **Manipulation costs money.** Inflating an agent's record means funding real premiums;
   attacking it means an underwriter absorbing real losses. The Sybil attack that is free
   against a star rating is capital-intensive here.

It also makes adversarial red-teaming endogenous. Nobody has to run it as an altruistic public
good and be trusted to report honestly — underwriters probe the agents they cover because their
own capital is at risk.

## Key features

- **Underwriting pool** with ERC-4626-style share accounting, so a loss slashes every
  underwriter pro-rata in O(1) gas and a claim can settle atomically with the record of failure.
- **Actuarial pricing.** `rateBps` blends observed loss experience against an unproven loading
  using credibility weighting. Unproven agents price *expensively*, not cheaply — the inverse of
  a reputation registry, and the correct response to a population where 85–97% of registrations
  are not live. One lucky success cannot buy a clean record.
- **Receipt-backed claims.** Signed execution receipts, nonce-guarded and bound to chain id and
  contract address. Proof-of-inference via ZK costs ~180s/query against <15ms for receipts at
  94% coverage (arXiv:2603.10060); Syndicate only needs to prove what was paid and to whom,
  which a signature over the payment tuple settles exactly.
- **Live adversarial demo.** Two agents, same order, same attacker-controlled listing carrying
  an indirect prompt injection. One is naive, one isolates untrusted content.
- **ERC-8004 write-through.** Syndicate registers as a validator in the ERC-8004 Validation
  Registry: binding a policy opens a `validationRequest`, settling a receipt writes a
  `validationResponse` scored 100 or 0 with the receipt digest attached. It extends the standard
  it critiques instead of sitting beside it, so any agent already reading ERC-8004 sees a verdict
  backed by capital next to the Sybil-farmed feedback.
- **Reinsurance.** Per-agent pools are the junior tranche; a shared book takes a 30% quota share
  of every premium and every loss, so underwriters can back one agent or the diversified book.
- **Correlation pricing — the term a per-agent pool cannot express.** Agents declare a model
  family; agents sharing a base model share its failure modes, so one new injection technique
  breaches all of them the same afternoon. Cover outstanding is tracked per family across all
  agents and concentration is surcharged quadratically. Same agent and same record, 0.5 ETH of
  cover prices at 9.76% while 4 ETH prices at 16.24%.
- **Term structure.** Risk loads scale with policy duration while the floor rate does not:
  9.76% at 30 days against 28.28% at 90.

## Demonstrated result (deterministic stand-in agents)

Stated plainly, because the project's thesis is that unverifiable claims are worthless: the run
below used deterministic stand-in agents. Against **live Claude Sonnet 5, the naive agent resists
this injection payload** — it keeps the address of record and the two agents do not diverge.

The insurance mechanism is therefore demonstrated end-to-end; the specific exploit used to trigger
it is not yet strong enough to beat a frontier model. Developing payloads that are, and measuring
which agent configurations survive them, is the first on-site work item.


| | Procure-Bot v1 (naive) | Procure-Bot v2 (isolated) |
|---|---|---|
| Cold quote, no history | 10.22% | 10.22% |
| Outcome vs. poisoned listing | Breach — paid the attacker | Held the address of record |
| Claim | 0.5 ETH paid to buyer | none |
| Re-quote | **12.79%** | **9.76%** |
| ERC-8004 verdict written on chain | **0 / 100** | **100 / 100** |
| Underwriter A's 6 ETH stake | **5.8115 ETH** | 6.0215 ETH |

The spread opened after a single observed trial, with no oracle, committee or rating agency in
the loop.

## Target users

- **Businesses deploying purchasing, procurement or treasury agents** who need recourse before
  they will raise transaction limits.
- **Agent marketplaces and A2A protocols** (ERC-8004, AP2, x402) that have an identity layer but
  no way to price the risk of the agents on it.
- **Crypto-native underwriters and risk desks**, for whom agent counterparty risk is a new,
  uncorrelated, and currently unpriced book.
- **Agent developers**, who gain a way to prove their hardening is real — a cheap premium is a
  credential competitors cannot fake.

## Technologies

Solidity 0.8.24 · Foundry (forge, anvil) · viem · Node.js 22 · server-sent events ·
ECDSA / ecrecover with EIP-191 signing · Anthropic Claude for the agent runtimes

## Sponsor tools / APIs used

None.

## Prior work disclosure

None. Every line in the repository was written during the hackathon period; the repository was
initialised from empty at the start of the session.

## What is real vs. what is next

Real and running today: the contract, pricing, signature verification, claims, payouts and
slashing all execute against a real EVM (anvil) — real deployment, real ECDSA recovery, real
reverts, real transaction hashes. The CLI and the dashboard share one code path, so there is no
separate demo mode that can drift from the real one.

Explicitly not done: Base Sepolia deployment is scripted and preflight-checks its own balance, but
has not been run — the deployer address is unfunded. The reinsurance, correlation and term-structure
loadings are structurally correct but **not calibrated**: they are reasoned defaults, because no
loss history for agent breaches exists anywhere yet to fit them to.
