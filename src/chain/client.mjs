// Chain layer: deploys Syndicate to the local EVM and exposes typed helpers.
//
// Everything here talks to a real EVM (anvil) over JSON-RPC — real deployment,
// real ECDSA recovery, real reverts, real transaction hashes. Nothing is mocked.
// Base Sepolia deployment is the first on-site milestone; see README.

import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseEther, keccak256, toHex, encodeAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";

const artifact = JSON.parse(readFileSync(new URL("../../out/Syndicate.sol/Syndicate.json", import.meta.url)));
export const ABI = artifact.abi;
const BYTECODE = artifact.bytecode.object;

// anvil's deterministic accounts. Deterministic keys keep the demo reproducible;
// these are the publicly published test keys and hold no real value.
const KEYS = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  underwriterA: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  underwriterB: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  vulnerableRuntime: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  hardenedRuntime: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  buyer: "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
};

export const accounts = Object.fromEntries(
  Object.entries(KEYS).map(([name, key]) => [name, privateKeyToAccount(key)]),
);

// Counterparties in the demo scenario.
export const VENDOR = "0x1111111111111111111111111111111111111111";
export const ATTACKER = "0x2222222222222222222222222222222222222222";

export const publicClient = createPublicClient({ chain: foundry, transport: http(RPC) });

export function walletFor(name) {
  return createWalletClient({ account: accounts[name], chain: foundry, transport: http(RPC) });
}

export const agentId = (name) => keccak256(toHex(name));

export async function deploy() {
  const wallet = walletFor("deployer");
  const hash = await wallet.deployContract({ abi: ABI, bytecode: BYTECODE, args: [] });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return { address: receipt.contractAddress, deployTx: hash, blockNumber: receipt.blockNumber };
}

export function contract(address) {
  const read = (functionName, args = []) =>
    publicClient.readContract({ address, abi: ABI, functionName, args });

  const write = async (walletName, functionName, args = [], value = 0n) => {
    const wallet = walletFor(walletName);
    const { request } = await publicClient.simulateContract({
      address,
      abi: ABI,
      functionName,
      args,
      value,
      account: accounts[walletName],
    });
    const hash = await wallet.writeContract(request);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return { hash, receipt };
  };

  return { address, read, write };
}

/// Sign an execution receipt with the agent's runtime key.
///
/// The signature is what makes the on-chain record un-forgeable in both
/// directions: the agent cannot invent a clean history it did not earn, and
/// nobody else can fabricate a breach against it.
export async function signReceipt({ address, runtimeKeyName, policyId, actualRecipient, amount, nonce }) {
  const digest = keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }],
      [BigInt(foundry.id), address, policyId, actualRecipient, amount, nonce],
    ),
  );
  const signature = await accounts[runtimeKeyName].signMessage({ message: { raw: digest } });
  return { digest, signature };
}

export { parseEther };
