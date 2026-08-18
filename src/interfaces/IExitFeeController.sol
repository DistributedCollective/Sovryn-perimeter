// SPDX-License-Identifier: MIT
// Range pragma is intentional: this one file must compile under Solidity
// 0.5.17, 0.6.11, and 0.8.20 -- the three compilers that consume it.
// aderyn-ignore-next-line(unspecific-solidity-pragma)
pragma solidity >=0.5.17 <0.9.0;
// `pragma experimental ABIEncoderV2;` is required for the 0.5.17 leg — that
// compiler needs the directive to emit/decode struct returns (ExitFeeQuote)
// across the ABI boundary. The modern `pragma abicoder v2;` was only added
// in 0.7.4 and is incompatible with 0.5.x, so the experimental pragma is the
// only spelling that works across all three target compilers. On 0.6+/0.8+
// the experimental pragma is accepted (silently on 0.6.x; with a deprecation
// notice on 0.8.x that does NOT enable the historical encoder bugs — those
// bugs were fixed long before 0.6.0). This is a pure interface (no
// implementation, no storage), so there is no exposure to encoder-bug
// surface area beyond the ABI itself. Removing it would mean shipping one
// interface file per pragma, which is exactly the drift this file avoids.
// aderyn-ignore-next-line(experimental-encoder)
pragma experimental ABIEncoderV2;

/// @title  IExitFeeController
/// @notice Cross-pragma interface for the ExitFee (ColFee) controller. One
///         file for every consumer on 0.5.17, 0.6.11, and 0.8.20. Consumers
///         on 0.4.26 use the structurally-different variant in `v0_4/`,
///         which must stay ABI-identical to this file.
interface IExitFeeController {
    // ─── Types ────────────────────────────────────────────────────────────

    /// @notice Reason a `ColFeeSkipped` event was emitted instead of an
    ///         `ColFeeApplied`. NONE covers honest paths (positive charge,
    ///         dust, or actor-exemption); the rest cover off-state outcomes.
    enum SkipReason {
        NONE, // Controller computed an honest quote (charge / dust / zero-rate).
        INACTIVE, // exitFeeEnabled == false.
        DISABLED, // feeReceiver == address(0), OR surface gate off.
        INVALID_QUOTE, // Defensive: overflow or fee > gross.
        CONTROLLER_REVERT, // Set by the product's local _safeQuote on staticcall failure.
        VAULT_REVERT // Set by the product hook when the fee transfer itself failed.

    }

    /// @notice A single rate-policy entry. Lives at each of the three tiers
    ///         (actor → sub-product → surface).
    struct RatePolicy {
        bool active;
        uint16 rateBps;
    }

    /// @notice A single delay-bypass entry (the DELAY feature). Lives
    ///         at each of the three bypass tiers (actor → sub-product → surface),
    ///         mirroring `RatePolicy`'s shape.
    ///
    ///         `active == false` ⇒ the tier is not configured; resolution falls
    ///         through to the next-broader tier. `active == true` ⇒ this tier
    ///         decides: `bypass == true` exempts the exit (`d = 0`, instant),
    ///         `bypass == false` FORCES the global delay (overriding a broader
    ///         bypass). It is a bypass/exemption toggle only — there is NO
    ///         per-instance delay *duration* (a single `globalDelaySeconds`
    ///         applies whenever a delay is imposed).
    struct DelayBypassPolicy {
        bool active;
        bool bypass;
    }

    /// @notice Quote returned by `quoteExitFee`. `reason` carries the precise
    ///         off-state code; `active` is the resolved policy state (true iff
    ///         a RatePolicy.active entry was used and reason ∈ {NONE}).
    struct ExitFeeQuote {
        bool active;
        uint16 rateBps;
        uint256 feeAmount;
        uint256 netAmount;
        address feeReceiver;
        uint8 reason;
    }

    // ─── Events ───────────────────────────────────────────────────────────

