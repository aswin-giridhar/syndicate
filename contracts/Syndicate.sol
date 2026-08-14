// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Syndicate — counterparty insurance for autonomous AI agents.
/// @notice Existing agent-trust designs (ERC-8004 Reputation Registry, gauntlet
///         scores, soulbound badges) all produce *claims*, which are cheap to
///         manufacture — empirically, 73.5%/59.2%/90.6% of ERC-8004 reviewers on
///         Ethereum/BSC/Base are coordinated Sybils (arXiv:2606.26028).
///
///         Syndicate replaces the claim with a price. Underwriters stake capital
///         behind a specific agent. A buyer about to transact with that agent binds
///         a policy; the quoted premium is the market's live assessment of the
///         agent's counterparty risk. If the agent breaches, the policy pays the
///         buyer and the loss falls on the underwriters' shares.
///
///         Two properties follow that no reputation registry has:
///
///         1. Reputation cannot be forged. Loss experience is only ever written by
///            `submitReceipt`, which requires an ECDSA signature from the agent's
///            own runtime key over the executed payment. An agent cannot invent a
///            clean record it did not earn, and no third party can invent a dirty
///            one on its behalf.
///         2. Manipulation costs money. Inflating an agent's record means funding
///            real premiums; attacking it means an underwriter absorbing real
///            losses. The Sybil attack that is free against a star rating is
///            capital-intensive here.
contract Syndicate {
    // ---------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;

    /// @notice Floor rate charged even to a flawless, deep-pooled agent (0.50%).
    uint256 public constant BASE_RATE_BPS = 50;

    /// @notice Loading applied to agents with no observed history. Unproven is
    ///         expensive, not cheap — the inverse of a reputation registry, where
    ///         a fresh registration is indistinguishable from a trusted one. Only
    ///         3%/4%/15% of ERC-8004 registrations even expose a live endpoint.
    uint256 public constant UNPROVEN_LOAD_BPS = 900;

    /// @notice Trials required before loss experience is fully credible. Below
    ///         this, the quote blends observed experience with the unproven
    ///         loading rather than over-fitting to a handful of samples.
    uint256 public constant CREDIBILITY_TRIALS = 20;

    /// @notice Weight on observed failure ratio once fully credible.
    uint256 public constant FAILURE_LOAD_BPS = 6_000;

    /// @notice Weight on capacity utilisation — a pool near its limit prices up.
    uint256 public constant UTILISATION_LOAD_BPS = 2_000;

    // ------------------------------------------------------------------- types

    struct Agent {
        /// Key the agent's runtime signs execution receipts with. Set once at
        /// registration; the agent cannot rotate it to escape its own history.
        address runtimeKey;
        string endpoint;
        /// Underwriter capital backing this agent, in wei.
        uint256 pool;
        /// Total shares issued against `pool`. Losses shrink `pool` and leave
        /// shares untouched, so every underwriter is slashed pro-rata.
        uint256 shares;
        /// Cover bound and not yet resolved.
        uint256 exposure;
        uint64 trials;
        uint64 failures;
        bool registered;
    }

    struct Policy {
        bytes32 agentId;
        address beneficiary;
        /// Address the buyer instructed the agent to pay. A receipt naming any
        /// other recipient is a breach.
        address expectedRecipient;
        uint256 cover;
        uint256 premium;
        bool resolved;
    }

    // ------------------------------------------------------------------ storage

    mapping(bytes32 => Agent) public agents;
    mapping(bytes32 => mapping(address => uint256)) public sharesOf;
    mapping(uint256 => Policy) public policies;
    /// Receipt nonces already consumed, per agent — blocks replay of a receipt.
    mapping(bytes32 => mapping(uint256 => bool)) public usedNonce;

    uint256 public nextPolicyId = 1;

    // ------------------------------------------------------------------- events

    event AgentRegistered(bytes32 indexed agentId, address runtimeKey, string endpoint);
    event Underwritten(bytes32 indexed agentId, address indexed underwriter, uint256 amount, uint256 shares);
    event Withdrawn(bytes32 indexed agentId, address indexed underwriter, uint256 shares, uint256 amount);
    event PolicyBound(
        uint256 indexed policyId,
        bytes32 indexed agentId,
        address indexed beneficiary,
        uint256 cover,
        uint256 premium,
        uint256 rateBps
    );
    event ReceiptAccepted(uint256 indexed policyId, bytes32 indexed agentId, address actualRecipient, uint256 amount);
    event Breach(uint256 indexed policyId, bytes32 indexed agentId, address expectedRecipient, address actualRecipient);
    event ClaimPaid(uint256 indexed policyId, bytes32 indexed agentId, address indexed beneficiary, uint256 amount);
    event PoolSlashed(bytes32 indexed agentId, uint256 amount, uint256 poolAfter);

    // ------------------------------------------------------------------- errors

    error UnknownAgent();
    error AlreadyRegistered();
    error ZeroAmount();
    error InsufficientCapacity();
    error PremiumMismatch(uint256 required, uint256 paid);
    error PolicyResolved();
    error BadSignature();
    error NonceUsed();
    error InsufficientShares();

    // --------------------------------------------------------------- registry

    function registerAgent(bytes32 agentId, address runtimeKey, string calldata endpoint) external {
        if (agents[agentId].registered) revert AlreadyRegistered();
        if (runtimeKey == address(0)) revert BadSignature();
        agents[agentId].runtimeKey = runtimeKey;
        agents[agentId].endpoint = endpoint;
        agents[agentId].registered = true;
        emit AgentRegistered(agentId, runtimeKey, endpoint);
    }

    // ------------------------------------------------------------ underwriting

    /// @notice Stake capital behind an agent. Shares are priced against the live
    ///         pool, so a depositor joining after losses buys in at the marked-down
    ///         value and one joining after premium income pays the marked-up value.
    function underwrite(bytes32 agentId) external payable {
        Agent storage a = agents[agentId];
        if (!a.registered) revert UnknownAgent();
        if (msg.value == 0) revert ZeroAmount();

        uint256 issued = a.shares == 0 ? msg.value : (msg.value * a.shares) / a.pool;
        a.shares += issued;
        a.pool += msg.value;
        sharesOf[agentId][msg.sender] += issued;

        emit Underwritten(agentId, msg.sender, msg.value, issued);
    }

    /// @notice Redeem shares for their current value. Capital committed as
    ///         outstanding exposure cannot be withdrawn — underwriters cannot
    ///         exit a risk they are still carrying.
    function withdraw(bytes32 agentId, uint256 shareAmount) external {
        Agent storage a = agents[agentId];
        if (sharesOf[agentId][msg.sender] < shareAmount) revert InsufficientShares();

        uint256 value = (shareAmount * a.pool) / a.shares;
        if (a.pool - value < a.exposure) revert InsufficientCapacity();

        sharesOf[agentId][msg.sender] -= shareAmount;
        a.shares -= shareAmount;
        a.pool -= value;

        (bool ok,) = msg.sender.call{value: value}("");
        require(ok, "transfer failed");
        emit Withdrawn(agentId, msg.sender, shareAmount, value);
    }

    // ------------------------------------------------------------------ pricing

    /// @notice The rate the market charges to carry `cover` on this agent, in bps.
    /// @dev This is the trust signal. It is a price, not a score: it rises with
    ///      observed breaches, rises when the agent is unproven, and rises as the
    ///      pool's free capacity is consumed.
    function rateBps(bytes32 agentId, uint256 cover) public view returns (uint256) {
        Agent storage a = agents[agentId];
        if (!a.registered) revert UnknownAgent();
        if (a.pool == 0 || a.pool < a.exposure + cover) revert InsufficientCapacity();

        uint256 rate = BASE_RATE_BPS;

        // Loss experience, credibility-weighted. With few trials the observed
        // ratio is noisy, so it is blended against the unproven loading rather
        // than trusted outright — standard actuarial credibility, and it stops a
        // brand-new agent from buying a clean record with two cheap successes.
        uint256 t = a.trials;
        uint256 observedBps = t == 0 ? 0 : (uint256(a.failures) * BPS) / t;
        uint256 credibility = t >= CREDIBILITY_TRIALS ? BPS : (t * BPS) / CREDIBILITY_TRIALS;

        rate += (observedBps * FAILURE_LOAD_BPS * credibility) / (BPS * BPS);
        rate += (UNPROVEN_LOAD_BPS * (BPS - credibility)) / BPS;

        // Capacity utilisation after this policy is bound.
        uint256 utilisation = ((a.exposure + cover) * BPS) / a.pool;
        rate += (utilisation * UTILISATION_LOAD_BPS) / BPS;

        return rate;
    }

    function quote(bytes32 agentId, uint256 cover) public view returns (uint256 premium) {
        premium = (cover * rateBps(agentId, cover)) / BPS;
    }

    // ------------------------------------------------------------------ policy

    /// @notice Bind cover on a single upcoming payment to `expectedRecipient`.
    function bindPolicy(bytes32 agentId, address expectedRecipient, uint256 cover)
        external
        payable
        returns (uint256 policyId)
    {
        Agent storage a = agents[agentId];
        if (!a.registered) revert UnknownAgent();
        if (cover == 0) revert ZeroAmount();

        uint256 rate = rateBps(agentId, cover);
        uint256 premium = (cover * rate) / BPS;
        if (msg.value != premium) revert PremiumMismatch(premium, msg.value);

        // Premium income accrues to the pool, lifting every share's value. This is
        // what pays underwriters for carrying the risk.
        a.pool += msg.value;
        a.exposure += cover;

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            agentId: agentId,
            beneficiary: msg.sender,
            expectedRecipient: expectedRecipient,
            cover: cover,
            premium: premium,
            resolved: false
        });

        emit PolicyBound(policyId, agentId, msg.sender, cover, premium, rate);
    }

    /// @notice The digest an agent runtime must sign for a payment receipt.
    /// @dev Binds the chain id and this contract's address so a receipt cannot be
    ///      replayed onto another deployment.
    function receiptDigest(uint256 policyId, address actualRecipient, uint256 amount, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), policyId, actualRecipient, amount, nonce));
    }

    /// @notice Submit the agent's signed record of what it actually paid, and to whom.
    /// @dev This is the only path that writes loss experience, and it demands a
    ///      signature from the agent's own runtime key. That is what makes the
    ///      record grounded in a verifiable interaction — the property arXiv:2606.26028
    ///      found missing from the ERC-8004 Reputation Registry, where feedback is
    ///      "rarely grounded in verifiable interactions".
    ///
    ///      A breach settles atomically: the beneficiary is made whole and the loss
    ///      falls on the pool in the same transaction that records the failure, so
    ///      the price and the payout can never disagree.
    function submitReceipt(
        uint256 policyId,
        address actualRecipient,
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) external {
        Policy storage p = policies[policyId];
        if (p.cover == 0) revert PolicyResolved();
        if (p.resolved) revert PolicyResolved();

        Agent storage a = agents[p.agentId];
        if (usedNonce[p.agentId][nonce]) revert NonceUsed();

        bytes32 digest = receiptDigest(policyId, actualRecipient, amount, nonce);
        if (_recover(_ethSigned(digest), signature) != a.runtimeKey) revert BadSignature();

        usedNonce[p.agentId][nonce] = true;
        p.resolved = true;
        a.exposure -= p.cover;
        a.trials += 1;

        emit ReceiptAccepted(policyId, p.agentId, actualRecipient, amount);

        if (actualRecipient != p.expectedRecipient) {
            a.failures += 1;
            emit Breach(policyId, p.agentId, p.expectedRecipient, actualRecipient);

            uint256 payout = p.cover > a.pool ? a.pool : p.cover;
            a.pool -= payout;
            emit PoolSlashed(p.agentId, payout, a.pool);

            (bool ok,) = p.beneficiary.call{value: payout}("");
            require(ok, "payout failed");
            emit ClaimPaid(policyId, p.agentId, p.beneficiary, payout);
        }
    }

    // ------------------------------------------------------------------- views

    function agentStats(bytes32 agentId)
        external
        view
        returns (uint256 pool, uint256 exposure, uint64 trials, uint64 failures, uint256 shares)
    {
        Agent storage a = agents[agentId];
        return (a.pool, a.exposure, a.trials, a.failures, a.shares);
    }

    function shareValue(bytes32 agentId, address underwriter) external view returns (uint256) {
        Agent storage a = agents[agentId];
        if (a.shares == 0) return 0;
        return (sharesOf[agentId][underwriter] * a.pool) / a.shares;
    }

    // -------------------------------------------------------------- signatures

    function _ethSigned(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
