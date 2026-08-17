// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

contract InvMockERC20 is ERC20 {
    constructor() ERC20("Inv", "INV") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Force-sends native RBTC via selfdestruct — bypasses the queue's
///      `receive` gate, exactly the donation-grief vector the tolerates.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Stateful handler that drives the queue through its whole surface for the
///      forge invariant runner. It is itself an `_allowedSource` and the
///      `nativePusher`, so it can exercise every ingress variant. It tracks a
///      ghost sum of Queued amounts per token to check solvency and
///      records executed ids to check monotonicity / no-double-spend.
///      Bounded actor set keeps blocks meaningful.
contract ExitDelayQueueHandler is Test {
    ExitDelayQueue public queue;
    InvMockERC20 public token;
    address public wrbtc; // canonical WRBTC (native-backed mock in the test)

    // three fixed actors → freeze/execute interplay is meaningful
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint32 public constant MIN_DELAY = 1 hours;

    // ghost accounting
    uint256 public ghostQueuedErc20; // Σ Queued amounts, token
    uint256 public ghostQueuedNative; // Σ Queued amounts, native
    uint256 public totalRecorded; // # of record* calls that succeeded
    uint256 public totalTerminal; // # of terminal transitions

    // track live ids for targeted execute/resolve
    uint256[] public liveIds;

    /// @dev (creation-time, C3): the minimumDelaySeconds floor in effect at
    ///      each request's OWN createdAt. Recorded at the moment of a successful
    ///      record so the invariant can check `unlockAt − createdAt >= floor-at-its-
    ///      creation` — NOT the current live floor. A later setMinimumDelaySeconds
    ///      raise must apply only to NEW requests and never retroactively extend an
    ///      already-Queued exit; this ghost is what lets the invariant assert that.
    mapping(uint256 => uint32) public floorAtCreation;

    constructor(ExitDelayQueue q, InvMockERC20 t, address wrbtc_) {
        queue = q;
        token = t;
        wrbtc = wrbtc_;
        token.mint(address(this), type(uint128).max);
        vm.deal(address(this), type(uint128).max);
    }

    receive() external payable {}

    // ── ingress ──

    /// @dev Overflow-safe actor trio. The receiver index is
    ///      `(seed%3 + 1) % 3` — computed here off the caller's stack (keeping the
    ///      record* frames under the non-via-ir stack limit) and, crucially, on the
    ///      ALREADY-reduced `%3` value so a max seed can never 0x11-overflow the
    ///      way the prior `(seed+1)%3` did. `orig`/`ownr` use the raw `%3` seeds so
    ///      the freeze/execute interplay still spans the whole actor set.
    function _trio(uint256 aSeed, uint256 bSeed)
        internal
        view
        returns (address orig, address ownr, address recvA, address recvB)
    {
        orig = actors[aSeed % 3];
        ownr = actors[bSeed % 3];
        recvA = actors[(aSeed % 3 + 1) % 3];
        recvB = actors[(bSeed % 3 + 1) % 3];
    }

    function recordErc20(uint128 amount, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        amount = uint128(bound(amount, 1, 1e24));
        // Delay is bounded above the live floor so a floor RAISE (see setMinDelay)
        // never bricks ingress here; the request's floor-at-creation is captured
        // below regardless of the delay actually chosen.
        uint32 floor = queue.minimumDelaySeconds();
        uint32 d = floor + uint32(bound(extraDelay, 0, 10 days));
        (address orig, address ownr, address recv,) = _trio(aSeed, bSeed);
        token.approve(address(queue), amount);
        try queue.recordERC20Exit(
            address(token), amount, d, keccak256("S"), address(0xBEEF), orig, ownr, recv, false
        ) returns (uint256 id) {
            liveIds.push(id);
            floorAtCreation[id] = floor;
            ghostQueuedErc20 += amount;
            totalRecorded++;
        } catch {}
    }

    function recordNative(uint128 amount, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        amount = uint128(bound(amount, 1, 1e21));
        uint32 floor = queue.minimumDelaySeconds();
        uint32 d = floor + uint32(bound(extraDelay, 0, 10 days));
        (address orig, address ownr,, address recv) = _trio(aSeed, bSeed);
        try queue.recordNativeExit{value: amount}(amount, d, keccak256("Z"), address(0), orig, ownr, recv)
        returns (uint256 id) {
            liveIds.push(id);
            floorAtCreation[id] = floor;
            ghostQueuedNative += amount;
            totalRecorded++;
        } catch {}
    }

    // ── measured-delta ingress: push then record in one tx. Credit is
    //    exactly `amount` when the non-backing surplus delta >= amount, so a
    //    donation (see donate*) must NOT brick these and must NOT break solvency.

    function recordReceivedErc20(uint128 amount, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        amount = uint128(bound(amount, 1, 1e24));
        uint32 floor = queue.minimumDelaySeconds();
        uint32 d = floor + uint32(bound(extraDelay, 0, 10 days));
        (address orig, address ownr, address recv,) = _trio(aSeed, bSeed);
        token.transfer(address(queue), amount); // push in the same tx
        try queue.recordReceivedERC20Exit(
            address(token), amount, d, keccak256("S"), address(0xBEEF), orig, ownr, recv
        ) returns (uint256 id) {
            liveIds.push(id);
            floorAtCreation[id] = floor;
            ghostQueuedErc20 += amount;
            totalRecorded++;
        } catch {}
    }

    function recordReceivedNative(uint128 amount, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        amount = uint128(bound(amount, 1, 1e21));
        uint32 floor = queue.minimumDelaySeconds();
        uint32 d = floor + uint32(bound(extraDelay, 0, 10 days));
        (address orig, address ownr,, address recv) = _trio(aSeed, bSeed);
        // The handler is the registered nativePusher, so this push clears receive().
        (bool ok,) = payable(address(queue)).call{value: amount}("");
        if (!ok) return;
        try queue.recordReceivedNativeExit(amount, d, keccak256("Z"), address(0), orig, ownr, recv) returns (
            uint256 id
        ) {
            liveIds.push(id);
            floorAtCreation[id] = floor;
            ghostQueuedNative += amount;
            totalRecorded++;
        } catch {}
    }

    // ── donation / force-send: creates non-backing surplus. The measured-delta
    //    credit-exactly-amount rule must keep / intact and never let a
    //    donation get mis-credited into totalEscrowed (grief resistance).

    function donateErc20(uint128 amount) external {
        amount = uint128(bound(amount, 1, 1e18));
        token.transfer(address(queue), amount); // ghost NOT updated: pure surplus
    }

    function donateNative(uint128 amount) external {
        amount = uint128(bound(amount, 1, 1e18));
        // selfdestruct force-send bypasses the receive() gate entirely.
        new ForceSender{value: amount}(payable(address(queue)));
    }

    // ── execution ──

    function execute(uint256 idSeed, uint256 actorSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        // jump past unlock sometimes
        if (actorSeed % 2 == 0 && block.timestamp < r.unlockAt) {
            vm.warp(r.unlockAt);
        }
        address caller = actors[actorSeed % 3];
        vm.prank(caller);
        try queue.executeExit(id) {
            _onTerminal(r);
        } catch {}
    }

    // ── block model ──

    function freeze(uint256 actorSeed) external {
        address a = actors[actorSeed % 3];
        try queue.freeze(a) {} catch {}
    }

    function blacklist(uint256 actorSeed) external {
        address a = actors[actorSeed % 3];
        try queue.blacklist(a) {} catch {}
    }

    function unfreeze(uint256 actorSeed) external {
        address a = actors[actorSeed % 3];
        try queue.unfreeze(a) {} catch {}
    }

    function unblacklist(uint256 actorSeed) external {
        address a = actors[actorSeed % 3];
        try queue.unblacklist(a) {} catch {}
    }

    function pause(bool p) external {
        try queue.setSecurityPerimeterPaused(p) {} catch {}
    }

    /// @dev (C3): fuzz the per-request floor across a RANGE that spans both
    ///      below and (crucially) ABOVE the delays of already-Queued requests. A
    ///      raise here must NOT retroactively extend any live request's unlockAt —
    ///      the creation-time invariant checks each request against its own
    ///      floorAtCreation, never the live floor, so a raise while short requests
    ///      sit Queued must not trip invariant_status_and_index_consistency.
    function setMinDelay(uint32 newFloor) external {
        // Cap well above the max ingress delay (floor + 10 days) so raises that
        // exceed live requests' (unlockAt − createdAt) are reachable and exercised.
        newFloor = uint32(bound(newFloor, 0, 30 days));
        try queue.setMinimumDelaySeconds(newFloor) {} catch {}
    }

    // ── stuck-exit recovery — verify-by-attempting redirect leg ──

    /// @dev recoverStuckExit(id, altReceiver): same {originator, owner} authorization
    ///      as execute. Attempts the STORED receiver first and pays altReceiver only
    ///      on a genuine bounce (verify-by-attempting) — but ON SUCCESS (either
    ///      branch) it is a TERMINAL transition, so ghost accounting must decrement,
    ///      exactly like execute. On a block/lock/pause/terminal/guard it reverts and
    ///      is caught (no state change). altReceiver is one of the plain handler
    ///      actors (never 0/this/token/wrbtc), so the guard never trips here. The
    ///      invariant property: recovery NEVER breaks solvency or double-spends,
    ///      whichever branch it takes.
    function recoverStuck(uint256 idSeed, uint256 actorSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        if (actorSeed % 2 == 0 && block.timestamp < r.unlockAt) {
            vm.warp(r.unlockAt);
        }
        address caller = actors[actorSeed % 3];
        address altReceiver = actors[(actorSeed / 3) % 3];
        vm.prank(caller);
        try queue.recoverStuckExit(id, altReceiver) {
            _onTerminal(r);
        } catch {}
    }

    // ── recovery ──

    function resolveBySIP(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        try queue.resolveBySIP(ids, address(0xD00D)) {
            _onTerminal(r);
        } catch {}
    }

    // ── sweep (surplus removal keeps equality-form solvency reachable) ──

    function sweep(bool native) external {
        try queue.sweepSurplus(native ? address(0) : address(token), address(0x5EE)) {} catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 5 days));
    }

    function _onTerminal(IExitDelayQueue.ExitRequest memory r) internal {
        totalTerminal++;
        if (r.token == address(0)) {
            ghostQueuedNative -= r.amount;
        } else {
            ghostQueuedErc20 -= r.amount;
        }
    }

    function liveIdCount() external view returns (uint256) {
        return liveIds.length;
    }

    function liveIdAt(uint256 i) external view returns (uint256) {
        return liveIds[i];
    }
}
