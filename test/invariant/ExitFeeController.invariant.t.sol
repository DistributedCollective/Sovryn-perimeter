// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitFeeController} from "../../src/interfaces/IExitFeeController.sol";
import {ControllerHandler} from "./ControllerHandler.sol";

/// @title  ExitFeeController stateful invariants
/// @notice A `ControllerHandler` drives a bounded random walk of policy
///         set/remove/config/ownership calls, and after every call we assert
///         (a) the on-chain enumeration index AND every stored `RatePolicy`
///         equal the handler's ghost mirror, for all three tiers and every
///         surface, (b) the owner is never `address(0)`, (c) once the fee
///         receiver has been written it never regresses to `address(0)`,
///         (d) the guards the handler probes negatively still reject, and
///         (e) every quote conserves the gross amount it was given.
contract ExitFeeControllerInvariantTest is Test {
    ExitFeeController internal controller;
    ControllerHandler internal handler;

    function setUp() public {
        ExitFeeController impl = new ExitFeeController();
        // Deployer (this test contract) is the initial owner via the sentinel.
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        controller = ExitFeeController(address(proxy));

        handler = new ControllerHandler(controller);

        // Hand ownership to the handler (2-step) so it can drive onlyOwner calls.
        controller.transferOwnership(address(handler));
        handler.acceptControllerOwnership();

        // Restrict the fuzzer to the action functions — exclude the one-time
        // `acceptControllerOwnership` bootstrap helper (it reverts once ownership
        // is already accepted and would otherwise dilute the random walk).
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ControllerHandler.setSubProductPolicy.selector;
        selectors[1] = ControllerHandler.removeSubProductPolicy.selector;
        selectors[2] = ControllerHandler.setActorPolicy.selector;
        selectors[3] = ControllerHandler.removeActorPolicy.selector;
        selectors[4] = ControllerHandler.setSurfacePolicy.selector;
        selectors[5] = ControllerHandler.setFeeReceiver.selector;
        selectors[6] = ControllerHandler.flipExitFeeEnabled.selector;
        selectors[7] = ControllerHandler.setFeeReceiverMaybeZero.selector;
        selectors[8] = ControllerHandler.attemptRenounceOwnership.selector;
        selectors[9] = ControllerHandler.rotateOwnership.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The sub-product tier matches the ghost mirror on every surface:
    ///         the same set of keys in the enumeration index, and the same
    ///         stored `RatePolicy` behind every address in the handler's pool
    ///         — including addresses currently absent from the index, which is
    ///         where a removal that forgets to clear the policy hides.
    function invariant_subProductKeys_match_ghost() public view {
        for (uint256 i = 0; i < handler.surfaceCount(); ++i) {
            bytes32 s = handler.surface(i);
            _assertSameSet(controller.subProductKeys(s), handler.ghostSubKeys(s));
            for (uint256 j = 0; j < handler.addrCount(); ++j) {
                address a = handler.addrAt(j);
                _assertSamePolicy(
                    controller.subProductPolicy(s, a), handler.ghostSubPolicy(s, a), "subProduct"
                );
            }
        }
    }

    /// @notice Same for actor overrides.
    function invariant_actorKeys_match_ghost() public view {
        for (uint256 i = 0; i < handler.surfaceCount(); ++i) {
            bytes32 s = handler.surface(i);
            _assertSameSet(controller.actorKeys(s), handler.ghostActorKeys(s));
            for (uint256 j = 0; j < handler.addrCount(); ++j) {
                address a = handler.addrAt(j);
                _assertSamePolicy(controller.actorPolicy(s, a), handler.ghostActorPolicy(s, a), "actor");
            }
        }
    }

    /// @notice The surface tier — the gate the other two tiers hang off — also
    ///         matches the ghost. It has no enumeration index, so the stored
    ///         value is the only thing to compare.
    function invariant_surfacePolicies_match_ghost() public view {
        for (uint256 i = 0; i < handler.surfaceCount(); ++i) {
            bytes32 s = handler.surface(i);
            _assertSamePolicy(controller.surfacePolicy(s), handler.ghostSurfacePolicy(s), "surface");
        }
    }

    /// @notice Ownership can never reach the zero address. The walk includes an
    ///         `attemptRenounceOwnership` action and a full 2-step transfer /
    ///         accept rotation, so this is a reachable assertion: re-enabling
    ///         renounce zeroes the owner and trips it.
    function invariant_owner_never_zero() public view {
        assertTrue(controller.owner() != address(0), "owner is zero");
    }

    /// @notice Once `setFeeReceiver` has accepted a write, the stored receiver
    ///         stays non-zero. The walk attempts zero writes directly
    ///         (`setFeeReceiverMaybeZero`), so dropping the setter's zero check
    ///         trips this.
    function invariant_feeReceiver_monotone() public view {
        if (handler.everSetFeeReceiver()) {
            assertTrue(controller.feeReceiver() != address(0), "feeReceiver regressed to zero");
        }
    }

    /// @notice The guards the handler probes negatively still hold: calls that
    ///         must revert did revert, with the documented error, and every
    ///         intermediate state of the 2-step ownership rotation was where
    ///         `Ownable2Step` promises. The handler records these on ghost flags
    ///         instead of reverting — a reverting handler call is discarded by
    ///         the fuzzer and would never be reported.
    function invariant_negative_probes_hold() public view {
        assertFalse(handler.sawUnexpectedSuccess(), "a call that must revert succeeded");
        assertFalse(handler.sawUnexpectedRevert(), "a call reverted with the wrong error");
        assertFalse(handler.ownershipMisbehaved(), "2-step ownership transition off-spec");
    }

    /// @notice Every quote conserves the gross amount it was handed: the fee
    ///         never exceeds gross, and fee + net == gross. Checked on every
    ///         surface, for a per-instance pair and for the `address(0)`
    ///         sub-product sentinel, at dust / ordinary / overflow-guard
    ///         magnitudes. Holds on the off-state paths too, where the quote
    ///         returns fee == 0 and net == gross.
    function invariant_quote_conserves_gross() public view {
        uint256[3] memory grosses = [uint256(1), 1e18, type(uint256).max];
        address subProduct = handler.addrAt(0);
        address actorA = handler.addrAt(1);
        address actorB = handler.addrAt(2);

        for (uint256 i = 0; i < handler.surfaceCount(); ++i) {
            bytes32 s = handler.surface(i);
            for (uint256 g = 0; g < grosses.length; ++g) {
                // Per-instance pair: exercises the sub-product tier.
                _assertQuoteConserves(s, subProduct, actorA, grosses[g]);
                // Sentinel pair: surfaces with no per-instance dimension pass
                // `address(0)`, and the sub-product map is skipped entirely.
                _assertQuoteConserves(s, address(0), actorB, grosses[g]);
            }
        }
    }

    /// @dev Order-insensitive set equality for two address arrays known to hold
    ///      unique elements (both are EnumerableSet snapshots).
    function _assertSameSet(address[] memory onchain, address[] memory ghost) internal pure {
        assertEq(onchain.length, ghost.length, "index/ghost length mismatch");
        for (uint256 i = 0; i < onchain.length; ++i) {
            bool found;
            for (uint256 j = 0; j < ghost.length; ++j) {
                if (onchain[i] == ghost[j]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "on-chain key missing from ghost");
        }
    }

    /// @dev Field-by-field equality of a stored policy against its ghost.
    function _assertSamePolicy(
        IExitFeeController.RatePolicy memory onchain,
        IExitFeeController.RatePolicy memory ghost,
        string memory tier
    ) internal pure {
        assertEq(onchain.active, ghost.active, string.concat(tier, ": active diverged from ghost"));
        assertEq(onchain.rateBps, ghost.rateBps, string.concat(tier, ": rateBps diverged from ghost"));
    }

    function _assertQuoteConserves(bytes32 surfaceId, address subProduct, address actor, uint256 gross)
        internal
        view
    {
        IExitFeeController.ExitFeeQuote memory q =
            controller.quoteExitFee(surfaceId, subProduct, actor, gross);
        assertLe(q.feeAmount, gross, "fee exceeds gross");
        assertEq(q.netAmount, gross - q.feeAmount, "fee + net != gross");
    }
}