    event ExitFeeEnabledSet(bool enabled);
    event FeeReceiverSet(address indexed feeReceiver);
    event SurfacePolicySet(bytes32 indexed surfaceId, bool active, uint16 rateBps);
    event SubProductPolicySet(
        bytes32 indexed surfaceId, address indexed subProduct, bool active, uint16 rateBps
    );
    event ActorPolicySet(bytes32 indexed surfaceId, address indexed actor, bool active, uint16 rateBps);
    event SubProductPolicyRemoved(bytes32 indexed surfaceId, address indexed subProduct);
    event ActorPolicyRemoved(bytes32 indexed surfaceId, address indexed actor);

    // ─── Events (delay extension) ─────────────────────────────────────

    event AdminSet(address indexed admin);
    event SecurityPerimeterEnabledSet(bool enabled);
    event GlobalDelaySet(uint32 seconds_);
    event SurfaceBypassSet(bytes32 indexed surfaceId, bool active, bool bypass);
    event SurfaceBypassRemoved(bytes32 indexed surfaceId);
    event SubProductBypassSet(
        bytes32 indexed surfaceId, address indexed subProduct, bool active, bool bypass
    );
    event ActorBypassSet(bytes32 indexed surfaceId, address indexed actor, bool active, bool bypass);
    event SubProductBypassRemoved(bytes32 indexed surfaceId, address indexed subProduct);
    event ActorBypassRemoved(bytes32 indexed surfaceId, address indexed actor);
    event PassthroughActorSet(bytes32 indexed surfaceId, address indexed actor, bool isPassthrough);

    // ─── Quote ────────────────────────────────────────────────────────────

    /// @notice Resolve the fee policy for `(surfaceId, subProduct, actor)` and
    ///         compute the fee on `grossAmount`. Reads only; never reverts on
    ///         policy lookups (returns active=false with a SkipReason instead).
    ///         May revert only on internal arithmetic invariants (caught by
    ///         the product's local _safeQuote helper as CONTROLLER_REVERT).
    function quoteExitFee(bytes32 surfaceId, address subProduct, address actor, uint256 grossAmount)
        external
        view
        returns (ExitFeeQuote memory);

    // ─── Delay quote (hook entry) ─────────────────────────────────────

    /// @notice The delay hook's SINGLE hot-path entry. Short-circuits
    ///         the kill switch FIRST: when `securityPerimeterEnabled == false` it
    ///         returns `(0, rawOriginator, owner)` WITHOUT consulting the
    ///         passthrough registry or the escrow queue (the liveness escape).
    ///         Otherwise it resolves the surface-scoped effective actors
    ///         (`effOrig`/`effOwner`) — a registered passthrough for `surfaceId`
    ///         resolves to `receiver` — quotes the delay on `effOrig`, and
    ///         returns all three so the quote and the record share ONE identity
    ///         (Finding 2). The hook MUST ignore `effOrig`/`effOwner` and pay
    ///         direct whenever `d == 0`.
    /// @param  rawOriginator The withdrawal caller (pre-normalization).
    /// @param  owner         The position owner (iToken holder / borrower / trove).
    /// @param  receiver      The immutable payout destination.
    /// @param  surfaceId     Operation-kind identifier (see fee tiers).
    /// @param  subProduct    Per-instance address (iToken / converter / 0).
    /// @return d       Delay seconds to escrow for (0 ⇒ off / inactive / bypassed).
    /// @return effOrig Effective originator (raw or passthrough→receiver).
    /// @return effOwner Effective owner (raw or passthrough→receiver).
    function quoteExitDelayFor(
        address rawOriginator,
        address owner,
        address receiver,
        bytes32 surfaceId,
        address subProduct
    ) external view returns (uint32 d, address effOrig, address effOwner);

