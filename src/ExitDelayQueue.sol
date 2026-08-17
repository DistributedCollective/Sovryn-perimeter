// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IExitDelayQueue} from "./interfaces/IExitDelayQueue.sol";

/// @notice Minimal WRBTC (wrapped-RBTC) surface. `unwrapOnDelivery` requests
///         hold WRBTC and unwrap to native RBTC at `executeExit` (Option B).
interface IWRBTC {
    function withdraw(uint256 amount) external;
}

/// @title  ExitDelayQueue
/// @notice Per-request escrow for the *user* leg of an exit. Each exit becomes
///         an immutable request with its own monotonic id; execution targets
///         explicit ids (no cursor, no ordering assumption). During the delay,
///         a detected theft can be Frozen/Blacklisted and disposed via the
///         three recovery legs. UUPS-upgradeable, mirroring the
///         `ExitFeeVault` skeleton.
///
///         Authoritative build spec:
///         The invariants are enumerated with the properties below and
///         pinned by the forge invariant suite.
///
///         Two-principal authority: `Owner` (Ownable2Step) holds UUPS
///         upgrade + all security-critical CONFIG; `Admin` (a single stored
///         address, `onlyAdminOrOwner`) is the fast guardian — freeze/blacklist,
///         pause, Leg-1 release, Leg-2 along Owner-approved routes. `Admin ≠
///         Owner` is the one hard separation.
//
// The queue custodies escrowed RBTC/ERC20/WRBTC by design; the only value-in
// path is the gated ingress (record*/receive()), and value-out is CEI-ordered
// behind nonReentrant. aderyn's "contract-locks-ether" is intentional here.
// aderyn-ignore-next-line(contract-locks-ether)
contract ExitDelayQueue is
    IExitDelayQueue,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ─── Storage layout ──────────────────────────────────────────
    // Verified via `forge inspect ExitDelayQueue storageLayout`. Inherited-OZ
    // namespaces occupy proxy slots 0..300 (Initializable/Context/Ownable/
    // Ownable2Step/ReentrancyGuard, each with a 50-slot __gap; UUPS/Context add
    // no fields). This contract's own slot 0 sits at proxy slot 301:
    //
    //   301  admin (address; the Admin guardian — 1 slot, no OZ AccessControl)
    //   302  lastRequestId (uint256)
    //   303  _requests (mapping head)
    //   304  _activeByParty (mapping head)
    //   305  _recoveryRoutes (mapping head)
    //   306  _recoveryRouteIds._values (Bytes32Set array head)   ┐ 2 slots
    //   307  _recoveryRouteIds._indexes (mapping head)           ┘
    //   308  _topUpFeasible (mapping head)
    //   309  _blockState (mapping head)
    //   310  _blockedAccounts._values (AddressSet array head)    ┐ 2 slots
    //   311  _blockedAccounts._indexes (mapping head)            ┘
    //   312  _blockTrigger (mapping head)
    //   313  _allowedSource (mapping head)
    //   314  _allowedSources._values (AddressSet array head)     ┐ 2 slots
    //   315  _allowedSources._indexes (mapping head)             ┘
    //   316  _totalEscrowed (mapping head)
    //   317  nativePusher (address)         ┐ address(20) + uint32(4) + bool(1)
    //        minimumDelaySeconds (uint32)   │ = 25 bytes → PACKED into one slot
    //        securityPerimeterPaused (bool) ┘
    //   318  wrbtc (address; canonical WRBTC — own slot)
    //   319 .. 350  __gap[32]  (50 − 18 own slots)
    //
    // own_slots = 18 (admin, lastRequestId, 8 mapping heads, 3 EnumerableSet ×2,
    // the packed nativePusher+minimumDelaySeconds+securityPerimeterPaused slot,
    // and wrbtc). __gap = 50 − 18 = 32. Re-derive at build time with
    // `forge inspect ExitDelayQueue storageLayout` before any deployment and
    // set __gap accordingly. Upgrades adding storage MUST consume from __gap.
    //
    // Stuck-exit recovery redesign the
    // markPayoutFailed / _payoutFailed recovery marker AND the earlier
    // executeExit(id, altReceiver) redirect overload were BOTH removed. A bouncing
    // honest recipient is handled self-service by {originator, owner} via the
    // dedicated recoverStuckExit(id, altReceiver) leg — which attempts the STORED
    // receiver FIRST and pays altReceiver only on a genuine bounce (verify-by-
    // attempting; a healthy exit is NEVER redirected). No stored failure flag, no
    // admin/Owner recovery path, no request re-targeting. The all-four-actor
    // block gate covers the STORED receiver so a blocked original receiver
    // refuses recovery and falls to Leg-3. The freed marker slot returns to __gap
    // (restoring the pre-marker layout, still 32).

    /// @notice Fast operational guardian. Not an OZ AccessControl role —
    ///         a single stored address checked by `onlyAdminOrOwner`. MUST be
    ///         distinct from the Owner for the authority bounds to
    ///         hold; enforced at `initialize` and `setAdmin`.
    address public admin;

    /// @notice Monotonic id source; ids are never reused. The first
    ///         recorded id is 1 (0 is reserved as "no request" / arbitrary block).
    uint256 public lastRequestId;

    mapping(uint256 => ExitRequest) internal _requests;

    /// @dev Executor party (originator, owner) → status==Queued request ids.
    ///      A freeze HOLDS but does not remove (Frozen is an address state, not
    ///      a request status). Dual-key when originator != owner. No
    ///      on-chain path iterates the full set — only O(1) add/remove and the
    ///      paginated `getActive` view touch it.
    mapping(address => EnumerableSet.UintSet) internal _activeByParty;

    mapping(bytes32 => RecoveryRoute) internal _recoveryRoutes;
    EnumerableSet.Bytes32Set internal _recoveryRouteIds;

    /// @dev surfaceId → may a topUpPool=true route be registered? Owner-set;
    ///      true only for lending-lender/borrower surfaces at launch.
    mapping(bytes32 => bool) internal _topUpFeasible;

    /// @dev Execution & recovery treat Frozen and Blacklisted alike as "blocked";
    ///      recovery-away distinguishes them.
    mapping(address => BlockState) internal _blockState;
    EnumerableSet.AddressSet internal _blockedAccounts; // Frozen ∪ Blacklisted, for getters

    /// @dev addr → exit-request id that triggered the block (0 = arbitrary block).
    mapping(address => uint256) internal _blockTrigger;

    mapping(address => bool) internal _allowedSource;
    EnumerableSet.AddressSet internal _allowedSources;

    /// @dev token => Σ amounts of Queued requests (solvency).
    ///      address(0) = native RBTC. Exposed via the `totalEscrowed(address)`
    ///      view (not a public auto-getter so the interface signature is exact).
    mapping(address => uint256) internal _totalEscrowed;

    /// @notice The single registered native pusher (Zero `ActivePool`), Owner-set.
    ///         NOTE: `receive()` is now UNCONDITIONAL and no longer reads
    ///         this slot — the pusher is no longer a `receive()`-time gate. The
    ///         field + setter are RETAINED (unchanged ABI/packing, so `__gap`
    ///         stays 32) as documented provenance of the intended native source;
    ///         `_allowedSource` still gates the record CALLER at ingress.
    address public nativePusher;

    /// @notice F1 floor enforced PER-REQUEST at ingress. Packs with
    ///         nativePusher + securityPerimeterPaused.
    uint32 public minimumDelaySeconds;

    /// @notice Pauses executeExit(s) ONLY; ingress + recovery stay live.
    ///         Packs with nativePusher (address) + minimumDelaySeconds (uint32).
    bool public securityPerimeterPaused;

    /// @notice Canonical WRBTC address. Set at initialize; used only to
    ///         guard the `unwrapOnDelivery` flag and to unwrap at delivery. A
    ///         full own slot (slot 318 in the layout note above), so __gap is
    ///         50 − 18 = 32. Re-derive via `forge inspect` before deployment.
    address public wrbtc;

    // aderyn-ignore-next-line(unused-state-variable)
    uint256[32] private __gap;

    /// @notice Max page size for the paginated `getActive` / `blockedAccounts`
    ///         views. Public so paging is
    ///         self-describing on-chain — a caller can read the cap instead of
    ///         hard-coding 500 and discovering the clamp empirically.
    uint256 public constant MAX_GET_ACTIVE_PAGE = 500;

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyAdminOrOwner() {
        if (msg.sender != admin && msg.sender != owner()) revert NotAdminOrOwner(msg.sender);
        _;
    }

    modifier onlyAllowedSource() {
        if (!_allowedSource[msg.sender]) revert UnregisteredSource(msg.sender);
        _;
    }

    error NotAdminOrOwner(address caller);
    error OwnershipCannotBeRenounced();
    error UpgradeImplZero();

    // ─── Construction / initialization ──────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Deployer becomes the initial Owner; the
    ///         bootstrap flow then `transferOwnership` → the governance Owner.
    /// @param owner_ Owner principal (0 or msg.sender ⇒ deployer stays owner).
    /// @param admin_ Fast guardian; non-zero. MAY equal the owner (
    ///        retired, deliberate: launch shape is admin = owner
    ///        = governance Safe; the split becomes a real authority bound only
    ///        when ownership later moves to Bitocracy).
    /// @param wrbtc_ Canonical WRBTC token. Must be non-zero.
    /// @param minimumDelaySeconds_ Per-request delay floor.
    /// @param initialAllowedSources Hooked source contracts.
    function initialize(
        address owner_,
        address admin_,
        address wrbtc_,
        uint32 minimumDelaySeconds_,
        address[] calldata initialAllowedSources
    ) external initializer {
        __Ownable_init();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (wrbtc_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        wrbtc = wrbtc_;

        admin = admin_;

        minimumDelaySeconds = minimumDelaySeconds_;

        for (uint256 i = 0; i < initialAllowedSources.length; ++i) {
            address src = initialAllowedSources[i];
            if (src == address(0)) revert ZeroAddress();
            if (_allowedSources.add(src)) {
                _allowedSource[src] = true;
                emit AllowedSourceSet(src, true);
            }
        }

        if (owner_ != address(0) && owner_ != msg.sender) {
            _transferOwnership(owner_);
        }
    }

    // ─── Ingress ──────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    function recordERC20Exit(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver,
        bool unwrapOnDelivery
    ) external nonReentrant onlyAllowedSource returns (uint256 id) {
        //  guard: the delivery-time unwrap can only be set on WRBTC escrow.
        if (unwrapOnDelivery && token != wrbtc) revert UnwrapNonWrbtc();
        _validateIngress(token, amount, delaySeconds, effOrig, effOwner, receiver);

        // ERC20 pull with receipt proof (High-3): measure before/after so a
        // fee-on-transfer/rebasing token cannot silently mis-escrow.
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert ReceivedAmountMismatch(token, received, amount);

        id = _record(
            token, amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, unwrapOnDelivery
        );
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Measured-delta path (0.5.x): the source pushes `amount` and records
    ///      in the SAME outer tx. We measure the current non-backing surplus
    ///      `delta = balanceOf − totalEscrowed` and require `delta >= amount`:
    ///      the record CONSUMES exactly `amount` into
    ///      totalEscrowed; any excess (pre-existing dust, a force-sent/donated
    ///      1-wei, another source's surplus) stays as non-backing surplus for
    ///      sweepSurplus and is NEVER mis-credited. The earlier `== amount` exact
    ///      rule was donation-griefable — a 1-wei force-send permanently reverted
    ///      every subsequent record. Because push and record are atomic in one
    ///      outer tx, there is no interleaved-push residual to protect against,
    ///      and a donation only RAISES the surplus, so `>= amount` still passes.
    function recordReceivedERC20Exit(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external nonReentrant onlyAllowedSource returns (uint256 id) {
        _validateIngress(token, amount, delaySeconds, effOrig, effOwner, receiver);

        // Non-backing surplus = (current backing balance) − (already-escrowed).
        // Require it covers `amount` (delta >= amount). Revert only when
        // the push under-delivered (delta < amount ⇒ ReceivedAmountMismatch).
        // Excess over `amount` is left as sweepable surplus (never mis-credited).
        uint256 backing = IERC20(token).balanceOf(address(this));
        uint256 escrowed = _totalEscrowed[token];
        uint256 delta = backing > escrowed ? backing - escrowed : 0;
        if (delta < amount) revert ReceivedAmountMismatch(token, delta, amount);

        id = _record(token, amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, false);
    }

    /// @inheritdoc IExitDelayQueue
    function recordNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external payable nonReentrant onlyAllowedSource returns (uint256 id) {
        if (msg.value != amount) revert AmountMismatch(msg.value, amount);
        _validateIngress(address(0), amount, delaySeconds, effOrig, effOwner, receiver);
        id = _record(
            address(0), amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, false
        );
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Native measured-receipt (Zero): `ActivePool.sendETH(queue, amount)`
    ///      pushes value (via `receive()`) BEFORE this record in the same outer
    ///      tx; a record revert rolls the push back (fail-closed). Same
    ///       rule as the ERC20 measured path: require the non-backing
    ///      surplus `delta >= amount` and credit exactly `amount`. The
    ///      `receive()` gate cannot stop a `selfdestruct` force-send, which is
    ///      exactly why crediting must tolerate surplus (`>= amount`) rather than
    ///      require an exact balance — a force-sent 1-wei must not
    ///      permanently brick every subsequent Zero exit record.
    function recordReceivedNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external nonReentrant onlyAllowedSource returns (uint256 id) {
        _validateIngress(address(0), amount, delaySeconds, effOrig, effOwner, receiver);
        uint256 backing = address(this).balance;
        uint256 escrowed = _totalEscrowed[address(0)];
        uint256 delta = backing > escrowed ? backing - escrowed : 0;
        if (delta < amount) revert ReceivedAmountMismatch(address(0), delta, amount);
        id = _record(
            address(0), amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, false
        );
    }

    /// @notice UNCONDITIONAL native-RBTC sink. Accepts
    ///         native from ANYONE with **no storage reads and no sender gate**.
    ///
    ///         Why unconditional: the real Rootstock WRBTC `withdraw()` returns
    ///         native via a 2300-gas `transfer` stipend. Any storage-slot sender
    ///         check here (SLOAD ≥ 2100 cold under EIP-2929/Paris) exceeds that
    ///         stipend, so a sender-gated `receive()` `OutOfGas`-bricks every
    ///         `unwrapOnDelivery` (native `burnToBTC`) payout after unlock —
    ///         empirically reproduced (`ExitDelayQueueUnwrapStipend`). Dropping
    ///         the gate is SAFE because the already neutralizes stray or
    ///         donated native: the two measured-receipt ingress paths credit
    ///         EXACTLY `amount` when the non-backing surplus `>= amount` and never
    ///         mis-credit, so unsolicited RBTC (including a `selfdestruct`
    ///         force-send the old gate could not stop anyway) only accrues as
    ///         `sweepSurplus`-able surplus. Accepted trade-off: the queue no
    ///         longer asserts "only ActivePool pays in native" — defense-in-depth
    ///         the made redundant.
    receive() external payable virtual {}

    // ─── Ingress helpers ────────────────────────────────────────────────

    function _validateIngress(
        address, /*token — reserved for future per-token gating*/
        uint128 amount,
        uint32 delaySeconds,
        address effOrig,
        address effOwner,
        address receiver
    ) internal view {
        if (amount == 0) revert ZeroAmount();
        // AmountTooLarge: the record* ABI takes `amount` as uint128
        // deliberately (keeps ExitRequest word-1 packing). The uint256→
        // uint128 narrowing therefore happens in the CALLER (the ColFee hook /
        // 0.5.x product host), which MUST `require(userAmount <= type(uint128).max)
        // else AmountTooLarge` BEFORE narrowing — that check is the live
        // queue-boundary guard, in the caller's pragma, against silent truncation
        // (IExitDelayQueue NatSpec). The queue re-asserting it on an already-
        // uint128 arg would be a compile-time tautology, so the guard is kept at
        // the boundary where a uint256 actually exists, not duplicated as dead code
        // here. We still reject a below-floor delay and zero-address parties.
        if (delaySeconds < minimumDelaySeconds) revert DelayBelowFloor(delaySeconds, minimumDelaySeconds);
        if (effOrig == address(0) || effOwner == address(0) || receiver == address(0)) revert ZeroAddress();
    }

    function _record(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver,
        bool unwrapOnDelivery
    ) internal returns (uint256 id) {
        id = ++lastRequestId;

        // Write field-by-field into storage to keep the stack shallow (a struct
        // literal with 11 members + the 9-arg event blows the 0.8.20 stack
        // without via-ir; this repo pins non-via-ir to match the deployed
        // ColFee bytecode profile).
        ExitRequest storage r = _requests[id];
        r.amount = amount;
        r.createdAt = uint64(block.timestamp);
        r.unlockAt = uint64(block.timestamp + delaySeconds);
        r.originator = effOrig;
        r.owner = effOwner;
        r.receiver = receiver;
        r.token = token;
        r.surfaceId = surfaceId;
        r.subProduct = subProduct;
        r.status = ExitStatus.Queued;
        r.unwrapOnDelivery = unwrapOnDelivery;

        // Dual-key insert; EnumerableSet dedups when originator == owner.
        _activeByParty[effOrig].add(id);
        _activeByParty[effOwner].add(id);

        _totalEscrowed[token] += amount;

        emit ExitQueued(id, effOrig, effOwner, receiver, token, amount, r.unlockAt, surfaceId, subProduct);
    }

    // ─── Execution ───────────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    /// @dev Pays the request's immutable `receiver`. A reverting receiver rolls
    ///      the whole call back (fail-closed) — the request stays Queued and
    ///      the rightful parties retry via `executeExit` (once the recipient is
    ///      fixed) or `recoverStuckExit` (redirect leg). No redirect here.
    function executeExit(uint256 requestId) external nonReentrant {
        _executeOne(requestId);
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Strict array order; atomic (any revert rolls the whole batch back).
    ///      A duplicate id flips to Executed on the first pass, then
    ///      hits AlreadyTerminal on the second — never double-pays. Always pays
    ///      the immutable receiver (no redirect in the batch path).
    function executeExits(uint256[] calldata ids) external nonReentrant {
        if (ids.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < ids.length; ++i) {
            _executeOne(ids[i]);
        }
    }

    /// @dev Shared execution core — always pays the immutable `receiver`.
    ///      Block gate covers `{originator, owner, receiver}`. CEI: terminal
    ///      status + escrow decrement + set removal ALL before the external transfer
    ///      (`nonReentrant`).
    function _executeOne(uint256 requestId) internal {
        if (securityPerimeterPaused) revert QueuePaused();
        ExitRequest storage r = _requests[requestId];
        if (r.status == ExitStatus.None) revert UnknownRequest(requestId);
        if (r.status != ExitStatus.Queued) revert AlreadyTerminal(requestId);
        if (block.timestamp < r.unlockAt) revert NotUnlocked(requestId, r.unlockAt);
        if (msg.sender != r.originator && msg.sender != r.owner) revert NotExecutor(msg.sender);

        _requireNotBlocked(r.originator);
        _requireNotBlocked(r.owner);
        _requireNotBlocked(r.receiver);

        address token = r.token;
        uint128 amount = r.amount;
        address receiver = r.receiver;
        bool unwrap = r.unwrapOnDelivery;

        r.status = ExitStatus.Executed;
        _removeActive(requestId, r.originator, r.owner);
        _totalEscrowed[token] -= amount;

        emit ExitExecuted(requestId, receiver, token, amount);
        _payout(token, receiver, amount, unwrap);
    }

    // ─── Stuck-exit recovery — verify-by-attempting redirect leg ──

    /// @inheritdoc IExitDelayQueue
    /// @dev Stuck-exit recovery redesign.
    ///      A bouncing honest recipient is not a perimeter-specific problem (the
    ///      same withdrawal would bounce without the delay), so recovery is
    ///      SELF-SERVICE by the frozen-metadata `{originator, owner}` set (the
    ///      receiver is NEVER an executor) — no admin/Owner path, NO stored failure
    ///      flag, and the stored request is NEVER re-targeted (`altReceiver` is a
    ///      payout-time destination only, so + hold).
    ///
    ///      VERIFY-BY-ATTEMPTING: after CEI (status → Executed, escrow decremented,
    ///      sets pruned), the STORED-receiver payout is attempted FIRST. If it
    ///      SUCCEEDS, that is the payout and `altReceiver` is unused — a HEALTHY
    ///      exit is NEVER redirected (no arbitrary redirect; Model-B stays
    ///      rejected). Only if the stored-receiver payout genuinely REVERTS do we
    ///      pay `altReceiver`; if `altReceiver` also fails, the whole call reverts
    ///      and the funds stay Queued (CEI rollback).
    ///
    ///      ALL-FOUR-ACTOR block gate: none of `{originator, owner, STORED
    ///      receiver, altReceiver}` may be Frozen/Blacklisted. Gating the STORED
    ///      receiver is the must-fix — a blocked/hacked original receiver refuses
    ///      recovery entirely (this leg can never move its funds), keeping the
    ///      blacklist-trap and the / receiver-only dead-end intact (that case
    ///      is Leg-3's). `altReceiver` is guarded: not 0/this/token/wrbtc.
    function recoverStuckExit(uint256 id, address altReceiver) external nonReentrant {
        if (securityPerimeterPaused) revert QueuePaused();
        ExitRequest storage r = _requests[id];
        if (r.status == ExitStatus.None) revert UnknownRequest(id);
        if (r.status != ExitStatus.Queued) revert AlreadyTerminal(id);
        if (block.timestamp < r.unlockAt) revert NotUnlocked(id, r.unlockAt);
        if (msg.sender != r.originator && msg.sender != r.owner) revert NotExecutor(msg.sender);

        address token = r.token;
        address receiver = r.receiver;

        // altReceiver guard: a payout-time destination, never the zero
        // address, this contract (would trap escrow), the escrowed token, or WRBTC
        // (a wrapped-token destination would silently swallow an unwrap payout).
        if (
            altReceiver == address(0) || altReceiver == address(this) || altReceiver == token
                || altReceiver == wrbtc
        ) revert InvalidAltReceiver(altReceiver);

        // All-four-actor block gate: originator, owner, the STORED receiver,
        // and altReceiver must all be unblocked. Gating the STORED receiver means a
        // blocked/hacked original receiver refuses recovery here (→ Leg-3).
        _requireNotBlocked(r.originator);
        _requireNotBlocked(r.owner);
        _requireNotBlocked(receiver);
        _requireNotBlocked(altReceiver);

        // CEI: terminal status + escrow decrement + set removal BEFORE
        // any external transfer, so a failed attempt or reentry cannot double-spend.
        uint128 amount = r.amount;
        bool unwrap = r.unwrapOnDelivery;

        r.status = ExitStatus.Executed;
        _removeActive(id, r.originator, r.owner);
        _totalEscrowed[token] -= amount;

        // Attempt the STORED-receiver payout first (a healthy exit pays here and
        // altReceiver is never used, even when altReceiver == receiver). Only on a
        // GENUINE bounce do we fall through to altReceiver — tracked by an explicit
        // bool, NOT an address compare, so a request whose stored receiver equals
        // altReceiver is paid exactly ONCE.
        address paid;
        if (_tryPayout(token, receiver, amount, unwrap)) {
            paid = receiver;
        } else {
            // Original bounced — pay altReceiver; if THIS also fails, the whole call
            // reverts (CEI rollback leaves the request Queued).
            _payout(token, altReceiver, amount, unwrap);
            paid = altReceiver;
        }
        emit ExitExecuted(id, paid, token, amount);
    }

    /// @dev Catchable single-payout attempt for `recoverStuckExit`. Routes the
    ///      transfer through an EXTERNAL self-call so a reverting recipient is
    ///      caught (Solidity cannot catch a low-level revert inline) and the leg
    ///      can fall through to `altReceiver`. Returns false on any failure.
    ///      Self-only (`msg.sender == address(this)`); NOT `nonReentrant` — it runs
    ///      inside `recoverStuckExit`'s guard, and CEI already made the state safe.
    function _tryPayout(address token, address to, uint128 amount, bool unwrap) internal returns (bool) {
        try this.payoutExternal(token, to, amount, unwrap) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Internal payout trampoline — only callable by the contract itself
    ///         (via `_tryPayout`). Reverts on a bouncing recipient so the caller's
    ///         try/catch can fall through. Not part of the external ABI surface for
    ///         any other caller (the `SelfOnly` guard makes a direct call revert).
    function payoutExternal(address token, address to, uint128 amount, bool unwrap) external {
        if (msg.sender != address(this)) revert SelfOnly();
        _payout(token, to, amount, unwrap);
    }

    // ─── Block model ──────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    function freezeFromRequest(uint256 requestId, bool freezeReceiver, bytes32 reasonHash)
        external
        onlyAdminOrOwner
    {
        _blockFromRequest(requestId, freezeReceiver, reasonHash, BlockState.Frozen);
    }

    /// @inheritdoc IExitDelayQueue
    function blacklistFromRequest(uint256 requestId, bool freezeReceiver, bytes32 reasonHash)
        external
        onlyAdminOrOwner
    {
        _blockFromRequest(requestId, freezeReceiver, reasonHash, BlockState.Blacklisted);
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Batch by-request-id. Resolves each
    ///      request's `{originator, owner}` (+ `receiver` if `freezeReceiver`) and
    ///      blocks all in ONE tx. Whole-batch ATOMIC: one unknown id reverts the
    ///      whole batch (like `executeExits`). Last-write-wins trigger/reason per
    ///       The emergency speed lever: block every owner + delegate behind a
    ///      set of known-malicious requests in a single Admin-multisig call.
    function freezeFromRequest(uint256[] calldata requestIds, bool freezeReceiver, bytes32 reasonHash)
        external
        onlyAdminOrOwner
    {
        if (requestIds.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _blockFromRequest(requestIds[i], freezeReceiver, reasonHash, BlockState.Frozen);
        }
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Batch by-request-id blacklist. Same atomicity + last-write-
    ///      wins semantics as the batch freeze above; a Frozen→Blacklisted
    ///      escalation within a batch is handled by `_setBlock`.
    function blacklistFromRequest(uint256[] calldata requestIds, bool freezeReceiver, bytes32 reasonHash)
        external
        onlyAdminOrOwner
    {
        if (requestIds.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _blockFromRequest(requestIds[i], freezeReceiver, reasonHash, BlockState.Blacklisted);
        }
    }

    function _blockFromRequest(uint256 requestId, bool freezeReceiver, bytes32 reasonHash, BlockState to)
        internal
    {
        ExitRequest storage r = _requests[requestId];
        if (r.status == ExitStatus.None) revert UnknownRequest(requestId);
        // originator always; owner too iff distinct; receiver only if flagged.
        _setBlock(r.originator, to, requestId, reasonHash);
        if (r.owner != r.originator) _setBlock(r.owner, to, requestId, reasonHash);
        if (freezeReceiver) _setBlock(r.receiver, to, requestId, reasonHash);
    }

    /// @inheritdoc IExitDelayQueue
    function freeze(address a) external onlyAdminOrOwner {
        _setBlock(a, BlockState.Frozen, 0, bytes32(0));
    }

    /// @inheritdoc IExitDelayQueue
    function blacklist(address a) external onlyAdminOrOwner {
        _setBlock(a, BlockState.Blacklisted, 0, bytes32(0));
    }

    /// @inheritdoc IExitDelayQueue
    function unfreeze(address a) external onlyAdminOrOwner {
        _clearBlock(a, BlockState.Frozen);
    }

    /// @inheritdoc IExitDelayQueue
    function unblacklist(address a) external onlyAdminOrOwner {
        _clearBlock(a, BlockState.Blacklisted);
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev EmptyIds guard: an empty array is a caller mistake, not a
    ///      silent no-op — for consistency with the by-id batch variants.
    function freeze(address[] calldata a) external onlyAdminOrOwner {
        if (a.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < a.length; ++i) {
            _setBlock(a[i], BlockState.Frozen, 0, bytes32(0));
        }
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev EmptyIds guard.
    function blacklist(address[] calldata a) external onlyAdminOrOwner {
        if (a.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < a.length; ++i) {
            _setBlock(a[i], BlockState.Blacklisted, 0, bytes32(0));
        }
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev EmptyIds guard.
    function unfreeze(address[] calldata a) external onlyAdminOrOwner {
        if (a.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < a.length; ++i) {
            _clearBlock(a[i], BlockState.Frozen);
        }
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev EmptyIds guard.
    function unblacklist(address[] calldata a) external onlyAdminOrOwner {
        if (a.length == 0) revert EmptyIds();
        for (uint256 i = 0; i < a.length; ++i) {
            _clearBlock(a[i], BlockState.Blacklisted);
        }
    }

    /// @dev Set (or escalate) a block. Frozen→Blacklisted is atomic (no unfreeze
    ///      first). Re-block on an already-`to` state is a state no-op that
    ///      refreshes trigger + reason (last-write-wins).
    function _setBlock(address a, BlockState to, uint256 triggerId, bytes32 reasonHash) internal {
        if (a == address(0)) revert ZeroAddress();
        // No Blacklisted → Frozen downgrade: a blacklist is only cleared by
        // unblacklist. A `freeze` on an already-Blacklisted address is a no-op
        // that still refreshes trigger/reason (does not downgrade).
        BlockState from = _blockState[a];
        if (to == BlockState.Frozen && from == BlockState.Blacklisted) {
            // hold the stronger state; refresh evidence only
            _blockTrigger[a] = triggerId;
            emit AccountBlocked(a, from, triggerId, reasonHash);
            return;
        }
        if (from == BlockState.None) {
            _blockedAccounts.add(a);
        }
        _blockState[a] = to;
        _blockTrigger[a] = triggerId;
        emit AccountBlocked(a, to, triggerId, reasonHash);
    }

    /// @dev Clear a block. `expected` selects which removal fn ran: unfreeze
    ///      requires Frozen, unblacklist requires Blacklisted (wrong-removal
    ///      reverts — footgun guard). Absent (`None`) always reverts.
    function _clearBlock(address a, BlockState expected) internal {
        BlockState from = _blockState[a];
        if (expected == BlockState.Frozen) {
            if (from != BlockState.Frozen) revert NotFrozen(a);
        } else {
            // expected == Blacklisted
            if (from != BlockState.Blacklisted) revert NotBlacklisted(a);
        }
        _blockState[a] = BlockState.None;
        _blockTrigger[a] = 0;
        _blockedAccounts.remove(a);
        emit AccountUnblocked(a, from);
    }

    function _requireNotBlocked(address a) internal view {
        BlockState s = _blockState[a];
        if (s != BlockState.None) revert ActorBlocked(a, s);
    }

    // ─── Pause ───────────────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    function setSecurityPerimeterPaused(bool p) external onlyAdminOrOwner {
        securityPerimeterPaused = p;
        emit SecurityPerimeterPausedSet(p);
    }

    // ─── Recovery ────────────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    /// @dev Leg-2: recover once `isBlacklisted(originator) || isBlacklisted(owner)`
    ///      (OR predicate); exact provenance match to an active route; a
    ///      mixed batch reverts wholesale.
    function resolveToProtocol(uint256[] calldata ids, bytes32 routeId)
        external
        nonReentrant
        onlyAdminOrOwner
    {
        if (ids.length == 0) revert EmptyIds();
        RecoveryRoute storage route = _recoveryRoutes[routeId];
        if (!route.active) revert RouteInactive(routeId);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            ExitRequest storage r = _requests[id];
            if (r.status == ExitStatus.None) revert UnknownRequest(id);
            if (r.status != ExitStatus.Queued) revert AlreadyTerminal(id);

            // OR-blacklist authorization over source parties; receiver-only
            // block never authorizes Leg-2.
            bool authorized = _blockState[r.originator] == BlockState.Blacklisted
                || _blockState[r.owner] == BlockState.Blacklisted;
            if (!authorized) revert SourceNotBlacklisted(r.originator);

            // Exact provenance: surface, subProduct, token must match.
            if (r.surfaceId != route.surfaceId || r.subProduct != route.subProduct || r.token != route.token)
            {
                revert RouteProvenanceMismatch(id, routeId);
            }

            address token = r.token;
            uint128 amount = r.amount;
            r.status = ExitStatus.ResolvedToProtocol;
            _removeActive(id, r.originator, r.owner);
            _totalEscrowed[token] -= amount;

            emit ExitResolvedToProtocol(id, routeId, route.destination, amount);
            // topUpPool routes are a plain token top-up to the pool
            // (destination == subProduct); both branches use the same primitive.
            _payout(token, route.destination, amount, false);
        }
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Leg-3: Owner catch-all, bounded to a blocked/held/non-executable
    ///      request — the DAO can never touch an honest, fully-unblocked,
    ///      unlocked, in-flight exit.
    function resolveBySIP(uint256[] calldata ids, address destination) external nonReentrant onlyOwner {
        if (ids.length == 0) revert EmptyIds();
        if (destination == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            ExitRequest storage r = _requests[id];
            if (r.status == ExitStatus.None) revert UnknownRequest(id);
            if (r.status != ExitStatus.Queued) revert AlreadyTerminal(id);

            // Bounded predicate: blocked | paused | locked. The DAO can never
            // touch an honest, fully-unblocked, unlocked, unpaused in-flight exit.
            // A bouncing (but unblocked) recipient is NOT admitted here — it is
            // handled self-service via recoverStuckExit(id, altReceiver),
            // so there is no _payoutFailed term (that mechanism was removed).
            bool resolvable = _isBlocked(r.originator) || _isBlocked(r.owner) || _isBlocked(r.receiver)
                || securityPerimeterPaused || block.timestamp < r.unlockAt;
            if (!resolvable) revert NotResolvableBySIP(id);

            address token = r.token;
            uint128 amount = r.amount;
            r.status = ExitStatus.ResolvedBySIP;
            _removeActive(id, r.originator, r.owner);
            _totalEscrowed[token] -= amount;

            emit ExitResolvedBySIP(id, destination, amount);
            _payout(token, destination, amount, false);
        }
    }

    function _isBlocked(address a) internal view returns (bool) {
        return _blockState[a] != BlockState.None;
    }

    /// @inheritdoc IExitDelayQueue
    function setRecoveryRoute(RecoveryRoute calldata route) external onlyOwner returns (bytes32 routeId) {
        if (route.destination == address(0)) revert ZeroAddress();
        // topUpPool routes restricted on-chain to feasible surfaces and
        // to non-native tokens (a native request can never be Leg-2a).
        if (route.topUpPool) {
            if (!_topUpFeasible[route.surfaceId]) revert TopUpInfeasibleSurface(route.surfaceId);
            if (route.token == address(0)) revert TopUpInfeasibleSurface(route.surfaceId);
        }
        routeId = keccak256(abi.encode(route.surfaceId, route.subProduct, route.token, route.destination));
        _recoveryRoutes[routeId] = route;
        _recoveryRouteIds.add(routeId);
        emit RecoveryRouteSet(
            routeId, route.surfaceId, route.subProduct, route.token, route.destination, route.topUpPool
        );
    }

    /// @inheritdoc IExitDelayQueue
    function removeRecoveryRoute(bytes32 routeId) external onlyOwner {
        delete _recoveryRoutes[routeId];
        _recoveryRouteIds.remove(routeId);
        emit RecoveryRouteRemoved(routeId);
    }

    /// @inheritdoc IExitDelayQueue
    function setTopUpFeasible(bytes32 surfaceId, bool feasible) external onlyOwner {
        _topUpFeasible[surfaceId] = feasible;
        emit TopUpFeasibleSet(surfaceId, feasible);
    }

    // ─── Config ──────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    function addAllowedSource(address src) external onlyOwner {
        if (src == address(0)) revert ZeroAddress();
        if (_allowedSources.add(src)) {
            _allowedSource[src] = true;
            emit AllowedSourceSet(src, true);
        }
    }

    /// @inheritdoc IExitDelayQueue
    function removeAllowedSource(address src) external onlyOwner {
        if (_allowedSources.remove(src)) {
            _allowedSource[src] = false;
            emit AllowedSourceSet(src, false);
        }
    }

    /// @inheritdoc IExitDelayQueue
    function setNativePusher(address pusher) external onlyOwner {
        nativePusher = pusher;
        emit NativePusherSet(pusher);
    }

    /// @notice Rotate the Admin guardian. Non-zero; MAY equal the Owner.
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }

    event AdminSet(address indexed admin);

    /// @inheritdoc IExitDelayQueue
    function setMinimumDelaySeconds(uint32 s) external onlyOwner {
        minimumDelaySeconds = s;
        emit MinimumDelaySet(s);
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Moves EXACTLY the non-backing surplus (balanceOf − totalEscrowed);
    ///      provably never touches escrowed backing via the post-sweep solvency
    ///      require. Unlocks the equality form of /.
    function sweepSurplus(address token, address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert SweepToZero();
        uint256 escrowed = _totalEscrowed[token];
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 surplus = bal > escrowed ? bal - escrowed : 0;
            emit SurplusSwept(token, to, surplus);
            if (surplus > 0) Address.sendValue(payable(to), surplus);
            if (address(this).balance < escrowed) revert SolvencyViolated();
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 surplus = bal > escrowed ? bal - escrowed : 0;
            emit SurplusSwept(token, to, surplus);
            if (surplus > 0) IERC20(token).safeTransfer(to, surplus);
            if (IERC20(token).balanceOf(address(this)) < escrowed) revert SolvencyViolated();
        }
    }

    // ─── Payout primitive ───────────────────────────────────────────────

    /// @dev ERC20 safeTransfer / native sendValue / WRBTC-unwrap-then-sendValue.
    ///      No fail-open: a reverting receiver rolls the whole call back
    ///      (status already terminal → held until Leg-3 redirects).
    function _payout(address token, address to, uint128 amount, bool unwrap) internal {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else if (unwrap) {
            // WRBTC-escrowed: unwrap to native, then send native (Option B).
            IWRBTC(token).withdraw(amount);
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ─── Active-index maintenance ───────────────────────────────────────

    /// @dev Remove an id from both party sets; single removal when equal.
    function _removeActive(uint256 id, address originator, address owner_) internal {
        _activeByParty[originator].remove(id);
        if (owner_ != originator) _activeByParty[owner_].remove(id);
    }

    // ─── Views ───────────────────────────────────────────────────

    /// @inheritdoc IExitDelayQueue
    function getRequest(uint256 id) external view returns (ExitRequest memory) {
        return _requests[id];
    }

    /// @inheritdoc IExitDelayQueue
    /// @dev Best-effort over a mutating set: a concurrent removal can
    ///      skip/repeat; the ExitQueued/ExitExecuted events are the authoritative
    ///      reconstruction source. `nextCursor == 0` signals end.
    function getActive(address party, uint256 cursor, uint256 n)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        if (n > MAX_GET_ACTIVE_PAGE) n = MAX_GET_ACTIVE_PAGE;
        EnumerableSet.UintSet storage set = _activeByParty[party];
        uint256 len = set.length();
        if (cursor >= len || n == 0) {
            return (new uint256[](0), 0);
        }
        uint256 end = cursor + n;
        if (end > len) end = len;
        ids = new uint256[](end - cursor);
        for (uint256 i = cursor; i < end; ++i) {
            ids[i - cursor] = set.at(i);
        }
        nextCursor = end >= len ? 0 : end;
    }

    /// @inheritdoc IExitDelayQueue
    function blockStateOf(address a) external view returns (BlockState) {
        return _blockState[a];
    }

    /// @inheritdoc IExitDelayQueue
    function blockedAccounts(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total)
    {
        // Return the FULL blocked-set size `total` alongside the clamped `page`:
        // a monitor/sanctions integrator paging
        // this view knows the exact range ("showing offset..offset+page.length of
        // total") and can never silently undercount past the 500 cap. `total` is
        // the true EnumerableSet length regardless of offset/limit.
        //
        // Page clamp/cap (retained): cap the page size at
        // MAX_GET_ACTIVE_PAGE and derive `end` from a bounded `limit` so
        // `offset + limit` can never overflow-revert (a griefy caller passing a
        // near-max offset/limit).
        uint256 len = _blockedAccounts.length();
        total = len;
        if (limit > MAX_GET_ACTIVE_PAGE) limit = MAX_GET_ACTIVE_PAGE;
        if (offset >= len || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit;
        if (end > len) end = len;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _blockedAccounts.at(i);
        }
    }

    /// @inheritdoc IExitDelayQueue
    function blockTrigger(address a) external view returns (uint256) {
        return _blockTrigger[a];
    }

    /// @inheritdoc IExitDelayQueue
    function totalEscrowed(address token) external view returns (uint256) {
        return _totalEscrowed[token];
    }

    /// @inheritdoc IExitDelayQueue
    function getRecoveryRoute(bytes32 routeId) external view returns (RecoveryRoute memory) {
        return _recoveryRoutes[routeId];
    }

    /// @inheritdoc IExitDelayQueue
    function allowedSources() external view returns (address[] memory) {
        return _allowedSources.values();
    }

    /// @notice Enumerate registered recovery route ids (owner tooling).
    function recoveryRouteIds() external view returns (bytes32[] memory) {
        return _recoveryRouteIds.values();
    }

    /// @notice Whether a topUpPool route may be registered for `surfaceId`.
    function topUpFeasible(bytes32 surfaceId) external view returns (bool) {
        return _topUpFeasible[surfaceId];
    }

    /// @notice Whether `src` is a registered ingress source.
    function isAllowedSource(address src) external view returns (bool) {
        return _allowedSource[src];
    }

    // ─── Upgrade authorization (UUPS) ───────────────────────────────────

    // aderyn-ignore-next-line(centralization-risk)
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert UpgradeImplZero();
    }

    /// @dev Disabled: an ownerless custody contract would lock escrowed funds
    ///      forever (no execute-side auth changes, but no upgrade / no config /
    ///      no recovery-config). The 2-step transfer is the only admin move.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // NOTE the
    // `_transferOwnership` chokepoint override (Admin != Owner enforced on
    // the ownership side) was REMOVED together with the initialize/setAdmin
    // owner-equality checks — admin == owner is a supported shape (the
    // governance Safe holds both roles at launch). Consequence, accepted:
    // while the roles coincide, the Leg-2/Leg-3 authority split and
    // the bounds are vacuous; they become real when ownership moves to
    // Bitocracy.
}
