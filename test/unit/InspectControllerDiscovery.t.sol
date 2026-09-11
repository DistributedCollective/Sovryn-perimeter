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
///      so proving that union CONTAINS an actor-only id is
///      exactly the "dump path discovers it" regression.
contract InspectHarness is InspectController {
    function probeSurfaceIds(ExitFeeController c) external view returns (bytes32[] memory) {
        return _probeSurfaceIds(c);
    }

    function delayLengthNote(bool enabled, uint32 length) external pure returns (string memory) {
        return _delayLengthNote(enabled, length);
    }

    function resolvedDelay(ExitFeeController c, bytes32 id, address sub, address actor)
        external
        returns (string memory)
    {
        return _resolvedDelay(c, id, sub, actor);
    }

    function resolvedFee(ExitFeeController c, bytes32 id, address sub, address actor)
        external
        view
        returns (string memory)
    {
        return _resolvedFee(c, id, sub, actor);
    }

    function resolutionSubProducts(address[] memory keys) external pure returns (address[] memory) {
        return _resolutionSubProducts(keys);
    }

    /// @dev Runs the real dump printers and returns the stored-row lines they
    ///      printed, fee side and delay side.
    function printRows(ExitFeeController c, string memory surfaceName)
        external
        returns (string[] memory feeRows, string[] memory delayRows)
    {
        feeRows = _printSurface(c, surfaceName);
        delayRows = _printDelayBypassRegistry(c);
    }
}

/// @dev Controller stand-in that keeps its delay switch and length at slot 0,
///      not where the controller keeps them, and quotes the length only while
///      the switch reads on.
contract SwitchElsewhere {
    bool public securityPerimeterEnabled;
    uint32 public globalDelaySeconds = 3600;

    function quoteExitDelay(bytes32, address, address) external view returns (uint32) {
        return securityPerimeterEnabled ? globalDelaySeconds : 0;
    }
}

