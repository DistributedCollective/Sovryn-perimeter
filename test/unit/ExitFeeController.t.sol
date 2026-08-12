// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitFeeController} from "../../src/interfaces/IExitFeeController.sol";

/// @dev V2 mock used to prove UUPS upgrades preserve storage and admit a
///      new public function. Adds one piece of state (`version`) and
///      surfaces it through a `version()` view.
contract ExitFeeControllerV2Mock is ExitFeeController {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract ExitFeeControllerTest is Test {
    // Re-declared here so vm.expectEmit can match by topic signature.
    event SubProductPolicyRemoved(bytes32 indexed surfaceId, address indexed subProduct);
    event ActorPolicyRemoved(bytes32 indexed surfaceId, address indexed actor);
    event AdminSet(address indexed admin);

    ExitFeeController controller;

    // NOTE: `ADMIN` predates the contract's admin role -- it is the proxy
    // OWNER throughout this file. The operational guardian stored in
    // `ExitFeeController.admin` is `GUARDIAN` below.
    address constant ADMIN = address(0xA1);
    address constant GUARDIAN = address(0xAD);
    address constant VAULT = address(0xBA);
    address constant ACTOR = address(0xAC);
    address constant IXUSD = address(0x1750D); // dummy iToken proxy "iXUSD"
    address constant IWRBTC = address(0x1700ABC); // dummy iToken proxy "iWRBTC"
    address constant OTHER = address(0xBEEF);
    address constant CAFE = address(0xCAFE);

    bytes32 constant SURFACE = keccak256("COLFEE:SURFACE_LENDING_LENDER_WITHDRAW");
    bytes32 constant SURFACE_OTHER = keccak256("COLFEE:SURFACE_ZERO_WITHDRAW_COLL");

    function setUp() public {
        ExitFeeController impl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, ADMIN);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        controller = ExitFeeController(address(proxy));
    }

    function _quote(address sub, uint256 gross)
        internal
        view
        returns (IExitFeeController.ExitFeeQuote memory)
    {
        return controller.quoteExitFee(SURFACE, sub, ACTOR, gross);
    }

    // ─── initialize sentinel (deferred vs immediate ownership) ──────────
    // Mirrors the ExitFeeVault initialize tests: the controller shares the
    // same `initialize(address newOwner_)` sentinel, so its deferred-ownership
    // branch (newOwner_ == 0 / == msg.sender) must be pinned too.

    function test_initialize_zero_newOwner_keeps_deployer_as_owner() public {
        // Sentinel: address(0) means "leave the deployer as owner" -- the
        // bootstrap-flow path that defers the Safe handoff.
        ExitFeeController freshImpl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        // This test contract is the deployer (no vm.prank), so it owns.
        assertEq(ExitFeeController(address(proxy)).owner(), address(this));
    }

    function test_initialize_msg_sender_keeps_deployer_as_owner() public {
        // Same sentinel when the caller passes itself explicitly.
        ExitFeeController freshImpl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, address(this));
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        assertEq(ExitFeeController(address(proxy)).owner(), address(this));
    }

    function test_initialize_other_owner_transfers_immediately() public {
        // Legacy "Safe is owner from deploy": a non-zero, non-self address
        // triggers the immediate _transferOwnership.
        ExitFeeController freshImpl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, ADMIN);
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        assertEq(ExitFeeController(address(proxy)).owner(), ADMIN);
    }

    // ─── Off-state outcomes (active = false) ────────────────────────────

    function test_inactive_by_default() public view {
        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertFalse(q.active);
        assertEq(q.feeAmount, 0);
        assertEq(q.netAmount, 1_000_000);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.INACTIVE));
    }

    function test_enabled_no_policy_returns_disabled() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertFalse(q.active);
        assertEq(q.feeAmount, 0);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.DISABLED));
    }

    function test_inactive_surface_kills_all_overrides() public {
        // Surface gates the surface: active=false on the surface entry
        // suppresses sub-product AND actor overrides.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: false, rateBps: 20}));
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: 5}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IWRBTC, 1_000_000);
        assertFalse(q.active);
        assertEq(q.feeAmount, 0);
        assertEq(q.netAmount, 1_000_000);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.DISABLED));

        // Positive control: flipping ONLY the surface gate on must revive the
        // very overrides that were suppressed above. Without this the test
        // would pass just as happily against a controller whose fee path was
        // dead altogether -- it would prove nothing about the gate.
        vm.prank(ADMIN);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));

        IExitFeeController.ExitFeeQuote memory qOn = _quote(IWRBTC, 1_000_000);
        assertTrue(qOn.active);
        assertEq(qOn.rateBps, 5, "actor override applies once the gate is on");
        assertEq(qOn.feeAmount, 500);
        assertEq(qOn.reason, uint8(IExitFeeController.SkipReason.NONE));
    }

    // ─── Tier resolution: surface → subProduct → actor ──────────────────

    function test_surface_fallback_20bps() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertTrue(q.active);
        assertEq(q.feeAmount, 2_000);
        assertEq(q.netAmount, 998_000);
        assertEq(q.feeReceiver, VAULT);
        assertEq(q.rateBps, 20);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.NONE));
    }

    function test_subProduct_overrides_surface() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        controller.setSubProductPolicy(
            SURFACE, IXUSD, IExitFeeController.RatePolicy({active: true, rateBps: 50})
        );
        vm.stopPrank();

        assertEq(_quote(IWRBTC, 1_000_000).feeAmount, 3_000);
        assertEq(_quote(IXUSD, 1_000_000).feeAmount, 5_000);
        // Unconfigured iToken falls back to surface 20 bps.
        assertEq(_quote(OTHER, 1_000_000).feeAmount, 2_000);
    }

    function test_subProduct_zero_uses_surface_fallback() public {
        // Zero passes subProduct = address(0); controller MUST NOT consult
        // sub-product map for address(0) — it just falls through to surface.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));
        // A configured-and-active subProduct policy on a different iToken must
        // not leak into the address(0) path.
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(address(0), 1_000_000);
        assertTrue(q.active);
        assertEq(q.feeAmount, 2_000); // surface fallback, NOT iWRBTC's 30 bps
        assertEq(q.rateBps, 20);
    }

    function test_actor_policy_overrides_subProduct_and_surface() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: 5}));
        vm.stopPrank();

        // ACTOR pays 5 bps on iWRBTC even though sub-product = 30 bps, surface = 20 bps.
        IExitFeeController.ExitFeeQuote memory q = _quote(IWRBTC, 1_000_000);
        assertTrue(q.active);
        assertEq(q.feeAmount, 500);
        assertEq(q.rateBps, 5);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.NONE));
    }

    function test_inactive_actor_policy_falls_through() public {
        // Inactive actor entry must NOT consume the tier; resolution falls through.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: false, rateBps: 5}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertTrue(q.active);
        assertEq(q.feeAmount, 2_000); // surface rate, not the 5 bps from inactive actor entry
        assertEq(q.rateBps, 20);
    }

    // ─── Exemption / dust ────────────────────────────────────────────────

    function test_actor_policy_zero_rate_is_exemption() public {
        // Exemption = active actor policy with rateBps=0. No special reason code.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 50}));
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: 0}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertTrue(q.active); // policy IS active (at 0 rate)
        assertEq(q.feeAmount, 0); // ...so no fee
        assertEq(q.netAmount, 1_000_000);
        assertEq(q.rateBps, 0);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.NONE));

        // Per-surface: a different surface for the same actor charges normally.
        vm.prank(ADMIN);
        controller.setSurfacePolicy(SURFACE_OTHER, IExitFeeController.RatePolicy({active: true, rateBps: 50}));
        IExitFeeController.ExitFeeQuote memory q2 =
            controller.quoteExitFee(SURFACE_OTHER, address(0), ACTOR, 1_000_000);
        assertTrue(q2.active);
        assertEq(q2.feeAmount, 5_000);
    }

    function test_surface_zero_with_actor_override() public {
        // "Off-by-default with actor override": surface active at 0 bps,
        // ACTOR pays the override, everyone else pays nothing.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 0}));
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: 5}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory qActor = _quote(IXUSD, 1_000_000);
        assertTrue(qActor.active);
        assertEq(qActor.feeAmount, 500);

        IExitFeeController.ExitFeeQuote memory qOther =
            controller.quoteExitFee(SURFACE, IXUSD, OTHER, 1_000_000);
        assertTrue(qOther.active);
        assertEq(qOther.feeAmount, 0);
    }

    function test_dust_keeps_active_true_with_zero_fee() public {
        // 1 bps on 100 wei rounds to 0 fee. Policy is active; dust is the product's branch concern.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 1}));
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 100);
        assertTrue(q.active); // policy is active; not the same as "will charge"
        assertEq(q.feeAmount, 0); // ...but rounded to 0; product skips fee leg
        assertEq(q.netAmount, 100);
        assertEq(q.rateBps, 1);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.NONE));
    }

    // ─── Defensive: INVALID_QUOTE ────────────────────────────────────────

    function test_overflow_returns_invalid_quote() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 50}));
        vm.stopPrank();

        uint256 huge = type(uint256).max / 9_999; // would overflow gross * MAX_BPS
        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, huge);
        assertEq(q.reason, uint8(IExitFeeController.SkipReason.INVALID_QUOTE));
        assertFalse(q.active);
        assertEq(q.feeAmount, 0);
        assertEq(q.netAmount, huge); // synthesized echo of gross

        // Pin the guard's comparison direction at the boundary. `max / MAX_BPS`
        // is the largest gross whose `gross * MAX_BPS` still fits, so it MUST
        // produce an honest quote; one wei more MUST trip the guard. Without
        // both sides an off-by-one (`>` vs `>=`) is invisible.
        uint256 edge = type(uint256).max / 10_000;
        IExitFeeController.ExitFeeQuote memory qEdge = _quote(IXUSD, edge);
        assertTrue(qEdge.active, "gross == max/MAX_BPS must not trip the guard");
        assertEq(qEdge.reason, uint8(IExitFeeController.SkipReason.NONE));
        assertEq(qEdge.feeAmount, (edge * 50) / 10_000);

        IExitFeeController.ExitFeeQuote memory qOver = _quote(IXUSD, edge + 1);
        assertFalse(qOver.active, "one wei past the boundary must trip the guard");
        assertEq(qOver.reason, uint8(IExitFeeController.SkipReason.INVALID_QUOTE));
    }

    // ─── Admin / setter validation ───────────────────────────────────────

    function test_setRate_above_max_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeController.RateExceedsMaxBps.selector, uint16(10_001)));
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 10_001}));
    }

    function test_stranger_cannot_setExitFeeEnabled() public {
        // This test contract is neither owner nor admin after setUp.
        vm.expectRevert(abi.encodeWithSelector(ExitFeeController.NotAdminOrOwner.selector, address(this)));
        controller.setExitFeeEnabled(true);
    }

    // ─── Admin role (operational guardian) ───────────────────────────────

    function test_admin_unset_at_init() public view {
        assertEq(controller.admin(), address(0));
    }

    function test_setAdmin_sets_and_emits() public {
        vm.expectEmit(true, false, false, false, address(controller));
        emit AdminSet(GUARDIAN);
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        assertEq(controller.admin(), GUARDIAN);
    }

    function test_setAdmin_non_owner_reverts() public {
        // setAdmin stays owner-only -- the guardian cannot appoint itself
        // or a successor.
        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setAdmin(GUARDIAN);
    }

    function test_setAdmin_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.AdminZero.selector);
        controller.setAdmin(address(0));
    }

    function test_setAdmin_may_equal_owner() public {
        // admin == owner is a supported shape: one address may hold both roles.
        vm.prank(ADMIN);
        controller.setAdmin(ADMIN);
        assertEq(controller.admin(), ADMIN);
    }

    function test_admin_can_setExitFeeEnabled_both_directions() public {
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        controller.setExitFeeEnabled(true);
        assertTrue(controller.exitFeeEnabled());

        vm.prank(GUARDIAN);
        controller.setExitFeeEnabled(false);
        assertFalse(controller.exitFeeEnabled());
    }

    function test_admin_can_setFeeReceiver() public {
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        controller.setFeeReceiver(VAULT);
        assertEq(controller.feeReceiver(), VAULT);
    }

    function test_owner_retains_operational_levers_after_admin_set() public {
        vm.startPrank(ADMIN);
        controller.setAdmin(GUARDIAN);
        controller.setExitFeeEnabled(true);
        controller.setFeeReceiver(VAULT);
        vm.stopPrank();

        assertTrue(controller.exitFeeEnabled());
        assertEq(controller.feeReceiver(), VAULT);
    }

    function test_stranger_still_rejected_after_admin_set() public {
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeController.NotAdminOrOwner.selector, OTHER));
        controller.setFeeReceiver(VAULT);
    }

    function test_admin_cannot_touch_owner_only_setters() public {
        // The admin's authority is BOUNDED to the two operational levers.
        // Representative owner-only surfaces: policy config, rotation of
        // the admin itself, and UUPS upgrades.
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        IExitFeeController.RatePolicy memory p = IExitFeeController.RatePolicy({active: true, rateBps: 20});

        vm.prank(GUARDIAN);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setSurfacePolicy(SURFACE, p);

        vm.prank(GUARDIAN);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setAdmin(OTHER);

        ExitFeeControllerV2Mock v2 = new ExitFeeControllerV2Mock();
        vm.prank(GUARDIAN);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.upgradeTo(address(v2));
    }

    function test_setFeeReceiver_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.FeeReceiverZero.selector);
        controller.setFeeReceiver(address(0));
    }

    function test_set_address_zero_reverts() public {
        // Set-path mirror of test_remove_address_zero_reverts: the zero
        // check lives in _write*Policy, so singular setters hit it too.
        IExitFeeController.RatePolicy memory p = IExitFeeController.RatePolicy({active: true, rateBps: 20});
        vm.startPrank(ADMIN);
        vm.expectRevert(ExitFeeController.SubProductZero.selector);
        controller.setSubProductPolicy(SURFACE, address(0), p);
        vm.expectRevert(ExitFeeController.ActorZero.selector);
        controller.setActorPolicy(SURFACE, address(0), p);
        vm.stopPrank();
    }

    function test_batch_setters_length_mismatch_reverts() public {
        address[] memory addrs = new address[](2);
        addrs[0] = IWRBTC;
        addrs[1] = IXUSD;
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](1);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 30});

        vm.startPrank(ADMIN);
        vm.expectRevert(ExitFeeController.LengthMismatch.selector);
        controller.setSubProductPolicies(SURFACE, addrs, ps);
        vm.expectRevert(ExitFeeController.LengthMismatch.selector);
        controller.setActorPolicies(SURFACE, addrs, ps);
        vm.stopPrank();
    }

    function test_setActorPolicies_batch() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 20}));

        address[] memory actors = new address[](2);
        actors[0] = ACTOR;
        actors[1] = CAFE;
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](2);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 0}); // exempt
        ps[1] = IExitFeeController.RatePolicy({active: true, rateBps: 5}); // special rate
        controller.setActorPolicies(SURFACE, actors, ps);
        vm.stopPrank();

        assertEq(_quote(IXUSD, 1_000_000).feeAmount, 0);
        IExitFeeController.ExitFeeQuote memory q = controller.quoteExitFee(SURFACE, IXUSD, CAFE, 1_000_000);
        assertEq(q.feeAmount, 500);
    }

    function test_setSubProductPolicies_batch() public {
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 1})); // surface active

        address[] memory subs = new address[](2);
        subs[0] = IWRBTC;
        subs[1] = IXUSD;
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](2);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 30});
        ps[1] = IExitFeeController.RatePolicy({active: true, rateBps: 50});
        controller.setSubProductPolicies(SURFACE, subs, ps);
        vm.stopPrank();

        // Use a fresh actor with no actor-policy so resolution falls through to sub-product.
        assertEq(controller.quoteExitFee(SURFACE, IWRBTC, OTHER, 1_000_000).feeAmount, 3_000);
        assertEq(controller.quoteExitFee(SURFACE, IXUSD, OTHER, 1_000_000).feeAmount, 5_000);
    }

    // ─── Enumeration index (subProductKeys / actorKeys) ──────────────────

    function test_subProductKeys_tracks_singular_and_batch_writes() public {
        vm.startPrank(ADMIN);
        // Singular write
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );

        // Batch write -- includes IWRBTC again (idempotent add) plus IXUSD.
        address[] memory subs = new address[](2);
        subs[0] = IWRBTC;
        subs[1] = IXUSD;
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](2);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 30});
        ps[1] = IExitFeeController.RatePolicy({active: true, rateBps: 50});
        controller.setSubProductPolicies(SURFACE, subs, ps);
        vm.stopPrank();

        address[] memory keys = controller.subProductKeys(SURFACE);
        assertEq(keys.length, 2, "should dedupe IWRBTC");
        // Order is insertion order in EnumerableSet.
        assertEq(keys[0], IWRBTC);
        assertEq(keys[1], IXUSD);
    }

    function test_actorKeys_tracks_singular_and_batch_writes() public {
        vm.startPrank(ADMIN);
        controller.setActorPolicy(SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: 5}));

        address[] memory actors = new address[](2);
        actors[0] = CAFE;
        actors[1] = ACTOR; // duplicate -- must not appear twice
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](2);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 0});
        ps[1] = IExitFeeController.RatePolicy({active: true, rateBps: 5});
        controller.setActorPolicies(SURFACE, actors, ps);
        vm.stopPrank();

        address[] memory keys = controller.actorKeys(SURFACE);
        assertEq(keys.length, 2);
        assertEq(keys[0], ACTOR);
        assertEq(keys[1], CAFE);
    }

    function test_keys_isolated_per_surface() public {
        vm.startPrank(ADMIN);
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 10})
        );
        controller.setSubProductPolicy(
            SURFACE_OTHER, IXUSD, IExitFeeController.RatePolicy({active: true, rateBps: 20})
        );
        vm.stopPrank();

        address[] memory a = controller.subProductKeys(SURFACE);
        address[] memory b = controller.subProductKeys(SURFACE_OTHER);
        assertEq(a.length, 1);
        assertEq(a[0], IWRBTC);
        assertEq(b.length, 1);
        assertEq(b[0], IXUSD);
    }

    function test_removeSubProductPolicy_clears_index_and_mapping() public {
        vm.startPrank(ADMIN);
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );

        vm.expectEmit(true, true, false, false);
        emit SubProductPolicyRemoved(SURFACE, IWRBTC);
        controller.removeSubProductPolicy(SURFACE, IWRBTC);
        vm.stopPrank();

        assertEq(controller.subProductKeys(SURFACE).length, 0);
        IExitFeeController.RatePolicy memory p = controller.subProductPolicy(SURFACE, IWRBTC);
        assertEq(p.active, false);
        assertEq(p.rateBps, 0);
    }

    function test_removeSubProductPolicy_idempotent_when_absent() public {
        // No prior setSubProductPolicy -- remove must succeed silently
        // (no event, no revert) so governance retire flows compose.
        vm.recordLogs();
        vm.prank(ADMIN);
        controller.removeSubProductPolicy(SURFACE, IWRBTC);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event when nothing to remove");
        assertEq(controller.subProductKeys(SURFACE).length, 0);
    }

    function test_removeActorPolicies_batch() public {
        vm.startPrank(ADMIN);
        address[] memory actors = new address[](2);
        actors[0] = ACTOR;
        actors[1] = CAFE;
        IExitFeeController.RatePolicy[] memory ps = new IExitFeeController.RatePolicy[](2);
        ps[0] = IExitFeeController.RatePolicy({active: true, rateBps: 5});
        ps[1] = IExitFeeController.RatePolicy({active: true, rateBps: 10});
        controller.setActorPolicies(SURFACE, actors, ps);
        // Pin the pre-state: without this the length-0 assertion below would
        // also hold if the batch SET had never populated the index.
        assertEq(controller.actorKeys(SURFACE).length, 2, "batch set populates the index");

        // Removing the same list back drops both keys.
        controller.removeActorPolicies(SURFACE, actors);
        vm.stopPrank();

        assertEq(controller.actorKeys(SURFACE).length, 0);

        // A hard remove clears the stored RatePolicy too, not just the index
        // entry -- otherwise a re-added key would resurrect the old rate.
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitFeeController.RatePolicy memory p = controller.actorPolicy(SURFACE, actors[i]);
            assertFalse(p.active, "stale actor policy left behind");
            assertEq(p.rateBps, 0, "stale actor rate left behind");
        }
    }

    function test_remove_address_zero_reverts() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(ExitFeeController.SubProductZero.selector);
        controller.removeSubProductPolicy(SURFACE, address(0));
        vm.expectRevert(ExitFeeController.ActorZero.selector);
        controller.removeActorPolicy(SURFACE, address(0));
        vm.stopPrank();
    }

    function test_remove_only_owner() public {
        vm.startPrank(ADMIN);
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        vm.stopPrank();

        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.removeSubProductPolicy(SURFACE, IWRBTC);
    }

    function test_keys_retained_when_policy_set_inactive() public {
        // Setting an entry to (false, 0) is the documented "soft retire"
        // path. The key remains in the index so off-chain tooling can show
        // "this address was once configured; current state is inactive".
        vm.startPrank(ADMIN);
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: true, rateBps: 30})
        );
        controller.setSubProductPolicy(
            SURFACE, IWRBTC, IExitFeeController.RatePolicy({active: false, rateBps: 0})
        );
        vm.stopPrank();

        address[] memory keys = controller.subProductKeys(SURFACE);
        assertEq(keys.length, 1);
        assertEq(keys[0], IWRBTC);

        IExitFeeController.RatePolicy memory p = controller.subProductPolicy(SURFACE, IWRBTC);
        assertEq(p.active, false);
        assertEq(p.rateBps, 0);
    }

    // ─── UUPS upgrade ────────────────────────────────────────────────────

    function test_owner_can_upgrade_through_proxy() public {
        // Set some state on v1, then upgrade, then read state through v2 view.
        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: 25}));
        controller.setAdmin(GUARDIAN); // own slot 257 -- the newest field, most at risk
        vm.stopPrank();

        ExitFeeControllerV2Mock v2impl = new ExitFeeControllerV2Mock();

        vm.prank(ADMIN);
        controller.upgradeTo(address(v2impl));

        // 1) New function callable through the same proxy address.
        ExitFeeControllerV2Mock asV2 = ExitFeeControllerV2Mock(address(controller));
        assertEq(asV2.version(), "v2");

        // 2) Pre-upgrade state preserved.
        assertTrue(controller.exitFeeEnabled());
        assertEq(controller.feeReceiver(), VAULT);
        assertEq(controller.admin(), GUARDIAN);
        IExitFeeController.RatePolicy memory sp = controller.surfacePolicy(SURFACE);
        assertTrue(sp.active);
        assertEq(sp.rateBps, 25);

        // 3) Quote still works post-upgrade with the preserved policy.
        IExitFeeController.ExitFeeQuote memory q = _quote(IXUSD, 1_000_000);
        assertTrue(q.active);
        assertEq(q.feeAmount, 2_500);
        assertEq(q.rateBps, 25);
    }

    function test_non_owner_cannot_upgrade() public {
        ExitFeeControllerV2Mock v2impl = new ExitFeeControllerV2Mock();
        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.upgradeTo(address(v2impl));
    }

    function test_upgrade_to_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.UpgradeImplZero.selector);
        controller.upgradeTo(address(0));
    }

    // ─── renounceOwnership lockout ───────────────────────────────────────

    function test_renounce_ownership_reverts() public {
        // Without this guard, an accidental renounce would brick all admin
        // operations including emergency disable and future upgrades.
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.OwnershipCannotBeRenounced.selector);
        controller.renounceOwnership();

        // Owner is still in place.
        assertEq(controller.owner(), ADMIN);
    }

    // ─── Ownable2Step transfer flow ──────────────────────────────────────

    function test_transferOwnership_two_step_flow() public {
        // Step 1: current owner nominates; ownership does NOT move yet.
        vm.prank(ADMIN);
        controller.transferOwnership(OTHER);
        assertEq(controller.owner(), ADMIN);
        assertEq(controller.pendingOwner(), OTHER);

        // Step 2: nominee accepts; ownership moves and pending clears.
        vm.prank(OTHER);
        controller.acceptOwnership();
        assertEq(controller.owner(), OTHER);
        assertEq(controller.pendingOwner(), address(0));
    }

    function test_acceptOwnership_non_pending_reverts() public {
        vm.prank(ADMIN);
        controller.transferOwnership(OTHER);

        vm.prank(CAFE);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        controller.acceptOwnership();

        // Nothing moved: owner and nominee are unchanged.
        assertEq(controller.owner(), ADMIN);
        assertEq(controller.pendingOwner(), OTHER);
    }

    // ─── Fuzz: arithmetic + tier resolution + non-revert contract ────────
    //
    // The deterministic unit tests above cover specific branches; the fuzz
    // tests below assert the *properties* that should hold for ALL valid
    // inputs across the policy + math surface.
    //
    // type(uint128).max is an ample upper bound on "any real token amount":
    // 1 token at 18 decimals is 1e18; 1e18 quadrillion tokens is ~1.2e33,
    // and uint128.max is ~3.4e38. We use uint128 as the active-path ceiling
    // so the fuzzer spends its budget on realistic inputs; the overflow
    // guard is exercised by the never-reverts test that unbounds gross.

    /// @dev Property: fee + net = gross, fee <= gross, and the resolved fee
    ///      equals the integer formula (gross * rateBps / MAX_BPS). Active
    ///      path only -- we configure everything-on so every input lands in
    ///      the `q.active` branch.
    function testFuzz_quoteExitFee_conservation_and_math(uint256 grossAmount, uint256 rateBps) public {
        grossAmount = bound(grossAmount, 0, type(uint128).max);
        rateBps = bound(rateBps, 0, 10_000);

        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(
            SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: uint16(rateBps)})
        );
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = controller.quoteExitFee(SURFACE, IXUSD, ACTOR, grossAmount);

        assertTrue(q.active, "should be active");
        assertLe(q.feeAmount, grossAmount, "fee <= gross");
        assertEq(q.feeAmount + q.netAmount, grossAmount, "conservation: fee + net = gross");
        assertEq(q.feeAmount, (grossAmount * rateBps) / 10_000, "fee math");
    }

    /// @dev Property: `quoteExitFee` NEVER reverts -- the function's core
    ///      contract. For gross values that would overflow the fee math,
    ///      the overflow guard must produce a clean INVALID_QUOTE quote
    ///      (no revert, no silent wrong-charge). For all other off-state
    ///      paths, net = gross and fee = 0.
    function testFuzz_quoteExitFee_never_reverts(uint256 grossAmount, uint256 rateBps) public {
        rateBps = bound(rateBps, 0, 10_000);
        // grossAmount NOT bounded -- want to exercise the overflow guard.

        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(
            SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: uint16(rateBps)})
        );
        vm.stopPrank();

        // The call itself not reverting IS the load-bearing assertion.
        IExitFeeController.ExitFeeQuote memory q = controller.quoteExitFee(SURFACE, IXUSD, ACTOR, grossAmount);

        // Everything is configured on, so the overflow guard is the ONLY thing
        // that can turn the quote off. Asserting the biconditional (rather than
        // just "overflow implies INVALID_QUOTE") is what pins the guard's
        // boundary: a guard that rejected one value too many would still
        // satisfy the one-way version below.
        assertEq(q.active, grossAmount <= type(uint256).max / 10_000, "active iff gross cannot overflow");

        if (q.active) {
            assertEq(q.feeAmount + q.netAmount, grossAmount, "conservation in active branch");
        } else {
            assertEq(q.netAmount, grossAmount, "net = gross in off-state");
            assertEq(q.feeAmount, 0, "fee = 0 in off-state");
            // The only off-state reason reachable with everything-on +
            // a configured surface is the overflow guard.
            if (grossAmount > type(uint256).max / 10_000) {
                assertEq(
                    q.reason, uint8(IExitFeeController.SkipReason.INVALID_QUOTE), "overflow -> INVALID_QUOTE"
                );
            }
        }
    }

    /// @dev Property: when surface + sub-product + actor are all configured
    ///      with active=true at distinct rates, `_resolvePolicy` returns the
    ///      ACTOR rate (most-specific tier wins) for every gross amount.
    function testFuzz_actorPolicy_wins_over_lower_tiers(
        uint256 surfaceRateBps,
        uint256 subProductRateBps,
        uint256 actorRateBps,
        uint256 grossAmount
    ) public {
        surfaceRateBps = bound(surfaceRateBps, 0, 10_000);
        subProductRateBps = bound(subProductRateBps, 0, 10_000);
        actorRateBps = bound(actorRateBps, 0, 10_000);
        grossAmount = bound(grossAmount, 0, type(uint128).max);

        vm.startPrank(ADMIN);
        controller.setFeeReceiver(VAULT);
        controller.setExitFeeEnabled(true);
        controller.setSurfacePolicy(
            SURFACE, IExitFeeController.RatePolicy({active: true, rateBps: uint16(surfaceRateBps)})
        );
        controller.setSubProductPolicy(
            SURFACE, IXUSD, IExitFeeController.RatePolicy({active: true, rateBps: uint16(subProductRateBps)})
        );
        controller.setActorPolicy(
            SURFACE, ACTOR, IExitFeeController.RatePolicy({active: true, rateBps: uint16(actorRateBps)})
        );
        vm.stopPrank();

        IExitFeeController.ExitFeeQuote memory q = controller.quoteExitFee(SURFACE, IXUSD, ACTOR, grossAmount);

        assertTrue(q.active);
        assertEq(uint256(q.rateBps), actorRateBps, "actor tier wins over sub-product and surface");
    }

    // ─── Invariant testing design (NOT IMPLEMENTED -- sketch for follow-up) ──
    //
    // Stateful invariant testing in Foundry needs a Handler contract that
    // drives random `set*` / `remove*` / `setExitFeeEnabled` / `transferOwnership`
    // calls against the controller, plus invariant_* functions on the test
    // contract that assert global properties after random call sequences.
    //
    // Suggested handler skeleton (file: test/invariant/ControllerHandler.sol):
    //
    //   contract ControllerHandler {
    //       ExitFeeController controller;
    //       // Bounded pools so the random walk reuses the same addresses /
    //       // surfaces enough times to exercise update + remove paths.
    //       bytes32[4] surfaces;       // the four canonical surfaces
    //       address[8] addresses;      // sub-product / actor candidates
    //       // Ghost mirror state used to compute expected `subProductKeys`
    //       // / `actorKeys` membership.
    //       mapping(bytes32 => EnumerableSet.AddressSet) ghostSubKeys;
    //       mapping(bytes32 => EnumerableSet.AddressSet) ghostActorKeys;
    //       bool everSetFeeReceiver;
    //
    //       function setSubProductPolicy(uint8 sIdx, uint8 aIdx, bool active, uint16 rateBps) public;
    //       function setActorPolicy     (uint8 sIdx, uint8 aIdx, bool active, uint16 rateBps) public;
    //       function removeSubProduct   (uint8 sIdx, uint8 aIdx)                              public;
    //       function removeActor        (uint8 sIdx, uint8 aIdx)                              public;
    //       function setSurfacePolicy   (uint8 sIdx,              bool active, uint16 rateBps) public;
    //       function setFeeReceiver     (uint8 receiverIdx)                                   public;
    //       function flipExitFeeEnabled ()                                                    public;
    //   }
    //
    // Then in `ExitFeeControllerInvariantTest`:
    //
    //   function setUp() public {
    //       // deploy controller as in this file's setUp
    //       handler = new ControllerHandler(controller);
    //       targetContract(address(handler));
    //   }
    //
    //   /// Every address in the on-chain index is also in the ghost mirror.
    //   function invariant_subProductKeys_match_ghost() public {
    //       for (uint i = 0; i < handler.SURFACE_COUNT(); ++i) {
    //           bytes32 s = handler.surface(i);
    //           address[] memory onchain = controller.subProductKeys(s);
    //           address[] memory ghost   = handler.ghostSubKeys(s);
    //           assertEq(onchain.length, ghost.length);
    //           // compare as sets (order-insensitive)
    //       }
    //   }
    //
    //   function invariant_actorKeys_match_ghost() public { /* mirror */ }
    //   function invariant_owner_never_zero() public { assertTrue(controller.owner() != address(0)); }
    //   function invariant_feeReceiver_monotone() public {
    //       if (handler.everSetFeeReceiver()) assertTrue(controller.feeReceiver() != address(0));
    //   }
    //
    // Effort: ~150-200 lines for the handler + ~50 for the invariant
    // contract. Catches: index-vs-policy desync, ghost-state divergences
    // from idempotent set/remove edge cases, feeReceiver monotonicity
    // violations. Right pre-audit hardening step; not needed for the
    // current property surface that the fuzz tests above cover.
}
