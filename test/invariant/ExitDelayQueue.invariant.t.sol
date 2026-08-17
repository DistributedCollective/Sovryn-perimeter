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

        // target only the handler
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](17);
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
