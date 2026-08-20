// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IExitFeeController} from "./interfaces/IExitFeeController.sol";

/// @title  ExitFeeController
/// @notice Governance-owned resolver for ExitFee (ColFee) policy. Three
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
    // is `keccak256("COLFEE:<NAME>")`; nothing on-chain enforces or depends
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
    //   257        ExitFeeController.admin  (address, 20 bytes; slot offset 0,
    //                                        12 bytes free).
    //   258 .. 300 __gap[43] -- preserves the OZ-style 50-slot namespace
    //                           (50 - 7 own slots used).
    //
    // Upgrades that add storage to THIS contract MUST consume from __gap
    // and reduce its length by exactly the number of slots added. They
    // MUST NOT reorder, insert, or change the type of any preceding slot.

    using EnumerableSet for EnumerableSet.AddressSet;

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
    ///         only the operational levers `setExitFeeEnabled` and
    ///         `setFeeReceiver`; policy setters, removals, `setAdmin` itself,
    ///         and UUPS upgrades stay `onlyOwner`. MAY equal the owner --
    ///         nothing requires the two authorities to be distinct. Unset
    ///         (`address(0)`) until the owner appoints one; while unset,
    ///         `onlyAdminOrOwner` admits only the owner.
    address public admin;

    // aderyn-ignore-next-line(unused-state-variable)
    uint256[43] private __gap;

    // ─── Custom errors ──────────────────────────────────────────────────

    error RateExceedsMaxBps(uint16 rateBps);
    error FeeReceiverZero();
    error SubProductZero();
    error ActorZero();
    error LengthMismatch();
    error OwnershipCannotBeRenounced();
    error UpgradeImplZero();
    error NotAdminOrOwner(address caller); // onlyAdminOrOwner gate
    error AdminZero(); //                     setAdmin(address(0))

    // ─── Events (admin role) ────────────────────────────────────────────
    //
    // Declared on the implementation rather than in IExitFeeController:
    // that file is the cross-pragma interface consumed by product code and
    // mirrored by the v0_4 variant, and the two must stay ABI-identical.
    // The admin role is an owner-side surface that product code never
    // touches, so the shared interface stays untouched.

    event AdminSet(address indexed admin);

    // ─── Modifiers ──────────────────────────────────────────────────────

    /// @dev The `admin` guardian OR the `Ownable2Step` owner. Gates only
    ///      the operational levers (`setExitFeeEnabled`, `setFeeReceiver`);
    ///      every other setter stays `onlyOwner`.
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

    // ─── Admin: global state ────────────────────────────────────────────

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

    // ─── Admin: policy setters ──────────────────────────────────────────
    //
    // `surfaceId` is an opaque operation-kind identifier. The off-chain
    // naming convention is `keccak256("COLFEE:<NAME>")`; the controller
    // stores the bytes32 as-is and never inspects the name.

    /// @notice Configure (or update) the surface tier for `surfaceId`.
    ///         The surface acts as the gate: with `policy.active == false`
    ///         the whole surface is off and sub-product / actor overrides
    ///         are ignored. Overwriting is idempotent.
    /// @param  surfaceId Opaque operation-kind identifier;
    ///         `keccak256("COLFEE:<SURFACE_NAME>")` by convention.
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
}
