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

    // ── provenance the ingress actions stamp on every request. The Leg-2
    //    recovery routes are registered from these exact values, so a route
    //    resolution is reachable from step one instead of being a dead action.
    bytes32 public constant ERC20_SURFACE = keccak256("S");
    bytes32 public constant NATIVE_SURFACE = keccak256("Z");
    address public constant ERC20_SUBPRODUCT = address(0xBEEF);
    address public constant NATIVE_ROUTE_DESTINATION = address(0x2EC0);
    bytes32 public constant BLOCK_REASON = keccak256("perimeter-incident");

    bytes32 public erc20RouteId;
    bytes32 public nativeRouteId;
    uint256 public routesRegistered;

    // ── payout ledger: what left the queue through a release, and the state
    //    the parties were in when it left.
    mapping(address => uint256) public paidTo; // sum released, per receiver
    uint256 public paidTotal;
    uint256 public executedPayouts; // requests released by execute/executeMany
    uint256 public blockedPayouts; // released while a party was Frozen/Blacklisted
    uint256 public blockedPayoutValue;
    address public blockedPayoutParty; // first counterexample, for the failure message
    uint256 public pausedPayouts; // released while the perimeter pause was on

    // reachability counters — proof the guarded paths were actually driven
    uint256 public executedWhileBlockedAttempts;
    uint256 public executedWhilePausedAttempts;
    uint256 public batchExecutions; // successful executeExits calls
    uint256 public batchExecutedIds; // requests released through the batch path

    // ── Leg-2 route resolutions
    mapping(uint256 => bool) public resolvedByRoute;
    uint256[] internal routeResolvedIds;
    uint256 public routeResolutions;
    uint256 public routeResolutionsWithoutBlacklist;
    uint256 public unauthorizedRouteResolutionId; // first counterexample

    // ── by-request blocking
    uint256 public byRequestBlocks; // successful freeze/blacklistFromRequest calls
    uint256 public byRequestReceiverBlocks; // ...of which carried freezeReceiver
    uint256 public byRequestPartyMisses; // a source party left below the asked state
    uint256 public byRequestReceiverMisses; // a flagged receiver left unblocked
    uint256 public byRequestReceiverLeaks; // an unflagged receiver's state moved

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
            address(token), amount, d, ERC20_SURFACE, ERC20_SUBPRODUCT, orig, ownr, recv, false
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
        try queue.recordNativeExit{value: amount}(amount, d, NATIVE_SURFACE, address(0), orig, ownr, recv)
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
            address(token), amount, d, ERC20_SURFACE, ERC20_SUBPRODUCT, orig, ownr, recv
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
        try queue.recordReceivedNativeExit(amount, d, NATIVE_SURFACE, address(0), orig, ownr, recv) returns (
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
        // Snapshot the two release gates BEFORE the call: whether the perimeter
        // was paused, and whether any of the three parties was blocked. Neither
        // is changed by a release, so this is the state at execution time — the
        // state the payout ledger has to be judged against.
        bool paused = queue.securityPerimeterPaused();
        address blocked = _anyBlocked(r);
        if (paused) executedWhilePausedAttempts++;
        if (blocked != address(0)) executedWhileBlockedAttempts++;
        address caller = actors[actorSeed % 3];
        vm.prank(caller);
        try queue.executeExit(id) {
            _onPaid(r, paused, blocked);
        } catch {}
    }

    /// @dev Batch release. `executeExits` is atomic and every id in it is paid
    ///      by the same caller, so the second id joins only when the first id's
    ///      originator is a party to it too; otherwise a one-element batch runs
    ///      (still the batch entry point, still the `EmptyIds` guard's other
    ///      side). Ghost accounting is applied once per request actually paid.
    function executeMany(uint256 seedA, uint256 seedB) external {
        if (liveIds.length == 0) return;
        uint256 idA = liveIds[seedA % liveIds.length];
        uint256 idB = liveIds[seedB % liveIds.length];
        IExitDelayQueue.ExitRequest memory a = queue.getRequest(idA);
        if (a.status != IExitDelayQueue.ExitStatus.Queued) return;
        IExitDelayQueue.ExitRequest memory b = queue.getRequest(idB);
        bool pair = idB != idA && b.status == IExitDelayQueue.ExitStatus.Queued
            && (b.originator == a.originator || b.owner == a.originator);
        _warpPastUnlock(a.unlockAt, pair ? b.unlockAt : 0);
        uint256[] memory ids = new uint256[](pair ? 2 : 1);
        ids[0] = idA;
        if (pair) ids[1] = idB;
        _executeBatch(ids, a, b, pair);
    }

    /// @dev Split out of `executeMany` to keep both frames inside the stack limit.
    function _executeBatch(
        uint256[] memory ids,
        IExitDelayQueue.ExitRequest memory a,
        IExitDelayQueue.ExitRequest memory b,
        bool pair
    ) internal {
        bool paused = queue.securityPerimeterPaused();
        address blockedA = _anyBlocked(a);
        address blockedB = pair ? _anyBlocked(b) : address(0);
        if (paused) executedWhilePausedAttempts++;
        if (blockedA != address(0) || blockedB != address(0)) executedWhileBlockedAttempts++;
        vm.prank(a.originator);
        try queue.executeExits(ids) {
            batchExecutions++;
            batchExecutedIds += ids.length;
            _onPaid(a, paused, blockedA);
            if (pair) _onPaid(b, paused, blockedB);
        } catch {}
    }

    function _warpPastUnlock(uint64 unlockA, uint64 unlockB) internal {
        uint64 unlockAt = unlockB > unlockA ? unlockB : unlockA;
        if (block.timestamp < unlockAt) vm.warp(unlockAt);
    }

    /// @dev The party that would have made this release illegal, or the zero
    ///      address when all three are clear. Mirrors the queue's own gate order.
    function _anyBlocked(IExitDelayQueue.ExitRequest memory r) internal view returns (address) {
        if (queue.blockStateOf(r.originator) != IExitDelayQueue.BlockState.None) return r.originator;
        if (queue.blockStateOf(r.owner) != IExitDelayQueue.BlockState.None) return r.owner;
        if (queue.blockStateOf(r.receiver) != IExitDelayQueue.BlockState.None) return r.receiver;
        return address(0);
    }

    /// @dev Ledger entry for a request a release actually paid out. Records where
    ///      the value went and, alongside it, the two conditions that were meant
    ///      to make the payout impossible.
    function _onPaid(IExitDelayQueue.ExitRequest memory r, bool paused, address blocked) internal {
        executedPayouts++;
        paidTo[r.receiver] += r.amount;
        paidTotal += r.amount;
        if (paused) pausedPayouts++;
        if (blocked != address(0)) {
            blockedPayouts++;
            blockedPayoutValue += r.amount;
            if (blockedPayoutParty == address(0)) blockedPayoutParty = blocked;
        }
        _onTerminal(r);
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

    // ── blocking by request id ──

    /// @dev The emergency lever: name a request, block the parties behind it.
    ///      `freezeReceiver` decides whether the payout destination is caught
    ///      too. Both variants take the batch form, which is what an operator
    ///      calls. The handler is the queue owner and every party of a recorded
    ///      request is a non-zero actor, so a known id cannot revert here — the
    ///      call is made bare so that an unexpected revert fails the run.
    function freezeByRequest(uint256 idSeed, bool receiver) external {
        _blockByRequest(idSeed, receiver, false);
    }

    function blacklistByRequest(uint256 idSeed, bool receiver) external {
        _blockByRequest(idSeed, receiver, true);
    }

    function _blockByRequest(uint256 idSeed, bool receiver, bool confirmed) internal {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status == IExitDelayQueue.ExitStatus.None) return;
        // The receiver's state before the call: with `freezeReceiver` false the
        // call must leave it exactly where it was.
        IExitDelayQueue.BlockState receiverBefore = queue.blockStateOf(r.receiver);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        if (confirmed) {
            queue.blacklistFromRequest(ids, receiver, BLOCK_REASON);
        } else {
            queue.freezeFromRequest(ids, receiver, BLOCK_REASON);
        }
        _recordByRequest(r, receiver, confirmed, receiverBefore);
    }

    /// @dev What the by-request lever promised, measured the moment it returned.
    ///      A later unfreeze may legitimately clear any of this, so the check has
    ///      to be taken here and carried in ghost state.
    function _recordByRequest(
        IExitDelayQueue.ExitRequest memory r,
        bool receiver,
        bool confirmed,
        IExitDelayQueue.BlockState receiverBefore
    ) internal {
        byRequestBlocks++;
        if (receiver) byRequestReceiverBlocks++;
        // Both source parties end at least as hard-blocked as asked. A freeze
        // over an already-blacklisted party holds the stronger state, which is
        // why this is a floor and not an equality.
        IExitDelayQueue.BlockState want =
            confirmed ? IExitDelayQueue.BlockState.Blacklisted : IExitDelayQueue.BlockState.Frozen;
        if (uint8(queue.blockStateOf(r.originator)) < uint8(want)) byRequestPartyMisses++;
        if (uint8(queue.blockStateOf(r.owner)) < uint8(want)) byRequestPartyMisses++;
        if (receiver) {
            // Same floor as the source parties, not merely "blocked at all": a
            // blacklist-by-request that only FROZE the receiver would otherwise
            // pass, and a freeze is clearable and does not authorize Leg-2.
            if (uint8(queue.blockStateOf(r.receiver)) < uint8(want)) byRequestReceiverMisses++;
        } else if (r.receiver != r.originator && r.receiver != r.owner) {
            // Unflagged and not a source party: the lever must not have touched it.
            if (queue.blockStateOf(r.receiver) != receiverBefore) byRequestReceiverLeaks++;
        }
    }

    // ── recovery routes (Leg-2) ──

    /// @notice Register the two routes that match this handler's own ingress
    ///         provenance. Called once by the invariant setUp after the handler
    ///         has accepted ownership; the queue calls below are made by the
    ///         handler itself, so they clear `onlyOwner` whoever calls this.
    function setUpRoutes() external {
        _registerErc20Route();
        _registerNativeRoute();
    }

    /// @dev A top-up route may only be registered on a surface the owner has
    ///      marked feasible, must carry a real token, and must pay the pool the
    ///      exit came from — hence `setTopUpFeasible` first and
    ///      `destination == subProduct`.
    function _registerErc20Route() internal {
        queue.setTopUpFeasible(ERC20_SURFACE, true);
        erc20RouteId = queue.setRecoveryRoute(
            IExitDelayQueue.RecoveryRoute({
                active: true,
                surfaceId: ERC20_SURFACE,
                subProduct: ERC20_SUBPRODUCT,
                token: address(token),
                destination: ERC20_SUBPRODUCT,
                topUpPool: true
            })
        );
        routesRegistered++;
    }

    /// @dev A native exit can never be a pool top-up, so this one is a plain
    ///      recovery-away route to a fixed destination.
    function _registerNativeRoute() internal {
        nativeRouteId = queue.setRecoveryRoute(
            IExitDelayQueue.RecoveryRoute({
                active: true,
                surfaceId: NATIVE_SURFACE,
                subProduct: address(0),
                token: address(0),
                destination: NATIVE_ROUTE_DESTINATION,
                topUpPool: false
            })
        );
        routesRegistered++;
    }

    /// @dev Re-registering a route is idempotent (the id is derived from the
    ///      route's own fields), so this action keeps both routes live across the
    ///      run and exercises the registration guards each time.
    function addRoute(uint256 tokenSeed) external {
        if (tokenSeed % 2 == 0) {
            _registerErc20Route();
        } else {
            _registerNativeRoute();
        }
    }

    /// @dev Leg-2 recovery-away. The blacklist state of the source parties is
    ///      read BEFORE the call and carried into ghost state exactly as observed
    ///      — the action never filters on it, so a resolution that went through
    ///      without one is recorded rather than skipped.
    function resolveByRoute(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = _routeCandidate(idSeed);
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        bytes32 routeId = r.token == address(0) ? nativeRouteId : erc20RouteId;
        if (routeId == bytes32(0)) return;
        bool blacklisted = queue.blockStateOf(r.originator) == IExitDelayQueue.BlockState.Blacklisted
            || queue.blockStateOf(r.owner) == IExitDelayQueue.BlockState.Blacklisted;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        try queue.resolveToProtocol(ids, routeId) {
            resolvedByRoute[id] = true;
            routeResolvedIds.push(id);
            routeResolutions++;
            if (!blacklisted) {
                routeResolutionsWithoutBlacklist++;
                if (unauthorizedRouteResolutionId == 0) unauthorizedRouteResolutionId = id;
            }
            _onTerminal(r);
        } catch {}
    }

    /// @dev Prefer a Queued id whose Leg-2 authorization already holds so the
    ///      route path is reachable, and fall back to the plain seed pick — the
    ///      fallback is what would carry an unauthorized resolution through if
    ///      the queue ever stopped demanding a blacklist.
    function _routeCandidate(uint256 idSeed) internal view returns (uint256) {
        uint256 n = liveIds.length;
        // Reduce the seed BEFORE adding the scan offset: `(idSeed + i) % n` on a
        // raw seed overflows at the top of the uint256 range.
        uint256 base = idSeed % n;
        uint256 scan = n < 16 ? n : 16;
        for (uint256 i = 0; i < scan; ++i) {
            uint256 c = liveIds[(base + i) % n];
            IExitDelayQueue.ExitRequest memory r = queue.getRequest(c);
            if (r.status != IExitDelayQueue.ExitStatus.Queued) continue;
            if (
                queue.blockStateOf(r.originator) == IExitDelayQueue.BlockState.Blacklisted
                    || queue.blockStateOf(r.owner) == IExitDelayQueue.BlockState.Blacklisted
            ) return c;
        }
        return liveIds[base];
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

    function routeResolvedIdCount() external view returns (uint256) {
        return routeResolvedIds.length;
    }

    function routeResolvedIdAt(uint256 i) external view returns (uint256) {
        return routeResolvedIds[i];
    }
}
