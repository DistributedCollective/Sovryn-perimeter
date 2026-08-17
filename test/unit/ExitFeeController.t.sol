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

    ExitFeeController controller;

    // NOTE: `ADMIN` predates the contract's admin role -- it is the proxy
    // OWNER throughout this file. The operational guardian stored in
    // `ExitFeeController.admin` is `GUARDIAN`, declared in the
    // delay-extension section below.
    address constant ADMIN = address(0xA1);
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
        assertEq(q.netAmount, huge); // synthesized echo of gross
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

    // ─── Admin role: fee levers ────────────────────────────
    //
    // setAdmin validation (zero / owner-equals / only-owner / emit) is
    // covered in the delay-extension section below (test_setAdmin_*); this
    // section pins the core-merge widening: the SAME guardian
    // that flips the perimeter kill switch also drives the fee levers.

    function test_admin_unset_at_init() public view {
        assertEq(controller.admin(), address(0));
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

        // Removing the same list back drops both keys.
        controller.removeActorPolicies(SURFACE, actors);
        vm.stopPrank();

        assertEq(controller.actorKeys(SURFACE).length, 0);
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
        vm.expectRevert(); // Ownable: caller is not the owner
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

    // ════════════════════════════════════════════════════════════════════
    //  DELAY EXTENSION
    //
    //  NOTE: in this suite `ADMIN` is the controller's OWNER (passed to
    //  `initialize`). The delay `Admin` GUARDIAN is a distinct address, set via
    //  `setAdmin` and stored below as `GUARDIAN`.
    // ════════════════════════════════════════════════════════════════════

    address constant GUARDIAN = address(0x6DA12D); // delay Admin guardian (≠ owner)
    address constant WRAPPER = address(0x323A99); // a registered passthrough
    address constant USER_EOA = address(0xE0A); // the human behind a wrapper burn

    // Re-declared so vm.expectEmit can match delay-extension events by topic.
    event SecurityPerimeterEnabledSet(bool enabled);
    event GlobalDelaySet(uint32 seconds_);
    event AdminSet(address indexed admin);
    event SurfaceBypassSet(bytes32 indexed surfaceId, bool active, bool bypass);
    event SurfaceBypassRemoved(bytes32 indexed surfaceId);
    event ActorBypassSet(bytes32 indexed surfaceId, address indexed actor, bool active, bool bypass);
    event PassthroughActorSet(bytes32 indexed surfaceId, address indexed actor, bool isPassthrough);

    uint32 constant DELAY = 6 hours;

    // Convenience: enable the perimeter with a global delay, guardian set.
    function _enableDelay(uint32 d) internal {
        vm.startPrank(ADMIN);
        controller.setAdmin(GUARDIAN);
        controller.setGlobalDelaySeconds(d);
        controller.setSecurityPerimeterEnabled(true);
        vm.stopPrank();
    }

    function _bp(bool active, bool bypass)
        internal
        pure
        returns (IExitFeeController.DelayBypassPolicy memory)
    {
        return IExitFeeController.DelayBypassPolicy({active: active, bypass: bypass});
    }

    // ─── Kill switch (both directions; independent of exitFeeEnabled) ────

    function test_delay_off_by_default_short_circuits_to_raw() public view {
        // Perimeter disabled by default: d == 0, raw identities echoed, registry
        // NOT consulted (Finding 3 liveness escape).
        (uint32 d, address effOrig, address effOwner) =
            controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, 0);
        assertEq(effOrig, ACTOR); // RAW, not normalized
        assertEq(effOwner, OTHER); // RAW
    }

    function test_kill_switch_enable_imposes_global_delay() public {
        _enableDelay(DELAY);
        (uint32 d,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, DELAY, "enabled perimeter imposes the global delay");
    }

    function test_kill_switch_disable_direction_by_guardian() public {
        _enableDelay(DELAY);
        // Guardian (Admin) can flip OFF (— both directions).
        vm.prank(GUARDIAN);
        controller.setSecurityPerimeterEnabled(false);
        assertFalse(controller.securityPerimeterEnabled());
        (uint32 d, address effOrig,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, 0, "disabled -> direct");
        assertEq(effOrig, ACTOR, "disabled -> raw identities");
    }

    function test_kill_switch_enable_direction_by_guardian() public {
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);
        vm.prank(ADMIN);
        controller.setGlobalDelaySeconds(DELAY);
        // Guardian can also flip ON (both directions).
        vm.prank(GUARDIAN);
        controller.setSecurityPerimeterEnabled(true);
        assertTrue(controller.securityPerimeterEnabled());
    }

    function test_kill_switch_owner_can_flip_both_directions() public {
        vm.startPrank(ADMIN); // owner
        controller.setGlobalDelaySeconds(DELAY);
        controller.setSecurityPerimeterEnabled(true);
        assertTrue(controller.securityPerimeterEnabled());
        controller.setSecurityPerimeterEnabled(false);
        assertFalse(controller.securityPerimeterEnabled());
        vm.stopPrank();
    }

    function test_kill_switch_rejects_stranger() public {
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeController.NotAdminOrOwner.selector, OTHER));
        controller.setSecurityPerimeterEnabled(true);
    }

    function test_kill_switch_emits() public {
        vm.prank(ADMIN);
        vm.expectEmit(false, false, false, true);
        emit SecurityPerimeterEnabledSet(true);
        controller.setSecurityPerimeterEnabled(true);
    }

    function test_perimeter_independent_of_exitFeeEnabled() public {
        // The delay perimeter is INDEPENDENT of the fee kill switch and
        // of any fee surfacePolicy. Fees OFF, perimeter ON ⇒ still delayed.
        _enableDelay(DELAY);
        assertFalse(controller.exitFeeEnabled(), "fees remain off");
        // No fee surfacePolicy configured at all.
        (uint32 d,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, DELAY, "delay fires with fees disabled and no fee policy");
    }

    function test_fee_surface_inactive_does_not_disable_delay() public {
        // A fee-inactive surface can still be delay-active (sole gate is the
        // perimeter switch, not surfacePolicy.active).
        _enableDelay(DELAY);
        vm.prank(ADMIN);
        controller.setSurfacePolicy(SURFACE, IExitFeeController.RatePolicy({active: false, rateBps: 0}));
        (uint32 d,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, DELAY, "fee surface inactive -> delay still fires");
    }

    // ─── globalDelaySeconds / floor (controller side) ───────────────────

    function test_globalDelay_returned_faithfully() public {
        // The controller returns EXACTLY globalDelaySeconds; the >= floor is a
        // queue-side per-request check. Verify faithful passthrough across
        // a couple of values incl. the max uint32.
        _enableDelay(1);
        (uint32 d1,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d1, 1);

        vm.prank(ADMIN);
        controller.setGlobalDelaySeconds(type(uint32).max);
        (uint32 d2,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d2, type(uint32).max, "~136y head-room passes through");
    }

    function test_globalDelay_zero_is_global_bypass() public {
        // globalDelaySeconds == 0 with perimeter ON ⇒ d == 0 for every
        // non-forced exit (equivalent to a global bypass; the queue skips it).
        _enableDelay(0);
        (uint32 d,,) = controller.quoteExitDelayFor(ACTOR, OTHER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, 0);
    }

    function test_globalDelay_only_owner() public {
        vm.prank(GUARDIAN); // guardian is NOT owner; global delay is owner-only
        vm.expectRevert();
        controller.setGlobalDelaySeconds(DELAY);
    }

    // ─── Bypass precedence (3-tier: actor > subProduct > surface) ───────

    function test_bypass_default_no_tier_is_delayed() public {
        _enableDelay(DELAY);
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), DELAY);
    }

    function test_surface_bypass_exempts() public {
        _enableDelay(DELAY);
        vm.prank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), 0, "surface bypass -> instant");
        // A different surface is untouched.
        assertEq(controller.quoteExitDelay(SURFACE_OTHER, address(0), ACTOR), DELAY);
    }

    function test_subProduct_bypass_overrides_surface() public {
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, false)); // surface: force delay
        controller.setSubProductBypass(SURFACE, IWRBTC, _bp(true, true)); // sub: bypass
        vm.stopPrank();
        assertEq(controller.quoteExitDelay(SURFACE, IWRBTC, ACTOR), 0, "sub-product bypass wins");
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), DELAY, "other sub falls to surface");
    }

    function test_actor_bypass_overrides_subProduct_and_surface() public {
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, false));
        controller.setSubProductBypass(SURFACE, IWRBTC, _bp(true, false));
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, true)); // MM exemption
        vm.stopPrank();
        assertEq(controller.quoteExitDelay(SURFACE, IWRBTC, ACTOR), 0, "actor bypass wins");
        // A different actor still pays the (forced) delay.
        assertEq(controller.quoteExitDelay(SURFACE, IWRBTC, OTHER), DELAY);
    }

    function test_active_false_bypass_forces_delay_over_broader_bypass() public {
        // The tricky override: a more-specific active {bypass:false} re-imposes
        // delay even when a broader tier bypasses.
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true)); // broad bypass
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, false)); // re-impose on ACTOR
        vm.stopPrank();
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), DELAY, "actor re-imposes delay");
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, OTHER), 0, "others keep surface bypass");
    }

    function test_inactive_bypass_tier_falls_through() public {
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true)); // surface bypass
        controller.setActorBypass(SURFACE, ACTOR, _bp(false, true)); // INACTIVE — ignored
        vm.stopPrank();
        // Inactive actor tier must NOT consume; falls through to surface bypass.
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), 0, "inactive actor tier falls through");
    }

    function test_subProduct_zero_skips_subProduct_tier() public {
        // Zero passes subProduct=address(0); the resolver must NOT consult the
        // sub-product map for address(0) (a sibling entry cannot leak in).
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setSubProductBypass(SURFACE_OTHER, IWRBTC, _bp(true, true));
        vm.stopPrank();
        // address(0) path falls straight through to surface (unconfigured) ⇒ global.
        assertEq(controller.quoteExitDelay(SURFACE_OTHER, address(0), ACTOR), DELAY);
    }

    // ─── Passthrough surface-scoping ──────────────────────────────

    function test_passthrough_resolves_to_receiver_on_scoped_surface() public {
        _enableDelay(DELAY);
        vm.prank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);

        // effectiveActor rewrites the wrapper to the receiver on THIS surface.
        assertEq(controller.effectiveActor(SURFACE, WRAPPER, USER_EOA), USER_EOA);
        // A non-passthrough is identity.
        assertEq(controller.effectiveActor(SURFACE, ACTOR, USER_EOA), ACTOR);

        // quoteExitDelayFor returns the NORMALIZED originator/owner.
        (uint32 d, address effOrig, address effOwner) =
            controller.quoteExitDelayFor(WRAPPER, WRAPPER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, DELAY);
        assertEq(effOrig, USER_EOA, "originator normalized wrapper->receiver");
        assertEq(effOwner, USER_EOA, "owner normalized wrapper->receiver");
    }

    function test_passthrough_is_surface_scoped_not_global() public {
        _enableDelay(DELAY);
        // Register WRAPPER as passthrough ONLY on the lending surface.
        vm.prank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);

        // On Zero (no passthrough entry) the wrapper is NOT rewritten — margin/
        // Zero keep raw identities (never collapse originator/owner globally).
        assertEq(controller.effectiveActor(SURFACE_OTHER, WRAPPER, USER_EOA), WRAPPER);
        (, address effOrig, address effOwner) =
            controller.quoteExitDelayFor(WRAPPER, WRAPPER, USER_EOA, SURFACE_OTHER, address(0));
        assertEq(effOrig, WRAPPER, "Zero keeps raw originator");
        assertEq(effOwner, WRAPPER, "Zero keeps raw owner");
    }

    function test_passthrough_actor_bypass_targets_effective_actor() public {
        // Finding 2: the quote is on effOrig, so an actorBypass on the USER_EOA
        // (not the wrapper) applies. Register wrapper passthrough + bypass on EOA.
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
        controller.setActorBypass(SURFACE, USER_EOA, _bp(true, true)); // exempt the human
        vm.stopPrank();

        (uint32 d, address effOrig,) =
            controller.quoteExitDelayFor(WRAPPER, WRAPPER, USER_EOA, SURFACE, IXUSD);
        assertEq(effOrig, USER_EOA);
        assertEq(d, 0, "actorBypass on the effective (EOA) actor applies, not the wrapper");
    }

    function test_disabled_perimeter_skips_passthrough_resolution() public {
        // Kill switch OFF: even with a passthrough registered, quoteExitDelayFor
        // returns RAW identities (short-circuits BEFORE the registry).
        vm.prank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
        // perimeter still disabled
        (uint32 d, address effOrig, address effOwner) =
            controller.quoteExitDelayFor(WRAPPER, WRAPPER, USER_EOA, SURFACE, IXUSD);
        assertEq(d, 0);
        assertEq(effOrig, WRAPPER, "raw, registry not consulted");
        assertEq(effOwner, WRAPPER, "raw, registry not consulted");
    }

    function test_passthrough_deregister() public {
        _enableDelay(DELAY);
        vm.startPrank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
        assertTrue(controller.passthroughActor(SURFACE, WRAPPER));
        controller.setPassthroughActor(SURFACE, WRAPPER, false);
        vm.stopPrank();
        assertFalse(controller.passthroughActor(SURFACE, WRAPPER));
        assertEq(controller.effectiveActor(SURFACE, WRAPPER, USER_EOA), WRAPPER);
    }

    function test_setPassthrough_zero_reverts_and_only_owner() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.ActorZero.selector);
        controller.setPassthroughActor(SURFACE, address(0), true);

        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
    }

    // ─── Admin guardian setter (setAdmin) ───────────────────────────────

    function test_setAdmin_sets_and_emits() public {
        vm.prank(ADMIN);
        vm.expectEmit(true, false, false, false);
        emit AdminSet(GUARDIAN);
        controller.setAdmin(GUARDIAN);
        assertEq(controller.admin(), GUARDIAN);
    }

    function test_setAdmin_rejects_zero() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeController.AdminZero.selector);
        controller.setAdmin(address(0));
    }

    function test_setAdmin_may_equal_owner() public {
        //  admin == owner is a
        // supported shape (the governance Safe holds both roles at launch).
        vm.prank(ADMIN);
        controller.setAdmin(ADMIN); // ADMIN is the owner here
        assertEq(controller.admin(), ADMIN);
    }

    function test_setAdmin_only_owner() public {
        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setAdmin(GUARDIAN);
    }

    function test_default_admin_zero_owner_still_flips_kill_switch() public {
        // Before setAdmin, admin == address(0). The Owner can still flip the
        // kill switch (safe default: only Owner until a guardian is appointed);
        // a stranger (and address(0) callers can't exist) cannot.
        assertEq(controller.admin(), address(0));
        vm.prank(ADMIN);
        controller.setSecurityPerimeterEnabled(true);
        assertTrue(controller.securityPerimeterEnabled());
    }

    // ─── Bypass setter validation / enumeration / removal ───────────────

    function test_bypass_setters_only_owner() public {
        vm.startPrank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        vm.expectRevert("Ownable: caller is not the owner");
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, true));
        vm.stopPrank();
    }

    function test_bypass_zero_address_reverts() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(ExitFeeController.SubProductZero.selector);
        controller.setSubProductBypass(SURFACE, address(0), _bp(true, true));
        vm.expectRevert(ExitFeeController.ActorZero.selector);
        controller.setActorBypass(SURFACE, address(0), _bp(true, true));
        vm.stopPrank();
    }

    function test_bypass_batch_and_length_mismatch() public {
        vm.startPrank(ADMIN);
        address[] memory actors = new address[](2);
        actors[0] = ACTOR;
        actors[1] = CAFE;
        IExitFeeController.DelayBypassPolicy[] memory ps = new IExitFeeController.DelayBypassPolicy[](2);
        ps[0] = _bp(true, true);
        ps[1] = _bp(true, false);
        controller.setActorBypasses(SURFACE, actors, ps);

        // Length mismatch reverts.
        IExitFeeController.DelayBypassPolicy[] memory bad = new IExitFeeController.DelayBypassPolicy[](1);
        bad[0] = _bp(true, true);
        vm.expectRevert(ExitFeeController.LengthMismatch.selector);
        controller.setActorBypasses(SURFACE, actors, bad);
        vm.stopPrank();

        address[] memory keys = controller.actorBypassKeys(SURFACE);
        assertEq(keys.length, 2);
        assertEq(keys[0], ACTOR);
        assertEq(keys[1], CAFE);
    }

    function test_bypass_enumeration_and_hard_removal() public {
        vm.startPrank(ADMIN);
        controller.setSubProductBypass(SURFACE, IWRBTC, _bp(true, true));
        controller.setSubProductBypass(SURFACE, IXUSD, _bp(true, false));
        assertEq(controller.subProductBypassKeys(SURFACE).length, 2);

        controller.removeSubProductBypass(SURFACE, IWRBTC);
        vm.stopPrank();

        assertEq(controller.subProductBypassKeys(SURFACE).length, 1);
        IExitFeeController.DelayBypassPolicy memory p = controller.subProductBypass(SURFACE, IWRBTC);
        assertFalse(p.active);
        assertFalse(p.bypass);
    }

    function test_bypass_remove_idempotent_when_absent() public {
        vm.recordLogs();
        vm.prank(ADMIN);
        controller.removeActorBypass(SURFACE, ACTOR);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event when nothing to remove");
    }

    function test_bypass_keys_retained_on_soft_retire() public {
        vm.startPrank(ADMIN);
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, true));
        controller.setActorBypass(SURFACE, ACTOR, _bp(false, false)); // soft retire
        vm.stopPrank();
        address[] memory keys = controller.actorBypassKeys(SURFACE);
        assertEq(keys.length, 1, "key retained on soft retire");
        assertEq(keys[0], ACTOR);
    }

    // ─── quoteExitDelay inner view: disabled-perimeter parity ───────────

    function test_inner_quote_returns_zero_when_disabled() public {
        // Even with a forcing bypass configured, the inner view returns 0 while
        // the perimeter is off (parity with quoteExitDelayFor).
        vm.startPrank(ADMIN);
        controller.setGlobalDelaySeconds(DELAY);
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, false)); // would force delay
        vm.stopPrank();
        // perimeter disabled
        assertEq(controller.quoteExitDelay(SURFACE, IXUSD, ACTOR), 0);
    }

    // ─── Fuzz / property: precedence + short-circuit + faithful delay ───

    /// @dev Property: when the perimeter is ON and no bypass tier is configured,
    ///      quoteExitDelay returns EXACTLY globalDelaySeconds for any actor and
    ///      any (non-zero-or-zero) subProduct — the "default delayed" rule.
    function testFuzz_default_delay_equals_global(uint32 d, address actor, address sub) public {
        _enableDelay(d);
        assertEq(controller.quoteExitDelay(SURFACE, sub, actor), d);
    }

    /// @dev Property: an active actor bypass ALWAYS decides on effOrig,
    ///      regardless of the sub-product and surface tiers.
    function testFuzz_actor_bypass_always_wins(
        uint32 d,
        bool surfActive,
        bool surfBypass,
        bool subActive,
        bool subBypass,
        bool actorBypassVal
    ) public {
        vm.assume(d > 0);
        _enableDelay(d);
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(surfActive, surfBypass));
        controller.setSubProductBypass(SURFACE, IXUSD, _bp(subActive, subBypass));
        controller.setActorBypass(SURFACE, ACTOR, _bp(true, actorBypassVal));
        vm.stopPrank();

        uint32 got = controller.quoteExitDelay(SURFACE, IXUSD, ACTOR);
        assertEq(got, actorBypassVal ? 0 : d, "active actor tier decides");
    }

    /// @dev Property: disabled perimeter ALWAYS returns (0, raw, owner) — the
    ///      registry is never consulted and identities are never normalized,
    ///      for any inputs (controller-side).
    function testFuzz_disabled_always_raw_and_zero(
        address raw,
        address owner_,
        address receiver,
        address sub,
        bool registerPassthrough
    ) public {
        // Optionally register a passthrough; it must NOT be consulted while off.
        if (registerPassthrough && raw != address(0)) {
            vm.prank(ADMIN);
            controller.setPassthroughActor(SURFACE, raw, true);
        }
        // perimeter disabled (default)
        (uint32 d, address effOrig, address effOwner) =
            controller.quoteExitDelayFor(raw, owner_, receiver, SURFACE, sub);
        assertEq(d, 0);
        assertEq(effOrig, raw, "raw originator echoed");
        assertEq(effOwner, owner_, "raw owner echoed");
    }

    /// @dev Property: quoteExitDelayFor and the inner quoteExitDelay agree on the
    ///      resolved delay when the perimeter is ON and no passthrough rewrites
    ///      the actor (so effOrig == rawOriginator).
    function testFuzz_outer_inner_agree(uint32 d, address actor, address sub) public {
        vm.assume(actor != WRAPPER); // no passthrough registered anyway
        _enableDelay(d);
        (uint32 outer,,) = controller.quoteExitDelayFor(actor, actor, actor, SURFACE, sub);
        uint32 inner = controller.quoteExitDelay(SURFACE, sub, actor);
        assertEq(outer, inner, "outer and inner resolve the same delay");
    }

    // ─── Admin == Owner is a supported shape ──
    //
    // The `_transferOwnership` chokepoint and setAdmin's
    // owner-equality check were removed by team decision: at launch the
    // governance Safe holds BOTH roles. These pin the new behavior: role
    // merges via the 2-step handoff succeed, and normal rotations are
    // unaffected.

    function test_transferOwnership_to_admin_then_accept_merges_roles() public {
        // Appoint a guardian, then hand ownership to that same guardian via
        // the 2-step flow. Both steps succeed; owner == admin afterwards.
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        vm.prank(ADMIN);
        controller.transferOwnership(GUARDIAN); // stages pendingOwner = GUARDIAN
        assertEq(controller.pendingOwner(), GUARDIAN, "pending staged");

        vm.prank(GUARDIAN);
        controller.acceptOwnership();

        assertEq(controller.owner(), GUARDIAN, "roles merged: guardian is now owner");
        assertEq(controller.admin(), GUARDIAN, "admin unchanged");
    }

    function test_transferOwnership_to_nonadmin_still_works() public {
        // A normal rotation to a fresh (non-admin) owner is unaffected.
        vm.prank(ADMIN);
        controller.setAdmin(GUARDIAN);

        vm.prank(ADMIN);
        controller.transferOwnership(OTHER); // OTHER != admin
        vm.prank(OTHER);
        controller.acceptOwnership();
        assertEq(controller.owner(), OTHER, "rotation to a non-admin owner succeeds");
    }

    function test_initialize_handoff_admin_unset_at_init() public {
        // At initialize, admin == address(0); it is only appointed AFTER init
        // via setAdmin. A fresh deploy handing off to a Safe starts adminless.
        ExitFeeController impl = new ExitFeeController();
        bytes memory init = abi.encodeWithSelector(ExitFeeController.initialize.selector, CAFE);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ExitFeeController c = ExitFeeController(address(proxy));
        assertEq(c.owner(), CAFE, "immediate handoff at init succeeds");
        assertEq(c.admin(), address(0), "admin unset until setAdmin");
    }

    // ─── surface-bypass + passthrough registries are ENUMERABLE ──

    function test_surfaceBypassKeys_enumerates_no_argument() public {
        // The getter takes NO argument — surface bypasses are keyed by surfaceId
        // alone. Configure two surfaces and confirm both are listed.
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        controller.setSurfaceBypass(SURFACE_OTHER, _bp(true, false));
        vm.stopPrank();

        bytes32[] memory keys = controller.surfaceBypassKeys();
        assertEq(keys.length, 2, "both configured surfaces enumerated");
        // Order is set-insertion order.
        assertEq(keys[0], SURFACE);
        assertEq(keys[1], SURFACE_OTHER);
    }

    function test_surfaceBypassKeys_idempotent_on_overwrite() public {
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        controller.setSurfaceBypass(SURFACE, _bp(true, false)); // overwrite same id
        vm.stopPrank();
        assertEq(controller.surfaceBypassKeys().length, 1, "no duplicate key on overwrite");
    }

    function test_surfaceBypassKeys_retained_on_soft_retire() public {
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        controller.setSurfaceBypass(SURFACE, _bp(false, false)); // soft retire
        vm.stopPrank();
        bytes32[] memory keys = controller.surfaceBypassKeys();
        assertEq(keys.length, 1, "soft-retired surface still enumerable");
        assertEq(keys[0], SURFACE);
    }

    function test_removeSurfaceBypass_hard_removes_and_emits() public {
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        assertEq(controller.surfaceBypassKeys().length, 1);

        vm.expectEmit(true, false, false, false);
        emit SurfaceBypassRemoved(SURFACE);
        controller.removeSurfaceBypass(SURFACE);
        vm.stopPrank();

        assertEq(controller.surfaceBypassKeys().length, 0, "key dropped");
        IExitFeeController.DelayBypassPolicy memory p = controller.surfaceBypass(SURFACE);
        assertFalse(p.active, "policy cleared");
        assertFalse(p.bypass);
    }

    function test_removeSurfaceBypass_idempotent_when_absent() public {
        vm.recordLogs();
        vm.prank(ADMIN);
        controller.removeSurfaceBypass(SURFACE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event when nothing to remove");
    }

    function test_removeSurfaceBypass_only_owner() public {
        vm.prank(ADMIN);
        controller.setSurfaceBypass(SURFACE, _bp(true, true));
        vm.prank(OTHER);
        vm.expectRevert("Ownable: caller is not the owner");
        controller.removeSurfaceBypass(SURFACE);
    }

    function test_bypass_enumeration_under_arbitrary_surfaceId() public {
        // A bypass set under an arbitrary surfaceId (never registered as a named
        // fee surface) must still be fully enumerated across all three tiers.
        bytes32 arbitrary = keccak256("ARBITRARY:SURFACE:XYZ");
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(arbitrary, _bp(true, true));
        controller.setSubProductBypass(arbitrary, IXUSD, _bp(true, false));
        controller.setActorBypass(arbitrary, ACTOR, _bp(true, true));
        vm.stopPrank();

        bytes32[] memory sKeys = controller.surfaceBypassKeys();
        assertEq(sKeys.length, 1);
        assertEq(sKeys[0], arbitrary, "arbitrary surface enumerated");
        assertEq(controller.subProductBypassKeys(arbitrary).length, 1);
        assertEq(controller.subProductBypassKeys(arbitrary)[0], IXUSD);
        assertEq(controller.actorBypassKeys(arbitrary).length, 1);
        assertEq(controller.actorBypassKeys(arbitrary)[0], ACTOR);
    }

    function test_passthroughKeys_enumerates_and_drops_on_deregister() public {
        vm.startPrank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
        controller.setPassthroughActor(SURFACE, CAFE, true);
        vm.stopPrank();

        address[] memory keys = controller.passthroughKeys(SURFACE);
        assertEq(keys.length, 2, "both passthroughs enumerated");
        assertEq(keys[0], WRAPPER);
        assertEq(keys[1], CAFE);

        // Deregister WRAPPER: exact-to-live (dropped from the index, unlike the
        // soft-retained bypass key-sets).
        vm.prank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, false);
        address[] memory keys2 = controller.passthroughKeys(SURFACE);
        assertEq(keys2.length, 1, "deregistered passthrough dropped from index");
        assertEq(keys2[0], CAFE);
    }

    function test_passthroughKeys_under_arbitrary_surfaceId() public {
        // A passthrough registered under an arbitrary surfaceId is enumerated.
        bytes32 arbitrary = keccak256("ARBITRARY:PASSTHROUGH:QQQ");
        vm.prank(ADMIN);
        controller.setPassthroughActor(arbitrary, WRAPPER, true);
        address[] memory keys = controller.passthroughKeys(arbitrary);
        assertEq(keys.length, 1);
        assertEq(keys[0], WRAPPER);
        // Surface-scoped: NOT visible under a different surface.
        assertEq(controller.passthroughKeys(SURFACE).length, 0);
    }

    function test_passthroughKeys_idempotent_reregister() public {
        vm.startPrank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, true);
        controller.setPassthroughActor(SURFACE, WRAPPER, true); // re-register
        vm.stopPrank();
        assertEq(controller.passthroughKeys(SURFACE).length, 1, "no duplicate on re-register");
    }

    function test_passthroughKeys_deregister_absent_is_noop() public {
        // Deregistering an address that was never registered leaves the index
        // empty and does not revert.
        vm.prank(ADMIN);
        controller.setPassthroughActor(SURFACE, WRAPPER, false);
        assertEq(controller.passthroughKeys(SURFACE).length, 0);
        assertFalse(controller.passthroughActor(SURFACE, WRAPPER));
    }

    /// @dev Property: every actively-registered passthrough is
    ///      enumerated, and enumeration membership tracks the boolean flag exactly
    ///      (register -> present, deregister -> absent) under a random walk.
    function testFuzz_passthroughKeys_membership_tracks_flag(address a, bool register, bool thenDeregister)
        public
    {
        vm.assume(a != address(0));
        bytes32 s = SURFACE;
        vm.startPrank(ADMIN);
        if (register) {
            controller.setPassthroughActor(s, a, true);
            if (thenDeregister) controller.setPassthroughActor(s, a, false);
        }
        vm.stopPrank();

        bool expectPresent = register && !thenDeregister;
        assertEq(controller.passthroughActor(s, a), expectPresent, "flag matches expectation");

        address[] memory keys = controller.passthroughKeys(s);
        bool found = false;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i] == a) {
                found = true;
                break;
            }
        }
        assertEq(found, expectPresent, "index membership tracks the boolean flag exactly");
    }

    /// @dev Property: the surface-bypass key-set contains a
    ///      surfaceId iff a surface bypass was set-and-not-hard-removed for it.
    function testFuzz_surfaceBypassKeys_membership(bytes32 s, bool active, bool bypass, bool thenRemove)
        public
    {
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(s, _bp(active, bypass));
        if (thenRemove) controller.removeSurfaceBypass(s);
        vm.stopPrank();

        bytes32[] memory keys = controller.surfaceBypassKeys();
        bool found = false;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i] == s) {
                found = true;
                break;
            }
        }
        // set-then-remove -> absent; set-only (even soft-retired) -> present.
        assertEq(found, !thenRemove, "membership = set && !hardRemove");
    }

    // ════════════════════════════════════════════════════════════════════
    //   — ANY-TIER-TOUCHED master id-sets
    //
    //  The exact gap the previous cycle left: the master surface-id set was
    //  populated ONLY by setSurfaceBypass, so a sub-product- or actor-ONLY
    //  bypass (the most common exemption shape, actor tier) or a
    //  passthrough-only entry under an arbitrary surfaceId was undiscoverable
    //  by any single enumeration getter. These tests pin that NO zero-delay /
    //  identity-collapse config is invisible to the inspector's driver.
    // ════════════════════════════════════════════════════════════════════

    /// @dev REGRESSION (the exact gap): configure ONLY an actor-tier bypass with
    ///      NO prior setSurfaceBypass. The surfaceId MUST appear in
    ///      bypassSurfaceIds() even though surfaceBypassKeys() (surface-tier only)
    ///      does not contain it.
    function test_bypassSurfaceIds_records_actor_only_bypass() public {
        bytes32 arbitrary = keccak256("ARBITRARY:ACTOR:ONLY");
        address someMM = address(0x11A11); // a market-maker actor
        vm.prank(ADMIN);
        controller.setActorBypass(
            arbitrary, someMM, IExitFeeController.DelayBypassPolicy({active: true, bypass: true})
        );

        // The OLD surface-tier-only driver misses it:
        assertEq(controller.surfaceBypassKeys().length, 0, "surface-tier set stays empty");

        // The any-tier-touched master set discovers it:
        bytes32[] memory ids = controller.bypassSurfaceIds();
        assertEq(ids.length, 1, "actor-only bypass surfaces the id");
        assertEq(ids[0], arbitrary, "the arbitrary surfaceId is discoverable");

        // And the per-surface actor tier is reachable from that id.
        address[] memory actorKeys = controller.actorBypassKeys(arbitrary);
        assertEq(actorKeys.length, 1);
        assertEq(actorKeys[0], someMM);
    }

    /// @dev REGRESSION: a sub-product-ONLY bypass with no prior setSurfaceBypass
    ///      is likewise discoverable via bypassSurfaceIds().
    function test_bypassSurfaceIds_records_subproduct_only_bypass() public {
        bytes32 arbitrary = keccak256("ARBITRARY:SUBPRODUCT:ONLY");
        vm.prank(ADMIN);
        controller.setSubProductBypass(arbitrary, IXUSD, _bp(true, false));

        assertEq(controller.surfaceBypassKeys().length, 0, "surface-tier set stays empty");
        bytes32[] memory ids = controller.bypassSurfaceIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], arbitrary);
        assertEq(controller.subProductBypassKeys(arbitrary)[0], IXUSD);
    }

    /// @dev The surface tier also records into the master set (so all three
    ///      writers feed it), and the master set dedups a surfaceId touched at
    ///      multiple tiers.
    function test_bypassSurfaceIds_dedups_across_tiers() public {
        bytes32 s = keccak256("ARBITRARY:ALL:TIERS");
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(s, _bp(true, true));
        controller.setSubProductBypass(s, IXUSD, _bp(true, false));
        controller.setActorBypass(s, ACTOR, _bp(true, true));
        vm.stopPrank();

        bytes32[] memory ids = controller.bypassSurfaceIds();
        assertEq(ids.length, 1, "single id even though 3 tiers touched it");
        assertEq(ids[0], s);
    }

    /// @dev REGRESSION: removeSurfaceBypass while sub/actor entries remain live
    ///      does NOT drop the id from discovery — the id stays in the master set
    ///      so the inspector keeps probing the still-live sub/actor tiers.
    function test_bypassSurfaceIds_retained_after_removeSurfaceBypass() public {
        bytes32 s = keccak256("ARBITRARY:REMOVE:SURFACE");
        vm.startPrank(ADMIN);
        controller.setSurfaceBypass(s, _bp(true, true));
        controller.setActorBypass(s, ACTOR, _bp(true, true)); // still-live actor tier
        controller.removeSurfaceBypass(s); // drop ONLY the surface tier
        vm.stopPrank();

        // Surface-tier key-set drops it (hard remove of the surface tier)...
        assertEq(controller.surfaceBypassKeys().length, 0, "surface-tier key dropped");
        // ...but the any-tier master set retains it (actor tier still live).
        bytes32[] memory ids = controller.bypassSurfaceIds();
        assertEq(ids.length, 1, "master set retains id while sub/actor live");
        assertEq(ids[0], s);
        assertEq(controller.actorBypassKeys(s)[0], ACTOR, "actor tier still live");
    }

    /// @dev REGRESSION: a passthrough-ONLY entry under an arbitrary surfaceId
    ///      (no bypass at any tier, not a named fee surface) is discoverable via
    ///      passthroughSurfaceIds().
    function test_passthroughSurfaceIds_records_passthrough_only_entry() public {
        bytes32 arbitrary = keccak256("ARBITRARY:PASSTHROUGH:ONLY");
        vm.prank(ADMIN);
        controller.setPassthroughActor(arbitrary, WRAPPER, true);

        // No bypass at any tier for this surfaceId:
        assertEq(controller.bypassSurfaceIds().length, 0, "no bypass touched this id");
        assertEq(controller.surfaceBypassKeys().length, 0);

        // But the passthrough master set discovers it:
        bytes32[] memory ids = controller.passthroughSurfaceIds();
        assertEq(ids.length, 1, "passthrough-only surface discoverable");
        assertEq(ids[0], arbitrary);
        assertEq(controller.passthroughKeys(arbitrary)[0], WRAPPER);
    }

    /// @dev passthroughSurfaceIds() is surface-level retention: the id stays
    ///      recorded even after every passthrough under it is deregistered (the
    ///      per-surface passthroughKeys going empty is the live signal). This
    ///      guarantees the inspector never loses the probe point.
    function test_passthroughSurfaceIds_retained_after_deregister() public {
        bytes32 s = keccak256("ARBITRARY:PASSTHROUGH:DEREG");
        vm.startPrank(ADMIN);
        controller.setPassthroughActor(s, WRAPPER, true);
        controller.setPassthroughActor(s, WRAPPER, false); // deregister the only one
        vm.stopPrank();

        // Per-surface live set is now empty...
        assertEq(controller.passthroughKeys(s).length, 0, "no live passthrough under s");
        assertFalse(controller.passthroughActor(s, WRAPPER));
        // ...but the surface-level master set retains the probe point.
        bytes32[] memory ids = controller.passthroughSurfaceIds();
        assertEq(ids.length, 1, "surface-level id retained for probing");
        assertEq(ids[0], s);
    }

    /// @dev Property: bypassSurfaceIds() contains a surfaceId iff at least one
    ///      bypass tier (surface / sub-product / actor) was EVER written for it —
    ///      independent of which tier, and independent of soft-retire / surface
    ///      hard-remove (retention-only master set).
    function testFuzz_bypassSurfaceIds_membership_any_tier(bytes32 s, uint8 tier, bool active, bool bypass)
        public
    {
        vm.startPrank(ADMIN);
        tier = uint8(bound(tier, 0, 2));
        if (tier == 0) {
            controller.setSurfaceBypass(s, _bp(active, bypass));
        } else if (tier == 1) {
            controller.setSubProductBypass(s, IXUSD, _bp(active, bypass));
        } else {
            controller.setActorBypass(s, ACTOR, _bp(active, bypass));
        }
        vm.stopPrank();

        bytes32[] memory ids = controller.bypassSurfaceIds();
        bool found = false;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == s) {
                found = true;
                break;
            }
        }
        assertTrue(found, "any tier write records the surfaceId in the master set");
    }

    /// @dev Property: passthroughSurfaceIds() contains a surfaceId iff a
    ///      passthrough was EVER registered under it (register-only recording,
    ///      surface-level retention).
    function testFuzz_passthroughSurfaceIds_membership(
        bytes32 s,
        address a,
        bool register,
        bool thenDeregister
    ) public {
        vm.assume(a != address(0));
        vm.startPrank(ADMIN);
        if (register) {
            controller.setPassthroughActor(s, a, true);
            if (thenDeregister) controller.setPassthroughActor(s, a, false);
        }
        vm.stopPrank();

        bytes32[] memory ids = controller.passthroughSurfaceIds();
        bool found = false;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == s) {
                found = true;
                break;
            }
        }
        // Ever-registered (even if later deregistered) -> present; never -> absent.
        assertEq(found, register, "master set records on register, retains on deregister");
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
