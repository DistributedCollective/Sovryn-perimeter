// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  IExitDelayQueue
/// @notice External ABI + type/event/error catalog for `ExitDelayQueue`, the
///         per-request escrow that holds the *user* leg of an exit for a
///         configurable delay so a detected theft can be blocked (frozen or
///         blacklisted) and routed to recovery before the funds leave.
///
///         This interface mirrors `ExitDelayQueue`'s complete queue-specific
///         operational function catalog and its event and error catalog,
///         other than the `SelfOnly`-guarded `payoutExternal` self-call
///         trampoline, which is not part of the ABI a caller is meant to use.
///         Two other classes of ABI member are deliberately left out as a
///         named carve-out, not an oversight: one-time proxy setup
///         (`initialize`) and the inherited ownership/upgrade administration
///         (`owner`, `pendingOwner`, `transferOwnership`, `acceptOwnership`,
///         `renounceOwnership`, `upgradeToAndCall`, `upgradeTo`,
///         `proxiableUUID`, from `OwnableUpgradeable`, `Ownable2StepUpgradeable`
///         and `UUPSUpgradeable`), which a caller consumes through those
///         base contracts' own interfaces, not this one. The types mirror the
///         queue's own struct and enum declarations.
///
///         Types (enums/structs) are declared here so cross-pragma callers
///         and off-chain tooling share one source of truth. The queue itself
///         is 0.8.20 UUPS; the four `record*` ingress fns are consumed from
///         0.5.x / 0.6.x product hosts via a minimal interface stub.
interface IExitDelayQueue {
    // ─── Types ───────────────────────────────────────────────────

    /// @notice Per-request lifecycle. `None` is the zero value (never stored
    ///         for a live id); the three terminal states are mutually
    ///         exclusive and a request leaves `Queued` at most once.
    enum ExitStatus {
        None, //               0 — never recorded
        Queued, //             1 — escrowed, awaiting execute / recovery
        Executed, //           2 — paid to receiver (terminal)
        ResolvedToProtocol, // 3 — Leg-2 recovery-away (terminal)
        ResolvedByOwner //     4 — Leg-3 Owner resolution (terminal)

    }

    /// @notice Per-address block state. `Frozen` = temporary (investigating);
    ///         `Blacklisted` = confirmed hack. Execution treats both as
    ///         "blocked"; recovery-away distinguishes them.
    enum BlockState {
        None, //        0
        Frozen, //      1 — temporary, cleared by unfreeze
        Blacklisted // 2 — confirmed, cleared only by unblacklist

    }

    /// @notice An immutable exit request. Every field except `status` is
    ///         frozen at record time. Packed into 7 words.
    struct ExitRequest {
        // word 1 (128 + 64 + 64 = 256 bits):
        uint128 amount; //    narrowed from the uint256 Perimeter amount at record
        uint64 createdAt; //  creation timestamp; readable through getRequest
        uint64 unlockAt; //   COMPUTED by the queue = createdAt + delaySeconds
        // words 2-5:
        address originator; // withdrawal caller the hook saw — block key + executor
        address owner; //      position owner — MANDATORY block key + executor
        address receiver; //   immutable payout destination — checked on release; may recover and may deliver
        address token; //      address(0) = native RBTC
        // word 6:
        bytes32 surfaceId; //  provenance: recovery-route key
        // word 7 (160 + 8 + 8 = 176 bits):
        address subProduct; // provenance: iToken / converter / address(0)
        ExitStatus status; //  uint8
        bool unwrapOnDelivery; //  when true, the queue holds WRBTC and executeExit unwraps it to native RBTC
    }

    /// @notice A pre-approved Leg-2 recovery route. `routeId` is
    ///         `keccak256(abi.encode(surfaceId, subProduct, token, destination))`.
    struct RecoveryRoute {
        bool active;
        bytes32 surfaceId;
        address subProduct;
        address token;
        address destination;
        bool topUpPool; // 2a: plain top-up of the originating pool (destination == subProduct)
    }

