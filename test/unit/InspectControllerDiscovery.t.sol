// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitFeeController} from "../../src/interfaces/IExitFeeController.sol";
import {InspectController} from "../../script/InspectController.s.sol";

/// @dev Test harness exposing InspectController's internal discovery driver so
///      the dump-path can be exercised without deployment artifacts / RPC. The
///      inspector prints from `_probeSurfaceIds` (the any-tier-touched union),
///      so proving that union CONTAINS an actor-only / passthrough-only id is
///      exactly the "dump path discovers it" regression.
contract InspectHarness is InspectController {
    function probeSurfaceIds(ExitFeeController c) external view returns (bytes32[] memory) {
        return _probeSurfaceIds(c);
    }
}

/// @title — InspectController discovery completeness
contract InspectControllerDiscoveryTest is Test {
    address constant OWNER = address(0xC0FFEE);
    address constant ACTOR = address(0xAC);
    address constant SUB = address(0x1750D);
    address constant WRAP = address(0x323A99);

    // A named fee surface, and two ARBITRARY surfaces never registered as fee surfaces.
    bytes32 constant NAMED = keccak256("COLFEE:SURFACE_LENDING_LENDER_WITHDRAW");
    bytes32 constant ARB_ACTOR = keccak256("ARBITRARY:ACTOR:ONLY");
    bytes32 constant ARB_PASS = keccak256("ARBITRARY:PASSTHROUGH:ONLY");

    ExitFeeController controller;
    InspectHarness harness;

    function setUp() public {
        ExitFeeController impl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, OWNER);
        controller = ExitFeeController(address(new ERC1967Proxy(address(impl), init)));
        harness = new InspectHarness();
    }

    function _contains(bytes32[] memory ids, bytes32 x) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == x) return true;
        }
        return false;
    }

    /// @dev The exact gap: an actor-ONLY bypass under an arbitrary surfaceId with
    ///      NO prior setSurfaceBypass must appear in the inspector's probe set.
    function test_probe_discovers_actor_only_bypass_under_arbitrary_surface() public {
        vm.prank(OWNER);
        controller.setActorBypass(
            ARB_ACTOR, ACTOR, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );

        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        assertTrue(_contains(ids, ARB_ACTOR), "actor-only arbitrary surface discovered by dump path");
        // Named fee surfaces are always folded in (human rows).
        assertTrue(_contains(ids, NAMED), "named fee surface always probed");
    }

    /// @dev A sub-product-ONLY bypass under an arbitrary surfaceId is discovered.
    function test_probe_discovers_subproduct_only_bypass() public {
        vm.prank(OWNER);
        controller.setSubProductBypass(
            ARB_ACTOR, SUB, IExitFeeController.DelayBypassPolicy({active: true, bypass: false})
        );
        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        assertTrue(_contains(ids, ARB_ACTOR), "sub-product-only arbitrary surface discovered");
    }

    /// @dev A passthrough-ONLY entry under an arbitrary surfaceId (no bypass at any
    ///      tier, not named) is discovered via passthroughSurfaceIds().
    function test_probe_discovers_passthrough_only_entry() public {
        vm.prank(OWNER);
        controller.setPassthroughActor(ARB_PASS, WRAP, true);
        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        assertTrue(_contains(ids, ARB_PASS), "passthrough-only arbitrary surface discovered");
    }

    /// @dev removeSurfaceBypass while an actor entry stays live keeps the id in
    ///      the probe set (retention-only master set).
    function test_probe_retains_id_after_removeSurfaceBypass_with_live_actor() public {
        vm.startPrank(OWNER);
        controller.setSurfaceBypass(
            ARB_ACTOR, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );
        controller.setActorBypass(
            ARB_ACTOR, ACTOR, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );
        controller.removeSurfaceBypass(ARB_ACTOR);
        vm.stopPrank();

        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        assertTrue(
            _contains(ids, ARB_ACTOR),
            "id retained in probe set while actor tier live after surface hard-remove"
        );
    }

    /// @dev The probe set is deduplicated: a surfaceId that is named AND carries
    ///      bypass + passthrough entries appears exactly once.
    function test_probe_dedups_named_and_touched_surface() public {
        vm.startPrank(OWNER);
        controller.setActorBypass(
            NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );
        controller.setPassthroughActor(NAMED, WRAP, true);
        vm.stopPrank();

        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == NAMED) count++;
        }
        assertEq(count, 1, "named+touched surface appears exactly once");
    }
}
