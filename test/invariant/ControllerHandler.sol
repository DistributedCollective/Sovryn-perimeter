// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitFeeController} from "../../src/interfaces/IExitFeeController.sol";

/// @title  OwnerAgent
/// @notice Stand-in owner used by the handler's 2-step ownership rotation.
///         `acceptOwnership` is callable only by the pending owner, so a
///         rotation needs a second real address that can execute the
///         owner-side half of the handoff and then give ownership back.
contract OwnerAgent {
    function acceptControllerOwnership(ExitFeeController controller) external {
        controller.acceptOwnership();
    }

    function startControllerHandoff(ExitFeeController controller, address newOwner) external {
        controller.transferOwnership(newOwner);
    }
}

/// @title  ControllerHandler
/// @notice Stateful-invariant handler that drives a bounded random walk of
///         `set*` / `remove*` / `setSurfacePolicy` / `setFeeReceiver` /
///         `flipExitFeeEnabled` / ownership calls against a live
///         `ExitFeeController`, while maintaining an independent ghost mirror
///         of BOTH the enumeration-index membership AND the stored
///         `RatePolicy` value behind every key. The invariant contract then
///         asserts the on-chain index and every stored policy equal the ghost
///         after each call — so an index-vs-policy desync in
///         `_writeSubProductPolicy` / `_removeSubProductPolicy` (and the actor
///         equivalents) shows up whether the drift is in the index, in the
///         stored value, or in only one of the two.
///
/// @dev    The handler is the controller's OWNER (the invariant `setUp` hands
///         ownership to it), so every `onlyOwner` call lands. Inputs are bounded
///         to a small pool of non-zero surfaces/addresses and `rateBps <= MAX_BPS`
///         so calls succeed (the run stays non-vacuous) and re-use the same keys
///         enough to exercise update + remove paths.
///
///         Two actions are deliberate NEGATIVE probes — `attemptRenounceOwnership`
///         and `setFeeReceiverMaybeZero` with a zero receiver. Both are expected
///         to revert, so both are wrapped in try/catch: the walk stays
///         revert-free, and a guard that stops guarding is recorded on a ghost
///         flag (`sawUnexpectedSuccess` / `sawUnexpectedRevert`) that the
///         invariant contract asserts. A reverting handler call would otherwise
///         be silently discarded by the fuzzer and prove nothing.
contract ControllerHandler {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint16 internal constant MAX_BPS = 10_000;

    ExitFeeController public immutable controller;

    // Bounded pools.
    bytes32[4] internal _surfaces;
    address[8] internal _addrs;
    address[4] internal _receivers;
    OwnerAgent[3] internal _agents;

    // Ghost mirrors of the on-chain enumeration index, keyed by surface.
    mapping(bytes32 => EnumerableSet.AddressSet) internal _ghostSubKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _ghostActorKeys;

    // Ghost mirrors of the stored RatePolicy behind each key. Kept for every
    // address in `_addrs`, not just the ones currently in the index: a removal
    // that drops the index entry but leaves the policy behind is exactly the
    // desync worth catching, and such an address is in NEITHER key set.
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _ghostSubPolicy;
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _ghostActorPolicy;
    mapping(bytes32 => IExitFeeController.RatePolicy) internal _ghostSurfacePolicy;

    /// @notice True once `setFeeReceiver` has accepted a write of any value.
    ///         Arms `invariant_feeReceiver_monotone`: past this point the
    ///         stored receiver must be non-zero.
    bool public everSetFeeReceiver;

    /// @notice A call that MUST revert returned successfully.
    bool public sawUnexpectedSuccess;

    /// @notice A call reverted, but not with the error the guard promises.
    bool public sawUnexpectedRevert;

    /// @notice An intermediate step of the 2-step ownership rotation left
    ///         `owner()` / `pendingOwner()` somewhere other than where
    ///         `Ownable2Step` says they should be.
    bool public ownershipMisbehaved;

    constructor(ExitFeeController controller_) {
        controller = controller_;

        _surfaces[0] = keccak256("PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW");
        _surfaces[1] = keccak256("PERIMETER_SURFACE_LENDING_BORROWER_WITHDRAW");
        _surfaces[2] = keccak256("PERIMETER_SURFACE_ZERO_WITHDRAW_COLL");
        _surfaces[3] = keccak256("PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY");

        for (uint256 i = 0; i < 8; ++i) {
            _addrs[i] = address(uint160(0xA00 + i + 1)); // all non-zero
        }
        for (uint256 i = 0; i < 4; ++i) {
            _receivers[i] = address(uint160(0xBEEF00 + i + 1)); // all non-zero
        }
        for (uint256 i = 0; i < 3; ++i) {
            _agents[i] = new OwnerAgent();
        }
    }

    /// @notice Called once by the invariant `setUp` to complete the 2-step
    ///         ownership handoff so the handler can drive `onlyOwner` calls.
    function acceptControllerOwnership() external {
        controller.acceptOwnership();
    }

    // ─── Bounded selectors ──────────────────────────────────────────────────

    function _surface(uint8 i) internal view returns (bytes32) {
        return _surfaces[i % _surfaces.length];
    }

    function _addr(uint8 i) internal view returns (address) {
        return _addrs[i % _addrs.length];
    }

    function _policy(bool active, uint16 rateBps)
        internal
        pure
        returns (IExitFeeController.RatePolicy memory)
    {
        return IExitFeeController.RatePolicy({active: active, rateBps: uint16(rateBps % (MAX_BPS + 1))});
    }

    // ─── Actions (fuzzed by the invariant engine) ──────────────────────────

    function setSubProductPolicy(uint8 sIdx, uint8 aIdx, bool active, uint16 rateBps) external {
        bytes32 s = _surface(sIdx);
        address a = _addr(aIdx);
        IExitFeeController.RatePolicy memory p = _policy(active, rateBps);
        controller.setSubProductPolicy(s, a, p);
        _ghostSubKeys[s].add(a); // every write adds the key (idempotent), mirrors the contract
        _ghostSubPolicy[s][a] = p;
    }

    function removeSubProductPolicy(uint8 sIdx, uint8 aIdx) external {
        bytes32 s = _surface(sIdx);
        address a = _addr(aIdx);
        controller.removeSubProductPolicy(s, a);
        // Mirrors the contract's gate: the stored policy is cleared only when
        // the key was actually in the index.
        if (_ghostSubKeys[s].remove(a)) {
            delete _ghostSubPolicy[s][a];
        }
    }

    function setActorPolicy(uint8 sIdx, uint8 aIdx, bool active, uint16 rateBps) external {
        bytes32 s = _surface(sIdx);
        address a = _addr(aIdx);
        IExitFeeController.RatePolicy memory p = _policy(active, rateBps);
        controller.setActorPolicy(s, a, p);
        _ghostActorKeys[s].add(a);
        _ghostActorPolicy[s][a] = p;
    }

    function removeActorPolicy(uint8 sIdx, uint8 aIdx) external {
        bytes32 s = _surface(sIdx);
        address a = _addr(aIdx);
        controller.removeActorPolicy(s, a);
        if (_ghostActorKeys[s].remove(a)) {
            delete _ghostActorPolicy[s][a];
        }
    }

    function setSurfacePolicy(uint8 sIdx, bool active, uint16 rateBps) external {
        bytes32 s = _surface(sIdx);
        IExitFeeController.RatePolicy memory p = _policy(active, rateBps);
        controller.setSurfacePolicy(s, p);
        _ghostSurfacePolicy[s] = p;
    }

    function setFeeReceiver(uint8 rIdx) external {
        controller.setFeeReceiver(_receivers[rIdx % _receivers.length]); // always non-zero
        everSetFeeReceiver = true;
    }

    /// @notice Negative probe for the `FeeReceiverZero` guard. `useZero` forces
    ///         the zero address roughly half the time so the rejected branch is
    ///         reached reliably rather than left to the fuzzer's address
    ///         dictionary; otherwise the raw fuzzed address is used unbounded.
    ///         This is what makes `invariant_feeReceiver_monotone` reachable:
    ///         without it, no action in the walk can even attempt to zero the
    ///         field.
    function setFeeReceiverMaybeZero(address newReceiver, bool useZero) external {
        address target = useZero ? address(0) : newReceiver;
        try controller.setFeeReceiver(target) {
            // A write only ever gets to land for a non-zero receiver. If a zero
            // one landed, arm the monotonicity invariant on the way out so the
            // regression is reported against the field itself, not just here.
            if (target == address(0)) sawUnexpectedSuccess = true;
            everSetFeeReceiver = true;
        } catch (bytes memory err) {
            if (target != address(0) || bytes4(err) != ExitFeeController.FeeReceiverZero.selector) {
                sawUnexpectedRevert = true;
            }
        }
    }

    function flipExitFeeEnabled(bool enabled) external {
        controller.setExitFeeEnabled(enabled);
    }

    /// @notice Negative probe for the disabled `renounceOwnership`. This is the
    ///         only reachable action that could ever drive `owner()` to
    ///         `address(0)`, which is what makes `invariant_owner_never_zero`
    ///         a live assertion instead of a constant.
    function attemptRenounceOwnership() external {
        try controller.renounceOwnership() {
            // Ownership is now gone; `invariant_owner_never_zero` reports the
            // zero owner and this flag names the call that caused it.
            sawUnexpectedSuccess = true;
        } catch (bytes memory err) {
            if (bytes4(err) != ExitFeeController.OwnershipCannotBeRenounced.selector) {
                sawUnexpectedRevert = true;
            }
        }
    }

    /// @notice Full 2-step ownership cycle: hand the controller to one of the
    ///         stand-in agents, have it accept, then have it hand ownership
    ///         straight back so the handler keeps driving the `onlyOwner`
    ///         actions. Each intermediate state is checked against what
    ///         `Ownable2Step` guarantees; a mismatch is recorded on a ghost flag
    ///         rather than reverted, because a reverting handler call is
    ///         discarded by the fuzzer and would go unreported.
    function rotateOwnership(uint8 idx) external {
        OwnerAgent agent = _agents[idx % _agents.length];

        // Step 1: start the handoff. Ownership does not move yet.
        controller.transferOwnership(address(agent));
        if (controller.owner() != address(this) || controller.pendingOwner() != address(agent)) {
            ownershipMisbehaved = true;
        }

        // Step 2: the agent accepts and becomes owner; the pending slot clears.
        agent.acceptControllerOwnership(controller);
        if (controller.owner() != address(agent) || controller.pendingOwner() != address(0)) {
            ownershipMisbehaved = true;
        }

        // Step 3: the agent starts the handoff back to the handler.
        agent.startControllerHandoff(controller, address(this));
        if (controller.owner() != address(agent) || controller.pendingOwner() != address(this)) {
            ownershipMisbehaved = true;
        }

        // Step 4: the handler re-accepts and resumes ownership.
        controller.acceptOwnership();
        if (controller.owner() != address(this) || controller.pendingOwner() != address(0)) {
            ownershipMisbehaved = true;
        }
    }

    // ─── Ghost views (consumed by the invariant asserts) ────────────────────

    function surfaceCount() external view returns (uint256) {
        return _surfaces.length;
    }

    function surface(uint256 i) external view returns (bytes32) {
        return _surfaces[i];
    }

    function addrCount() external view returns (uint256) {
        return _addrs.length;
    }

    function addrAt(uint256 i) external view returns (address) {
        return _addrs[i];
    }

    function ghostSubKeys(bytes32 s) external view returns (address[] memory) {
        return _ghostSubKeys[s].values();
    }

    function ghostActorKeys(bytes32 s) external view returns (address[] memory) {
        return _ghostActorKeys[s].values();
    }

    function ghostSubPolicy(bytes32 s, address a)
        external
        view
        returns (IExitFeeController.RatePolicy memory)
    {
        return _ghostSubPolicy[s][a];
    }

    function ghostActorPolicy(bytes32 s, address a)
        external
        view
        returns (IExitFeeController.RatePolicy memory)
    {
        return _ghostActorPolicy[s][a];
    }

    function ghostSurfacePolicy(bytes32 s) external view returns (IExitFeeController.RatePolicy memory) {
        return _ghostSurfacePolicy[s];
    }
}
