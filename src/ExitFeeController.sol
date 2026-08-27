// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IExitFeeController} from "./interfaces/IExitFeeController.sol";

/// @title  ExitFeeController
/// @notice Governance-owned resolver for ExitFee (Perimeter) policy. Three
///         RatePolicy tiers per surface: actor → sub-product → surface.
///         Most-specific *active* entry wins; the surface itself gates the
///         surface (if its `active` flag is false, overrides do not apply).
///         All quote calls are view-only; the controller never moves tokens.
///         UUPS upgradeable; only the owner can authorize a new impl.
//
// The `payable` flag aderyn flags comes from UUPSUpgradeable.upgradeToAndCall;
// it forwards msg.value to the new impl's initializer if any. The function is
// owner-gated by _authorizeUpgrade below, so the only way the gas token could reach
// this contract is if governance deliberately attaches value to an upgrade
// call. The controller itself has no payable user surface and no `receive()`.
// aderyn-ignore-next-line(contract-locks-ether)
contract ExitFeeController is IExitFeeController, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Hard ceiling on any rate (100.00%).
    // 10_000 is more readable than `1e4` in bps context (MAX_BPS == 100.00%).
    // aderyn-ignore-next-line(large-numeric-literal)
    uint16 public constant MAX_BPS = 10_000;

    // ─── Surface identifiers ────────────────────────────────────────────
    //
    // A `surfaceId` is an opaque `bytes32` naming an operation kind. The
    // controller stores it as-is and never inspects or decodes it -- the
    // contract is product/asset-agnostic. The off-chain naming convention
    // is `keccak256("<SURFACE_NAME>")`; nothing on-chain enforces or depends
    // on it. Adding a surface is therefore an owner-only
    // `setSurfacePolicy(newId, policy)` call -- never a contract upgrade.

    // ─── Own storage ────────────────────────────────────────────────────
    // Verified via `forge inspect ExitFeeController storageLayout`. The
    // contract's "own" slot 0 sits at proxy slot 251, after the inherited
    // OZ namespaces:
    //
    //   0          Initializable (_initialized + _initializing packed)
    //   1   .. 50  Initializable.__gap
    //   51  .. 100 UUPSUpgradeable.__gap
    //   101 .. 150 ContextUpgradeable.__gap
    //   151        OwnableUpgradeable._owner
    //   152 .. 200 OwnableUpgradeable.__gap
    //   201        Ownable2StepUpgradeable._pendingOwner
    //   202 .. 250 Ownable2StepUpgradeable.__gap
    //   251        ExitFeeController.exitFeeEnabled (1 byte) +
    //              ExitFeeController.feeReceiver    (20 bytes) -- PACKED.
    //   252        _surfacePolicy           mapping head
    //   253        _subProductPolicy        mapping head
    //   254        _actorPolicy             mapping head
    //   255        _subProductKeys          mapping head (enumeration index)
    //   256        _actorKeys               mapping head (enumeration index)
    //
    //   257        admin (20 bytes, offset 0) -- alone; the remaining
    //              12 bytes of the slot are intentionally unused.
    //
    //   258        _surfaceBypass           mapping head
    //   259        _subProductBypass        mapping head
    //   260        _actorBypass             mapping head
    //   261        _surfaceBypassKeys._values  (Bytes32Set array head)   ┐ 2 slots
    //   262        _surfaceBypassKeys._indexes (mapping head)            ┘
    //   263        _subProductBypassKeys    mapping head (enumeration index)
    //   264        _actorBypassKeys         mapping head (enumeration index)
    //   265        _passthroughActor        nested-mapping head (surface-scoped)
    //   266        _passthroughKeys         mapping head (enumeration index)
    //   267        _bypassSurfaceIds._values  (Bytes32Set array head)    ┐ 2 slots
    //   268        _bypassSurfaceIds._indexes (mapping head)             ┘
    //   269        _passthroughSurfaceIds._values  (Bytes32Set array head) ┐ 2 slots
    //   270        _passthroughSurfaceIds._indexes (mapping head)          ┘
    //   271        securityPerimeterEnabled (1 byte) + globalDelaySeconds
    //              (4 bytes) -- PACKED; 27 bytes of the slot are unused.
    //   272 .. 300 __gap[29] -- preserves the OZ-style 50-slot namespace
    //                           (50 - 21 own slots used).
    //
    // Own slots: 251 + 252..256 + 257 + 258..271 = 21, so __gap = 50 - 21 = 29
    // and the namespace ends at slot 300.
    //
    // Upgrades that add storage to THIS contract MUST consume from __gap and
    // reduce its length by exactly the number of slots added. They MUST NOT
    // reorder, insert, or change the type of any preceding slot. In
    // particular, nothing may be declared before `admin`, and nothing may be
    // packed into the free bytes of its slot.

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Global enablement flag. When false, every `quoteExitFee`
    ///         call returns `INACTIVE` regardless of per-surface configuration.
    ///         The single runtime kill switch.
    bool public exitFeeEnabled;

    /// @notice Destination for every fee leg. Product hooks read this from
    ///         the quote payload; the controller itself never moves tokens.
    address public feeReceiver;

    /// @dev Surface tier -- the policy gate + default rate per operation kind.
    ///
    ///      Key: `surfaceId` (bytes32) -- opaque operation-kind identifier.
    ///      Value: `RatePolicy` ({active, rateBps}).
    ///
    ///      The surface tier acts as the gate: if `active == false`, the whole
    ///      surface is off and the sub-product / actor overrides below are
    ///      ignored for that surface.
    mapping(bytes32 => RatePolicy) internal _surfacePolicy;

    /// @dev Sub-product override tier (one level finer than surface).
    ///
    ///      Outer key: `surfaceId` (bytes32) -- as above.
    ///      Inner key: `subProduct` (address) -- per-instance address whose
    ///      meaning is fixed by the surface convention (lending = iToken proxy,
    ///      AMM = converter address). Non-zero only -- `_writeSubProductPolicy`
    ///      reverts on `address(0)`.
    ///      Value: `RatePolicy` ({active, rateBps}).
    ///
    ///      Surfaces with no per-instance dimension call `quoteExitFee` with
    ///      `subProduct = address(0)` as a sentinel. `_resolvePolicy` sees the
    ///      zero argument and skips this map entirely, falling through to the
    ///      surface tier -- so the map is never consulted on those paths.
    ///
    ///      Wins over the surface tier when active. Only consulted if the
    ///      surface gate is on.
    mapping(bytes32 => mapping(address => RatePolicy)) internal _subProductPolicy;

    /// @dev Actor override tier (most specific).
    ///
    ///      Outer key: `surfaceId` (bytes32) -- as above.
    ///      Inner key: `actor` (address) -- whoever initiated the exit (always
    ///      `msg.sender` from the product hook -- never `tx.origin`). Non-zero
    ///      only -- `_writeActorPolicy` reverts on `address(0)`.
    ///      Value: `RatePolicy` ({active, rateBps}).
    ///
    ///      Wins over sub-product and surface when active. The common shape for
    ///      an exemption is `(active = true, rateBps = 0)`.
    mapping(bytes32 => mapping(address => RatePolicy)) internal _actorPolicy;

    /// @dev Enumeration indexes -- every (surfaceId, address) pair that
    ///      has been written via setSubProductPolicy / setActorPolicy
    ///      (singular or batch) is recorded here. Used by external
    ///      read-only inspectors and off-chain tooling to list configured
    ///      overrides without log scans. Entries are NOT auto-cleared on
    ///      soft retire (setSubProductPolicy with `(false, 0)`); use
    ///      removeSubProductPolicy / removeActorPolicy for hard removal.
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    /// @notice Fast operational guardian. A SINGLE stored address checked by
    ///         `onlyAdminOrOwner` -- NOT an OZ AccessControl role (the
    ///         controller stays single-Owner for configuration). It authorizes
    ///         the perimeter kill switch and the operational levers
    ///         `setExitFeeEnabled` and `setFeeReceiver`; policy setters,
    ///         removals, `setAdmin` itself, and UUPS upgrades stay `onlyOwner`.
    ///         MAY equal the owner -- nothing requires the two authorities to
    ///         be distinct. Unset (`address(0)`) until the owner appoints one;
    ///         while unset, `onlyAdminOrOwner` admits only the owner.
    /// @dev    Occupies slot 257 at offset 0, alone. Its position is fixed:
    ///         nothing may be declared before it, and nothing may be packed
    ///         into the free bytes beside it.
    address public admin;

    // ─── Delay policy state ─────────────────────────────────────────────

    /// @dev Surface-tier delay bypass. Key: `surfaceId`. Value:
    ///      `DelayBypassPolicy {active, bypass}`. Mirrors `_surfacePolicy`'s
    ///      shape but is INDEPENDENT of it — the delay resolver never
    ///      reads the fee `surfacePolicy.active`.
    mapping(bytes32 => IExitFeeController.DelayBypassPolicy) internal _surfaceBypass;

    /// @dev Sub-product-tier delay bypass. Outer key `surfaceId`, inner key
    ///      `subProduct` (non-zero). Wins over the surface tier when active.
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _subProductBypass;

    /// @dev Actor-tier delay bypass (most specific). Outer key `surfaceId`,
    ///      inner key `actor` (non-zero) — evaluated on `effOrig` ONLY (there is
    ///      NO global actor bypass). Wins over sub-product and surface.
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _actorBypass;

    /// @dev Enumeration index for the SURFACE-tier bypass. A single
    ///      flat `Bytes32Set` of every `surfaceId` with a configured surface bypass
    ///      — surface bypasses are keyed by `surfaceId` alone and are NOT scoped by
    ///      a parent surface, so `surfaceBypassKeys()` takes NO argument. Backed on
    ///      chain so `InspectController` / monitoring can dump every surface bypass
    ///      (no unenumerable zero-delay state). Retains soft-retired entries
    ///      (`active=false`); `removeSurfaceBypass` hard-removes.
    EnumerableSet.Bytes32Set internal _surfaceBypassKeys;

    /// @dev Enumeration indexes for the sub-product / actor bypass tiers (mirror
    ///      `_subProductKeys` / `_actorKeys`). Entries are retained on
    ///      soft-retire (`active=false`); use `removeSubProductBypass` /
    ///      `removeActorBypass` for hard removal. Consumed by `InspectController`.
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductBypassKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorBypassKeys;

    /// @dev Surface-scoped passthrough-actor registry. A passthrough
    ///      registered for `surfaceId` resolves to the `receiver` in
    ///      `effectiveActor`; it NEVER collapses identities globally — the
    ///      wrapper is registered only under `SURFACE_LENDING_LENDER_WITHDRAW`,
    ///      so margin/Zero (no entry) keep `effOrig = raw`, `effOwner = owner`.
    ///      Co-located here (not in the escrow queue) so the hook normalizes
    ///      WITHOUT touching the queue, keeping the kill switch queue-independent
    ///     .
    mapping(bytes32 => mapping(address => bool)) internal _passthroughActor;

    /// @dev Enumeration index for the surface-scoped passthrough registry.
    ///      Outer key `surfaceId`, values = every passthrough
    ///      address registered under it. Unlike the bypass key-sets this is kept
    ///      exact-to-live: an address is added on register and DROPPED on
    ///      deregister (`setPassthroughActor(.., false)`), because a passthrough is
    ///      a boolean membership with no soft-retire state to preserve. Gives the
    ///      passthrough registry the same enumerability as the bypass tiers (no
    ///      events-only blind spot on a security-critical registry).
    mapping(bytes32 => EnumerableSet.AddressSet) internal _passthroughKeys;

    /// @dev ANY-TIER-TOUCHED master surface-id set for delay bypasses.
    ///      Every bypass WRITER — `_writeSurfaceBypass` (via
    ///      `setSurfaceBypass`), `_writeSubProductBypass`, `_writeActorBypass` —
    ///      records its `surfaceId` here, so a surface that carries ONLY a
    ///      sub-product- or actor-tier bypass (the most common exemption shape,
    ///       actor tier) is discoverable even though it was never passed to
    ///      `setSurfaceBypass`. This is the root-cause fix: the per-tier key-sets
    ///      (`_surfaceBypassKeys` / `_subProductBypassKeys` / `_actorBypassKeys`)
    ///      only tell you WHICH keys exist UNDER a known surfaceId — they cannot
    ///      by themselves enumerate the surfaceIds. `bypassSurfaceIds()` closes
    ///      that gap so NO zero-delay / identity config is invisible to
    ///      `InspectController`. Entries are NEVER dropped (soft-retire retention),
    ///      so a `removeSurfaceBypass` while sub/actor entries remain live does not
    ///      remove the id from discovery — the inspector still probes every tier.
    EnumerableSet.Bytes32Set internal _bypassSurfaceIds;

    /// @dev ANY-TIER-TOUCHED master surface-id set for the passthrough registry.
    ///      `setPassthroughActor(surfaceId, .., true)` records
    ///      the `surfaceId` here, so a passthrough-only surface (no bypass entry,
    ///      not a named fee surface) is still enumerable. Like the passthrough
    ///      key-set it is retention-only at the SURFACE level: a surfaceId stays
    ///      recorded even after every passthrough under it is deregistered (the
    ///      per-surface `_passthroughKeys` set going empty is the live signal;
    ///      keeping the surfaceId costs one slot and guarantees the inspector never
    ///      loses the probe point). `passthroughSurfaceIds()` exposes it.
    EnumerableSet.Bytes32Set internal _passthroughSurfaceIds;

    /// @notice Global kill switch for the DELAY perimeter. Independent of
    ///         `exitFeeEnabled`: turning fees off does NOT disable the
    ///         perimeter, and a fee-inactive surface can still be delay-active.
    ///         When false, `quoteExitDelayFor` short-circuits to
    ///         `(0, raw, owner)` without consulting the bypass tiers, the
    ///         passthrough registry, or the queue.
    bool public securityPerimeterEnabled;

    /// @notice One delay for EVERY surface (uint32 gives ~136 years of head
    ///         room). There is no per-surface delay *duration* -- only the
    ///         per-tier bypass toggles above exempt a surface, sub-product or
    ///         actor. The `>= queue.minimumDelaySeconds` relationship is a
    ///         liveness invariant enforced PER-REQUEST in the queue, not a
    ///         cross-contract setter guard here: the controller never reads or
    ///         calls the queue.
    uint32 public globalDelaySeconds;

    // aderyn-ignore-next-line(unused-state-variable)
    uint256[29] private __gap;

    // ─── Custom errors ──────────────────────────────────────────────────

    error RateExceedsMaxBps(uint16 rateBps);
    error FeeReceiverZero();
    error SubProductZero();
    error ActorZero();
    error LengthMismatch();
    error OwnershipCannotBeRenounced();
    error UpgradeImplZero();

    // ─── Custom errors (admin role) ─────────────────────────────────────
    error NotAdminOrOwner(address caller); // onlyAdminOrOwner gate
    error AdminZero(); //                     setAdmin(address(0))

    // ─── Modifiers ──────────────────────────────────────────────────────

    /// @dev The `Admin` guardian OR the `Ownable2Step` owner. Gates the
    ///      perimeter kill switch and — since the core
    ///      merge — the fee levers `setExitFeeEnabled` /
    ///      `setFeeReceiver`. All other setters are `onlyOwner`.
    modifier onlyAdminOrOwner() {
        if (msg.sender != admin && msg.sender != owner()) revert NotAdminOrOwner(msg.sender);
        _;
    }

    // ─── Construction / initialization ──────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. `__Ownable_init` makes the caller the
    ///         initial owner; `newOwner_` decides whether ownership moves
    ///         on immediately or stays with the caller.
    /// @param  newOwner_ Address to take ownership.
    ///         - `address(0)` or `msg.sender`: the caller stays owner, so
    ///           it can configure the proxy and hand ownership off later.
    ///         - Any other address: ownership transfers immediately.
    function initialize(address newOwner_) external initializer {
        __Ownable_init();
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        if (newOwner_ != address(0) && newOwner_ != msg.sender) {
            _transferOwnership(newOwner_);
        }
    }

    // ─── Upgrade authorization (UUPS) ───────────────────────────────────

    /// @dev Only the owner can authorize an upgrade, and the new impl must
    ///      be non-zero. Storage-layout compatibility and impl verification
    ///      are the owner's responsibility off-chain; this function is only
    ///      the on-chain access gate.
    // aderyn-ignore-next-line(centralization-risk)
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert UpgradeImplZero();
    }

    // ─── Disable renounceOwnership ──────────────────────────────────────

    /// @notice Disabled. Reverts with `OwnershipCannotBeRenounced`. Use
    ///         `transferOwnership` + `acceptOwnership` to rotate the owner.
    /// @dev Prevents permanent loss of admin -- without an owner, no rate
    ///      updates, no emergency disable, and no UUPS upgrades are
    ///      possible.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // NOTE the
    // `_transferOwnership` chokepoint override (Admin != Owner enforced on
    // the ownership side) was REMOVED together with `setAdmin`'s
    // owner-equality check — admin == owner is a supported shape (the
    // governance Safe holds both roles at launch). The queue's counterpart
    // was removed in the same change.

    /// @notice Appoint (or rotate) the operational guardian checked by
    ///         `onlyAdminOrOwner`. Owner-only. `address(0)` is rejected --
    ///         clearing the guardian would silently drop the fast incident
    ///         path; to disable it, rotate to a held-but-inert address
    ///         instead. MAY equal the owner.
    /// @param  newAdmin Non-zero address.
    // aderyn-ignore-next-line(centralization-risk)
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert AdminZero();
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }

    // ─── Admin: global state ────────────────────────────────────────────

    /// @notice Flip the global kill switch. While `false`, every
    ///         `quoteExitFee` returns `INACTIVE` and product hooks no-op.
    ///         All other configuration is preserved across flips.
    ///         Admin-or-owner (both directions) for fast incident response.
    /// @param  enabled Target state for the global switch.
    // aderyn-ignore-next-line(centralization-risk)
    function setExitFeeEnabled(bool enabled) external onlyAdminOrOwner {
        exitFeeEnabled = enabled;
        emit ExitFeeEnabledSet(enabled);
    }

    /// @notice Set the global fee destination (typically the ExitFeeVault
    ///         proxy). Required before the system can charge: with the
    ///         receiver unset, quotes return `DISABLED` even when enabled.
    ///         Admin-or-owner so the fee leg can be re-pointed (e.g. to a
    ///         replacement vault) without waiting on governance.
    /// @param  newReceiver Non-zero address that receives every fee leg.
    // aderyn-ignore-next-line(centralization-risk)
    function setFeeReceiver(address newReceiver) external onlyAdminOrOwner {
        if (newReceiver == address(0)) revert FeeReceiverZero();
        feeReceiver = newReceiver;
        emit FeeReceiverSet(newReceiver);
    }

    // ─── Admin: delay global state ───────────────

    /// @notice Flip the DELAY perimeter kill switch. `onlyAdminOrOwner`
    ///         (the fee levers joined this gate in) — both
    ///         directions, for sub-minute incident response. Independent of
    ///         `exitFeeEnabled`:
    ///         disabling fees does NOT disable the perimeter and vice-versa.
    ///         Accepted residual: a rogue Admin can DISABLE the perimeter (a
    ///         protocol-wide fail-OPEN delay removal) — the deliberate tradeoff.
    /// @param  enabled Target state for the perimeter.
    // aderyn-ignore-next-line(centralization-risk)
    function setSecurityPerimeterEnabled(bool enabled) external onlyAdminOrOwner {
        securityPerimeterEnabled = enabled;
        emit SecurityPerimeterEnabledSet(enabled);
    }

    /// @notice Set the single global delay applied whenever a delay is imposed.
    ///         Owner-only. The `>= queue.minimumDelaySeconds` floor
    ///         is a documented liveness invariant enforced PER-REQUEST in the
    ///         queue and by a deploy-script assertion — NOT a
    ///         cross-contract setter guard, so the controller never reads or
    ///         calls the queue (kill-switch queue-independence). A value
    ///         below the floor would self-brick every non-bypassed exit
    ///         (fail-closed) but can NEVER rush a request below the floor.
    /// @param  seconds_ Delay in seconds (uint32; 0 is allowed and disables the
    ///         delay for all non-bypassed exits, equivalent to a global bypass).
    function setGlobalDelaySeconds(uint32 seconds_) external onlyOwner {
        globalDelaySeconds = seconds_;
        emit GlobalDelaySet(seconds_);
    }

    // ─── Admin: policy setters ──────────────────────────────────────────
    //
    // `surfaceId` is an opaque operation-kind identifier. The off-chain
    // naming convention is `keccak256("<SURFACE_NAME>")`; the controller
    // stores the bytes32 as-is and never inspects the name.

    /// @notice Configure (or update) the surface tier for `surfaceId`.
    ///         The surface acts as the gate: with `policy.active == false`
    ///         the whole surface is off and sub-product / actor overrides
    ///         are ignored. Overwriting is idempotent.
    /// @param  surfaceId Opaque operation-kind identifier;
    ///         `keccak256("<SURFACE_NAME>")` by convention.
    /// @param  policy Active flag + rate in basis points (`rateBps <= MAX_BPS`).
    function setSurfacePolicy(bytes32 surfaceId, RatePolicy calldata policy) external onlyOwner {
        if (policy.rateBps > MAX_BPS) revert RateExceedsMaxBps(policy.rateBps);
        _surfacePolicy[surfaceId] = policy;
        emit SurfacePolicySet(surfaceId, policy.active, policy.rateBps);
    }

    /// @notice Configure (or update) a sub-product override under
    ///         `surfaceId`. Wins over the surface tier when its `active`
    ///         flag is true (and the surface gate is on). Records the
    ///         address in the enumeration index for off-chain inspection.
    /// @param  surfaceId  See `setSurfacePolicy`.
    /// @param  subProduct Per-instance address; meaning fixed by surface
    ///         (lending = iToken, AMM = converter, etc.). Non-zero.
    /// @param  policy     Active flag + rate (`rateBps <= MAX_BPS`).
    function setSubProductPolicy(bytes32 surfaceId, address subProduct, RatePolicy calldata policy)
        external
        onlyOwner
    {
        _writeSubProductPolicy(surfaceId, subProduct, policy);
    }

    /// @notice Batch variant of `setSubProductPolicy`. Reverts on length
    ///         mismatch or any per-entry validation failure (zero address,
    ///         rate above ceiling); a revert mid-batch undoes the whole
    ///         batch.
    /// @param  surfaceId   See `setSurfacePolicy`.
    /// @param  subProducts Sub-product addresses, same order as `policies`.
    /// @param  policies    Per-address policies, same order as `subProducts`.
    function setSubProductPolicies(
        bytes32 surfaceId,
        address[] calldata subProducts,
        RatePolicy[] calldata policies
    ) external onlyOwner {
        uint256 len = subProducts.length;
        if (len != policies.length) revert LengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            _writeSubProductPolicy(surfaceId, subProducts[i], policies[i]);
        }
    }

    /// @notice Configure (or update) an actor override under `surfaceId`.
    ///         The most-specific tier: wins over sub-product and surface
    ///         when active. Use `(active=true, rateBps=0)` for an
    ///         exemption.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @param  actor     Address whose exits are policy-keyed. Non-zero.
    /// @param  policy    Active flag + rate (`rateBps <= MAX_BPS`).
    function setActorPolicy(bytes32 surfaceId, address actor, RatePolicy calldata policy)
        external
        onlyOwner
    {
        _writeActorPolicy(surfaceId, actor, policy);
    }

    /// @notice Batch variant of `setActorPolicy`. Same revert semantics
    ///         as `setSubProductPolicies`.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @param  actors    Actor addresses, same order as `policies`.
    /// @param  policies  Per-address policies, same order as `actors`.
    function setActorPolicies(bytes32 surfaceId, address[] calldata actors, RatePolicy[] calldata policies)
        external
        onlyOwner
    {
        uint256 len = actors.length;
        if (len != policies.length) revert LengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            _writeActorPolicy(surfaceId, actors[i], policies[i]);
        }
    }

    function _writeSubProductPolicy(bytes32 surfaceId, address subProduct, RatePolicy calldata policy)
        internal
    {
        if (subProduct == address(0)) revert SubProductZero();
        if (policy.rateBps > MAX_BPS) revert RateExceedsMaxBps(policy.rateBps);
        _subProductPolicy[surfaceId][subProduct] = policy;
        // EnumerableSet.add returns false if already present; idempotent here.
        // aderyn-ignore-next-line(unchecked-return)
        _subProductKeys[surfaceId].add(subProduct);
        emit SubProductPolicySet(surfaceId, subProduct, policy.active, policy.rateBps);
    }

    function _writeActorPolicy(bytes32 surfaceId, address actor, RatePolicy calldata policy) internal {
        if (actor == address(0)) revert ActorZero();
        if (policy.rateBps > MAX_BPS) revert RateExceedsMaxBps(policy.rateBps);
        _actorPolicy[surfaceId][actor] = policy;
        // aderyn-ignore-next-line(unchecked-return)
        _actorKeys[surfaceId].add(actor);
        emit ActorPolicySet(surfaceId, actor, policy.active, policy.rateBps);
    }

    // ─── Admin: policy removal ──────────────────────────────────────────
    //
    // Hard-removes a sub-product or actor override: clears the stored
    // RatePolicy AND drops the address from the enumeration index.
    // Idempotent: a remove call for an address that is not currently in
    // the index is a successful no-op (no event emitted, no revert), so a
    // batched retire cannot fail because an earlier step already removed
    // the entry.
    //
    // To temporarily disable an override while keeping it visible in the
    // inspector, use setSubProductPolicy / setActorPolicy with
    // RatePolicy(false, 0) instead (soft retire). To remove it
    // permanently, use these.

    /// @notice Hard-remove a sub-product override: clears its `RatePolicy`
    ///         and drops it from the enumeration index. Idempotent --
    ///         a remove for an address that is not currently in the
    ///         index is a successful no-op (no event, no revert).
    /// @param  surfaceId  See `setSurfacePolicy`.
    /// @param  subProduct Sub-product address to remove. Non-zero.
    function removeSubProductPolicy(bytes32 surfaceId, address subProduct) external onlyOwner {
        _removeSubProductPolicy(surfaceId, subProduct);
    }

    /// @notice Batch variant of `removeSubProductPolicy`. Each entry is
    ///         independently idempotent; the batch reverts only on a zero
    ///         address.
    /// @param  surfaceId   See `setSurfacePolicy`.
    /// @param  subProducts Sub-product addresses to remove.
    function removeSubProductPolicies(bytes32 surfaceId, address[] calldata subProducts) external onlyOwner {
        uint256 len = subProducts.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeSubProductPolicy(surfaceId, subProducts[i]);
        }
    }

    /// @notice Hard-remove an actor override. Same idempotent semantics
    ///         as `removeSubProductPolicy`.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @param  actor     Actor address to remove. Non-zero.
    function removeActorPolicy(bytes32 surfaceId, address actor) external onlyOwner {
        _removeActorPolicy(surfaceId, actor);
    }

    /// @notice Batch variant of `removeActorPolicy`. Each entry
    ///         independently idempotent; batch reverts only on a zero
    ///         address.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @param  actors    Actor addresses to remove.
    function removeActorPolicies(bytes32 surfaceId, address[] calldata actors) external onlyOwner {
        uint256 len = actors.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeActorPolicy(surfaceId, actors[i]);
        }
    }

    function _removeSubProductPolicy(bytes32 surfaceId, address subProduct) internal {
        if (subProduct == address(0)) revert SubProductZero();
        // EnumerableSet.remove returns true iff the element was present.
        // Gating the cleanup on that lets us emit only on real removals
        // (audit trail) while keeping the call idempotent.
        if (_subProductKeys[surfaceId].remove(subProduct)) {
            delete _subProductPolicy[surfaceId][subProduct];
            emit SubProductPolicyRemoved(surfaceId, subProduct);
        }
    }

    function _removeActorPolicy(bytes32 surfaceId, address actor) internal {
        if (actor == address(0)) revert ActorZero();
        if (_actorKeys[surfaceId].remove(actor)) {
            delete _actorPolicy[surfaceId][actor];
            emit ActorPolicyRemoved(surfaceId, actor);
        }
    }

    // ─── Admin: delay bypass tiers ────────────────────
    //
    // Mirrors the fee-tier setters but on `DelayBypassPolicy`. A
    // `{active:true, bypass:true}` entry EXEMPTS the surface/subProduct/actor
    // (d = 0, instant); a `{active:true, bypass:false}` entry FORCES the global
    // delay (overriding a broader bypass). `{active:false}` falls through. The
    // enumeration keys retain soft-retired entries; use the removers for hard
    // removal. Precedence and the truth table live in `_resolveDelay` below.

    /// @notice Configure (or update) the surface-tier delay bypass for
    ///         `surfaceId`. Overwriting is idempotent.
    function setSurfaceBypass(bytes32 surfaceId, IExitFeeController.DelayBypassPolicy calldata policy)
        external
        onlyOwner
    {
        _writeSurfaceBypass(surfaceId, policy);
    }

    function _writeSurfaceBypass(bytes32 surfaceId, IExitFeeController.DelayBypassPolicy calldata policy)
        internal
    {
        _surfaceBypass[surfaceId] = policy;
        // Per-tier enumeration index. Idempotent: add returns
        // false if already present. Retained on soft-retire (`active=false`).
        // aderyn-ignore-next-line(unchecked-return)
        _surfaceBypassKeys.add(surfaceId);
        // ANY-TIER-TOUCHED master set: record the surfaceId so the
        // inspector discovers it regardless of which tier configured it.
        // aderyn-ignore-next-line(unchecked-return)
        _bypassSurfaceIds.add(surfaceId);
        emit SurfaceBypassSet(surfaceId, policy.active, policy.bypass);
    }

    /// @notice Hard-remove a surface-tier delay bypass: clears the stored policy
    ///         and drops the surfaceId from the enumeration index. Idempotent --
    ///         a remove for a surfaceId not currently in the index is a successful
    ///         no-op (no event, no revert). To temporarily disable while keeping it
    ///         visible in the inspector, use `setSurfaceBypass(id, {false, false})`.
    function removeSurfaceBypass(bytes32 surfaceId) external onlyOwner {
        if (_surfaceBypassKeys.remove(surfaceId)) {
            delete _surfaceBypass[surfaceId];
            emit SurfaceBypassRemoved(surfaceId);
        }
    }

    /// @notice Configure (or update) a sub-product-tier delay bypass. Records
    ///         the address in the enumeration index. `subProduct` non-zero.
    function setSubProductBypass(
        bytes32 surfaceId,
        address subProduct,
        IExitFeeController.DelayBypassPolicy calldata policy
    ) external onlyOwner {
        _writeSubProductBypass(surfaceId, subProduct, policy);
    }

    /// @notice Batch variant of `setSubProductBypass`. Reverts on length
    ///         mismatch or a zero address; a revert mid-batch undoes the batch.
    function setSubProductBypasses(
        bytes32 surfaceId,
        address[] calldata subProducts,
        IExitFeeController.DelayBypassPolicy[] calldata policies
    ) external onlyOwner {
        uint256 len = subProducts.length;
        if (len != policies.length) revert LengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            _writeSubProductBypass(surfaceId, subProducts[i], policies[i]);
        }
    }

    /// @notice Configure (or update) an actor-tier delay bypass (most specific;
    ///         evaluated on `effOrig`). `actor` non-zero.
    function setActorBypass(
        bytes32 surfaceId,
        address actor,
        IExitFeeController.DelayBypassPolicy calldata policy
    ) external onlyOwner {
        _writeActorBypass(surfaceId, actor, policy);
    }

    /// @notice Batch variant of `setActorBypass`. Same revert semantics as
    ///         `setSubProductBypasses`.
    function setActorBypasses(
        bytes32 surfaceId,
        address[] calldata actors,
        IExitFeeController.DelayBypassPolicy[] calldata policies
    ) external onlyOwner {
        uint256 len = actors.length;
        if (len != policies.length) revert LengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            _writeActorBypass(surfaceId, actors[i], policies[i]);
        }
    }

    function _writeSubProductBypass(
        bytes32 surfaceId,
        address subProduct,
        IExitFeeController.DelayBypassPolicy calldata policy
    ) internal {
        if (subProduct == address(0)) revert SubProductZero();
        _subProductBypass[surfaceId][subProduct] = policy;
        // aderyn-ignore-next-line(unchecked-return)
        _subProductBypassKeys[surfaceId].add(subProduct);
        // ANY-TIER-TOUCHED master set: a sub-product-only bypass
        // under an arbitrary surfaceId is otherwise undiscoverable — record it.
        // aderyn-ignore-next-line(unchecked-return)
        _bypassSurfaceIds.add(surfaceId);
        emit SubProductBypassSet(surfaceId, subProduct, policy.active, policy.bypass);
    }

    function _writeActorBypass(
        bytes32 surfaceId,
        address actor,
        IExitFeeController.DelayBypassPolicy calldata policy
    ) internal {
        if (actor == address(0)) revert ActorZero();
        _actorBypass[surfaceId][actor] = policy;
        // aderyn-ignore-next-line(unchecked-return)
        _actorBypassKeys[surfaceId].add(actor);
        // ANY-TIER-TOUCHED master set: the actor tier is the MOST
        // COMMON exemption shape — an actor-only bypass with no prior
        // setSurfaceBypass MUST still surface the id to the inspector.
        // aderyn-ignore-next-line(unchecked-return)
        _bypassSurfaceIds.add(surfaceId);
        emit ActorBypassSet(surfaceId, actor, policy.active, policy.bypass);
    }

    /// @notice Hard-remove a sub-product-tier delay bypass: clears the stored
    ///         policy and drops it from the enumeration index. Idempotent.
    function removeSubProductBypass(bytes32 surfaceId, address subProduct) external onlyOwner {
        _removeSubProductBypass(surfaceId, subProduct);
    }

    /// @notice Batch variant of `removeSubProductBypass`.
    function removeSubProductBypasses(bytes32 surfaceId, address[] calldata subProducts) external onlyOwner {
        uint256 len = subProducts.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeSubProductBypass(surfaceId, subProducts[i]);
        }
    }

    /// @notice Hard-remove an actor-tier delay bypass. Idempotent.
    function removeActorBypass(bytes32 surfaceId, address actor) external onlyOwner {
        _removeActorBypass(surfaceId, actor);
    }

    /// @notice Batch variant of `removeActorBypass`.
    function removeActorBypasses(bytes32 surfaceId, address[] calldata actors) external onlyOwner {
        uint256 len = actors.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeActorBypass(surfaceId, actors[i]);
        }
    }

    function _removeSubProductBypass(bytes32 surfaceId, address subProduct) internal {
        if (subProduct == address(0)) revert SubProductZero();
        if (_subProductBypassKeys[surfaceId].remove(subProduct)) {
            delete _subProductBypass[surfaceId][subProduct];
            emit SubProductBypassRemoved(surfaceId, subProduct);
        }
    }

    function _removeActorBypass(bytes32 surfaceId, address actor) internal {
        if (actor == address(0)) revert ActorZero();
        if (_actorBypassKeys[surfaceId].remove(actor)) {
            delete _actorBypass[surfaceId][actor];
            emit ActorBypassRemoved(surfaceId, actor);
        }
    }

    // ─── Admin: surface-scoped passthrough registry ───────────────

    /// @notice Register/deregister a surface-scoped passthrough actor.
    ///         A passthrough registered for `surfaceId` normalizes to the
    ///         `receiver` in `effectiveActor` / `quoteExitDelayFor`. Owner-only
    ///         and — because `bypass=true` is equivalent to zero delay and a
    ///         passthrough rewrites the block key — as security-critical as the
    ///         source-registry. NEVER collapses identities globally: the
    ///         wrapper is registered ONLY under `SURFACE_LENDING_LENDER_WITHDRAW`,
    ///         so margin/Zero keep their raw identities.
    /// @param  surfaceId     Operation-kind identifier.
    /// @param  a             Passthrough contract (e.g. the RBTCWrapperProxy).
    /// @param  isPassthrough True to register, false to deregister.
    // aderyn-ignore-next-line(centralization-risk)
    function setPassthroughActor(bytes32 surfaceId, address a, bool isPassthrough) external onlyOwner {
        if (a == address(0)) revert ActorZero();
        _passthroughActor[surfaceId][a] = isPassthrough;
        // Keep the enumeration index exact-to-live: a passthrough is
        // a boolean membership with no soft-retire state, so add on register and
        // drop on deregister. add/remove return values are intentionally unchecked
        // (idempotent — a repeat register or a deregister of an absent entry is a
        // successful no-op that still emits, matching the setter's overwrite
        // semantics).
        if (isPassthrough) {
            // aderyn-ignore-next-line(unchecked-return)
            _passthroughKeys[surfaceId].add(a);
            // ANY-TIER-TOUCHED master set: record the surfaceId on
            // register so a passthrough-only surface (no bypass entry, not a named
            // fee surface) is still a probe point for the inspector. Surface-level
            // retention: the id stays even after every passthrough under it is
            // deregistered — the per-surface `_passthroughKeys` set going empty is
            // the live signal, and keeping the id guarantees the probe point.
            // aderyn-ignore-next-line(unchecked-return)
            _passthroughSurfaceIds.add(surfaceId);
        } else {
            // aderyn-ignore-next-line(unchecked-return)
            _passthroughKeys[surfaceId].remove(a);
        }
        emit PassthroughActorSet(surfaceId, a, isPassthrough);
    }

    // ─── Policy views ───────────────────────────────────────────────────

    /// @notice Surface tier (gate + default rate) for `surfaceId`. Returns
    ///         the zero-initialised `RatePolicy` if never configured.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @return The stored `RatePolicy` for the surface tier.
    function surfacePolicy(bytes32 surfaceId) external view returns (RatePolicy memory) {
        return _surfacePolicy[surfaceId];
    }

    /// @notice Sub-product override for `(surfaceId, subProduct)`. Returns
    ///         a zero-initialised `RatePolicy` if never configured.
    /// @param  surfaceId  See `setSurfacePolicy`.
    /// @param  subProduct Sub-product address whose override is being read.
    /// @return The stored `RatePolicy` for that sub-product.
    function subProductPolicy(bytes32 surfaceId, address subProduct)
        external
        view
        returns (RatePolicy memory)
    {
        return _subProductPolicy[surfaceId][subProduct];
    }

    /// @notice Actor override for `(surfaceId, actor)`. Returns a
    ///         zero-initialised `RatePolicy` if never configured.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @param  actor     Actor address whose override is being read.
    /// @return The stored `RatePolicy` for that actor.
    function actorPolicy(bytes32 surfaceId, address actor) external view returns (RatePolicy memory) {
        return _actorPolicy[surfaceId][actor];
    }

    /// @notice Every sub-product address ever configured under `surfaceId`
    ///         (via setSubProductPolicy or the batch variant). Entries are
    ///         not removed when a policy is set inactive -- pair each
    ///         address with `subProductPolicy(surfaceId, addr)` to see the
    ///         live state. Use `removeSubProductPolicy(...)` for hard
    ///         removal. Intended for off-chain inspection tooling.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @return Snapshot of every configured sub-product address.
    function subProductKeys(bytes32 surfaceId) external view returns (address[] memory) {
        return _subProductKeys[surfaceId].values();
    }

    /// @notice Every actor address ever configured under `surfaceId`
    ///         (via setActorPolicy or the batch variant). Same retention
    ///         semantics as `subProductKeys`.
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @return Snapshot of every configured actor address.
    function actorKeys(bytes32 surfaceId) external view returns (address[] memory) {
        return _actorKeys[surfaceId].values();
    }

    // ─── Delay views ──────────────────────────────────

    /// @notice Surface-tier delay bypass for `surfaceId`. Zero-initialised if
    ///         never configured (`{active:false, bypass:false}`).
    function surfaceBypass(bytes32 surfaceId)
        external
        view
        returns (IExitFeeController.DelayBypassPolicy memory)
    {
        return _surfaceBypass[surfaceId];
    }

    /// @notice Sub-product-tier delay bypass for `(surfaceId, subProduct)`.
    function subProductBypass(bytes32 surfaceId, address subProduct)
        external
        view
        returns (IExitFeeController.DelayBypassPolicy memory)
    {
        return _subProductBypass[surfaceId][subProduct];
    }

    /// @notice Actor-tier delay bypass for `(surfaceId, actor)`.
    function actorBypass(bytes32 surfaceId, address actor)
        external
        view
        returns (IExitFeeController.DelayBypassPolicy memory)
    {
        return _actorBypass[surfaceId][actor];
    }

    /// @notice Every surfaceId configured in the surface-tier delay-bypass index.
    ///         Takes NO argument — surface bypasses are keyed by
    ///         `surfaceId` alone, NOT scoped by a parent surface. Entries are not
    ///         removed when a bypass is set inactive; pair each id with
    ///         `surfaceBypass(id)` to see the live state, or use
    ///         `removeSurfaceBypass(id)` for hard removal. Intended for
    ///         `InspectController` / monitoring so there is no unenumerable
    ///         zero-delay state.
    /// @return Snapshot of every configured surface-bypass surfaceId.
    function surfaceBypassKeys() external view returns (bytes32[] memory) {
        return _surfaceBypassKeys.values();
    }

    /// @notice Every sub-product configured under `surfaceId` in the delay
    ///         bypass index. Same retention semantics as `subProductKeys`.
    function subProductBypassKeys(bytes32 surfaceId) external view returns (address[] memory) {
        return _subProductBypassKeys[surfaceId].values();
    }

    /// @notice Every actor configured under `surfaceId` in the delay bypass
    ///         index. Same retention semantics as `actorKeys`.
    function actorBypassKeys(bytes32 surfaceId) external view returns (address[] memory) {
        return _actorBypassKeys[surfaceId].values();
    }

    /// @notice ANY-TIER-TOUCHED master set: EVERY surfaceId that has a bypass
    ///         entry at ANY tier — surface, sub-product, OR actor.
    ///         This is the discovery driver for `InspectController`: unlike
    ///         `surfaceBypassKeys()` (surface-tier writes only), this records the
    ///         surfaceId from `setSurfaceBypass`, `setSubProductBypass`, AND
    ///         `setActorBypass`, so a surface carrying ONLY a sub-product- or
    ///         actor-tier bypass (the most common exemption shape) is never missed.
    ///         Retention-only: entries are never dropped, so a `removeSurfaceBypass`
    ///         while sub/actor entries remain live keeps the id in discovery — the
    ///         inspector re-probes every tier per id and shows the live state.
    /// @return Snapshot of every surfaceId touched by any bypass tier.
    function bypassSurfaceIds() external view returns (bytes32[] memory) {
        return _bypassSurfaceIds.values();
    }

    /// @notice ANY-TIER-TOUCHED master set for the passthrough registry: every
    ///         surfaceId under which a passthrough has been registered.
    ///         Drives `InspectController`'s passthrough dump so a
    ///         passthrough-only surface (no bypass entry, not a named fee surface)
    ///         is still enumerable. Surface-level retention: an id stays recorded
    ///         even after every passthrough under it is deregistered.
    /// @return Snapshot of every surfaceId touched by the passthrough registry.
    function passthroughSurfaceIds() external view returns (bytes32[] memory) {
        return _passthroughSurfaceIds.values();
    }

    /// @notice Every passthrough address registered under `surfaceId`.
    ///         Exact-to-live: an address enters on `setPassthroughActor(.., true)`
    ///         and is dropped on `setPassthroughActor(.., false)`. Gives the
    ///         security-critical passthrough registry the same on-chain
    ///         enumerability as the bypass tiers (no events-only blind spot).
    /// @param  surfaceId See `setSurfacePolicy`.
    /// @return Snapshot of every live passthrough address under `surfaceId`.
    function passthroughKeys(bytes32 surfaceId) external view returns (address[] memory) {
        return _passthroughKeys[surfaceId].values();
    }

    /// @notice Whether `a` is a surface-scoped passthrough for `surfaceId`.
    function passthroughActor(bytes32 surfaceId, address a) external view returns (bool) {
        return _passthroughActor[surfaceId][a];
    }

    // ─── Quote ──────────────────────────────────────────────────────────

    /// @inheritdoc IExitFeeController
    function quoteExitFee(bytes32 surfaceId, address subProduct, address actor, uint256 grossAmount)
        external
        view
        returns (ExitFeeQuote memory quote)
    {
        // Always echo the configured receiver and gross even on off-state
        // paths so the product can show "configured but turned off" without
        // a second call.
        quote.feeReceiver = feeReceiver;
        quote.netAmount = grossAmount;

        if (!exitFeeEnabled) {
            quote.reason = uint8(SkipReason.INACTIVE);
            return quote;
        }
        if (feeReceiver == address(0)) {
            quote.reason = uint8(SkipReason.DISABLED);
            return quote;
        }

        RatePolicy memory policy = _resolvePolicy(surfaceId, subProduct, actor);

        if (!policy.active) {
            // Surface inactive OR all tiers fell through without an active
            // policy. Either way: nothing to charge.
            quote.reason = uint8(SkipReason.DISABLED);
            return quote;
        }

        // Defensive overflow guards. With rateBps capped at MAX_BPS (10_000)
        // these can only trip for genuinely absurd `grossAmount` -- but if
        // they do, we surface INVALID_QUOTE so the product can log it
        // instead of silently charging the wrong amount.
        if (grossAmount > type(uint256).max / MAX_BPS) {
            quote.reason = uint8(SkipReason.INVALID_QUOTE);
            return quote;
        }
        uint256 fee = (grossAmount * uint256(policy.rateBps)) / MAX_BPS;
        if (fee > grossAmount) {
            quote.reason = uint8(SkipReason.INVALID_QUOTE);
            return quote;
        }

        // `active` reflects POLICY state, not fee amount. Dust (fee==0 from
        // rounding) and explicit exemption (rateBps==0) both return
        // active=true with feeAmount=0. The product's hook keys on
        // `quote.active && quote.feeAmount > 0` to decide the fee leg.
        quote.active = true;
        quote.rateBps = policy.rateBps;
        quote.feeAmount = fee;
        quote.netAmount = grossAmount - fee;
        quote.reason = uint8(SkipReason.NONE);
    }

    // ─── Policy resolution ──────────────────────────────────────────────

    /// @dev Resolution order: surface-gate → actor → sub-product → surface.
    ///      The SURFACE gate is checked first: if its `active` flag is
    ///      false, the whole surface is off and overrides are ignored.
    ///      When the gate is on, the most-specific *active* entry wins.
    ///      Inactive override entries fall through to the next tier.
    function _resolvePolicy(bytes32 surfaceId, address subProduct, address actor)
        internal
        view
        returns (RatePolicy memory)
    {
        RatePolicy memory surface = _surfacePolicy[surfaceId];
        if (!surface.active) {
            // Surface gate off -- caller checks `policy.active` and reports DISABLED.
            return surface;
        }

        // Actor tier (top).
        RatePolicy memory p = _actorPolicy[surfaceId][actor];
        if (p.active) return p;

        // Sub-product tier. address(0) means "no per-instance dimension"
        // (e.g. Zero) -- in that case we skip the map lookup so a sibling
        // sub-product's policy can't leak into the address(0) path.
        if (subProduct != address(0)) {
            p = _subProductPolicy[surfaceId][subProduct];
            if (p.active) return p;
        }

        // Surface fallback (always active here, since we checked above).
        return surface;
    }

    // ─── Delay quote + resolution ─────────────────────

    /// @inheritdoc IExitFeeController
    function effectiveActor(bytes32 surfaceId, address raw, address receiver) public view returns (address) {
        // A passthrough registered FOR THIS SURFACE resolves to the receiver;
        // otherwise identity. Never collapses identities globally — a
        // surface with no passthrough entry returns `raw` unchanged, so margin
        // and Zero keep their real originator/owner.
        return _passthroughActor[surfaceId][raw] ? receiver : raw;
    }

    /// @inheritdoc IExitFeeController
    function quoteExitDelayFor(
        address rawOriginator,
        address owner_,
        address receiver,
        bytes32 surfaceId,
        address subProduct
    ) external view returns (uint32 d, address effOrig, address effOwner) {
        // KILL-SWITCH SHORT-CIRCUIT FIRST: a disabled perimeter pays
        // direct WITHOUT consulting the passthrough registry or the queue — the
        // liveness escape. Returns RAW identities; the hook must ignore them and
        // pay direct whenever d == 0, so the raw identities never record.
        if (!securityPerimeterEnabled) {
            return (0, rawOriginator, owner_);
        }

        // Resolve the surface-scoped effective identities, then quote on
        // effOrig, so the quote and the record share ONE identity.
        effOrig = effectiveActor(surfaceId, rawOriginator, receiver);
        effOwner = effectiveActor(surfaceId, owner_, receiver);
        d = _resolveDelay(surfaceId, subProduct, effOrig);
    }

    /// @inheritdoc IExitFeeController
    function quoteExitDelay(bytes32 surfaceId, address subProduct, address effectiveActor_)
        external
        view
        returns (uint32)
    {
        // Handles the disabled-perimeter case identically (returns 0 when the
        // perimeter is off) so an off-chain caller of the inner view never gets
        // a non-zero delay while the perimeter is disabled. Callers pass an
        // ALREADY-effective actor (never a raw wrapper).
        if (!securityPerimeterEnabled) return 0;
        return _resolveDelay(surfaceId, subProduct, effectiveActor_);
    }

    /// @dev The 3-tier delay resolver (truth table). Evaluated on
    ///      the EFFECTIVE originator. Precedence mirrors the fee resolver —
    ///      actor > subProduct > surface, most-specific-*active*-wins — but the
    ///      SOLE gate is `securityPerimeterEnabled` (checked by the callers
    ///      above): the delay resolver is INDEPENDENT of the fee
    ///      `surfacePolicy.active` and `exitFeeEnabled`. A `{active:false}` tier
    ///      falls through; an `{active:true}` tier decides — `bypass ? 0 :
    ///      globalDelaySeconds`. With no active bypass tier the default is
    ///      `globalDelaySeconds` (delayed). An active `{bypass:false}` tier at a
    ///      more-specific level overrides a broader bypass.
    function _resolveDelay(bytes32 surfaceId, address subProduct, address effOrig)
        internal
        view
        returns (uint32)
    {
        // Actor tier (most specific). No global actor bypass — always keyed
        // [surfaceId][effOrig].
        IExitFeeController.DelayBypassPolicy memory a = _actorBypass[surfaceId][effOrig];
        if (a.active) return a.bypass ? 0 : globalDelaySeconds;

        // Sub-product tier. address(0) means "no per-instance dimension" (e.g.
        // Zero) — skip the lookup so a sibling sub-product cannot leak in.
        if (subProduct != address(0)) {
            IExitFeeController.DelayBypassPolicy memory s = _subProductBypass[surfaceId][subProduct];
            if (s.active) return s.bypass ? 0 : globalDelaySeconds;
        }

        // Surface tier.
        IExitFeeController.DelayBypassPolicy memory f = _surfaceBypass[surfaceId];
        if (f.active) return f.bypass ? 0 : globalDelaySeconds;

        // No active bypass tier: default is the global delay (delayed).
        return globalDelaySeconds;
    }
}