    // ─── Events ──────────────────────────────────────────────────

    event ExitQueued(
        uint256 indexed id,
        address indexed originator,
        address indexed owner,
        address receiver,
        address token,
        uint128 amount,
        uint64 unlockAt,
        bytes32 surfaceId,
        address subProduct
    );
    event ExitExecuted(uint256 indexed id, address indexed receiver, address token, uint128 amount);
    event ExitResolvedToProtocol(
        uint256 indexed id, bytes32 indexed routeId, address destination, uint128 amount
    );
    event ExitResolvedByOwner(uint256 indexed id, address indexed destination, uint128 amount);
    event AccountBlocked(
        address indexed account, BlockState state, uint256 indexed triggerRequestId, bytes32 reasonHash
    );
    event AccountUnblocked(address indexed account, BlockState fromState);
    event RecoveryRouteSet(
        bytes32 indexed routeId,
        bytes32 surfaceId,
        address subProduct,
        address token,
        address destination,
        bool topUpPool
    );
    event RecoveryRouteRemoved(bytes32 indexed routeId);
    event AllowedSourceSet(address indexed source, bool allowed);
    event TopUpFeasibleSet(bytes32 indexed surfaceId, bool feasible);
    event MinimumDelaySet(uint32 seconds_);
    event SecurityPerimeterPausedSet(bool paused);
    event NativePusherSet(address indexed pusher);
    event SurplusSwept(address indexed token, address indexed to, uint256 amount);
    event AdminSet(address indexed admin);

    // ─── Custom errors ───────────────────────────────────────────

    error UnregisteredSource(address caller); //  onlyAllowedSource — DISTINCT record-path halt selector
    error ActorBlocked(address actor, BlockState state); // execution-gate revert (event: AccountBlocked)
    error NotExecutor(address caller); //         delivery: msg.sender ∉ {originator, owner, receiver} and the owner has no code; recovery: ∉ {originator, owner, receiver}
    error NotUnlocked(uint256 id, uint64 unlockAt);
    error QueuePaused();
    error AlreadyTerminal(uint256 id); //         status != Queued at a transition (also duplicate-batch-id)
    error UnknownRequest(uint256 id);
    error DelayBelowFloor(uint32 delay, uint32 floor);
    error AmountTooLarge(uint256 amount); //      uint256→uint128 narrowing guard
    error AmountMismatch(uint256 msgValue, uint256 amount); // native value-carrying
    error ReceivedAmountMismatch(address token, uint256 have, uint256 want); // pull / measured-delta proof
    error ZeroAmount();
    error RouteInactive(bytes32 routeId);
    error RouteProvenanceMismatch(uint256 id, bytes32 routeId);
    error TopUpInfeasibleSurface(bytes32 surfaceId); // setRecoveryRoute topUpPool guard
    error TopUpDestinationMismatch(address destination, address subProduct); // top-up must pay its own pool
    error SourceNotBlacklisted(address src); //   Leg-2 OR-predicate not satisfied
    error NotBlacklisted(address a); //           unblacklist / downgradeToFrozen on a non-Blacklisted address
    error NotFrozen(address a); //                unfreeze on a non-Frozen address
    error AlreadyBlacklisted(address a); //       evidence-free freeze over a Blacklisted address
    error NotResolvableByOwner(uint256 id); //    Leg-3: no blacklisted party on the request
    error UnwrapNonWrbtc(); //                    unwrapOnDelivery set on a non-WRBTC token (guard)
    error InvalidAltReceiver(address altReceiver); // recoverStuckExit altReceiver ∈ {0,this,token,wrbtc}
    error InvalidReceiver(address receiver); //   ingress: the queue itself, or WRBTC when delivery sends native RBTC
    error SelfOnly(); //                          payoutExternal trampoline is self-call-only
    error ZeroAddress();
    error EmptyIds();
    error SweepToZero();
    error SolvencyViolated(); //                  post-transfer balance < totalEscrowed
    error NotAdminOrOwner(address caller); //     onlyAdminOrOwner
    error OwnershipCannotBeRenounced(); //        renounceOwnership disabled
    error UpgradeImplZero(); //                   UUPS _authorizeUpgrade guard
    error InvalidDestination(address destination); // resolveByOwner / setRecoveryRoute destination guard

