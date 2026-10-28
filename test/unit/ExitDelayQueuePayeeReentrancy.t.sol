// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

/// @title  ExitDelayQueuePayeeReentrancy
/// @notice Drives a re-entering payee through every value-out entry point of
///         the queue that does not already have a re-entering-payee test
///         elsewhere in the suite — `executeExit`, `executeExits`,
///         `recoverStuckExit`, `resolveByOwner`, `sweepSurplus` — across
///         native, WRBTC-unwrap and hooked-ERC20 payouts, plus the
///         transient-surplus case of a token that calls its recipient
///         BEFORE moving the balance. (Ingress reentrancy is pinned by
///         `test_recordERC20_is_nonReentrant` in `ExitDelayQueue.t.sol`;
///         `resolveToProtocol` reentrancy by
///         `test_mutant_ExitDelayQueue_798_resolveToProtocol_is_nonReentrant`
///         in `ExitDelayQueueMutants.t.sol`.) Every test asserts the concrete
///         outcome: the re-entry attempt is rejected, the request already
///         shows its terminal state and reduced escrow while the payee is
///         running, balances move exactly once for exactly the paid amount,
///         and — for the pre-hook token — the transient surplus is neither
///         recorded as escrow nor swept.
contract ExitDelayQueuePayeeReentrancyTest is Test {
    ExitDelayQueue queue;
    StipendWRBTC wrbtc;
    HookToken hookToken;
    Source source;
    Hostile hostile;

    address constant OWNER = address(0x0E1);
    address constant ADMIN = address(0xAd11);
    address constant ORIG = address(0x0111);
    address constant OWNR = address(0x0222);
    address constant OUTSIDE_RECEIVER = address(0x0333);
    address constant ALT_RECEIVER = address(0xA17);

    uint32 constant MIN_DELAY = 1 hours;
    uint32 constant DELAY = 2 hours;

    function setUp() public {
        wrbtc = new StipendWRBTC();

        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory noSources = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, noSources
        );
        queue = ExitDelayQueue(payable(address(new ERC1967Proxy(address(impl), init))));

        source = new Source(queue);
        hostile = new Hostile(queue);
        hookToken = new HookToken();

        vm.startPrank(OWNER);
        queue.addAllowedSource(address(source));
        // The payee is also registered as an allowed source, so its own
        // record* re-entry attempts reach the reentrancy guard instead of
        // stopping earlier at the source-allowlist check — the guard is
        // what these tests are pinning, not the allowlist.
        queue.addAllowedSource(address(hostile));
        vm.stopPrank();

        hookToken.mint(address(source), 1_000 ether);
        wrbtc.mint(address(source), 1_000 ether);
        vm.deal(address(wrbtc), 1_000 ether);
        vm.deal(address(source), 1_000 ether);
    }

    /// @dev Every attempt the payee makes while being paid is rejected: five
    ///      by the shared reentrancy guard, one (`payoutExternal`) by its
    ///      self-only check. `expectedStatus` is the paid request's own
    ///      status, read mid-payout, so this also proves the status flip,
    ///      the index removal and the escrow decrement all land before the
    ///      external call that hands the payee control.
    function _assertAllAttemptsBlocked(uint256 expectedStatus) internal view {
        assertEq(hostile.attempts(), 6, "every re-entry attempt ran");
        assertEq(hostile.succeeded(), 0, "no re-entry attempt succeeded");
        assertEq(hostile.guardReverts(), 5, "five attempts were stopped by the shared reentrancy guard");
        assertEq(
            hostile.selfOnlyReverts(), 1, "the payout trampoline refused a caller that is not the queue itself"
        );
        assertEq(hostile.statusSeen(), expectedStatus, "the request was already terminal while the payee ran");
    }

    function test_executeExit_native_reentrant_receiver_paid_once_other_request_untouched() public {
        uint256 a = source.recNative(10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(0), false);

        hostile.callExecute(a);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(hostile.escrowSeen(), 5 ether, "escrow already reduced to just the other request mid-payout");
        assertEq(hostile.balanceSeen(), 5 ether, "no transient native surplus visible mid-payout");
        assertEq(hostile.activeSeen(), 1, "only the other request is still indexed to the payee mid-payout");
        assertEq(address(hostile).balance, 10 ether, "paid exactly once, exactly the request amount");
        assertEq(
            uint256(queue.getRequest(b).status),
            uint256(IExitDelayQueue.ExitStatus.Queued),
            "the other request is untouched"
        );
    }

    function test_executeExits_native_reentrant_receiver_paid_once() public {
        uint256 a = source.recNative(10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(0), false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        hostile.callExecuteMany(ids);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(address(hostile).balance, 10 ether, "paid exactly once, exactly the request amount");
    }

    function test_executeExit_wrbtc_unwrap_reentrant_receiver_paid_once_as_native() public {
        uint256 a = source.recUnwrap(address(wrbtc), 10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recUnwrap(address(wrbtc), 5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(wrbtc), false);

        hostile.callExecute(a);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(hostile.balanceSeen(), 5 ether, "WRBTC backing already reduced mid-payout");
        assertEq(address(queue).balance, 0, "no native left behind by the unwrap");
        assertEq(address(hostile).balance, 10 ether, "paid exactly once, exactly the request amount, as native");
    }

    function test_executeExit_posthook_token_reentrant_receiver_paid_once() public {
        hookToken.setHook(address(hostile), false);
        uint256 a = source.recErc20(address(hookToken), 10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recErc20(address(hookToken), 5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(hookToken), false);

        hostile.callExecute(a);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(hostile.balanceSeen(), 5 ether, "the token balance was already moved mid-payout");
        assertEq(hookToken.balanceOf(address(hostile)), 10 ether, "paid exactly once, exactly the request amount");
    }

    /// @dev A token that calls its recipient BEFORE moving the balance
    ///      exposes, for the length of that call, a surplus equal to the
    ///      payout amount (balance held minus escrow owed). The reentrancy
    ///      guard shared by the measured-receipt record* functions and
    ///      `sweepSurplus` keeps that surplus from being credited as new
    ///      escrow or moved out while the payout is still in flight.
    function test_executeExit_prehook_token_transient_surplus_cannot_be_recorded_or_swept() public {
        hookToken.setHook(address(hostile), true);
        uint256 a = source.recErc20(address(hookToken), 10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recErc20(address(hookToken), 5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(hookToken), false);

        hostile.callExecute(a);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(
            hostile.escrowSeen(), 5 ether, "escrow reflects only the other request, not the transient surplus"
        );
        assertEq(hostile.balanceSeen(), 15 ether, "the pre-move balance is visible as a transient surplus");
        assertEq(
            queue.totalEscrowed(address(hookToken)), 5 ether, "the transient surplus was not recorded as escrow"
        );
        assertEq(
            hookToken.balanceOf(address(queue)),
            5 ether,
            "the transient surplus was not swept out from under the other request"
        );
    }

    function test_recoverStuckExit_healthy_reentrant_receiver_paid_once_alt_unused() public {
        uint256 a = source.recNative(10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(0), false);

        hostile.callRecover(a, ALT_RECEIVER);

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(address(hostile).balance, 10 ether, "the healthy receiver was paid; the alternate went unused");
        assertEq(ALT_RECEIVER.balance, 0, "the alternate address received nothing");
    }

    /// @dev The payee arms itself to bounce (revert) after making its
    ///      re-entry attempts, so none of those attempts' own effects
    ///      survive — the whole reentering call unwinds with the bounce.
    ///      `recoverStuckExit` catches that bounce and falls through to the
    ///      alternate address exactly once.
    function test_recoverStuckExit_bouncing_receiver_pays_alternate_once() public {
        uint256 a = source.recNative(10 ether, DELAY, ORIG, OWNR, address(hostile));
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.warp(block.timestamp + DELAY);
        hostile.arm(a, b, address(0), true);

        vm.prank(ORIG);
        queue.recoverStuckExit(a, ALT_RECEIVER);

        assertEq(address(hostile).balance, 0, "the bouncing receiver kept nothing");
        assertEq(ALT_RECEIVER.balance, 10 ether, "the alternate address was paid exactly once, exactly the amount");
        assertEq(address(queue).balance, 5 ether, "the queue's native balance equals the remaining escrow");
        assertEq(queue.totalEscrowed(address(0)), 5 ether, "escrow reflects only the other request");
    }

    function test_resolveByOwner_reentrant_destination_paid_once() public {
        // Request `a` pays out to an Owner-chosen destination unrelated to
        // its own recorded receiver; request `b` is the one the payee is
        // actually the receiver of, so it is the live target of the
        // re-entry attempts.
        uint256 a = source.recNative(10 ether, DELAY, ORIG, OWNR, OUTSIDE_RECEIVER);
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, address(hostile));
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        hostile.arm(a, b, address(0), false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(OWNER);
        queue.resolveByOwner(ids, address(hostile));

        _assertAllAttemptsBlocked(uint256(IExitDelayQueue.ExitStatus.ResolvedByOwner));
        assertEq(address(hostile).balance, 10 ether, "paid exactly once, exactly the request amount");
    }

    function test_sweepSurplus_reentrant_destination_gets_surplus_once_escrow_untouched() public {
        uint256 b = source.recNative(5 ether, DELAY, ORIG, OWNR, OUTSIDE_RECEIVER);
        vm.deal(address(queue), address(queue).balance + 1 ether);
        hostile.arm(b, b, address(0), false);

        vm.prank(OWNER);
        queue.sweepSurplus(address(0), address(hostile));

        assertEq(hostile.attempts(), 6, "every re-entry attempt ran");
        assertEq(hostile.succeeded(), 0, "no re-entry attempt succeeded");
        assertEq(hostile.guardReverts(), 5, "five attempts were stopped by the shared reentrancy guard");
        assertEq(
            hostile.selfOnlyReverts(), 1, "the payout trampoline refused a caller that is not the queue itself"
        );
        assertEq(address(hostile).balance, 1 ether, "exactly the surplus moved");
        assertEq(address(queue).balance, 5 ether, "the escrowed request's backing is untouched");
    }
}

// ─── Mocks ──────────────────────────────────────────────────────────────

/// @dev WETH9-style WRBTC: `withdraw()` forwards native via the 2300-gas
///      `transfer` stipend, like the real Rootstock WRBTC. The queue's own
///      `receive()` is unconditional and touches no storage, so that
///      stipend never gates the unwrap leg; the payee still receives its
///      payout through `Address.sendValue`, which forwards all remaining
///      gas.
contract StipendWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

interface IPayeeHook {
    function onTokenReceived(uint256 amount) external;
}

/// @dev ERC20 that calls a registered hook address on every transfer TO that
///      address, either before or after its own balance moves. Calling
///      before the move is what exposes a token's transient
///      balance-vs-escrow mismatch; calling after models an ordinary
///      hooked-recipient token.
contract HookToken is ERC20 {
    address public hooked;
    bool public preHook;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address hookedAddr, bool callBeforeMove) external {
        hooked = hookedAddr;
        preHook = callBeforeMove;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        if (preHook && to == hooked) IPayeeHook(hooked).onTokenReceived(value);
        super._transfer(from, to, value);
        if (!preHook && to == hooked) IPayeeHook(hooked).onTokenReceived(value);
    }
}

/// @dev Registered allowed source (mirrors an iToken proxy): pulls the
///      escrowed token, or carries native value, and calls the matching
///      record* entry point.
contract Source {
    ExitDelayQueue public queue;

    bytes32 constant SURFACE = keccak256("PERIMETER:LENDING_LENDER_WITHDRAW");
    address constant SUBPRODUCT = address(0xB00C);

    constructor(ExitDelayQueue q) {
        queue = q;
    }

    function recNative(uint128 amount, uint32 delaySeconds, address effOrig, address effOwner, address receiver)
        external
        returns (uint256)
    {
        return queue.recordNativeExit{value: amount}(
            amount, delaySeconds, SURFACE, SUBPRODUCT, effOrig, effOwner, receiver
        );
    }

    function recErc20(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        ERC20(token).approve(address(queue), amount);
        return queue.recordERC20Exit(
            token, amount, delaySeconds, SURFACE, SUBPRODUCT, effOrig, effOwner, receiver, false
        );
    }

    function recUnwrap(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        ERC20(token).approve(address(queue), amount);
        return queue.recordERC20Exit(
            token, amount, delaySeconds, SURFACE, SUBPRODUCT, effOrig, effOwner, receiver, true
        );
    }

    receive() external payable {}
}

/// @dev Payee that, on every payout it receives (native or the ERC20 hook
///      this file uses), attempts every user-facing and ingress entry
///      point of the queue and records what happened, plus snapshots the
///      queue's own state mid-payout. Used from both sides: as the
///      recorded receiver of a request (the queue calls it), and as a
///      direct caller of `executeExit` / `executeExits` / `recoverStuckExit`
///      (so the re-entry happens from inside its own outer call, exactly
///      as it would for any other payee that is also the caller).
contract Hostile is IPayeeHook {
    ExitDelayQueue public queue;

    uint256 public payoutRequestId; // the request whose payout is under observation
    uint256 public otherId; // a second, still-queued request to attempt against
    address public token; // escrow token of the payout being observed; address(0) = native
    bool public bounce; // revert after the attempts, to drive the recoverStuckExit fall-through

    uint256 public attempts;
    uint256 public guardReverts;
    uint256 public selfOnlyReverts;
    uint256 public succeeded;

    // mid-payout snapshots of the queue's own state
    uint256 public statusSeen;
    uint256 public escrowSeen;
    uint256 public balanceSeen;
    uint256 public activeSeen;

    constructor(ExitDelayQueue q) {
        queue = q;
    }

    function arm(uint256 payoutId, uint256 other, address tok, bool bounce_) external {
        payoutRequestId = payoutId;
        otherId = other;
        token = tok;
        bounce = bounce_;
    }

    function callExecute(uint256 id) external {
        queue.executeExit(id);
    }

    function callExecuteMany(uint256[] calldata ids) external {
        queue.executeExits(ids);
    }

    function callRecover(uint256 id, address altReceiver) external {
        queue.recoverStuckExit(id, altReceiver);
    }

    function _classify(bytes memory err) internal {
        attempts++;
        if (keccak256(err) == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")))
        {
            guardReverts++;
        } else if (bytes4(err) == IExitDelayQueue.SelfOnly.selector) {
            selfOnlyReverts++;
        }
    }

    function _reenter() internal {
        statusSeen = uint256(queue.getRequest(payoutRequestId).status);
        escrowSeen = queue.totalEscrowed(token);
        balanceSeen = token == address(0) ? address(queue).balance : ERC20(token).balanceOf(address(queue));
        (uint256[] memory ids,) = queue.getActive(address(this), 0, 50);
        activeSeen = ids.length;

        uint256[] memory one = new uint256[](1);
        one[0] = otherId;
        try queue.executeExit(otherId) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.executeExits(one) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recoverStuckExit(otherId, address(0xA17)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.payoutExternal(address(0), address(this), 1, false) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recordNativeExit{value: 0}(
            1, 1 days, keccak256("PERIMETER:LENDING_LENDER_WITHDRAW"), address(0xB00C), address(this), address(this), address(this)
        ) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recordReceivedNativeExit(
            1, 1 days, keccak256("PERIMETER:LENDING_LENDER_WITHDRAW"), address(0xB00C), address(this), address(this), address(this)
        ) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }

        if (bounce) revert("bounce");
    }

    receive() external payable {
        if (payoutRequestId != 0) _reenter();
    }

    function onTokenReceived(uint256) external {
        if (payoutRequestId != 0) _reenter();
    }
}