    /// @notice Inner per-actor delay view (off / inactive / bypass ⇒ 0, else
    ///         `globalDelaySeconds`), evaluated on an ALREADY-effective actor.
    ///         Handles the disabled-perimeter case identically (returns 0 when
    ///         the perimeter is off). Hot-path callers use `quoteExitDelayFor`;
    ///         this is for off-chain quoting and the inner resolver.
    /// @param  surfaceId       Operation-kind identifier.
    /// @param  subProduct      Per-instance address (iToken / converter / 0).
    /// @param  effectiveActor  The already-normalized actor (never a raw wrapper).
    /// @return The delay seconds resolved by the 3-tier bypass resolver.
    function quoteExitDelay(bytes32 surfaceId, address subProduct, address effectiveActor)
        external
        view
        returns (uint32);

    /// @notice Resolve a surface-scoped passthrough: a passthrough registered
    ///         for `surfaceId` resolves `raw` to `receiver`, else identity.
    function effectiveActor(bytes32 surfaceId, address raw, address receiver)
        external
        view
        returns (address);

    // ─── State views ──────────────────────────────────────────────────────

    function exitFeeEnabled() external view returns (bool);
    function feeReceiver() external view returns (address);
    function surfacePolicy(bytes32 surfaceId) external view returns (RatePolicy memory);
    function subProductPolicy(bytes32 surfaceId, address subProduct)
        external
        view
        returns (RatePolicy memory);
    function actorPolicy(bytes32 surfaceId, address actor) external view returns (RatePolicy memory);
    function subProductKeys(bytes32 surfaceId) external view returns (address[] memory);
    function actorKeys(bytes32 surfaceId) external view returns (address[] memory);

    // ─── State views (delay extension) ──────────────────────────────────────

    function admin() external view returns (address);
    function securityPerimeterEnabled() external view returns (bool);
    function globalDelaySeconds() external view returns (uint32);
    function surfaceBypass(bytes32 surfaceId) external view returns (DelayBypassPolicy memory);
    function subProductBypass(bytes32 surfaceId, address subProduct)
        external
        view
        returns (DelayBypassPolicy memory);
    function actorBypass(bytes32 surfaceId, address actor) external view returns (DelayBypassPolicy memory);

    /// @notice Every surfaceId ever configured in the surface-tier delay-bypass
    ///         index. NOTE: this getter takes NO argument — surface
    ///         bypasses are keyed by `surfaceId` alone and are NOT scoped by a
    ///         parent surface. Backed by an `EnumerableSet.Bytes32Set` so
    ///         `InspectController` / monitoring can dump every surface bypass with
    ///         no unenumerable zero-delay state. Same soft-retire retention as the
    ///         other key-sets: entries persist on `{active:false}`; use
    ///         `removeSurfaceBypass` for hard removal.
    function surfaceBypassKeys() external view returns (bytes32[] memory);
    function subProductBypassKeys(bytes32 surfaceId) external view returns (address[] memory);
    function actorBypassKeys(bytes32 surfaceId) external view returns (address[] memory);

    /// @notice ANY-TIER-TOUCHED master set: every surfaceId that
    ///         carries a delay-bypass entry at ANY tier — surface, sub-product, OR
    ///         actor. Recorded from all three writers, so a surface with ONLY a
    ///         sub-product- or actor-tier bypass (the most common exemption shape)
    ///         is enumerable even though it was never passed to
    ///         `setSurfaceBypass`. This is the discovery driver `InspectController`
    ///         uses so NO zero-delay config under an arbitrary surfaceId is
    ///         invisible. Retention-only (entries never dropped).
    function bypassSurfaceIds() external view returns (bytes32[] memory);

    /// @notice ANY-TIER-TOUCHED master set for the passthrough registry:
    ///         every surfaceId under which a passthrough has been
    ///         registered. Lets `InspectController` discover a passthrough-only
    ///         surface (no bypass entry, not a named fee surface). Surface-level
    ///         retention (the id stays after every passthrough under it is dropped).
    function passthroughSurfaceIds() external view returns (bytes32[] memory);

    /// @notice Every passthrough address ever registered under `surfaceId`.
    ///         Backed by an `EnumerableSet.AddressSet` so the
    ///         surface-scoped passthrough registry — as security-critical as the
    ///         bypass tiers — has no events-only blind spot. Entries are dropped
    ///         from the index when deregistered (`setPassthroughActor(.., false)`).
    function passthroughKeys(bytes32 surfaceId) external view returns (address[] memory);