/// @title — InspectController discovery completeness
contract InspectControllerDiscoveryTest is Test {
    address constant OWNER = address(0xC0FFEE);
    address constant ACTOR = address(0xAC);
    address constant SUB = address(0x1750D);

    // A named fee surface, and two ARBITRARY surfaces never registered as fee surfaces.
    bytes32 constant NAMED = keccak256("PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW");
    bytes32 constant ARB_ACTOR = keccak256("ARBITRARY:ACTOR:ONLY");

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

    // ── resolved values beside stored rows ──

    address constant VAULT = address(0xBA);

    /// @dev A delay entry written inactive falls through. When a broader tier
    ///      exempts, the row's resolved value must read exempt, not the stored
    ///      "active=false" that looks like a revocation.
    function test_resolved_delay_shows_an_inactive_entry_still_exempt_through_the_surface() public {
        vm.startPrank(OWNER);
        controller.setGlobalDelaySeconds(1 hours);
        controller.setSecurityPerimeterEnabled(true);
        controller.setSurfaceBypass(NAMED, IExitFeeController.DelayBypassPolicy({active: true, bypass: true}));
        controller.setActorBypass(NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: false, bypass: false}));
        controller.setSubProductBypass(NAMED, SUB, IExitFeeController.DelayBypassPolicy({active: false, bypass: false}));
        vm.stopPrank();

        assertEq(
            harness.resolvedDelay(controller, NAMED, address(0), ACTOR), "resolves exempt (0s) for sub-product none"
        );
        assertEq(
            harness.resolvedDelay(controller, NAMED, SUB, address(0)),
            string.concat("resolves exempt (0s) for sub-product ", vm.toString(SUB), ", actor without an entry")
        );
    }

    /// @dev The controller keeps the delay switch (lowest byte) and length (next
    ///      four bytes) packed in this slot.
    bytes32 constant DELAY_SWITCH_SLOT = bytes32(uint256(271));

    /// @dev While the delay is switched off every row reads 0s now, so each row
    ///      also shows what it would resolve to once switched on: an inactive
    ///      actor entry still exempt through the surface reads exempt, a held
    ///      row names the length. The simulation leaves the controller's state
    ///      as it found it.
    function test_resolved_delay_shows_what_a_switched_off_row_would_resolve_once_switched_on() public {
        vm.startPrank(OWNER);
        controller.setGlobalDelaySeconds(1 hours);
        controller.setSurfaceBypass(NAMED, IExitFeeController.DelayBypassPolicy({active: true, bypass: true}));
        controller.setActorBypass(NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: false, bypass: false}));
        controller.setSubProductBypass(NAMED, SUB, IExitFeeController.DelayBypassPolicy({active: true, bypass: false}));
        vm.stopPrank();
        bytes32 before = vm.load(address(controller), DELAY_SWITCH_SLOT);

        assertEq(
            harness.resolvedDelay(controller, NAMED, address(0), ACTOR),
            "resolves 0s (delay switched off) for sub-product none; would resolve once switched on: exempt (0s)"
        );
        assertEq(
            harness.resolvedDelay(controller, NAMED, SUB, ACTOR),
            string.concat(
                "resolves 0s (delay switched off) for sub-product ",
                vm.toString(SUB),
                "; would resolve once switched on: delayed 3600s"
            )
        );

        assertEq(vm.load(address(controller), DELAY_SWITCH_SLOT), before, "switch and length written back");
        assertFalse(controller.securityPerimeterEnabled(), "switch still off");
        assertEq(controller.globalDelaySeconds(), 1 hours, "length unchanged");
    }

    /// @dev Switched off with the length unset: a row that would be held says so
    ///      without printing the placeholder length, an exempt row reads exempt,
    ///      and the length stays unset.
    function test_resolved_delay_once_switched_on_names_a_hold_while_the_length_is_unset() public {
        vm.prank(OWNER);
        controller.setSurfaceBypass(NAMED, IExitFeeController.DelayBypassPolicy({active: true, bypass: true}));
        bytes32 before = vm.load(address(controller), DELAY_SWITCH_SLOT);

        assertEq(
            harness.resolvedDelay(controller, NAMED, address(0), ACTOR),
            "resolves 0s (delay switched off) for sub-product none; would resolve once switched on: exempt (0s)"
        );
        assertEq(
            harness.resolvedDelay(controller, ARB_ACTOR, address(0), ACTOR),
            "resolves 0s (delay switched off) for sub-product none; would resolve once switched on: held (length unset - the Owner sets it before switching on)"
        );

        assertEq(vm.load(address(controller), DELAY_SWITCH_SLOT), before, "switch and length written back");
        assertEq(controller.globalDelaySeconds(), 0, "length still unset");
    }

    /// @dev When the switch does not read back as written, the inspector says it
    ///      could not simulate instead of reporting a value, and writes the slot
    ///      back.
    function test_resolved_delay_refuses_to_simulate_when_the_switch_lives_elsewhere() public {
        SwitchElsewhere elsewhere = new SwitchElsewhere();

        assertEq(
            harness.resolvedDelay(ExitFeeController(address(elsewhere)), NAMED, address(0), ACTOR),
            "resolves 0s (delay switched off) for sub-product none; would resolve once switched on: NOT SIMULATED - the switch and length are not at the storage slot this inspector writes"
        );

        assertEq(vm.load(address(elsewhere), DELAY_SWITCH_SLOT), bytes32(0), "slot written back");
        assertFalse(elsewhere.securityPerimeterEnabled(), "stand-in switch untouched");
    }

    /// @dev A held withdrawal names its length; a switched-off delay is not
    ///      reported as an exemption.
    function test_resolved_delay_names_a_hold_and_the_switched_off_state() public {
        vm.prank(OWNER);
        controller.setActorBypass(NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: false, bypass: true}));
        assertEq(
            harness.resolvedDelay(controller, NAMED, address(0), ACTOR),
            "resolves 0s (delay switched off) for sub-product none; would resolve once switched on: held (length unset - the Owner sets it before switching on)"
        );

        vm.startPrank(OWNER);
        controller.setGlobalDelaySeconds(1 hours);
        controller.setSecurityPerimeterEnabled(true);
        vm.stopPrank();
        assertEq(
            harness.resolvedDelay(controller, NAMED, address(0), ACTOR), "resolves delayed 3600s for sub-product none"
        );
    }

    /// @dev A fee entry written inactive falls through too; an exempt surface
    ///      must show through on the actor row.
    function test_resolved_fee_shows_an_inactive_entry_still_exempt_through_the_surface() public {
        vm.startPrank(OWNER);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(NAMED, IExitFeeController.RatePolicy({active: true, rateBps: 0}));
        controller.setActorPolicy(NAMED, ACTOR, IExitFeeController.RatePolicy({active: false, rateBps: 25}));
        vm.stopPrank();

        assertEq(
            harness.resolvedFee(controller, NAMED, address(0), ACTOR),
            "resolves exempt (0 bps) on sample gross 1e18 for sub-product none"
        );
    }

    /// @dev A charge names its rate and amount; the two off states name why no
    ///      fee applies; the sub-product used is part of the label.
    function test_resolved_fee_names_a_charge_and_the_off_states() public {
        vm.prank(OWNER);
        controller.setActorPolicy(NAMED, ACTOR, IExitFeeController.RatePolicy({active: false, rateBps: 25}));
        assertEq(
            harness.resolvedFee(controller, NAMED, address(0), ACTOR),
            "resolves no fee (INACTIVE: fee switch off) on sample gross 1e18 for sub-product none"
        );

        vm.startPrank(OWNER);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        vm.stopPrank();
        assertEq(
            harness.resolvedFee(controller, NAMED, address(0), ACTOR),
            "resolves no fee (DISABLED: surface off or no fee receiver) on sample gross 1e18 for sub-product none"
        );

        vm.startPrank(OWNER);
        controller.setSurfacePolicy(NAMED, IExitFeeController.RatePolicy({active: true, rateBps: 10}));
        controller.setSubProductPolicy(NAMED, SUB, IExitFeeController.RatePolicy({active: true, rateBps: 0}));
        vm.stopPrank();
        assertEq(
            harness.resolvedFee(controller, NAMED, address(0), ACTOR),
            "resolves 10 bps, fee 1000000000000000 on sample gross 1e18 for sub-product none"
        );
        assertEq(
            harness.resolvedFee(controller, NAMED, SUB, ACTOR),
            string.concat("resolves exempt (0 bps) on sample gross 1e18 for sub-product ", vm.toString(SUB))
        );
    }

    /// @dev Compares printed rows line by line, then the row count.
    function _assertRows(string[] memory got, string[] memory want) internal pure {
        uint256 common = got.length < want.length ? got.length : want.length;
        for (uint256 i = 0; i < common; i++) {
            assertEq(got[i], want[i], string.concat("printed row ", vm.toString(i)));
        }
        assertEq(got.length, want.length, "printed row count");
    }

    /// @dev The dump path itself prints the resolved lines for every stored row
    ///      on both sides, and every printed line is checked. The actor here is
    ///      inactive on both sides: at no sub-product it pays 10 bps and is held,
    ///      at the stored sub-product it is exempt from both, and the dump prints
    ///      both lines. An actor row that resolves at fewer sub-products fails.
    function test_dump_prints_resolved_rows_on_both_sides() public {
        vm.startPrank(OWNER);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(NAMED, IExitFeeController.RatePolicy({active: true, rateBps: 10}));
        controller.setSubProductPolicy(NAMED, SUB, IExitFeeController.RatePolicy({active: true, rateBps: 0}));
        controller.setActorPolicy(NAMED, ACTOR, IExitFeeController.RatePolicy({active: false, rateBps: 25}));
        controller.setGlobalDelaySeconds(1 hours);
        controller.setSecurityPerimeterEnabled(true);
        controller.setSubProductBypass(NAMED, SUB, IExitFeeController.DelayBypassPolicy({active: true, bypass: true}));
        controller.setActorBypass(NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: false, bypass: false}));
        vm.stopPrank();

        (string[] memory feeRows, string[] memory delayRows) =
            harness.printRows(controller, "PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW");

        string[] memory fee = new string[](7);
        fee[0] = "  sub-products:";
        fee[1] = string.concat("    ", vm.toString(SUB), "  (active=true, rateBps=0)");
        fee[2] = string.concat(
            "      resolves exempt (0 bps) on sample gross 1e18 for sub-product ",
            vm.toString(SUB),
            ", actor without an entry"
        );
        fee[3] = "  actors:";
        fee[4] = string.concat("    ", vm.toString(ACTOR), "  (active=false, rateBps=25)");
        fee[5] = "      resolves 10 bps, fee 1000000000000000 on sample gross 1e18 for sub-product none";
        fee[6] = string.concat("      resolves exempt (0 bps) on sample gross 1e18 for sub-product ", vm.toString(SUB));
        _assertRows(feeRows, fee);

        string[] memory delay = new string[](5);
        delay[0] = string.concat("    sub-product ", vm.toString(SUB), "  (active=true, bypass=true)");
        delay[1] = string.concat(
            "      resolves exempt (0s) for sub-product ", vm.toString(SUB), ", actor without an entry"
        );
        delay[2] = string.concat("    actor       ", vm.toString(ACTOR), "  (active=false, bypass=false)");
        delay[3] = "      resolves delayed 3600s for sub-product none";
        delay[4] = string.concat("      resolves exempt (0s) for sub-product ", vm.toString(SUB));
        _assertRows(delayRows, delay);
    }

    /// @dev The dump path with the delay switched off, which is when exemptions
    ///      are reviewed: every delay row reads 0s now and also prints what it
    ///      would resolve to once switched on. The actor's entry is inactive and
    ///      the dump shows it still exempt through the surface at no
    ///      sub-product, and held at the stored sub-product.
    function test_dump_prints_what_each_delay_row_would_resolve_once_switched_on() public {
        vm.startPrank(OWNER);
        controller.setGlobalDelaySeconds(1 hours);
        controller.setSurfaceBypass(NAMED, IExitFeeController.DelayBypassPolicy({active: true, bypass: true}));
        controller.setActorBypass(NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: false, bypass: false}));
        controller.setSubProductBypass(NAMED, SUB, IExitFeeController.DelayBypassPolicy({active: true, bypass: false}));
        vm.stopPrank();

        (, string[] memory delayRows) = harness.printRows(controller, "PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW");

        string[] memory delay = new string[](5);
        delay[0] = string.concat("    sub-product ", vm.toString(SUB), "  (active=true, bypass=false)");
        delay[1] = string.concat(
            "      resolves 0s (delay switched off) for sub-product ",
            vm.toString(SUB),
            ", actor without an entry; would resolve once switched on: delayed 3600s"
        );
        delay[2] = string.concat("    actor       ", vm.toString(ACTOR), "  (active=false, bypass=false)");
        delay[3] =
            "      resolves 0s (delay switched off) for sub-product none; would resolve once switched on: exempt (0s)";
        delay[4] = string.concat(
            "      resolves 0s (delay switched off) for sub-product ",
            vm.toString(SUB),
            "; would resolve once switched on: delayed 3600s"
        );
        _assertRows(delayRows, delay);
        assertFalse(controller.securityPerimeterEnabled(), "switch still off after the dump");
    }

    /// @dev An actor row resolves at no sub-product and at every stored one, so
    ///      an exemption reachable only through a sub-product entry is shown.
    function test_actor_rows_resolve_at_no_sub_product_and_every_stored_one() public view {
        address[] memory keys = new address[](2);
        keys[0] = SUB;
        keys[1] = address(0xB2);
        address[] memory subs = harness.resolutionSubProducts(keys);
        assertEq(subs.length, 3);
        assertEq(subs[0], address(0));
        assertEq(subs[1], SUB);
        assertEq(subs[2], address(0xB2));
    }

    /// @dev The status dump never prints a zero length bare: zero means unset,
    ///      switching on is refused while it is, and a switch that reads on with
    ///      a zero length holds nothing.
    function test_status_dump_explains_a_zero_delay_length() public view {
        assertEq(
            harness.delayLengthNote(false, 0),
            "  (0 = unset: switching the delay on is refused until the Owner sets a length)"
        );
        assertEq(
            harness.delayLengthNote(true, 0),
            "  WARNING: switched on with the length unset (0) - no withdrawal is held"
        );
        assertEq(harness.delayLengthNote(false, 1 hours), "");
        assertEq(harness.delayLengthNote(true, 1 hours), "");
    }

    /// @dev The probe set is deduplicated: a surfaceId that is named AND carries
    ///      bypass entries appears exactly once.
    function test_probe_dedups_named_and_touched_surface() public {
        vm.startPrank(OWNER);
        controller.setActorBypass(
            NAMED, ACTOR, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );
        vm.stopPrank();

        bytes32[] memory ids = harness.probeSurfaceIds(controller);
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == NAMED) count++;
        }
        assertEq(count, 1, "named+touched surface appears exactly once");
    }
}