    // ─── Ingress ──────────────────────────────────────────

    /// @dev CALLER-SIDE NARROWING PRECONDITION. Every
    ///      `record*` takes `amount` as a **`uint128`**, deliberately NOT widened
    ///      to `uint256`. The Perimeter hook computes the user leg as a `uint256` and
    ///      MUST narrow it (`uint128(userAmount)`) at the call site; that narrowing
    ///      is the caller's responsibility and MUST be preceded by the caller's own
    ///      `require(userAmount <= type(uint128).max)` (`AmountTooLarge`) so a value
    ///      that would silently truncate is rejected UPSTREAM, before any escrow
    ///      accounting. The queue itself CANNOT re-assert this on an
    ///      already-`uint128` argument — the `AmountTooLarge` error is declared for
    ///      that CALLER-side hook boundary, not re-checked here. Keeping
    ///      the ABI at `uint128` also packs `amount` into `ExitRequest` word 1
    ///       — widening would cost a whole extra storage word per request.

    /// @notice Pull ERC20 escrow from an authorized source and record a delayed withdrawal.
    /// @dev Requires receipt of exactly `amount`; delay must meet the current floor.
    ///      Only WRBTC may be marked for unwrapping. Caller must check uint128 bounds before narrowing.
    /// @param token Escrowed ERC20 token.
    /// @param amount Nonzero amount to escrow.
    /// @param delaySeconds Delay in seconds from recording to unlock.
    /// @param surfaceId Withdrawal surface identifying recovery provenance.
    /// @param subProduct Originating pool or other sub-product identifying recovery provenance.
    /// @param effOrig Nonzero withdrawal originator recorded for authorization and blocking.
    /// @param effOwner Nonzero position owner recorded for authorization and blocking.
    /// @param receiver Nonzero immutable payout recipient; must be valid for the delivery asset.
    /// @param unwrapOnDelivery Whether to unwrap escrowed WRBTC to native RBTC on user delivery.
    /// @return id Newly created request identifier.
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
    ) external returns (uint256 id);

    /// @notice Record ERC20 escrow already transferred by an authorized source in the same transaction.
    /// @dev Requires unaccounted token balance of at least `amount`; credits exactly that amount.
    ///      Excess remains surplus. Delay must meet the current floor; delivery does not unwrap.
    ///      Caller must check uint128 bounds before narrowing.
    /// @param token Escrowed ERC20 token.
    /// @param amount Nonzero amount to escrow.
    /// @param delaySeconds Delay in seconds from recording to unlock.
    /// @param surfaceId Withdrawal surface identifying recovery provenance.
    /// @param subProduct Originating pool or other sub-product identifying recovery provenance.
    /// @param effOrig Nonzero withdrawal originator recorded for authorization and blocking.
    /// @param effOwner Nonzero position owner recorded for authorization and blocking.
    /// @param receiver Nonzero immutable payout recipient; must be valid for the delivery asset.
    /// @return id Newly created request identifier.
    function recordReceivedERC20Exit(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id);

    /// @notice Record a delayed native-RBTC withdrawal funded by an authorized source's call value.
    /// @dev Requires `msg.value == amount` and a delay meeting the current floor.
    ///      Caller must check uint128 bounds before narrowing.
    /// @param amount Nonzero amount to escrow.
    /// @param delaySeconds Delay in seconds from recording to unlock.
    /// @param surfaceId Withdrawal surface identifying recovery provenance.
    /// @param subProduct Originating pool or other sub-product identifying recovery provenance.
    /// @param effOrig Nonzero withdrawal originator recorded for authorization and blocking.
    /// @param effOwner Nonzero position owner recorded for authorization and blocking.
    /// @param receiver Nonzero immutable payout recipient; must be valid for the delivery asset.
    /// @return id Newly created request identifier.
    function recordNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external payable returns (uint256 id);

    /// @notice Record native RBTC already transferred by an authorized source in the same transaction.
    /// @dev Requires unaccounted native balance of at least `amount`; credits exactly that amount.
    ///      Excess remains surplus. Delay must meet the current floor.
    ///      Caller must check uint128 bounds before narrowing.
    /// @param amount Nonzero amount to escrow.
    /// @param delaySeconds Delay in seconds from recording to unlock.
    /// @param surfaceId Withdrawal surface identifying recovery provenance.
    /// @param subProduct Originating pool or other sub-product identifying recovery provenance.
    /// @param effOrig Nonzero withdrawal originator recorded for authorization and blocking.
    /// @param effOwner Nonzero position owner recorded for authorization and blocking.
    /// @param receiver Nonzero immutable payout recipient; must be valid for the delivery asset.
    /// @return id Newly created request identifier.
    function recordReceivedNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id);

    // ─── Execution ───────────────────────────────────────────────

    /// @notice Pay an unlocked request to its recorded receiver. Who may call:
    ///         the request's originator, owner or receiver, always; ANYONE, when
    ///         the recorded owner has code at the moment of this call (a contract,
    ///         or a wallet that has delegated to code), because a contract owner
    ///         cannot press the button itself. The owner's code is read when delivery is called,
    ///         not when the request was recorded. Whoever calls, the money goes
    ///         only to the recorded receiver, and the call reverts while the
    ///         originator, the owner or the receiver is frozen or blacklisted. A
    ///         caller who is not a party must not be frozen or blacklisted either.
    ///         Blocking whoever presses deliver does not hold a contract-owned
    ///         request — block a recorded party to hold it. Reverts while the
    ///         queue is paused or the request is still locked.
    /// @param requestId Queued request to deliver.
    function executeExit(uint256 requestId) external;

    /// @notice `executeExit` for several ids in one call, with the same rule
    ///         applied to each id: parties always, anyone when that request's
    ///         owner has code, never a blocked caller. Atomic: one id that fails
    ///         reverts the whole batch. Blocking whoever presses deliver does not
    ///         hold a contract-owned request — block a recorded party to hold it.
    /// @dev Rejects an empty batch.
    /// @param ids Queued requests to deliver.
    function executeExits(uint256[] calldata ids) external;

    /// @notice Verify-by-attempting stuck-exit recovery. Callable by the
    ///         request's originator, its owner, or its recorded receiver,
    ///         whether or not the owner has code. Unlike delivery, this call is
    ///         never widened to anyone when the owner has code: delivery pays
    ///         only the recorded receiver, while this call names a destination,
    ///         so opening it that way would let a stranger take a contract-owned
    ///         request whose receiver refuses payment.
    ///         Requires the request Queued, unlocked, and the queue not paused.
    ///
    ///         Attempts the STORED-receiver payout FIRST; pays `altReceiver` ONLY if
    ///         the stored-receiver attempt fails, including out-of-gas. There is
    ///         NO stored failure flag. If
    ///         `altReceiver` also fails, the whole call reverts (funds stay Queued).
    ///
    ///         Block gate covers ALL FOUR actors — `{originator, owner, STORED
    ///         receiver, altReceiver}`: a blocked/hacked original receiver refuses
    ///         recovery entirely (→ Leg-3), preserving the blacklist trap and
    ///         leaving no receiver-only dead end. `altReceiver` is guarded: reverts
    ///         if it is `0`, this contract, the request token, or WRBTC. The stored
    ///         request is NEVER re-targeted (`altReceiver` is a payout-time
    ///         destination only), so request immutability and the block gate still
    ///         hold.
    ///
    ///         GAS: the caller's gas limit is the budget for the stored-receiver
    ///         attempt. An underfunded attempt can redirect a receiver that would
    ///         accept payment with more gas. The EVM keeps 1/64 back from
    ///         the attempt, which is what pays `altReceiver` when the receiver
    ///         consumes everything — so supply enough for both legs.
    /// @param id Queued request whose stored payout is attempted first.
    /// @param altReceiver Fallback payout recipient if the stored payout fails.
    function recoverStuckExit(uint256 id, address altReceiver) external;

    // ─── Block model ─────────────────────────────────────────────

    /// @notice Freeze a request's originator and owner, optionally its receiver. Admin or Owner only.
    /// @dev Requires known request ids, including terminal requests. Records request/reason evidence.
    ///      A freeze preserves an existing blacklist while updating evidence.
    /// @param requestId Request providing the recorded parties and evidence trigger.
    /// @param freezeReceiver Whether to block the recorded receiver as well.
    /// @param reasonHash Hash identifying supporting evidence; emitted in AccountBlocked.
    function freezeFromRequest(uint256 requestId, bool freezeReceiver, bytes32 reasonHash) external;

    /// @notice Blacklist a request's originator and owner, optionally its receiver. Admin or Owner only.
    /// @dev Requires known request ids, including terminal requests. Records request/reason evidence.
    /// @param requestId Request providing the recorded parties and evidence trigger.
    /// @param freezeReceiver Whether to block the recorded receiver as well.
    /// @param reasonHash Hash identifying supporting evidence; emitted in AccountBlocked.
    function blacklistFromRequest(uint256 requestId, bool freezeReceiver, bytes32 reasonHash) external;

    // Batch by-request-id — whole-batch atomic (one bad
    // id reverts all, like executeExits); last-write-wins trigger/reason per
    // address when the same address is blocked by more than one id in the batch.
    /// @notice Freeze a request's originator and owner, optionally its receiver. Admin or Owner only.
    /// @dev Requires known request ids, including terminal requests. Records request/reason evidence.
    ///      A freeze preserves an existing blacklist while updating evidence.
    ///      Nonempty atomic batch; later requests overwrite evidence for shared parties.
    /// @param requestIds Request identifiers to process.
    /// @param freezeReceiver Whether to block the recorded receiver as well.
    /// @param reasonHash Hash identifying supporting evidence; emitted in AccountBlocked.
    function freezeFromRequest(uint256[] calldata requestIds, bool freezeReceiver, bytes32 reasonHash)
        external;

    /// @notice Blacklist a request's originator and owner, optionally its receiver. Admin or Owner only.
    /// @dev Requires known request ids, including terminal requests. Records request/reason evidence.
    ///      Nonempty atomic batch; later requests overwrite evidence for shared parties.
    /// @param requestIds Request identifiers to process.
    /// @param freezeReceiver Whether to block the recorded receiver as well.
    /// @param reasonHash Hash identifying supporting evidence; emitted in AccountBlocked.
    function blacklistFromRequest(uint256[] calldata requestIds, bool freezeReceiver, bytes32 reasonHash)
        external;

    /// @notice Flat block levers. They carry no evidence, so a `freeze` over an
    ///         address that is already Blacklisted would change nothing and record
    ///         nothing: it reverts `AlreadyBlacklisted` rather than answering with
    ///         a success that reads as "this address is now frozen". The
    ///         by-request levers above carry a trigger and a reason, so they stay
    ///         unconditional on a known id — over a Blacklisted party they hold the
    ///         stronger state, record the new evidence, and announce Blacklisted.
    /// @dev Admin or Owner only; rejects zero and retains existing request triggers.
    /// @param a Address to freeze.
    function freeze(address a) external;

    /// @notice Blacklist an address, escalating an existing freeze. Admin or Owner only.
    /// @dev Rejects zero addresses and preserves existing request triggers.
    /// @param a Address to process.
    function blacklist(address a) external;

    /// @notice Clear Frozen blocks; other starting states revert. Admin or Owner only.
    /// @param a Address to process.
    function unfreeze(address a) external;

    /// @notice Clear Blacklisted blocks; other starting states revert. Admin or Owner only.
    /// @param a Address to process.
    function unblacklist(address a) external;

    /// @notice Move a Blacklisted address down to Frozen in one call — the
    ///         remedy for an address blacklisted in haste that should only be held
    ///         while it is investigated. There is no window in which the address is
    ///         unblocked, unlike unblacklist-then-freeze. Reverts `NotBlacklisted`
    ///         on any other state; the recorded trigger is kept, because a
    ///         downgrade means "still under investigation", not "exonerated".
    /// @dev Admin or Owner only; rejects zero.
    /// @param a Blacklisted address to keep frozen.
    function downgradeToFrozen(address a) external;

    // Batch by-address: each reverts `EmptyIds()` on
    // an empty array, for API consistency with the by-id batch variants
    // (`executeExits` / batch `freezeFromRequest` / `resolveToProtocol` /
    // `resolveByOwner`) — an empty batch is a caller mistake, never a silent no-op.
    /// @notice Freeze addresses; rejects any Blacklisted address. Admin or Owner only.
    /// @dev Nonempty atomic batch; one invalid entry reverts the whole call.
    ///      Rejects zero addresses and preserves existing request triggers.
    /// @param a Addresses to process.
    function freeze(address[] calldata a) external;

    /// @notice Blacklist addresses, escalating existing freezes. Admin or Owner only.
    /// @dev Nonempty atomic batch; one invalid entry reverts the whole call.
    ///      Rejects zero addresses and preserves existing request triggers.
    /// @param a Addresses to process.
    function blacklist(address[] calldata a) external;

    /// @notice Clear Frozen blocks; other starting states revert. Admin or Owner only.
    /// @dev Nonempty atomic batch; one invalid entry reverts the whole call.
    /// @param a Addresses to process.
    function unfreeze(address[] calldata a) external;

    /// @notice Clear Blacklisted blocks; other starting states revert. Admin or Owner only.
    /// @dev Nonempty atomic batch; one invalid entry reverts the whole call.
    /// @param a Addresses to process.
    function unblacklist(address[] calldata a) external;

    /// @notice Downgrade Blacklisted addresses to Frozen while retaining their triggers. Admin or Owner only.
    /// @dev Nonempty atomic batch; one invalid entry reverts the whole call.
    /// @param a Addresses to process.
    function downgradeToFrozen(address[] calldata a) external;

    // ─── Pause ───────────────────────────────────────────────────

    /// @notice Pause or resume the queue. Admin or Owner.
    ///         A pause stops `executeExit`, `executeExits` and `recoverStuckExit`
    ///         for every caller — the originator, the owner, and anyone
    ///         delivering a contract-owned request — so while it holds users have
    ///         no path of their own to their money.
    ///         It does not stop ingress: the four `record*` functions keep
    ///         escrowing new withdrawals. It does not stop the block levers, the
    ///         Admin-or-Owner `resolveToProtocol` (still bound to a blacklisted
    ///         originator or owner and a matching active route), or the Owner's
    ///         `resolveByOwner`, which reaches only requests with a blacklisted
    ///         party whether or not the queue is paused.
    /// @param p Whether to pause user delivery and stuck-exit recovery.
    function setSecurityPerimeterPaused(bool p) external;

    // ─── Recovery ────────────────────────────────────────────────

    /// @notice Resolve queued requests to an active recovery route. Admin or Owner only.
    /// @dev Each request must have a blacklisted originator or owner and match the route's
    ///      surface, sub-product and token. No unlock or pause restriction; transfers do not unwrap.
    ///      The batch must be nonempty and succeeds atomically.
    /// @param ids Requests to resolve.
    /// @param routeId Registered route selecting the recovery destination.
    function resolveToProtocol(uint256[] calldata ids, bytes32 routeId) external;

    /// @notice Resolve queued requests with any blacklisted recorded party. Owner only.
    /// @dev No unlock or pause restriction; transfers do not unwrap. Rejects zero, this queue,
    ///      WRBTC and each request's token as destinations. Nonempty batch; all-or-nothing.
    /// @param ids Requests to resolve.
    /// @param destination Destination chosen by the Owner.
    function resolveByOwner(uint256[] calldata ids, address destination) external;

    /// @notice Register or replace a recovery route, including its active flag. Owner only.
    /// @dev Destination cannot be zero, this queue, the route token or WRBTC. Pool top-ups
    ///      require a feasible surface, a non-native token and destination equal to subProduct.
    /// @param route Route configuration; active must be true for resolution to use it.
    /// @return routeId Hash of abi.encode(surfaceId, subProduct, token, destination).
    function setRecoveryRoute(RecoveryRoute calldata route) external returns (bytes32 routeId);

    /// @notice Delete a recovery route and remove its id from enumeration. Owner only.
    /// @dev Emits RecoveryRouteRemoved even if the route was absent.
    /// @param routeId Route to remove.
    function removeRecoveryRoute(bytes32 routeId) external;

    /// @notice Set whether pool-top-up routes may be registered for a surface. Owner only.
    /// @dev Affects route registration; does not disable already registered routes.
    /// @param surfaceId Withdrawal surface to configure.
    /// @param feasible Whether new or replacement top-up routes are permitted.
    function setTopUpFeasible(bytes32 surfaceId, bool feasible) external;

    // ─── Config ──────────────────────────────────────────

    /// @notice Authorize a source to call the four withdrawal-recording functions. Owner only.
    /// @dev Rejects zero. Adds the source to enumeration and enables its authorization lookup.
    ///      An already authorized source is unchanged and emits no event.
    /// @param src Trusted withdrawal-recording source.
    function addAllowedSource(address src) external;

    /// @notice Revoke a source's withdrawal-recording permission. Owner only.
    /// @dev Removes it from enumeration; an absent source is unchanged and emits no event.
    ///      Existing requests remain queued and retain their normal settlement paths.
    /// @param src Source to remove.
    function removeAllowedSource(address src) external;

    /// @notice Record the intended native-RBTC pusher as provenance. Owner only.
    /// @dev Accepts zero. Does not gate native receipts or grant withdrawal-recording permission.
    /// @param pusher Intended native funding contract.
    function setNativePusher(address pusher) external;

    /// @notice Replace the operational guardian. Owner only.
    /// @dev Rejects zero; the Admin may equal the Owner.
    /// @param newAdmin Guardian authorized for blocking, pause and protocol recovery operations.
    function setAdmin(address newAdmin) external;

    /// @notice Set the minimum delay accepted for future requests. Owner only.
    /// @dev Accepts zero; existing requests retain their recorded unlock times.
    /// @param s Minimum delay in seconds.
    function setMinimumDelaySeconds(uint32 s) external;

    /// @notice Transfer the full balance exceeding escrow liabilities to a destination. Owner only.
    /// @dev Reverts if the destination is zero or escrow is underbacked after the transfer.
    /// @param token Asset to sweep; address(0) denotes native RBTC.
    /// @param to Surplus recipient.
    function sweepSurplus(address token, address to) external;

    // ─── Views ───────────────────────────────────────────────────

    // `payoutExternal` is deliberately not declared here: it is the
    // `SelfOnly`-guarded self-call trampoline `recoverStuckExit` uses for its
    // catchable payout attempt, not a member of the external ABI a
    // caller or client is meant to use.

    /// @notice Read a withdrawal request, including its current status.
    /// @dev Unknown ids return a zero-initialized request with status None.
    /// @param id Request identifier.
    /// @return The stored request.
    function getRequest(uint256 id) external view returns (ExitRequest memory);

    /// @notice Paginate queued request ids involving a recorded originator, owner or receiver.
    /// @dev Page size is capped at MAX_GET_ACTIVE_PAGE. Set order may change between calls,
    ///      so pagination can skip or repeat entries if requests settle between reads.
    /// @param party Recorded party whose active requests to list.
    /// @param cursor Starting set index; use zero for the first page.
    /// @param n Requested page size.
    /// @return ids Active request ids in this page.
    /// @return nextCursor Next set index, or zero when there are no more entries.
    function getActive(address party, uint256 cursor, uint256 n)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor);

    /// @notice Read an address's current block state.
    /// @param a Address to inspect.
    /// @return None, Frozen or Blacklisted.
    function blockStateOf(address a) external view returns (BlockState);

    /// @notice The fast operational guardian checked by `onlyAdminOrOwner`.
    function admin() external view returns (address);

    /// @notice Monotonic id source; the first recorded id is 1.
    function lastRequestId() external view returns (uint256);

    /// @notice The registered native pusher recorded as ingress provenance.
    function nativePusher() external view returns (address);

    /// @notice The per-request delay floor enforced at ingress.
    function minimumDelaySeconds() external view returns (uint32);

    /// @notice Whether the queue currently pays nobody through the
    ///         user-facing legs.
    function securityPerimeterPaused() external view returns (bool);

    /// @notice The canonical WRBTC address used to guard and unwrap
    ///         `unwrapOnDelivery` requests.
    function wrbtc() external view returns (address);

    /// @notice Enumerate registered recovery route ids.
    function recoveryRouteIds() external view returns (bytes32[] memory);

    /// @notice Whether a topUpPool route may be registered for `surfaceId`.
    function topUpFeasible(bytes32 surfaceId) external view returns (bool);

    /// @notice Whether `src` is a registered ingress source.
    function isAllowedSource(address src) external view returns (bool);

    /// @notice Paginate the blocked set (Frozen ∪ Blacklisted).
    /// @param offset First index into the blocked set to return.
    /// @param limit  Requested page size; clamped to `MAX_GET_ACTIVE_PAGE` (500).
    /// @return page  The clamped slice `[offset, offset + page.length)` of the
    ///               blocked set (empty when `offset >= total` or `limit == 0`).
    /// @return total The FULL blocked-set size (EnumerableSet length), independent
    ///               of `offset`/`limit` — so a caller/monitor knows the whole
    ///               range ("showing offset..offset+page.length of total") and
    ///               never silently undercounts past the 500-entry page cap.
    function blockedAccounts(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total);

    /// @notice Read the request id retained as evidence for an address's block.
    /// @dev Zero means no retained request trigger. Clearing a block resets the trigger;
    ///      flat block calls and downgradeToFrozen preserve an existing trigger.
    /// @param a Address to inspect.
    /// @return Retained triggering request id, or zero.
    function blockTrigger(address a) external view returns (uint256);

    /// @notice Read the total amount backing queued requests for an asset.
    /// @param token Escrow asset; address(0) denotes native RBTC.
    /// @return Aggregate queued amount, excluding unaccounted surplus.
    function totalEscrowed(address token) external view returns (uint256);

    /// @notice Read a registered recovery route.
    /// @dev Unknown or removed ids return a zero-initialized, inactive route.
    /// @param routeId Route identifier.
    /// @return Stored route configuration.
    function getRecoveryRoute(bytes32 routeId) external view returns (RecoveryRoute memory);

    /// @notice List all authorized withdrawal-recording sources.
    /// @dev Enumeration order is not stable after removals.
    /// @return Currently authorized source addresses.
    function allowedSources() external view returns (address[] memory);

    /// @notice Max page size for the paginated `getActive` / `blockedAccounts`
    ///         views. Public constant, so paging is
    ///         self-describing on-chain (500).
    function MAX_GET_ACTIVE_PAGE() external view returns (uint256);
}
