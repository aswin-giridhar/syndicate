// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidationRegistry} from "./IValidationRegistry.sol";

/// @title Syndicate — counterparty insurance for autonomous AI agents.
/// @notice Existing agent-trust designs (ERC-8004 Reputation Registry, gauntlet
///         scores, soulbound badges) all produce *claims*, which are cheap to
///         manufacture — empirically, 73.5%/59.2%/90.6% of ERC-8004 reviewers on
///         Ethereum/BSC/Base are coordinated Sybils (arXiv:2606.26028).
///
///         Syndicate replaces the claim with a price. Underwriters stake capital
///         behind a specific agent; a buyer binds cover on a single payment; the
///         quoted premium is the market's live assessment of that agent's
///         counterparty risk. A breach pays the buyer and the loss falls on the
///         underwriters.
///
///         Two properties follow that no reputation registry has:
///
///         1. Reputation cannot be forged. Loss experience is only ever written by
///            `submitReceipt`, which requires an ECDSA signature from the agent's
///            own runtime key over the executed payment.
///         2. Manipulation costs money. Inflating a record means funding real
///            premiums; attacking one means an underwriter absorbing real losses.
///
///         Verdicts are written through to the ERC-8004 Validation Registry, so
///         Syndicate extends the standard it critiques instead of sitting beside it.
contract Syndicate {
    // ---------------------------------------------------------------- constants

    uint256 public constant BPS = 10_000;

    /// @notice Floor rate charged even to a flawless, deep-pooled agent (0.50%).
    uint256 public constant BASE_RATE_BPS = 50;

    /// @notice Loading applied to agents with no observed history. Unproven is
    ///         expensive, not cheap — the inverse of a reputation registry, where
    ///         a fresh registration is indistinguishable from a trusted one.
    uint256 public constant UNPROVEN_LOAD_BPS = 900;

    /// @notice Trials required before loss experience is fully credible.
    uint256 public constant CREDIBILITY_TRIALS = 20;

    /// @notice Weight on observed failure ratio once fully credible.
    uint256 public constant FAILURE_LOAD_BPS = 6_000;

    /// @notice Weight on the agent pool's capacity utilisation.
    uint256 public constant UTILISATION_LOAD_BPS = 2_000;

    /// @notice Weight on correlated exposure to a single model family. See
    ///         `_concentrationLoad` for why this is the systemic term.
    uint256 public constant CONCENTRATION_LOAD_BPS = 4_000;

    /// @notice Quota-share treaty: the reinsurance book takes this share of every
    ///         policy's cover and premium, and carries the same share of any loss.
    uint256 public constant CESSION_BPS = 3_000;

    /// @notice Reference policy term. Rates are quoted for this term and scaled.
    uint256 public constant BASE_TERM_DAYS = 30;

    /// @notice Verdicts written to ERC-8004 for a settlement with no breach.
    uint8 public constant RESPONSE_CLEAN = 100;
    /// @notice Verdict written for a proven breach.
    uint8 public constant RESPONSE_BREACH = 0;

    string public constant VALIDATION_TAG = "syndicate.settlement";

    // ------------------------------------------------------------------- types

    struct Agent {
        /// Key the agent's runtime signs execution receipts with. Set once at
        /// registration; the agent cannot rotate it to escape its own history.
        address runtimeKey;
        /// Identity in the ERC-8004 Identity Registry, so verdicts written here
        /// are attributable to the same agent other protocols already know.
        uint256 erc8004Id;
        /// The base model or framework this agent runs on. Agents sharing a
        /// family fail together, which is what makes their risk correlated.
        bytes32 modelFamily;
        string endpoint;
        /// Underwriter capital dedicated to this agent — the junior tranche,
        /// which absorbs its retained share of every loss first.
        uint256 pool;
        uint256 shares;
        /// Retained cover outstanding (net of cession to the book).
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
        /// Portion of `cover` ceded to the reinsurance book.
        uint256 ceded;
        uint32 termDays;
        /// After this timestamp, silence from the agent is itself a breach.
        uint64 deadline;
        bool resolved;
    }

    // ------------------------------------------------------------------ storage

    mapping(bytes32 => Agent) public agents;
    mapping(bytes32 => mapping(address => uint256)) public sharesOf;
    mapping(uint256 => Policy) public policies;
    mapping(bytes32 => mapping(uint256 => bool)) public usedNonce;
    /// Job nonces the agent has already accepted — blocks replaying one
    /// acceptance signature across several policies.
    mapping(bytes32 => mapping(uint256 => bool)) public usedJobNonce;

    /// Cover outstanding per model family, across every agent. This is the
    /// quantity a per-agent pool structurally cannot see.
    mapping(bytes32 => uint256) public familyExposure;

    // --- Reinsurance book: shared, cross-agent, senior to every agent pool. ---

    uint256 public bookCapital;
    uint256 public bookShares;
    uint256 public bookExposure;
    mapping(address => uint256) public bookSharesOf;

    IValidationRegistry public immutable validationRegistry;

    uint256 public nextPolicyId = 1;

    // ------------------------------------------------------------------- events

    event AgentRegistered(
        bytes32 indexed agentId, uint256 indexed erc8004Id, address runtimeKey, bytes32 modelFamily, string endpoint
    );
    event Underwritten(bytes32 indexed agentId, address indexed underwriter, uint256 amount, uint256 shares);
    event Withdrawn(bytes32 indexed agentId, address indexed underwriter, uint256 shares, uint256 amount);
    event ReinsuranceDeposited(address indexed underwriter, uint256 amount, uint256 shares);
    event ReinsuranceWithdrawn(address indexed underwriter, uint256 shares, uint256 amount);
    event PolicyBound(
        uint256 indexed policyId,
        bytes32 indexed agentId,
        address indexed beneficiary,
        uint256 cover,
        uint256 premium,
        uint256 rateBps,
        uint256 ceded
    );
    event PolicyAccepted(uint256 indexed policyId, bytes32 indexed agentId, uint256 jobNonce, uint64 deadline);
    event ReceiptAccepted(uint256 indexed policyId, bytes32 indexed agentId, address actualRecipient, uint256 amount);
    event Expired(uint256 indexed policyId, bytes32 indexed agentId, uint64 deadline);
    event Breach(uint256 indexed policyId, bytes32 indexed agentId, address expectedRecipient, address actualRecipient);
    event ClaimPaid(uint256 indexed policyId, bytes32 indexed agentId, address indexed beneficiary, uint256 amount);
    event PoolSlashed(bytes32 indexed agentId, uint256 amount, uint256 poolAfter);
    event BookSlashed(bytes32 indexed agentId, uint256 amount, uint256 bookAfter);
    event ValidationWritten(bytes32 indexed agentId, uint256 indexed erc8004Id, bytes32 requestHash, uint8 response);

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
    error BadTerm();
    error NotExpired(uint64 deadline);

    constructor(address validationRegistry_) {
        validationRegistry = IValidationRegistry(validationRegistry_);
    }

    // --------------------------------------------------------------- registry

    function registerAgent(
        bytes32 agentId,
        uint256 erc8004Id,
        address runtimeKey,
        bytes32 modelFamily,
        string calldata endpoint
    ) external {
        Agent storage a = agents[agentId];
        if (a.registered) revert AlreadyRegistered();
        if (runtimeKey == address(0)) revert BadSignature();
        a.runtimeKey = runtimeKey;
        a.erc8004Id = erc8004Id;
        a.modelFamily = modelFamily;
        a.endpoint = endpoint;
        a.registered = true;
        emit AgentRegistered(agentId, erc8004Id, runtimeKey, modelFamily, endpoint);
    }

    // ------------------------------------------------------------ underwriting

    /// @notice Stake capital behind one agent — the junior tranche. Shares are
    ///         priced against the live pool, so a depositor joining after losses
    ///         buys in at the marked-down value.
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

    /// @notice Deposit into the shared reinsurance book — the senior tranche,
    ///         diversified across every agent. It earns a cession of all premium
    ///         and carries the same share of every loss.
    function depositReinsurance() external payable {
        if (msg.value == 0) revert ZeroAmount();
        uint256 issued = bookShares == 0 ? msg.value : (msg.value * bookShares) / bookCapital;
        bookShares += issued;
        bookCapital += msg.value;
        bookSharesOf[msg.sender] += issued;
        emit ReinsuranceDeposited(msg.sender, msg.value, issued);
    }

    function withdrawReinsurance(uint256 shareAmount) external {
        if (bookSharesOf[msg.sender] < shareAmount) revert InsufficientShares();
        uint256 value = (shareAmount * bookCapital) / bookShares;
        if (bookCapital - value < bookExposure) revert InsufficientCapacity();

        bookSharesOf[msg.sender] -= shareAmount;
        bookShares -= shareAmount;
        bookCapital -= value;

        (bool ok,) = msg.sender.call{value: value}("");
        require(ok, "transfer failed");
        emit ReinsuranceWithdrawn(msg.sender, shareAmount, value);
    }

    // ------------------------------------------------------------------ pricing

    /// @notice The rate the market charges to carry `cover` on this agent for
    ///         `termDays`, in bps. This is the trust signal: a price, not a score.
    function rateBps(bytes32 agentId, uint256 cover, uint256 termDays) public view returns (uint256) {
        Agent storage a = agents[agentId];
        if (!a.registered) revert UnknownAgent();
        if (termDays == 0) revert BadTerm();

        uint256 ceded = (cover * CESSION_BPS) / BPS;
        uint256 retained = cover - ceded;
        if (a.pool == 0 || a.pool < a.exposure + retained) revert InsufficientCapacity();
        if (bookCapital < bookExposure + ceded) revert InsufficientCapacity();

        // Idiosyncratic risk: this agent's own loss experience, credibility
        // weighted. With few trials the observed ratio is noisy, so it is blended
        // against the unproven loading rather than trusted outright — and a
        // brand-new agent cannot buy a clean record with two cheap successes.
        uint256 t = a.trials;
        uint256 observedBps = t == 0 ? 0 : (uint256(a.failures) * BPS) / t;
        uint256 credibility = t >= CREDIBILITY_TRIALS ? BPS : (t * BPS) / CREDIBILITY_TRIALS;

        uint256 risk = (observedBps * FAILURE_LOAD_BPS * credibility) / (BPS * BPS);
        risk += (UNPROVEN_LOAD_BPS * (BPS - credibility)) / BPS;

        // Capacity: a pool near its limit prices up.
        risk += (((a.exposure + retained) * BPS) / a.pool * UTILISATION_LOAD_BPS) / BPS;

        // Systemic: correlated exposure to this agent's model family.
        risk += _concentrationLoad(a.modelFamily, cover);

        // Term structure: risk accrues with exposure time, the floor does not.
        // A 90-day policy carries three times the chance of meeting a bad day.
        return BASE_RATE_BPS + (risk * termDays) / BASE_TERM_DAYS;
    }

    /// @notice Surcharge for correlated exposure to one model family.
    /// @dev The gap a per-agent pool cannot see. Agents sharing a base model share
    ///      its failure modes: one newly discovered injection technique against
    ///      that model breaches every agent built on it in the same afternoon.
    ///      Losses that a diversified book treats as independent arrive together,
    ///      so exposure concentrated in a single family is priced up. This is the
    ///      agent-economy analogue of writing every policy on one flood plain.
    function _concentrationLoad(bytes32 modelFamily, uint256 cover) private view returns (uint256) {
        if (bookCapital == 0) return CONCENTRATION_LOAD_BPS;
        uint256 share = ((familyExposure[modelFamily] + cover) * BPS) / bookCapital;
        if (share > BPS) share = BPS;
        // Quadratic in the concentration share: diversified books are barely
        // touched, and the surcharge bites hard as one family dominates.
        return (share * share * CONCENTRATION_LOAD_BPS) / (BPS * BPS);
    }

    function quote(bytes32 agentId, uint256 cover, uint256 termDays) public view returns (uint256) {
        return (cover * rateBps(agentId, cover, termDays)) / BPS;
    }

    /// @notice Convenience overloads quoting the reference 30-day term.
    function rateBps(bytes32 agentId, uint256 cover) external view returns (uint256) {
        return rateBps(agentId, cover, BASE_TERM_DAYS);
    }

    function quote(bytes32 agentId, uint256 cover) external view returns (uint256) {
        return quote(agentId, cover, BASE_TERM_DAYS);
    }

    // ------------------------------------------------------------------ policy

    /// @notice The digest an agent runtime signs to accept a job before cover is
    ///         bound on it.
    /// @dev Acceptance is what makes silence attributable. Without it, a buyer
    ///      could bind cover, never give the agent any work, wait for the deadline
    ///      and collect the full cover for the price of a premium — a larger hole
    ///      than the one the deadline closes. Requiring the agent's own signature
    ///      up front means every bound policy corresponds to work it took on.
    function acceptanceDigest(bytes32 agentId, uint256 jobNonce, address expectedRecipient, uint256 cover)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(block.chainid, address(this), "syndicate.accept", agentId, jobNonce, expectedRecipient, cover)
        );
    }

    /// @notice Bind cover on a single upcoming payment to `expectedRecipient`.
    /// @param jobNonce Buyer-chosen identifier for the job, signed by the agent.
    /// @param acceptance Agent runtime's signature over `acceptanceDigest`.
    function bindPolicy(
        bytes32 agentId,
        address expectedRecipient,
        uint256 cover,
        uint256 termDays,
        uint256 jobNonce,
        bytes calldata acceptance
    ) public payable returns (uint256 policyId) {
        Agent storage a = agents[agentId];
        if (!a.registered) revert UnknownAgent();
        if (cover == 0) revert ZeroAmount();

        if (usedJobNonce[agentId][jobNonce]) revert NonceUsed();
        bytes32 accepted = acceptanceDigest(agentId, jobNonce, expectedRecipient, cover);
        if (_recover(_ethSigned(accepted), acceptance) != a.runtimeKey) revert BadSignature();
        usedJobNonce[agentId][jobNonce] = true;

        uint256 rate = rateBps(agentId, cover, termDays);
        uint256 premium = (cover * rate) / BPS;
        if (msg.value != premium) revert PremiumMismatch(premium, msg.value);

        uint256 ceded = (cover * CESSION_BPS) / BPS;
        uint256 cededPremium = (premium * CESSION_BPS) / BPS;

        // Premium is split on the same quota share as the risk: the book is paid
        // for the losses it agrees to carry.
        a.pool += premium - cededPremium;
        bookCapital += cededPremium;

        a.exposure += cover - ceded;
        bookExposure += ceded;
        familyExposure[a.modelFamily] += cover;

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            agentId: agentId,
            beneficiary: msg.sender,
            expectedRecipient: expectedRecipient,
            cover: cover,
            premium: premium,
            ceded: ceded,
            termDays: uint32(termDays),
            deadline: uint64(block.timestamp + termDays * 1 days),
            resolved: false
        });

        emit PolicyBound(policyId, agentId, msg.sender, cover, premium, rate, ceded);
        emit PolicyAccepted(policyId, agentId, jobNonce, uint64(block.timestamp + termDays * 1 days));
        _requestValidation(agentId, policyId);
    }

    function bindPolicy(
        bytes32 agentId,
        address expectedRecipient,
        uint256 cover,
        uint256 jobNonce,
        bytes calldata acceptance
    ) external payable returns (uint256) {
        return bindPolicy(agentId, expectedRecipient, cover, BASE_TERM_DAYS, jobNonce, acceptance);
    }

    /// @notice The digest an agent runtime must sign for a payment receipt.
    function receiptDigest(uint256 policyId, address actualRecipient, uint256 amount, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), policyId, actualRecipient, amount, nonce));
    }

    /// @notice Stable handle for a policy's ERC-8004 validation record.
    function validationRequestHash(uint256 policyId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), "syndicate.policy", policyId));
    }

    /// @notice Submit the agent's signed record of what it actually paid, and to whom.
    /// @dev The only path that writes loss experience, and it demands a signature
    ///      from the agent's own runtime key — the grounding that arXiv:2606.26028
    ///      found missing from the ERC-8004 Reputation Registry. A breach settles
    ///      atomically, so the price and the payout can never disagree.
    function submitReceipt(
        uint256 policyId,
        address actualRecipient,
        uint256 amount,
        uint256 nonce,
        bytes calldata signature
    ) external {
        Policy storage p = policies[policyId];
        if (p.cover == 0 || p.resolved) revert PolicyResolved();

        Agent storage a = agents[p.agentId];
        if (usedNonce[p.agentId][nonce]) revert NonceUsed();

        bytes32 digest = receiptDigest(policyId, actualRecipient, amount, nonce);
        if (_recover(_ethSigned(digest), signature) != a.runtimeKey) revert BadSignature();

        usedNonce[p.agentId][nonce] = true;
        p.resolved = true;

        uint256 retained = p.cover - p.ceded;
        a.exposure -= retained;
        bookExposure -= p.ceded;
        familyExposure[a.modelFamily] -= p.cover;
        a.trials += 1;

        emit ReceiptAccepted(policyId, p.agentId, actualRecipient, amount);

        bool breached = actualRecipient != p.expectedRecipient;
        if (breached) {
            emit Breach(policyId, p.agentId, p.expectedRecipient, actualRecipient);
            _payClaim(policyId, p, a, retained);
        }

        _respondValidation(p.agentId, policyId, breached ? RESPONSE_BREACH : RESPONSE_CLEAN, digest);
    }

    /// @notice Resolve a policy whose agent never accounted for the payment.
    /// @dev The failure mode a receipt alone cannot cover. An agent that has been
    ///      fully compromised does not sign an incriminating receipt — it goes
    ///      quiet, and without this the policy would sit unresolved forever with
    ///      the buyer uncovered and the underwriters' capital locked.
    ///
    ///      Silence is therefore treated as a breach. That is only fair because
    ///      the agent signed an acceptance at bind time: every policy corresponds
    ///      to work it took on, so failing to account for it is non-performance,
    ///      not absence of a job.
    ///
    ///      Permissionless: anyone may call it, because everyone with capital at
    ///      stake wants stale exposure cleared, and the outcome is fixed by the
    ///      deadline rather than by who calls.
    function resolveExpired(uint256 policyId) external {
        Policy storage p = policies[policyId];
        if (p.cover == 0 || p.resolved) revert PolicyResolved();
        if (block.timestamp <= p.deadline) revert NotExpired(p.deadline);

        Agent storage a = agents[p.agentId];
        uint256 retained = p.cover - p.ceded;

        p.resolved = true;
        a.exposure -= retained;
        bookExposure -= p.ceded;
        familyExposure[a.modelFamily] -= p.cover;
        a.trials += 1;

        emit Expired(policyId, p.agentId, p.deadline);
        _payClaim(policyId, p, a, retained);
        _respondValidation(p.agentId, policyId, RESPONSE_BREACH, bytes32(0));
    }

    /// @dev Quota share in the loss direction: the junior tranche pays its
    ///      retention, the book pays its cession, each capped by what it holds.
    function _payClaim(uint256 policyId, Policy storage p, Agent storage a, uint256 retained) private {
        a.failures += 1;

        uint256 fromPool = retained > a.pool ? a.pool : retained;
        uint256 fromBook = p.ceded > bookCapital ? bookCapital : p.ceded;

        a.pool -= fromPool;
        bookCapital -= fromBook;
        emit PoolSlashed(p.agentId, fromPool, a.pool);
        emit BookSlashed(p.agentId, fromBook, bookCapital);

        uint256 payout = fromPool + fromBook;
        (bool ok,) = p.beneficiary.call{value: payout}("");
        require(ok, "payout failed");
        emit ClaimPaid(policyId, p.agentId, p.beneficiary, payout);
    }

    // ------------------------------------------------------------- ERC-8004 I/O

    function _requestValidation(bytes32 agentId, uint256 policyId) private {
        if (address(validationRegistry) == address(0)) return;
        validationRegistry.validationRequest(
            address(this), agents[agentId].erc8004Id, "syndicate://policy", validationRequestHash(policyId)
        );
    }

    /// @dev Writes the settlement outcome back to the ERC-8004 Validation Registry
    ///      so any agent already reading the standard sees a verdict that is
    ///      backed by capital rather than by an unaccountable review.
    function _respondValidation(bytes32 agentId, uint256 policyId, uint8 response, bytes32 receiptHash) private {
        if (address(validationRegistry) == address(0)) return;
        bytes32 requestHash = validationRequestHash(policyId);
        validationRegistry.validationResponse(requestHash, response, "syndicate://settlement", receiptHash, VALIDATION_TAG);
        emit ValidationWritten(agentId, agents[agentId].erc8004Id, requestHash, response);
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

    function bookStats() external view returns (uint256 capital, uint256 exposure, uint256 shares) {
        return (bookCapital, bookExposure, bookShares);
    }

    function shareValue(bytes32 agentId, address underwriter) external view returns (uint256) {
        Agent storage a = agents[agentId];
        if (a.shares == 0) return 0;
        return (sharesOf[agentId][underwriter] * a.pool) / a.shares;
    }

    function reinsuranceValue(address underwriter) external view returns (uint256) {
        if (bookShares == 0) return 0;
        return (bookSharesOf[underwriter] * bookCapital) / bookShares;
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
