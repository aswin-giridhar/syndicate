// Deploy Syndicate to Base Sepolia and exercise it with one real transaction.
//
// A deployment nobody has transacted against is a claim, not evidence. This
// script deploys, registers an agent, underwrites, binds a policy and settles a
// receipt — then reads the resulting state back off the public chain and prints
// explorer links for every hash, so the run can be checked by someone who does
// not trust this script.

import { readFileSync, existsSync, writeFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, parseEther, keccak256, toHex,
  encodeAbiParameters, formatEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

// ------------------------------------------------------------------- config

function loadEnv() {
  const path = new URL("../.env", import.meta.url);
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) process.env[m[1]] ??= m[2].replace(/^["']|["']$/g, "");
  }
}
loadEnv();

const KEY = process.env.DEPLOYER_PRIVATE_KEY;
if (!KEY) {
  console.error("DEPLOYER_PRIVATE_KEY missing from .env — nothing to deploy with.");
  process.exit(1);
}

const RPC = process.env.BASE_SEPOLIA_RPC ?? "https://sepolia.base.org";
const EXPLORER = "https://sepolia.basescan.org";

const account = privateKeyToAccount(KEY);
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(RPC) });

const load = (p) => JSON.parse(readFileSync(new URL(`../out/${p}`, import.meta.url)));
const syndicate = load("Syndicate.sol/Syndicate.json");
const registry = load("ValidationRegistry.sol/ValidationRegistry.json");

const eth = (v) => `${formatEther(v)} ETH`;
const link = (h) => `${EXPLORER}/tx/${h}`;
const step = (m) => console.log(`\n\x1b[1;36m→\x1b[0m ${m}`);

// ------------------------------------------------------------------ preflight

console.log(`\n\x1b[1mSyndicate → Base Sepolia\x1b[0m`);
console.log(`deployer  ${account.address}`);

const balance = await publicClient.getBalance({ address: account.address });
console.log(`balance   ${eth(balance)}`);

// Deploy + five transactions. Fail early and say the real number rather than
// running out of gas halfway and leaving a half-deployed system behind.
const NEEDED = parseEther("0.01");
if (balance < NEEDED) {
  console.error(
    `\nInsufficient balance. Need roughly ${eth(NEEDED)} to deploy and exercise the contract.` +
    `\nFund ${account.address} from a Base Sepolia faucet:` +
    `\n  https://portal.cdp.coinbase.com/products/faucet` +
    `\n  https://faucets.chain.link/base-sepolia`,
  );
  process.exit(1);
}

const send = async (label, hash) => {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted — ${link(hash)}`);
  console.log(`  ${label.padEnd(22)} ${link(hash)}`);
  return receipt;
};

const write = async (label, address, abi, functionName, args, value = 0n) => {
  const { request } = await publicClient.simulateContract({ address, abi, functionName, args, value, account });
  return send(label, await wallet.writeContract(request));
};

// ------------------------------------------------------------------- deploy

step("Deploying the ERC-8004 Validation Registry");
const regReceipt = await send("ValidationRegistry", await wallet.deployContract({
  abi: registry.abi, bytecode: registry.bytecode.object,
  args: ["0x0000000000000000000000000000000000000000"],
}));
const REGISTRY = regReceipt.contractAddress;

step("Deploying Syndicate");
const synReceipt = await send("Syndicate", await wallet.deployContract({
  abi: syndicate.abi, bytecode: syndicate.bytecode.object, args: [REGISTRY],
}));
const SYNDICATE = synReceipt.contractAddress;

const abi = syndicate.abi;
const agentId = keccak256(toHex("base-sepolia-procure-v1"));
const MODEL_FAMILY = keccak256(toHex("claude-sonnet-5"));
const VENDOR = "0x1111111111111111111111111111111111111111";
const ATTACKER = "0x2222222222222222222222222222222222222222";

// The deployer doubles as the agent runtime here so the whole flow fits one
// funded key. In production these are separate parties by construction.
step("Registering an agent and staking capital");
await write("registerAgent", SYNDICATE, abi, "registerAgent",
  [agentId, 1n, account.address, MODEL_FAMILY, "https://agents.example/procure-v1"]);
await write("underwrite", SYNDICATE, abi, "underwrite", [agentId], parseEther("0.002"));

step("Binding a policy");
const cover = parseEther("0.0005");
const premium = await publicClient.readContract({
  address: SYNDICATE, abi, functionName: "quote", args: [agentId, cover, 30n],
});
console.log(`  premium quoted        ${eth(premium)}`);
const bindReceipt = await write("bindPolicy", SYNDICATE, abi, "bindPolicy",
  [agentId, VENDOR, cover, 30n], premium);

const policyId = BigInt(bindReceipt.logs.find((l) => l.address.toLowerCase() === SYNDICATE.toLowerCase())
  ?.topics[1] ?? "0x1");

step("Settling a breach — the agent signs that it paid the wrong address");
const nonce = 1n;
const digest = keccak256(encodeAbiParameters(
  [{ type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }],
  [BigInt(baseSepolia.id), SYNDICATE, policyId, ATTACKER, cover, nonce],
));
const signature = await account.signMessage({ message: { raw: digest } });
await write("submitReceipt", SYNDICATE, abi, "submitReceipt", [policyId, ATTACKER, cover, nonce, signature]);

// ---------------------------------------------------------------- verify

step("Reading state back off the public chain");
const [pool, exposure, trials, failures] = await publicClient.readContract({
  address: SYNDICATE, abi, functionName: "agentStats", args: [agentId],
});
const requestHash = await publicClient.readContract({
  address: SYNDICATE, abi, functionName: "validationRequestHash", args: [policyId],
});
const [validator, regAgentId, response] = await publicClient.readContract({
  address: REGISTRY, abi: registry.abi, functionName: "getValidationStatus", args: [requestHash],
});

console.log(`  pool                  ${eth(pool)}`);
console.log(`  trials / failures     ${trials} / ${failures}`);
console.log(`  ERC-8004 verdict      agent #${regAgentId} scored ${response}/100 by ${validator}`);

if (failures !== 1n) throw new Error(`expected the breach to be recorded, got failures=${failures}`);
if (response !== 0) throw new Error(`expected a breach verdict of 0, got ${response}`);

const out = {
  chain: "base-sepolia",
  chainId: baseSepolia.id,
  syndicate: SYNDICATE,
  validationRegistry: REGISTRY,
  deployTx: synReceipt.transactionHash,
  explorer: `${EXPLORER}/address/${SYNDICATE}`,
};
writeFileSync(new URL("../deployments/base-sepolia.json", import.meta.url), JSON.stringify(out, null, 2) + "\n");

console.log(`\n\x1b[1;32mLive on Base Sepolia\x1b[0m`);
console.log(`  Syndicate  ${EXPLORER}/address/${SYNDICATE}`);
console.log(`  Registry   ${EXPLORER}/address/${REGISTRY}`);
console.log(`  written to deployments/base-sepolia.json\n`);
