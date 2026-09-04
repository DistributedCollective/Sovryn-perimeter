// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {ExitDelayQueueHandler, InvMockERC20} from "./ExitDelayQueueHandler.sol";

/// @dev Minimal native-backed WRBTC for the invariant run (unused by the
///      handler's ingress but required by initialize()).
contract InvWRBTC {
    function withdraw(uint256) external {}
    receive() external payable {}
}

/// @notice Stateful invariant suite for `ExitDelayQueue` covering its
///         invariants. The handler (owner + source + pusher) fuzzes ingress,
///         execution, blocks, recovery, pause, sweep and time. Assertions read
///         ghost accounting + on-chain state.
contract ExitDelayQueueInvariant is Test {
    ExitDelayQueue queue;
    InvMockERC20 token;
    InvWRBTC wrbtc;
    ExitDelayQueueHandler handler;

    address constant ADMIN = address(0xAD);

    function setUp() public {
        wrbtc = new InvWRBTC();
        token = new InvMockERC20();

        ExitDelayQueue impl = new ExitDelayQueue();
        // The handler will be the owner; deploy with the test as temp owner then
        // hand off. Sources include the handler; admin is a distinct dummy.
        address[] memory sources = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, address(this), ADMIN, address(wrbtc), uint32(1 hours), sources
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        queue = ExitDelayQueue(payable(address(proxy)));

        handler = new ExitDelayQueueHandler(queue, token, address(wrbtc));

        // Wire the handler as an allowed source + native pusher, then transfer
        // ownership to it so it can also exercise owner/admin-gated fns.
        queue.addAllowedSource(address(handler));
        queue.setNativePusher(address(handler));
        queue.transferOwnership(address(handler));
        vm.prank(address(handler));
        queue.acceptOwnership();

        // Leg-2 routes matching the handler's own ingress provenance, so the
        // recovery-away action is reachable from the first step of every run.
        handler.setUpRoutes();

        // target only the handler
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](22);
        selectors[0] = handler.recordErc20.selector;
        selectors[1] = handler.recordNative.selector;
        selectors[2] = handler.execute.selector;
        selectors[3] = handler.freeze.selector;
        selectors[4] = handler.blacklist.selector;
        selectors[5] = handler.unfreeze.selector;
        selectors[6] = handler.unblacklist.selector;
        selectors[7] = handler.pause.selector;
        selectors[8] = handler.resolveBySIP.selector;
        selectors[9] = handler.sweep.selector;
        selectors[10] = handler.warp.selector;
        //  coverage: measured-delta ingress + donation/force-send surplus.
        selectors[11] = handler.recordReceivedErc20.selector;
        selectors[12] = handler.recordReceivedNative.selector;
        selectors[13] = handler.donateErc20.selector;
        selectors[14] = handler.donateNative.selector;
        //  (C3): fuzz floor raises/lowers so the creation-time invariant is
        // exercised against live short requests without falsely tripping.
        selectors[15] = handler.setMinDelay.selector;
        // Gate-5 stuck-exit recovery: recoverStuckExit(id, altReceiver) must never
        // break solvency / double-spend, whichever branch it takes (stored-receiver
        // pay, altReceiver pay on a bounce, or whole-call revert on block/lock/pause).
        selectors[16] = handler.recoverStuck.selector;
        // Operator levers the release depends on: blocking by request id (with
        // and without the receiver), batch release, route registration and
        // recovery-away along a route.
        selectors[17] = handler.freezeByRequest.selector;
        selectors[18] = handler.blacklistByRequest.selector;
        selectors[19] = handler.executeMany.selector;
        selectors[20] = handler.addRoute.selector;
        selectors[21] = handler.resolveByRoute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // Per-token solvency — totalEscrowed == Σ Queued amounts, and
    // ≤ backing balance. Ghost sum tracks Σ Queued.
    function invariant_solvency_erc20() public view {
        assertEq(queue.totalEscrowed(address(token)), handler.ghostQueuedErc20());
        assertLe(queue.totalEscrowed(address(token)), token.balanceOf(address(queue)));
    }

    function invariant_solvency_native() public view {
        assertEq(queue.totalEscrowed(address(0)), handler.ghostQueuedNative());
        assertLe(queue.totalEscrowed(address(0)), address(queue).balance);
    }

    //  ids monotonic and never reused (lastRequestId only grows; every
    // recorded id ≤ lastRequestId and unique by construction of ++lastRequestId).
    function invariant_id_monotonic() public view {
        assertEq(queue.lastRequestId(), handler.totalRecorded());
    }

    // A request leaves Queued at most once. Every id is in exactly
    // one of {Queued, terminal}; terminal count never exceeds recorded count.
    function invariant_no_double_terminal() public view {
        assertLe(handler.totalTerminal(), handler.totalRecorded());
    }

    //  + metadata immutable + status monotonic across all live ids.
    // Also active-index membership biconditional (Queued ⇔ in set).
    function invariant_status_and_index_consistency() public view {
        uint256 n = handler.liveIdCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.liveIdAt(i);
            IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
            //  (creation-time, C3): every request satisfies
            // `unlockAt − createdAt ≥ the minimumDelaySeconds in effect at ITS OWN
            // createdAt` (the floor is enforced once, at record time). We check
            // against the handler's recorded floor-at-creation, NOT the current
            // live floor — a later setMinimumDelaySeconds raise applies only to NEW
            // requests and must never retroactively extend an already-Queued exit,
            // so asserting against the live floor would falsely trip after a raise.
            assertGe(uint256(r.unlockAt) - uint256(r.createdAt), uint256(handler.floorAtCreation(id)));
            //  for the originator, id ∈ active iff Queued.
            bool inSet = _inActive(r.originator, id);
            if (r.status == IExitDelayQueue.ExitStatus.Queued) {
                assertTrue(inSet, "queued id must be in originator active set");
            } else {
                assertFalse(inSet, "terminal id must NOT be in originator active set");
                assertFalse(_inActive(r.owner, id), "terminal id must NOT be in owner active set");
            }
        }
    }

    // ── operator levers ──────────────────────────────────────────

    /// @notice No payout ever reached a party the perimeter had blocked. Both
    ///         payout legs feed the same ledger: the handler snapshots
    ///         `blockStateOf` for originator, owner and receiver immediately
    ///         before every `executeExit`/`executeExits`, and for those three
    ///         plus `altReceiver` before every `recoverStuckExit` — the stricter
    ///         gate that leg carries. A payout taken while any of them was
    ///         Frozen or Blacklisted is recorded, not filtered out.
    function invariant_blocked_party_never_paid() public view {
        assertEq(handler.blockedPayouts(), 0, "a release paid out while a party was blocked");
        assertEq(handler.blockedPayoutValue(), 0, "value left the queue while a party was blocked");
        assertEq(handler.blockedPayoutParty(), address(0), "blocked party was paid");
        // Every credit in the ledger names one of the three known actors: the
        // stored receiver is immutable and the recovery leg's alternate is drawn
        // from the same set, so no payout can land outside it.
        uint256 credited;
        for (uint256 i = 0; i < 3; ++i) {
            credited += handler.paidTo(handler.actors(i));
        }
        assertEq(credited, handler.paidTotal(), "a release paid an address that is not a request party");
    }

    /// @notice A paused perimeter pays nobody, down either payout leg. The
    ///         handler snapshots `securityPerimeterPaused()` before each release
    ///         and each stuck-exit recovery, and counts any payout that still
    ///         went through.
    function invariant_pause_stops_payouts() public view {
        assertEq(handler.pausedPayouts(), 0, "a payout went through while the perimeter was paused");
    }

    /// @notice Recovery-away along a route only ever moved funds whose
    ///         originator or owner was Blacklisted, and every id it moved is
    ///         terminal in exactly that state.
    function invariant_route_resolution_requires_blacklist() public view {
        assertEq(
            handler.routeResolutionsWithoutBlacklist(),
            0,
            "a route resolved funds with no blacklisted source party"
        );
        assertEq(handler.unauthorizedRouteResolutionId(), 0, "unauthorized route resolution");
        uint256 n = handler.routeResolvedIdCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.routeResolvedIdAt(i);
            assertTrue(handler.resolvedByRoute(id), "route ledger missing an id it resolved");
            assertEq(
                uint256(queue.getRequest(id).status),
                uint256(IExitDelayQueue.ExitStatus.ResolvedToProtocol),
                "route-resolved id is not ResolvedToProtocol"
            );
        }
    }

    /// @notice Blocking by request id blocks exactly that request's parties:
    ///         originator and owner always land at least as hard-blocked as
    ///         asked, the receiver lands blocked when and only when the caller
    ///         flagged it, and an unflagged receiver that is not itself a source
    ///         party is left untouched. Measured by the handler the moment the
    ///         call returns, because a later unfreeze may legitimately clear it.
    function invariant_by_request_block_matches_parties() public view {
        assertEq(handler.byRequestPartyMisses(), 0, "by-request block left a source party unblocked");
        assertEq(handler.byRequestReceiverMisses(), 0, "by-request block skipped a flagged receiver");
        assertEq(handler.byRequestReceiverLeaks(), 0, "by-request block touched an unflagged receiver");
    }

    // ── reachability ─────────────────────────────────────────────

    /// @notice Non-vacuity companion for the four operator-lever invariants.
    ///         Each of them is a "this never happened" assertion, which a
    ///         handler that never reaches the guarded path would satisfy for
    ///         free. This drives a short scripted campaign through the same
    ///         handler and proves every guarded path was entered: a release was
    ///         attempted under the pause, a release was attempted with a blocked
    ///         party, a two-id batch was released, the stuck-exit recovery leg
    ///         paid out, both by-request block variants ran, and both routes
    ///         resolved funds away. The guard counters are then still zero — the
    ///         invariants hold on a run that demonstrably reached them.
    function test_handler_reaches_operator_levers() public {
        // Four ERC20 exits and one native exit, all sharing originator/owner so
        // one caller can release a batch of them.
        handler.recordErc20(uint128(1e18), 0, 0, 0);
        handler.recordErc20(uint128(1e18), 0, 0, 0);
        handler.recordErc20(uint128(1e18), 0, 0, 0);
        handler.recordNative(uint128(1e18), 0, 0, 0);
        handler.recordErc20(uint128(1e18), 0, 0, 0);

        // Batch release of two ids in one call.
        handler.executeMany(0, 1);
        assertEq(handler.batchExecutions(), 1, "batch release never ran");
        assertEq(handler.batchExecutedIds(), 2, "batch release did not carry two ids");
        assertEq(handler.multiIdBatches(), 1, "no batch carried more than one id");
        assertGt(handler.executedPayouts(), 0, "no release was ever paid");

        // The second payout leg: stuck-exit recovery, which shares the pause
        // gate, carries a stricter block gate, and may pay an address the
        // request never named. It has to reach the same payout ledger.
        uint256 paidBefore = handler.paidTotal();
        handler.recoverStuck(4, 0);
        assertEq(handler.recoveredPayouts(), 1, "stuck-exit recovery never paid out");
        assertGt(handler.paidTotal(), paidBefore, "recovery payout never reached the ledger");

        // A release attempted while the perimeter is paused.
        handler.pause(true);
        handler.execute(2, 0);
        assertGt(handler.executedWhilePausedAttempts(), 0, "no release was attempted under the pause");
        handler.pause(false);

        // A release attempted with a blocked party.
        handler.freeze(0);
        handler.execute(2, 0);
        assertGt(handler.executedWhileBlockedAttempts(), 0, "no release was attempted with a blocked party");
        handler.unfreeze(0);

        // Both by-request block variants, with and without the receiver. The
        // last call escalates a receiver the freeze above left merely Frozen, so
        // the receiver's "at least as hard-blocked as asked" floor is exercised
        // and not just its "blocked at all" state.
        handler.freezeByRequest(2, true);
        handler.blacklistByRequest(2, false);
        handler.blacklistByRequest(2, true);
        assertEq(handler.byRequestBlocks(), 3, "by-request blocking never ran");
        assertEq(handler.byRequestReceiverBlocks(), 2, "the receiver-catching variant never ran");

        // Recovery-away down both routes, now that a source party is blacklisted.
        handler.resolveByRoute(2);
        handler.resolveByRoute(3);
        assertEq(handler.routeResolutions(), 2, "route resolution never ran on both routes");

        // Re-registering a route is idempotent and stays reachable.
        handler.addRoute(0);
        handler.addRoute(1);
        assertEq(handler.routesRegistered(), 4, "route registration never ran");

        // …and every guard the four invariants pin still held throughout.
        invariant_blocked_party_never_paid();
        invariant_pause_stops_payouts();
        invariant_route_resolution_requires_blacklist();
        invariant_by_request_block_matches_parties();
        invariant_solvency_erc20();
        invariant_solvency_native();
        invariant_id_monotonic();
        invariant_no_double_terminal();
    }

    function _inActive(address party, uint256 id) internal view returns (bool) {
        // page through getActive (bounded live sets in the run)
        uint256 cursor = 0;
        for (uint256 guard = 0; guard < 50; ++guard) {
            (uint256[] memory ids, uint256 next) = queue.getActive(party, cursor, 100);
            for (uint256 j = 0; j < ids.length; ++j) {
                if (ids[j] == id) return true;
            }
            if (next == 0) break;
            cursor = next;
        }
        return false;
    }
}