    function passthroughActor(bytes32 surfaceId, address a) external view returns (bool);

    // ─── Admin ────────────────────────────────────────────────────────────

    /// @notice `onlyAdminOrOwner`:
    ///         the fee kill switch and receiver re-point are operational
    ///         levers shared with the Admin guardian. Every other setter in
    ///         this section is Owner-only.
    function setExitFeeEnabled(bool enabled) external;
    function setFeeReceiver(address newReceiver) external;
    function setSurfacePolicy(bytes32 surfaceId, RatePolicy calldata policy) external;
    function setSubProductPolicy(bytes32 surfaceId, address subProduct, RatePolicy calldata policy)
        external;
    function setSubProductPolicies(
        bytes32 surfaceId,
        address[] calldata subProducts,
        RatePolicy[] calldata policies
    ) external;
    function setActorPolicy(bytes32 surfaceId, address actor, RatePolicy calldata policy) external;
    function setActorPolicies(bytes32 surfaceId, address[] calldata actors, RatePolicy[] calldata policies)
        external;
    function removeSubProductPolicy(bytes32 surfaceId, address subProduct) external;
    function removeSubProductPolicies(bytes32 surfaceId, address[] calldata subProducts) external;
    function removeActorPolicy(bytes32 surfaceId, address actor) external;
    function removeActorPolicies(bytes32 surfaceId, address[] calldata actors) external;

    // ─── Admin (delay extension) ────────────────────────────────────────────

    /// @notice Rotate the fast operational guardian (`Admin`). Owner-only.
    ///         MAY equal the Owner -- nothing requires the two to be distinct.
    ///         The only delay principal on the controller; there is no OZ
    ///         AccessControl role.
    function setAdmin(address newAdmin) external;

    /// @notice Flip the global delay kill switch. `onlyAdminOrOwner` in both
    ///         directions, for sub-minute incident response. Independent of
    ///         `exitFeeEnabled`.
    function setSecurityPerimeterEnabled(bool enabled) external;

    /// @notice Set the single global delay applied whenever a delay is imposed.
    ///         Owner-only. The `>= minimumDelaySeconds` floor is a liveness
    ///         invariant enforced PER-REQUEST in the queue, not here -- the
    ///         controller never reads or calls the queue.
    function setGlobalDelaySeconds(uint32 seconds_) external;

    function setSurfaceBypass(bytes32 surfaceId, DelayBypassPolicy calldata policy) external;

    /// @notice Hard-remove a surface-tier delay bypass: clears the stored policy
    ///         and drops the surfaceId from the enumeration index. Idempotent.
    function removeSurfaceBypass(bytes32 surfaceId) external;

    function setSubProductBypass(bytes32 surfaceId, address subProduct, DelayBypassPolicy calldata policy)
        external;

    function setSubProductBypasses(
        bytes32 surfaceId,
        address[] calldata subProducts,
        DelayBypassPolicy[] calldata policies
    ) external;

    function setActorBypass(bytes32 surfaceId, address actor, DelayBypassPolicy calldata policy) external;

    function setActorBypasses(
        bytes32 surfaceId,
        address[] calldata actors,
        DelayBypassPolicy[] calldata policies
    ) external;

    function removeSubProductBypass(bytes32 surfaceId, address subProduct) external;

    function removeSubProductBypasses(bytes32 surfaceId, address[] calldata subProducts) external;

    function removeActorBypass(bytes32 surfaceId, address actor) external;

    function removeActorBypasses(bytes32 surfaceId, address[] calldata actors) external;

    /// @notice Register/deregister a surface-scoped passthrough actor. A
    ///         passthrough registered for `surfaceId` normalizes to `receiver`
    ///         in `effectiveActor` / `quoteExitDelayFor`. Owner-only.
    function setPassthroughActor(bytes32 surfaceId, address a, bool isPassthrough) external;
}
