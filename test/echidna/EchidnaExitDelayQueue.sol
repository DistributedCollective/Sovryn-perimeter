// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

contract EchMockERC20 is ERC20 {
    constructor() ERC20("Ech", "ECH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EchWRBTC {
    function withdraw(uint256) external {}
    receive() external payable {}
}

/// @dev Self-contained Echidna harness (property mode, no cheatcodes).
///      The harness is contract owner + allowed source + native pusher and is
///      itself one of the request parties so it can execute. Ghost accounting
///      mirrors test/invariant/ExitDelayQueueHandler.sol: conservation
///      (/ solvency), id monotonicity, and single terminal
///      transition.
contract EchidnaExitDelayQueue {
    ExitDelayQueue internal queue;
    EchMockERC20 internal token;
    EchWRBTC internal wrbtc;

    address internal constant ADMIN = address(0xAD01);
    uint32 internal constant MIN_DELAY = 1 hours;

    address[3] internal actors;

    // ghost accounting
    uint256 internal ghostQueuedErc20;
    uint256 internal ghostQueuedNative;
    uint256 internal totalRecorded;
    uint256 internal totalTerminal;

    uint256[] internal liveIds;

    // Provenance stamped on every recorded request; the Leg-2 routes are
    // registered from these exact values so recovery-away is reachable.
    bytes32 internal constant ERC20_SURFACE = keccak256("S");
    bytes32 internal constant NATIVE_SURFACE = keccak256("Z");
    address internal constant ERC20_SUBPRODUCT = address(0xBEEF);
    address internal constant NATIVE_ROUTE_DESTINATION = address(0x2EC0);
    bytes32 internal constant BLOCK_REASON = keccak256("perimeter-incident");

    bytes32 internal erc20RouteId;
    bytes32 internal nativeRouteId;

    // operator-lever ghost state, mirroring ExitDelayQueueHandler
    mapping(address => uint256) public paidTo;
    uint256 public paidTotal;
    uint256 public blockedPayouts;
    uint256 public blockedPayoutValue;
    uint256 public pausedPayouts;
    mapping(uint256 => bool) public resolvedByRoute;
    uint256 public routeResolutions;
    uint256 public routeResolutionsWithoutBlacklist;

    // Reachability counters. A "this never happened" property is satisfied for
    // free by a campaign that never enters the path it guards, so these record
    // that the campaign did. They are permanent and public: `leversReached()`
    // reads them, and inverting it into a property makes a run falsify it,
    // which is the campaign reporting its own coverage in one line.
    uint256 public executedPayouts; // requests released by execute/executeMany
    uint256 public recoveredPayouts; // requests paid out by recoverStuckExit
    uint256 public executedWhileBlockedAttempts; // releases tried with a party blocked
    uint256 public executedWhilePausedAttempts; // releases tried under the pause
    uint256 public batchExecutions; // successful executeExits calls
    uint256 public batchExecutedIds; // requests released through the batch path
    uint256 public multiIdBatches; // ...of which carried more than one id
    uint256 public byRequestBlocks; // successful freeze/blacklistFromRequest calls
    uint256 public byRequestReceiverBlocks; // ...of which carried freezeReceiver

    constructor() payable {
        actors[0] = address(this);
        actors[1] = address(0xA1);
        actors[2] = address(0xA2);

        wrbtc = new EchWRBTC();
        token = new EchMockERC20();

        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory sources = new address[](1);
        sources[0] = address(this);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, address(this), ADMIN, address(wrbtc), MIN_DELAY, sources
        );
        queue = ExitDelayQueue(payable(address(new ERC1967Proxy(address(impl), init))));
        queue.setNativePusher(address(this));

        token.mint(address(this), type(uint128).max);

        _registerErc20Route();
        _registerNativeRoute();
    }

    receive() external payable {}

    // ── actions ──

    function recordErc20(uint128 amountSeed, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        uint128 amount = uint128(1 + (uint256(amountSeed) % 1e24));
        uint32 d = MIN_DELAY + (extraDelay % uint32(2 days));
        token.approve(address(queue), amount);
        try queue.recordERC20Exit(
            address(token),
            amount,
            d,
            ERC20_SURFACE,
            ERC20_SUBPRODUCT,
            actors[aSeed % 3],
            actors[bSeed % 3],
            actors[(aSeed % 3 + 1) % 3],
            false
        ) returns (uint256 id) {
            liveIds.push(id);
            ghostQueuedErc20 += amount;
            totalRecorded++;
        } catch {}
    }

    function recordNative(uint128 amountSeed, uint32 extraDelay, uint256 aSeed, uint256 bSeed) external {
        uint128 amount = uint128(1 + (uint256(amountSeed) % 1e20));
        if (address(this).balance < amount) return;
        uint32 d = MIN_DELAY + (extraDelay % uint32(2 days));
        try queue.recordNativeExit{value: amount}(
            amount,
            d,
            NATIVE_SURFACE,
            address(0),
            actors[aSeed % 3],
            actors[bSeed % 3],
            actors[(bSeed % 3 + 1) % 3]
        ) returns (uint256 id) {
            liveIds.push(id);
            ghostQueuedNative += amount;
            totalRecorded++;
        } catch {}
    }

    function execute(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        // Snapshot the two release gates before the call. Neither is changed by
        // a release, so this is the state at execution time.
        bool paused = queue.securityPerimeterPaused();
        address blocked = _anyBlocked(r);
        if (paused) executedWhilePausedAttempts++;
        if (blocked != address(0)) executedWhileBlockedAttempts++;
        try queue.executeExit(id) {
            _onPaid(r, paused, blocked);
        } catch {}
    }

    /// @dev Batch release. `executeExits` is atomic and every id in it is paid
    ///      by the same caller — here always the harness — so the second id
    ///      joins only when the harness is a party to it too; otherwise a
    ///      one-element batch runs (still the batch entry point, still the
    ///      `EmptyIds` guard's other side). Without the party check the pair
    ///      reverts as a whole and the batch path degenerates into a no-op.
    ///      Attempt counters are per call, matching the invariant handler.
    function executeMany(uint256 seedA, uint256 seedB) external {
        if (liveIds.length == 0) return;
        uint256 idA = liveIds[seedA % liveIds.length];
        uint256 idB = liveIds[seedB % liveIds.length];
        IExitDelayQueue.ExitRequest memory a = queue.getRequest(idA);
        if (a.status != IExitDelayQueue.ExitStatus.Queued) return;
        IExitDelayQueue.ExitRequest memory b = queue.getRequest(idB);
        bool pair = idB != idA && b.status == IExitDelayQueue.ExitStatus.Queued
            && (b.originator == address(this) || b.owner == address(this));
        uint256[] memory ids = new uint256[](pair ? 2 : 1);
        ids[0] = idA;
        if (pair) ids[1] = idB;
        bool paused = queue.securityPerimeterPaused();
        address blockedA = _anyBlocked(a);
        address blockedB = pair ? _anyBlocked(b) : address(0);
        if (paused) executedWhilePausedAttempts++;
        if (blockedA != address(0) || blockedB != address(0)) executedWhileBlockedAttempts++;
        try queue.executeExits(ids) {
            batchExecutions++;
            batchExecutedIds += ids.length;
            if (ids.length > 1) multiIdBatches++;
            _onPaid(a, paused, blockedA);
            if (pair) _onPaid(b, paused, blockedB);
        } catch {}
    }

    /// @dev The party that would have made this release illegal, or the zero
    ///      address when all three are clear.
    function _anyBlocked(IExitDelayQueue.ExitRequest memory r) internal view returns (address) {
        if (queue.blockStateOf(r.originator) != IExitDelayQueue.BlockState.None) return r.originator;
        if (queue.blockStateOf(r.owner) != IExitDelayQueue.BlockState.None) return r.owner;
        if (queue.blockStateOf(r.receiver) != IExitDelayQueue.BlockState.None) return r.receiver;
        return address(0);
    }

    /// @dev The party that would have made this recovery illegal. Recovery
    ///      carries a stricter gate than a plain release: `altReceiver` is a
    ///      fourth actor the queue also refuses to pay past.
    function _anyBlockedForRecovery(IExitDelayQueue.ExitRequest memory r, address alt)
        internal
        view
        returns (address)
    {
        address blocked = _anyBlocked(r);
        if (blocked != address(0)) return blocked;
        if (queue.blockStateOf(alt) != IExitDelayQueue.BlockState.None) return alt;
        return address(0);
    }

    /// @dev Balance of `who` in the asset the request escrows; address(0) is
    ///      native. Reading it either side of a payout is what names the actual
    ///      recipient without trusting which branch the queue took.
    function _balanceOf(address t, address who) internal view returns (uint256) {
        return t == address(0) ? who.balance : token.balanceOf(who);
    }

    /// @dev Ledger entry for a request a release actually paid, alongside the
    ///      two conditions that were meant to make the payout impossible.
    function _onPaid(IExitDelayQueue.ExitRequest memory r, bool paused, address blocked) internal {
        executedPayouts++;
        _onPaidTo(r, r.receiver, paused, blocked);
    }

    /// @dev Payout ledger keyed on the address the value actually reached, which
    ///      the recovery leg may choose at payout time.
    function _onPaidTo(IExitDelayQueue.ExitRequest memory r, address recipient, bool paused, address blocked)
        internal
    {
        paidTo[recipient] += r.amount;
        paidTotal += r.amount;
        if (paused) pausedPayouts++;
        if (blocked != address(0)) {
            blockedPayouts++;
            blockedPayoutValue += r.amount;
        }
        _onTerminal(r);
    }

    // ── blocking by request id ──

    /// @dev Name a request, block the parties behind it; `freezeReceiver`
    ///      decides whether the payout destination is caught too.
    function freezeByRequest(uint256 idSeed, bool receiver) external {
        _blockByRequest(idSeed, receiver, false);
    }

    function blacklistByRequest(uint256 idSeed, bool receiver) external {
        _blockByRequest(idSeed, receiver, true);
    }

    function _blockByRequest(uint256 idSeed, bool receiver, bool confirmed) internal {
        if (liveIds.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = liveIds[idSeed % liveIds.length];
        if (confirmed) {
            try queue.blacklistFromRequest(ids, receiver, BLOCK_REASON) {
                _onByRequest(receiver);
            } catch {}
        } else {
            try queue.freezeFromRequest(ids, receiver, BLOCK_REASON) {
                _onByRequest(receiver);
            } catch {}
        }
    }

    function _onByRequest(bool receiver) internal {
        byRequestBlocks++;
        if (receiver) byRequestReceiverBlocks++;
    }

    // ── recovery routes (Leg-2) ──

    /// @dev A top-up route may only be registered on a feasible surface, must
    ///      carry a real token, and must pay the pool the exit came from.
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
    }

    /// @dev A native exit can never be a pool top-up, so this is a plain
    ///      recovery-away route.
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
    }

    /// @dev Re-registering a route is idempotent (its id is derived from its own
    ///      fields) and re-runs the registration guards each time.
    function addRoute(uint256 tokenSeed) external {
        if (tokenSeed % 2 == 0) {
            _registerErc20Route();
        } else {
            _registerNativeRoute();
        }
    }

    /// @dev Leg-2 recovery-away. The blacklist state of the source parties is
    ///      read before the call and carried into ghost state as observed — the
    ///      action never filters on it, so a resolution that went through
    ///      without one is recorded rather than skipped.
    function resolveByRoute(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = _routeCandidate(idSeed);
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        bytes32 routeId = r.token == address(0) ? nativeRouteId : erc20RouteId;
        bool blacklisted = queue.blockStateOf(r.originator) == IExitDelayQueue.BlockState.Blacklisted
            || queue.blockStateOf(r.owner) == IExitDelayQueue.BlockState.Blacklisted;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        try queue.resolveToProtocol(ids, routeId) {
            resolvedByRoute[id] = true;
            routeResolutions++;
            if (!blacklisted) routeResolutionsWithoutBlacklist++;
            _onTerminal(r);
        } catch {}
    }

    /// @dev Prefer a Queued id whose Leg-2 authorization already holds so the
    ///      route path is reachable, falling back to the plain seed pick — the
    ///      fallback is what would carry an unauthorized resolution through if
    ///      the queue ever stopped demanding a blacklist. The seed is reduced
    ///      before the scan offset is added so a max seed cannot overflow.
    function _routeCandidate(uint256 idSeed) internal view returns (uint256) {
        uint256 n = liveIds.length;
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

    /// @dev Gate-5 redirect leg (mirrors ExitDelayQueueHandler.recoverStuck).
    ///      recoverStuckExit(id, altReceiver) shares execute's {originator, owner}
    ///      authorization and on SUCCESS (stored-receiver or altReceiver branch) is
    ///      a TERMINAL transition, so ghost accounting decrements exactly like
    ///      execute. altReceiver is one of the plain EOA actors — never 0/this/
    ///      token/wrbtc — so the guard doesn't mask the leg (actors[0] is this
    ///      harness, hence the 1 + altSeed % 2 pick). Lock/block/pause/terminal
    ///      failures revert and are caught (no state change).
    ///
    ///      This is a SECOND payout leg, so a success goes through the same
    ///      payout ledger as a plain release: the pause and the four-actor block
    ///      gate are snapshotted before the call, and the recipient is read off
    ///      the balance the payout moved rather than assumed, because the leg
    ///      pays `altReceiver` when the stored receiver bounces.
    function recoverStuck(uint256 idSeed, uint256 altSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        _recover(id, r, actors[1 + (altSeed % 2)]);
    }

    /// @dev Split out of `recoverStuck` to keep both frames inside the stack limit.
    function _recover(uint256 id, IExitDelayQueue.ExitRequest memory r, address alt) internal {
        bool paused = queue.securityPerimeterPaused();
        address blocked = _anyBlockedForRecovery(r, alt);
        uint256 balBefore = _balanceOf(r.token, r.receiver);
        try queue.recoverStuckExit(id, alt) {
            recoveredPayouts++;
            _onPaidTo(r, _recipientOf(r, alt, balBefore), paused, blocked);
        } catch {}
    }

    /// @dev Whoever the payout actually credited: the stored receiver when its
    ///      balance moved by the request amount, otherwise the alternate.
    function _recipientOf(IExitDelayQueue.ExitRequest memory r, address alt, uint256 balBefore)
        internal
        view
        returns (address)
    {
        return _balanceOf(r.token, r.receiver) >= balBefore + r.amount ? r.receiver : alt;
    }

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

    function freeze(uint256 actorSeed) external {
        try queue.freeze(actors[actorSeed % 3]) {} catch {}
    }

    function blacklist(uint256 actorSeed) external {
        try queue.blacklist(actors[actorSeed % 3]) {} catch {}
    }

    function unfreeze(uint256 actorSeed) external {
        try queue.unfreeze(actors[actorSeed % 3]) {} catch {}
    }

    function unblacklist(uint256 actorSeed) external {
        try queue.unblacklist(actors[actorSeed % 3]) {} catch {}
    }

    function pause(bool p) external {
        try queue.setSecurityPerimeterPaused(p) {} catch {}
    }

    function sweep(bool native) external {
        try queue.sweepSurplus(native ? address(0) : address(token), address(0x5EE)) {} catch {}
    }

    function _onTerminal(IExitDelayQueue.ExitRequest memory r) internal {
        totalTerminal++;
        if (r.token == address(0)) {
            ghostQueuedNative -= r.amount;
        } else {
            ghostQueuedErc20 -= r.amount;
        }
    }

    // ── properties ──

    function echidna_solvency_erc20() external view returns (bool) {
        uint256 esc = queue.totalEscrowed(address(token));
        return esc == ghostQueuedErc20 && esc <= token.balanceOf(address(queue));
    }

    function echidna_solvency_native() external view returns (bool) {
        uint256 esc = queue.totalEscrowed(address(0));
        return esc == ghostQueuedNative && esc <= address(queue).balance;
    }

    function echidna_id_monotonic() external view returns (bool) {
        return queue.lastRequestId() == totalRecorded;
    }

    function echidna_no_double_terminal() external view returns (bool) {
        return totalTerminal <= totalRecorded;
    }

    /// @dev No release ever paid out while any of originator/owner/receiver was
    ///      Frozen or Blacklisted, measured at execution time.
    function echidna_blocked_party_never_paid() external view returns (bool) {
        // Every credit in the payout ledger names a known request party: the
        // stored receiver is immutable, so a release cannot pay elsewhere.
        uint256 credited = paidTo[actors[0]] + paidTo[actors[1]] + paidTo[actors[2]];
        return blockedPayouts == 0 && blockedPayoutValue == 0 && credited == paidTotal;
    }

    /// @dev A paused perimeter pays nobody.
    function echidna_pause_stops_payouts() external view returns (bool) {
        return pausedPayouts == 0;
    }

    /// @dev Recovery-away down a route only ever moved funds whose originator or
    ///      owner was Blacklisted.
    function echidna_route_needs_blacklist() external view returns (bool) {
        return routeResolutionsWithoutBlacklist == 0;
    }

    /// @notice True once the campaign has entered every guarded path the three
    ///         properties above are about: a release paid, a release tried with a
    ///         party blocked, a release tried under the pause, a batch carrying
    ///         more than one id, both by-request block variants, a route
    ///         resolution, and a recovery payout. Not a property itself — a run
    ///         that has not got there yet is not a failure. `EchidnaExitDelayQueueReach`
    ///         turns it into one, so a campaign reports its own coverage.
    function leversReached() public view returns (bool) {
        return executedPayouts > 0 && recoveredPayouts > 0 && executedWhileBlockedAttempts > 0
            && executedWhilePausedAttempts > 0 && byRequestBlocks > 0 && byRequestReceiverBlocks > 0
            && multiIdBatches > 0 && routeResolutions > 0;
    }

    /// @dev The ledger and the reachability counters have to agree: a payout
    ///      taken under a gate is one of the payouts (release or recovery), a
    ///      batch never reports fewer ids than calls nor more multi-id batches
    ///      than batches, and an unauthorized route resolution is one of the
    ///      route resolutions. Drift here means the evidence above is measuring
    ///      something other than what it claims.
    function echidna_lever_counters_consistent() external view returns (bool) {
        uint256 payouts = executedPayouts + recoveredPayouts;
        return blockedPayouts <= payouts && pausedPayouts <= payouts && blockedPayoutValue <= paidTotal
            && batchExecutions <= batchExecutedIds && multiIdBatches <= batchExecutions
            && byRequestReceiverBlocks <= byRequestBlocks && routeResolutionsWithoutBlacklist <= routeResolutions;
    }
}
