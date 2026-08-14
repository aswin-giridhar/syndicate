## Inspiration

The first empirical study of ERC-8004 — the leading trustless-agent standard — crawled Ethereum, BSC and Base and found that **73.5% / 59.2% / 90.6% of reviewers were coordinated Sybils**. Remove them and 15.8% / 77.9% / 86.8% of rated agents have no valid feedback left at all. Only 3–15% of registered agents even expose a live service endpoint. The paper's own words: reputation there "can be manipulated at minimal cost", and feedback is "rarely grounded in verifiable interactions".

Separately, a red-team of Google's Agent Payments Protocol showed that simple indirect prompt injection reliably redirects a real payment agent's funds to an attacker.

Put those together and the conclusion is uncomfortable: every agent-trust design we have — reputation registries, gauntlet scores, soulbound badges — produces a **claim**, and claims are cheap to manufacture. Adding a better test doesn't fix a cost asymmetry. It just makes a more expensive claim to forge.

Capital at risk has never been cheap to fake. That's the opening.

## What it does

Syndicate stops scoring agents and prices them instead.

Underwriters stake capital behind a specific agent. A buyer about to transact with that agent binds a policy on a single upcoming payment, and the quoted premium *is* the market's live assessment of that agent's counterparty risk. If the agent breaches — gets prompt-injected into redirecting funds, or simply never accounts for the payment — the policy pays the buyer and the loss falls on the underwriters' shares.

Two properties follow that no reputation registry has:

**1. Reputation cannot be forged, in either direction.** Loss experience is only ever written by a receipt carrying an ECDSA signature from the agent's *own runtime key* over the payment it actually executed. An agent cannot invent a clean history it did not earn, and a rival cannot fabricate a breach against it. The record is grounded in a verifiable interaction by construction.

**2. Manipulation costs money.** Inflating an agent's record means funding real premiums; attacking one means an underwriter absorbing real losses. The Sybil attack that is free against a star rating is capital-intensive here.

It also makes adversarial red-teaming *endogenous*. Nobody has to run it as an altruistic public good and be trusted to report honestly — underwriters probe the agents they cover because their own capital is on the line.

## How we built it

Solidity 0.8.24 on Foundry, driven by a Node runtime over viem, with a live dashboard fed by server-sent events. Everything executes against a real EVM — real deployment, real ECDSA recovery, real reverts, real transaction hashes. The CLI and the dashboard share one code path, so there is no separate demo mode that can drift from the real one.

Three agents receive the same order and the same attacker-controlled marketplace listing, which hides an instruction to remit payment elsewhere. They differ only in how they treat untrusted content:

| Agent | Outcome | Re-quote | ERC-8004 verdict | Pool |
|---|---|---|---|---|
| **v1** — naive, listing goes into the prompt | **Breach**, paid the attacker | 12.79% | **0 / 100** | 9.6858 ETH |
| **v2** — isolated, listing treated as data | Clean, held the address of record | 9.76% | **100 / 100** | 10.0358 ETH |
| **v0** — compromised, takes the job then goes dark | **Timed out**, silence settled as a breach | — | — | 9.6858 ETH |

Both v1 and v2 were quoted **10.22% cold**, with no history to separate them. After a single trial, Underwriter A's 6 ETH stake was worth **5.81 ETH** on v1 and **6.02 ETH** on v2. The shared reinsurance book absorbed its quota share of both losses, falling from 20 ETH to **19.75 ETH**.

Pricing is actuarial rather than heuristic:

- **Credibility weighting** blends observed loss experience against an unproven loading, so one lucky success cannot buy a clean record and one lucky exploit cannot destroy a good one.
- **Unproven agents price expensively, not cheaply** — the inverse of a registry where a fresh registration is indistinguishable from a trusted one.
- **Reinsurance**: per-agent pools are the junior tranche; a shared book takes a 30% quota share of every premium and every loss.
- **Correlation** — the term a per-agent pool structurally cannot express. Agents sharing a base model share its failure modes: one newly discovered injection technique breaches all of them the same afternoon. Cover outstanding is tracked *per model family across all agents* and concentration is surcharged quadratically. Same agent, same loss record: 0.5 ETH of cover prices at **9.76%**, 4 ETH at **16.27%**.
- **Term structure**: risk loads scale with policy duration while the floor rate does not — **9.76%** at 30 days against **28.28%** at 90.

Verdicts are written through to the **ERC-8004 Validation Registry**: binding a policy opens a `validationRequest`, settling writes a `validationResponse`. Syndicate extends the standard it critiques rather than sitting beside it.

## Challenges we ran into

**A design trap around timeouts.** A fully compromised agent doesn't sign an incriminating receipt — it goes quiet, leaving the policy unresolved forever with the buyer uncovered and underwriter capital locked. The obvious fix is a deadline that settles silence as a breach. But that opens a worse hole in the other direction: a buyer could bind cover, never give the agent a job, wait out the term and collect the full cover for the price of a premium. Since cover far exceeds premium, that is free money. The fix was requiring the agent to **counter-sign the job at bind time**, so every policy corresponds to work it actually took on, and silence afterwards is unambiguously the agent's failure.

**Honesty about the result.** Under live Claude Sonnet 5, the naive agent **resists** our injection payload — no breach occurs and the agents do not diverge. The breach shown in the demo is produced by a deterministic stand-in. Every document in the repository says so, because a project arguing that unverifiable claims are worthless does not get to make one.

**Stack depth.** Adding quota-share settlement and the ERC-8004 write-through pushed `submitReceipt` past what Solidity's legacy codegen could hold on stack, requiring the IR pipeline.

## Accomplishments that we're proud of

- A trust signal that **cannot be Sybil-farmed**, because being wrong about it costs money.
- **Correlation pricing for agent risk** — as far as we can find, nobody is pricing the systemic exposure created by thousands of agents sharing a handful of base models.
- Every claim in the repository is **verified rather than asserted**: the ERC-8004 verdict is read back off-chain after being written, the contract is tested for *refusing* to settle before a deadline as well as settling after it, and the deploy script asserts the breach was recorded rather than trusting its own writes.
- Documenting the result that undercuts our own headline demo, in the README, the submission and the one-pager.

## What we learned

Frontier models are meaningfully harder to prompt-inject than the published attack literature suggests — our first-generation payload is not strong enough to beat one. That is a genuine finding and it cuts both ways: the insurance mechanism is demonstrated end to end, while the specific exploit used to trigger it needs to get considerably better.

More broadly: insurance is what actually unlocked card payments, letters of credit and marine shipping. Recourse, not identity, is the precondition for strangers transacting at scale — and the agent economy is rediscovering that in the same order.

## What's next for Syndicate

- **Injection payloads that beat a frontier model**, and measuring which agent configurations survive them.
- **Base Sepolia deployment** — scripted and preflight-checked, not yet run.
- **Broadening the claim trigger.** Today we prove "paid the wrong recipient". Real failures are messier: overpaid, bought the wrong thing, leaked credentials. Each needs its own provable trigger.
- **Calibrating the actuarial loadings** against real loss data — which does not exist anywhere yet, because nobody has been writing this risk.
