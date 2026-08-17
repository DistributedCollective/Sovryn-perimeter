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
            keccak256("S"),
            address(0xBEEF),
            actors[aSeed % 3],
            actors[bSeed % 3],
            actors[(aSeed + 1) % 3],
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
            keccak256("Z"),
            address(0),
            actors[aSeed % 3],
            actors[bSeed % 3],
            actors[(bSeed + 1) % 3]
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
        try queue.executeExit(id) {
            _onTerminal(r);
        } catch {}
    }

    /// @dev Gate-5 redirect leg (mirrors ExitDelayQueueHandler.recoverStuck).
    ///      recoverStuckExit(id, altReceiver) shares execute's {originator, owner}
    ///      authorization and on SUCCESS (stored-receiver or altReceiver branch) is
    ///      a TERMINAL transition, so ghost accounting decrements exactly like
    ///      execute. altReceiver is one of the plain EOA actors — never 0/this/
    ///      token/wrbtc — so the guard doesn't mask the leg (actors[0] is this
    ///      harness, hence the 1 + altSeed % 2 pick). Lock/block/pause/terminal
    ///      failures revert and are caught (no state change). Property under test:
    ///      recovery never breaks solvency or double-spends, whichever branch runs.
    function recoverStuck(uint256 idSeed, uint256 altSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (r.status != IExitDelayQueue.ExitStatus.Queued) return;
        address altReceiver = actors[1 + (altSeed % 2)];
        try queue.recoverStuckExit(id, altReceiver) {
            _onTerminal(r);
        } catch {}
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
}
