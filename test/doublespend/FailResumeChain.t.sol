// SPDX-License-Identifier: MIT
// Fork adversarial probe #2 (2026-10-20): the composite
//   "intentional failure to withdraw -> capture the execution -> skip the queue
//    -> resume payment from the queue -> double payment"
// chain against the LIVE ExitDelayQueue proxy on Rootstock chain 30 (anvil fork).
//
// Companion to DoubleSpendProbe.t.sol (same live deployment, same fork recipe).
// Every step asserts: queue balances per asset, totalEscrowed per asset, request
// status, receiver/alt/vault balances. Run with:
//   forge test --match-path test/doublespend/FailResumeChain.t.sol --fork-url http://127.0.0.1:8547 -vv
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {MockQueueHost} from "../phaseG/MockQueueHost.sol";

interface IWRBTC9 {
    function deposit() external payable;
}

interface IQueueMinimal {
    function executeExit(uint256 requestId) external;
    function recoverStuckExit(uint256 id, address altReceiver) external;
    function recordNativeExit(uint128 amount, uint32 delaySeconds, bytes32 surfaceId, address subProduct, address effOrig, address effOwner, address receiver)
        external
        payable
        returns (uint256 id);
}

/// @dev Switchable receiver: Calm (accepts), Bounce (reverts on receipt),
///      Greedy (burns a configurable amount of gas, then accepts). It can also
///      arm re-entry attempts (same-id execute, recover, fresh record) from
///      inside its receive() hook.
contract SwitchReceiver {
    enum Mode {
        Calm,
        Bounce,
        Greedy
    }

    Mode public mode;
    uint256 public burnIterations;
    uint256 public junk; // sink for the burn loop
    IQueueMinimal public queue;
    // re-entry arming
    bool public armed;
    uint256 public selfId;
    uint256 public attempts;
    uint256 public guardReverts;
    uint256 public succeeded;
    bool public mutateModeOnReceipt; // flip to Bounce mid-payout (self-mutation attempt)

    constructor(address queue_) {
        queue = IQueueMinimal(queue_);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setBurn(uint256 iters) external {
        burnIterations = iters;
    }

    function arm(uint256 selfId_, bool mutate) external {
        armed = true;
        selfId = selfId_;
        mutateModeOnReceipt = mutate;
    }

    function disarm() external {
        armed = false;
        mutateModeOnReceipt = false;
    }

    function callExecute(uint256 id) external {
        queue.executeExit(id);
    }

    function callRecover(uint256 id, address alt) external {
        queue.recoverStuckExit(id, alt);
    }

    function _classify(bytes memory err) internal {
        attempts++;
        if (keccak256(err) == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call")))
        {
            guardReverts++;
        }
    }

    function _attack() internal {
        // same-id re-execute (must hit the guard; status already flipped by CEI anyway)
        try queue.executeExit(selfId) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        // recover with an alt (must hit the guard)
        try queue.recoverStuckExit(selfId, address(0xA17)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        // fresh record mid-payout (must hit the guard)
        try queue.recordNativeExit{value: 0}(1, 1 days, keccak256("S"), address(0), address(this), address(this), address(this)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
    }

    receive() external payable {
        if (mode == Mode.Bounce) revert("SwitchReceiver: bounce");
        if (burnIterations > 0) {
            uint256 x = junk;
            for (uint256 i = 0; i < burnIterations; i++) {
                x = x + i;
            }
            junk = x;
        }
        if (mutateModeOnReceipt) mode = Mode.Bounce; // self-mutation attempt
        if (armed) _attack();
    }
}

/// @dev ERC20 that moves the balance and THEN reverts, in the same call - the
///      "transfer succeeded but the status flip must abort" construction. EVM
///      atomicity must roll the balance movement back together with the flip.
contract TransferThenRevertToken is ERC20 {
    bool public trigger;
    address public immutable victimQueue;

    constructor(address queue_) ERC20("TTR", "TTR") {
        victimQueue = queue_;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setTrigger(bool t) external {
        trigger = t;
    }

    function _transfer(address from, address to, uint256 amt) internal override {
        super._transfer(from, to, amt);
        if (trigger && from == victimQueue) revert("TTR: post-transfer abort");
    }
}

/// @dev Plain ERC20 for the UnwrapNonWrbtc fee-mirror variant.
contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Product-host stand-in whose record leg is deliberately broken, to prove
///      the fee leg cannot be kept while the hold fails (atomic rollback of the
///      whole product transaction).
contract FaultyFeeHost {
    IExitDelayQueue public queue;
    address public controller;

    constructor(address queue_, address controller_) {
        queue = IExitDelayQueue(queue_);
        controller = controller_;
    }

    function approveToken(address token, uint256 amt) external {
        IERC20(token).approve(address(queue), amt);
    }

    struct ExitFeeQuote {
        bool active;
        uint16 rateBps;
        uint256 feeAmount;
        uint256 netAmount;
        address feeReceiver;
        uint8 reason;
    }

    function _quote(bytes32 surfaceId, address actor, uint256 gross) internal view returns (ExitFeeQuote memory q) {
        (q.active, q.rateBps, q.feeAmount, q.netAmount, q.feeReceiver, q.reason) = IControllerLike(controller)
            .quoteExitFee(surfaceId, address(0), actor, gross);
    }

    /// @dev fee leg transferred, then the queue record reverts DelayBelowFloor.
    function doFeeThenFailDelay(address token, uint256 gross, bytes32 surfaceId, address orig, address owner_, address rcvr)
        external
        returns (uint256 id)
    {
        ExitFeeQuote memory q = _quote(surfaceId, orig, gross);
        require(q.active && q.feeAmount > 0, "FaultyFeeHost: quote not chargeable");
        IERC20(token).transfer(q.feeReceiver, q.feeAmount); // fee leg FIRST
        id = queue.recordERC20Exit(token, uint128(q.netAmount), 86399, surfaceId, address(0), orig, owner_, rcvr, false); // floor-1 -> reverts
    }

    /// @dev fee leg transferred, then the queue record reverts UnwrapNonWrbtc.
    function doFeeThenFailUnwrap(address token, uint256 gross, bytes32 surfaceId, address orig, address owner_, address rcvr)
        external
        returns (uint256 id)
    {
        ExitFeeQuote memory q = _quote(surfaceId, orig, gross);
        require(q.active && q.feeAmount > 0, "FaultyFeeHost: quote not chargeable");
        IERC20(token).transfer(q.feeReceiver, q.feeAmount);
        id = queue.recordERC20Exit(token, uint128(q.netAmount), 86400, surfaceId, address(0), orig, owner_, rcvr, true); // unwrap on non-WRBTC -> reverts
    }
}

interface IControllerLike {
    function quoteExitFee(bytes32 surfaceId, address subProduct, address actor, uint256 grossAmount)
        external
        view
        returns (bool, uint16, uint256, uint256, address, uint8);
}

/// @title FailResumeChain
/// @notice Composite fail -> capture -> skip -> resume -> double-pay probe.
contract FailResumeChain is Test {
    IExitDelayQueue internal constant queue =
        IExitDelayQueue(0x6A281FCB0838F7a75f93d678000cb0E57ed8Dc45);
    IQueueMinimal internal constant queueM =
        IQueueMinimal(0x6A281FCB0838F7a75f93d678000cb0E57ed8Dc45);
    address internal constant CONTROLLER = 0x99994b4522483DE17F31a5bC010c5901AdD3440E;
    address internal constant VAULT = 0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B;
    IWRBTC9 internal constant wrbtc = IWRBTC9(0x542fDA317318eBF1d3DEAf76E0b632741A7e677d);
    IERC20 internal constant WRBTC_ERC20 = IERC20(0x542fDA317318eBF1d3DEAf76E0b632741A7e677d);
    address internal constant EXCHEQUER = 0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711;
    uint32 internal constant FLOOR = 86400;
    bytes32 internal constant SURFACE_LENDING =
        0xd4896528a9fba849e3d3db442dea05ef8f08c93e00cc760acac34c42a7dacffe;
    bytes32 internal constant SURFACE_ZERO =
        0xfb3234ca0cf70fe9c90b73939f36a37fadcfdef4628afc42dd57d1f26dfd8fb5;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0x000000000000000000000000000000000000cA20);

    MockQueueHost internal host;
    SwitchReceiver internal sw;
    FaultyFeeHost internal faulty;

    function setUp() public {
        console2.log("=== FailResumeChain on fork block:", block.number, "===");
        host = new MockQueueHost(address(queue));
        sw = new SwitchReceiver(address(queue));
        faulty = new FaultyFeeHost(address(queue), CONTROLLER);

        vm.startPrank(EXCHEQUER);
        queue.addAllowedSource(address(host));
        queue.addAllowedSource(address(faulty));
        vm.stopPrank();

        vm.deal(address(this), 100_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(address(host), 1_000 ether);
        vm.deal(address(sw), 1_000 ether);
        wrbtc.deposit{value: 10_000 ether}();
        WRBTC_ERC20.transfer(address(host), 4_000 ether);
        WRBTC_ERC20.transfer(address(faulty), 2_000 ether);
        host.approveToken(address(wrbtc), type(uint256).max);
        faulty.approveToken(address(wrbtc), type(uint256).max);
    }

    // ─── per-step state snapshot + reporting ────────────────────

    struct State {
        uint256 qNative;
        uint256 qWrbtc;
        uint256 escNative;
        uint256 escWrbtc;
        uint256 rcvNative;
        uint256 rcvWrbtc;
        uint256 altNative;
        uint256 vaultWrbtc;
        uint8 status;
        uint256 lastId;
    }

    function _snap(uint256 id, address rcv, address alt) internal view returns (State memory s) {
        s.qNative = address(queue).balance;
        s.qWrbtc = WRBTC_ERC20.balanceOf(address(queue));
        s.escNative = queue.totalEscrowed(address(0));
        s.escWrbtc = queue.totalEscrowed(address(wrbtc));
        s.rcvNative = rcv.balance;
        s.rcvWrbtc = WRBTC_ERC20.balanceOf(rcv);
        s.altNative = alt.balance;
        s.vaultWrbtc = WRBTC_ERC20.balanceOf(VAULT);
        s.status = uint8(queue.getRequest(id).status);
        s.lastId = queue.lastRequestId();
    }

    function _logState(string memory tag, State memory s) internal pure {
        console2.log(tag);
        console2.log("   queue: native", s.qNative, "wrc", s.qWrbtc);
        console2.log("   escrow: native", s.escNative, "wrc", s.escWrbtc);
        console2.log("   status", s.status, "lastId", s.lastId);
        console2.log("   rcv: native", s.rcvNative, "wrc", s.rcvWrbtc);
        console2.log("   alt native", s.altNative, "vault wrc", s.vaultWrbtc);
    }

    function _assertInert(State memory before_, State memory after_, string memory what) internal pure {
        assertEq(after_.qNative, before_.qNative, string.concat(what, ": queue native unchanged"));
        assertEq(after_.qWrbtc, before_.qWrbtc, string.concat(what, ": queue WRBTC unchanged"));
        assertEq(after_.escNative, before_.escNative, string.concat(what, ": escrow native unchanged"));
        assertEq(after_.escWrbtc, before_.escWrbtc, string.concat(what, ": escrow WRBTC unchanged"));
        assertEq(after_.rcvNative, before_.rcvNative, string.concat(what, ": receiver native unchanged"));
        assertEq(after_.rcvWrbtc, before_.rcvWrbtc, string.concat(what, ": receiver WRBTC unchanged"));
        assertEq(after_.vaultWrbtc, before_.vaultWrbtc, string.concat(what, ": vault unchanged (no fee leg)"));
        assertEq(after_.status, before_.status, string.concat(what, ": status unchanged"));
        assertEq(after_.lastId, before_.lastId, string.concat(what, ": no id created"));
    }

    function _report(string memory name, bool ok, bytes memory err) internal {
        if (ok) {
            console2.log("  [STEP]", name, "=> SUCCESS (no revert)");
        } else {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            console2.log("  [STEP]", name, "=> REVERT, selector:");
            console2.logBytes(abi.encodePacked(sel));
            if (err.length <= 200) {
                console2.log("  [STEP] full error:");
                console2.logBytes(err);
            }
        }
    }

    function _execAs(address who, uint256 id) internal returns (bool ok, bytes memory err) {
        vm.startPrank(who);
        try queue.executeExit(id) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _recoverAs(address who, uint256 id, address alt) internal returns (bool ok, bytes memory err) {
        vm.startPrank(who);
        try queue.recoverStuckExit(id, alt) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _recordNative(uint128 amt) internal returns (uint256 id) {
        id = host.doRecordNative{value: amt}(amt, FLOOR, SURFACE_ZERO, address(0), alice, alice, address(sw));
    }

    function _recordUnwrap(uint128 amt) internal returns (uint256 id) {
        id = host.doRecordERC20(address(wrbtc), amt, FLOOR, SURFACE_LENDING, address(0), alice, alice, address(sw), true);
    }

    function _warpUnlocked() internal {
        vm.warp(block.timestamp + FLOOR + 1);
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 1 - record native + WRBTC-unwrap exits for the switch receiver
    // ══════════════════════════════════════════════════════════════════

    function test_C1_record_two_exits_for_switch_receiver() public {
        console2.log("== STEP 1: record native 2 + WRBTC-unwrap 3 for switch receiver ==");
        uint256 idN = _recordNative(2 ether);
        uint256 idW = _recordUnwrap(3 ether);
        State memory s = _snap(idN, address(sw), bob);
        _logState("after record", s);
        assertEq(s.qNative, 2 ether, "queue holds 2 native");
        assertEq(s.escNative, 2 ether, "escrowed native 2");
        assertEq(s.qWrbtc, 3 ether, "queue holds 3 WRBTC");
        assertEq(s.escWrbtc, 3 ether, "escrowed WRBTC 3");
        assertEq(s.status, 1, "native id Queued");
        assertEq(uint8(queue.getRequest(idW).status), 1, "unwrap id Queued");
        assertEq(s.rcvNative, 1_000 ether, "receiver prefunded, nothing paid");
        assertEq(s.rcvWrbtc, 0);
        console2.log("  recorded ids: native", idN, "unwrap", idW);
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 2 - execute with receiver in BOUNCE mode: whole tx must be inert
    // ══════════════════════════════════════════════════════════════════

    function test_C2_bounce_execution_is_atomic_and_value_inert() public {
        console2.log("== STEP 2: bounce-mode execution - atomic revert, nothing moves ==");
        uint256 idN = _recordNative(2 ether);
        uint256 idW = _recordUnwrap(3 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Bounce);

        State memory beforeN = _snap(idN, address(sw), bob);
        (bool okN, bytes memory errN) = _execAs(alice, idN);
        _report("execute native, receiver bouncing", okN, errN);
        assertFalse(okN);
        assertEq(
            keccak256(errN),
            keccak256(
                abi.encodeWithSignature("Error(string)", "Address: unable to send value, recipient may have reverted")
            ),
            "queue's native payout primitive wraps the receiver bounce"
        );
        State memory afterN = _snap(idN, address(sw), bob);
        _logState("after bounced native exec", afterN);
        _assertInert(beforeN, afterN, "bounce(native)");
        assertEq(afterN.status, 1, "still Queued");
        assertEq(uint256(sw.mode()), uint256(SwitchReceiver.Mode.Bounce));

        State memory beforeW = _snap(idW, address(sw), bob);
        (bool okW, bytes memory errW) = _execAs(alice, idW);
        _report("execute WRBTC-unwrap, receiver bouncing", okW, errW);
        assertFalse(okW);
        State memory afterW = _snap(idW, address(sw), bob);
        _logState("after bounced unwrap exec", afterW);
        // crux: the WRBTC.withdraw already happened INSIDE the reverted tx -
        // both the WRBTC balance and the native leg must be rolled back.
        _assertInert(beforeW, afterW, "bounce(unwrap)");
        assertEq(afterW.status, 1, "still Queued");
        assertEq(WRBTC_ERC20.balanceOf(address(sw)), 0, "receiver got no WRBTC either");
        assertEq(address(queue).balance, beforeW.qNative, "queue native restored (unwrap leg rolled back)");
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 3a - re-execute to the SAME bouncing receiver
    // ══════════════════════════════════════════════════════════════════

    function test_C3a_reexecute_bounce_reverts_again() public {
        console2.log("== STEP 3a: re-execute to same bouncing receiver ==");
        uint256 idN = _recordNative(2 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Bounce);
        State memory s0 = _snap(idN, address(sw), bob);
        (bool ok1,) = _execAs(alice, idN);
        (bool ok2, bytes memory err2) = _execAs(alice, idN);
        _report("second execute, receiver still bouncing", ok2, err2);
        assertFalse(ok1 && ok2);
        State memory s1 = _snap(idN, address(sw), bob);
        _assertInert(s0, s1, "re-bounce");
        console2.log("  bounce is repeatable: exit stays Queued, zero value moved twice");
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 3b - flip to calm: pays exactly once, terminal
    // ══════════════════════════════════════════════════════════════════

    function test_C3b_flip_to_calm_pays_exactly_once() public {
        console2.log("== STEP 3b: flip receiver to calm -> pays once ==");
        uint256 idN = _recordNative(2 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Bounce);
        _execAs(alice, idN); // bounce (inert)
        sw.setMode(SwitchReceiver.Mode.Calm);
        State memory s0 = _snap(idN, address(sw), bob);
        (bool ok, bytes memory err) = _execAs(alice, idN);
        _report("execute after flip to calm", ok, err);
        assertTrue(ok);
        State memory s1 = _snap(idN, address(sw), bob);
        _logState("after calm exec", s1);
        assertEq(s1.rcvNative, s0.rcvNative + 2 ether, "paid exactly 2 once");
        assertEq(s1.qNative, 0);
        assertEq(s1.escNative, 0);
        assertEq(s1.status, 2, "Executed");
        (bool ok2, bytes memory err2) = _execAs(alice, idN);
        _report("execute after success", ok2, err2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(address(sw).balance, 1_000 ether + 2 ether, "no double pay");
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 3c - recover on a NEVER-failed queued exit (pre-failure redirect)
    // ══════════════════════════════════════════════════════════════════

    function test_C3c_recover_on_never_failed_queued_exit() public {
        console2.log("== STEP 3c: recoverStuckExit BEFORE any failed execution ==");
        // Honest semantic: recover is verify-by-attempting and NOT failure-gated.
        uint256 id = _recordNative(2 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Calm); // healthy receiver, never executed

        // non-party may NOT call it:
        (bool okBad, bytes memory errBad) = _recoverAs(carol, id, bob);
        _report("recover by non-party carol", okBad, errBad);
        assertFalse(okBad);
        assertEq(bytes4(errBad), IExitDelayQueue.NotExecutor.selector, "guard: party-only");

        // party CAN call it pre-failure; stored receiver is attempted FIRST and paid:
        State memory s0 = _snap(id, address(sw), bob);
        (bool ok, bytes memory err) = _recoverAs(alice, id, bob);
        _report("recover by originator (alt=bob), stored healthy", ok, err);
        assertTrue(ok);
        State memory s1 = _snap(id, address(sw), bob);
        _logState("after pre-failure recover", s1);
        assertEq(s1.rcvNative, s0.rcvNative + 2 ether, "STORED receiver paid");
        assertEq(s1.altNative, s0.altNative, "alt NOT paid");
        assertEq(s1.status, 2, "terminal");
        assertEq(s1.escNative, 0);

        // and with a BOUNCING stored receiver pre-execution, alt is used:
        uint256 id2 = _recordNative(5 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Bounce);
        (bool ok2,) = _recoverAs(alice, id2, bob);
        _report("recover by originator, stored bouncing -> alt", ok2, "");
        assertTrue(ok2);
        assertEq(address(sw).balance, 1_000 ether + 2 ether, "bouncing stored receiver got nothing");
        assertEq(bob.balance, 1_000 ether + 5 ether, "alt paid exactly once");
        assertEq(uint8(queue.getRequest(id2).status), 2);
        console2.log("  NOTE: recover is not failure-gated (verify-by-attempting); still one payment, one transition");
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 3d - make the first transfer "succeed" but abort the flip
    // ══════════════════════════════════════════════════════════════════

    function test_C3d1_transfer_then_revert_token_is_inert() public {
        console2.log("== STEP 3d1: token that transfers then reverts in the same call ==");
        TransferThenRevertToken ttr = new TransferThenRevertToken(address(queue));
        ttr.mint(address(host), 1_000 ether);
        vm.prank(address(host));
        ttr.approve(address(queue), type(uint256).max);
        uint256 id = host.doRecordERC20(address(ttr), 10 ether, FLOOR, SURFACE_LENDING, address(0), alice, alice, address(sw), false);
        _warpUnlocked();
        ttr.setTrigger(true); // payout transfer moves balance, then reverts

        uint256 queueBefore = ttr.balanceOf(address(queue));
        uint256 swBefore = ttr.balanceOf(address(sw));
        State memory s0 = _snap(id, address(sw), bob);
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("execute with post-transfer-abort token", ok, err);
        assertFalse(ok);
        assertEq(keccak256(err), keccak256(abi.encodeWithSignature("Error(string)", "TTR: post-transfer abort")));
        // EVM atomicity: the balance movement inside the token is rolled back too
        assertEq(ttr.balanceOf(address(queue)), queueBefore, "token: queue balance rolled back");
        assertEq(ttr.balanceOf(address(sw)), swBefore, "token: receiver got nothing");
        State memory s1 = _snap(id, address(sw), bob);
        _assertInert(s0, s1, "transfer-then-revert");
        assertEq(s1.status, 1, "no flip persisted");
        console2.log("  transfer + flip are one atomic unit: neither survives");
    }

    function test_C3d2_greedy_gas_exhaustion_is_inert() public {
        console2.log("== STEP 3d2: greedy receiver exhausts gas mid-payout (gas-limited subcall) ==");
        uint256 id = _recordNative(2 ether);
        _warpUnlocked();
        sw.setBurn(type(uint256).max); // effectively unbounded burn loop
        State memory s0 = _snap(id, address(sw), bob);
        vm.prank(alice);
        try queueM.executeExit{gas: 2_000_000}(id) {
            console2.log("  [STEP] gas-limited execute => SUCCESS (unexpected)");
        } catch (bytes memory e) {
            _report("gas-limited execute (2M) vs greedy receiver", false, e);
        }
        State memory s1 = _snap(id, address(sw), bob);
        _logState("after greedy OOG", s1);
        _assertInert(s0, s1, "greedy-OOG");
        assertEq(s1.status, 1, "still Queued after mid-payout exhaustion");
        console2.log("  mid-transfer gas exhaustion reverts the whole tx, flip included");
        sw.setBurn(0);
    }

    function test_C3d3_greedy_success_pays_once_reentry_blocked() public {
        console2.log("== STEP 3d3: greedy-but-successful receiver + re-entry attempts mid-payout ==");
        uint256 id = _recordNative(2 ether);
        _warpUnlocked();
        sw.setBurn(200_000); // burns gas, then accepts
        sw.arm(id, true);
        State memory s0 = _snap(id, address(sw), bob);
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("execute vs greedy+armed receiver", ok, err);
        assertTrue(ok);
        State memory s1 = _snap(id, address(sw), bob);
        _logState("after greedy success", s1);
        assertEq(s1.rcvNative, s0.rcvNative + 2 ether, "paid exactly once despite re-entry attempts");
        assertEq(s1.status, 2, "flip persisted");
        assertEq(sw.attempts(), 3, "3 re-entry attempts ran");
        assertEq(sw.succeeded(), 0, "none succeeded");
        assertEq(sw.guardReverts(), 3, "all stopped by ReentrancyGuard");
        sw.disarm();
    }

    function test_C3d4_receiver_self_mutation_no_double_pay() public {
        console2.log("== STEP 3d4: receiver flips itself to Bounce mid-payout ==");
        uint256 id = _recordNative(2 ether);
        _warpUnlocked();
        sw.arm(id, true); // arm(selfId, mutate=true): flips itself to Bounce mid-payout
        State memory s0 = _snap(id, address(sw), bob);
        (bool ok,) = _execAs(alice, id);
        _report("execute vs self-mutating receiver", ok, "");
        assertTrue(ok);
        assertEq(address(sw).balance, s0.rcvNative + 2 ether, "paid once");
        assertEq(uint8(queue.getRequest(id).status), 2, "flip persisted");
        assertEq(uint256(sw.mode()), uint256(SwitchReceiver.Mode.Bounce), "receiver now bounces");
        (bool ok2, bytes memory err2) = _execAs(alice, id);
        _report("execute again (receiver now bounces)", ok2, err2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector, "terminal regardless of mode");
        assertEq(address(sw).balance, s0.rcvNative + 2 ether, "still exactly one payment");
        sw.disarm();
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 4 - real failure -> legitimate recovery -> every resume attempt
    // ══════════════════════════════════════════════════════════════════

    function test_C4a_fail_then_recover_alt_pays_exactly_one_party() public {
        console2.log("== STEP 4a: fail -> recover(alt) -> conservation + resume attempts ==");
        uint256 id = _recordNative(4 ether);
        _warpUnlocked();

        // 4.1 real failed execution
        sw.setMode(SwitchReceiver.Mode.Bounce);
        State memory s0 = _snap(id, address(sw), bob);
        (bool okF, bytes memory errF) = _execAs(alice, id);
        _report("4.1 execute, receiver bouncing", okF, errF);
        assertFalse(okF);
        _assertInert(s0, _snap(id, address(sw), bob), "4.1");

        // 4.2 legitimate recovery by originator with alt=bob (stored still bouncing)
        (bool okR, bytes memory errR) = _recoverAs(alice, id, bob);
        _report("4.2 recoverStuckExit(id, alt=bob) by originator", okR, errR);
        assertTrue(okR);
        State memory s2 = _snap(id, address(sw), bob);
        _logState("4.2 after recovery", s2);
        assertEq(s2.rcvNative, s0.rcvNative, "recorded receiver paid NOTHING");
        assertEq(s2.altNative, s0.altNative + 4 ether, "alt paid exactly 4 once");
        assertEq(s2.status, 2, "Executed (recovery is a terminal payout)");
        assertEq(s2.escNative, 0, "escrow released exactly once");
        assertEq(s2.qNative, 0);

        // 4.3 resume attempts: re-execute, recover-again, execute as another party
        (bool ok1, bytes memory e1) = _execAs(alice, id);
        _report("4.3a re-execute original id", ok1, e1);
        assertEq(bytes4(e1), IExitDelayQueue.AlreadyTerminal.selector);
        (bool ok2, bytes memory e2) = _recoverAs(alice, id, carol);
        _report("4.3b recover AGAIN with different alt", ok2, e2);
        assertEq(bytes4(e2), IExitDelayQueue.AlreadyTerminal.selector);
        (bool ok3, bytes memory e3) = _execAs(carol, id);
        _report("4.3c execute as a different party", ok3, e3);
        assertEq(bytes4(e3), IExitDelayQueue.AlreadyTerminal.selector);

        _assertInert(s2, _snap(id, address(sw), bob), "4.3");
        // money conservation: total paid from this exit == 4, to exactly one party
        assertEq(bob.balance, 1_000 ether + 4 ether);
        assertEq(address(sw).balance, 1_000 ether, "recorded receiver never paid");
        console2.log("  paid exactly one party exactly once: alt(bob) +4, recorded(sw) +0");
    }

    function test_C4b_resolve_after_recovery_blocked() public {
        console2.log("== STEP 4b: recovery first, then owner/admin resolution legs ==");
        uint256 id = _recordNative(4 ether);
        _warpUnlocked();
        sw.setMode(SwitchReceiver.Mode.Bounce);
        (bool okF,) = _execAs(alice, id);
        assertFalse(okF);
        (bool okR,) = _recoverAs(alice, id, bob);
        assertTrue(okR);
        State memory s2 = _snap(id, address(sw), bob);

        bytes32 routeId = _setupRoute(address(0));
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        (bool ok4, bytes memory e4) = _resolveToProtocolAs(one, routeId);
        _report("resolveToProtocol after recovery", ok4, e4);
        assertEq(bytes4(e4), IExitDelayQueue.AlreadyTerminal.selector);
        (bool ok5, bytes memory e5) = _resolveByOwnerAs(one, carol);
        _report("resolveByOwner after recovery", ok5, e5);
        assertEq(bytes4(e5), IExitDelayQueue.AlreadyTerminal.selector);
        _assertInert(s2, _snap(id, address(sw), bob), "post-resolve-attempts");
        assertEq(bob.balance, 1_000 ether + 4 ether, "no second payment to anyone");
    }

    function test_C4c_owner_resolve_first_then_every_resume_attempt() public {
        console2.log("== STEP 4b: owner-resolve first, then every resume attempt ==");
        uint256 id = _recordNative(6 ether);
        _warpUnlocked();
        vm.startPrank(EXCHEQUER);
        queue.blacklist(alice); // blacklisted party admits Leg-3
        vm.stopPrank();

        uint256[] memory one = new uint256[](1);
        one[0] = id;
        uint256 carolBefore = carol.balance;
        (bool ok1,) = _resolveByOwnerAs(one, carol);
        _report("resolveByOwner (Leg-3) to carol", ok1, "");
        assertTrue(ok1);
        assertEq(carol.balance, carolBefore + 6 ether, "carol paid once");

        (bool ok2, bytes memory e2) = _recoverAs(alice, id, bob);
        _report("recover after owner-resolve", ok2, e2);
        assertEq(bytes4(e2), IExitDelayQueue.AlreadyTerminal.selector);
        (bool ok3, bytes memory e3) = _execAs(alice, id);
        _report("execute after owner-resolve", ok3, e3);
        assertEq(bytes4(e3), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(carol.balance, carolBefore + 6 ether, "no second payment to anyone");
        assertEq(bob.balance, 1_000 ether);
        assertEq(address(queue).balance, 0);
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 5 - ingress mirror: fee leg kept while the hold fails?
    // ══════════════════════════════════════════════════════════════════

    function test_C5_fee_then_failed_record_is_atomic() public {
        console2.log("== STEP 5: product host pulls FEE then record FAILS ==");
        // plain ERC20 for the UnwrapNonWrbtc variant (unwrap flag valid only on WRBTC)
        PlainToken ptoken = new PlainToken();
        ptoken.mint(address(faulty), 1_000 ether);
        vm.prank(address(faulty));
        ptoken.approve(address(queue), type(uint256).max);

        uint256 vaultWBefore = WRBTC_ERC20.balanceOf(VAULT);
        uint256 vaultPBefore = ptoken.balanceOf(VAULT);
        uint256 faultyWBefore = WRBTC_ERC20.balanceOf(address(faulty));
        uint256 idBefore = queue.lastRequestId();

        (bool ok1, bytes memory err1) = _tryFeeThenFailDelay();
        _report("doFeeThenFailDelay (fee first, record floor-1)", ok1, err1);
        assertFalse(ok1);
        assertEq(bytes4(err1), IExitDelayQueue.DelayBelowFloor.selector, "record leg reverts");

        (bool ok2, bytes memory err2) = _tryFeeThenFailUnwrap(address(ptoken));
        _report("doFeeThenFailUnwrap (fee first, record UnwrapNonWrbtc)", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.UnwrapNonWrbtc.selector);

        assertEq(WRBTC_ERC20.balanceOf(VAULT), vaultWBefore, "vault kept NOTHING (WRBTC) - fee leg rolled back");
        assertEq(ptoken.balanceOf(VAULT), vaultPBefore, "vault kept NOTHING (plain token)");
        assertEq(WRBTC_ERC20.balanceOf(address(faulty)), faultyWBefore, "host principal intact");
        assertEq(WRBTC_ERC20.balanceOf(address(queue)), 0, "queue empty");
        assertEq(queue.lastRequestId(), idBefore, "nothing queued");
        console2.log("  fee leg + hold leg are one atomic product tx: no fee-without-hold");
    }

    function _tryFeeThenFailDelay() internal returns (bool, bytes memory) {
        vm.startPrank(alice);
        try faulty.doFeeThenFailDelay(address(wrbtc), 800 ether, SURFACE_LENDING, alice, alice, bob) returns (uint256) {
            vm.stopPrank();
            return (true, "");
        } catch (bytes memory e) {
            vm.stopPrank();
            return (false, e);
        }
    }

    function _tryFeeThenFailUnwrap(address ptoken) internal returns (bool, bytes memory) {
        vm.startPrank(alice);
        try faulty.doFeeThenFailUnwrap(ptoken, 500 ether, SURFACE_LENDING, alice, alice, bob) returns (uint256) {
            vm.stopPrank();
            return (true, "");
        } catch (bytes memory e) {
            vm.stopPrank();
            return (false, e);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // STEP 6 - skip-queue variants: same-block, self-executing receiver
    // ══════════════════════════════════════════════════════════════════

    function test_C6a_execute_same_block_as_record_reverts() public {
        console2.log("== STEP 6a: execute in the same block as record (before unlock) ==");
        uint256 id = _recordNative(2 ether); // no warp
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("same-block execute", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.NotUnlocked.selector);
        assertEq(uint8(queue.getRequest(id).status), 1);
        assertEq(address(queue).balance, 2 ether, "nothing moved");
    }

    function test_C6b_self_executing_receiver_cannot_reclaim() public {
        console2.log("== STEP 6b: executor==receiver==contract re-records during payout ==");
        // exit owned+received by sw itself; it executes itself; during payout it
        // tries to record a FRESH exit (old id still live?) - all from receive().
        uint256 id = host.doRecordNative{value: 3 ether}(3 ether, FLOOR, SURFACE_ZERO, address(0), address(sw), address(sw), address(sw));
        _warpUnlocked();
        uint256 idBefore = queue.lastRequestId();
        sw.arm(id, false); // armed: receive() will attempt execute/recover/record
        uint256 swBefore = address(sw).balance;
        State memory s0 = _snap(id, address(sw), bob);
        sw.callExecute(id); // receiver executes its own exit
        State memory s1 = _snap(id, address(sw), bob);
        _logState("after self-execute", s1);
        assertEq(s1.rcvNative, swBefore + 3 ether, "paid exactly once to itself");
        assertEq(s1.status, 2, "terminal flip paired with the payment");
        assertEq(s1.lastId, idBefore, "NO fresh id recorded mid-payout (guard)");
        assertEq(sw.succeeded(), 0, "mid-payout re-record blocked");
        // after the fact, a brand-new exit requires NEW value in:
        uint256 id2 = host.doRecordNative{value: 1 ether}(1 ether, FLOOR, SURFACE_ZERO, address(0), address(sw), address(sw), address(sw));
        assertEq(queue.lastRequestId(), idBefore + 1, "new id only via a new funded record");
        assertEq(uint8(queue.getRequest(id2).status), 1);
        assertEq(address(queue).balance, 1 ether);
        console2.log("  no payment-without-terminal-transition path exists");
        sw.disarm();
    }

    // ══════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════

    function _setupRoute(address tok) internal returns (bytes32 routeId) {
        vm.startPrank(EXCHEQUER);
        routeId = queue.setRecoveryRoute(
            IExitDelayQueue.RecoveryRoute({
                active: true,
                surfaceId: SURFACE_LENDING,
                subProduct: address(0),
                token: tok,
                destination: VAULT,
                topUpPool: false
            })
        );
        vm.stopPrank();
    }

    function _resolveToProtocolAs(uint256[] memory ids, bytes32 routeId) internal returns (bool, bytes memory) {
        vm.startPrank(EXCHEQUER);
        try queue.resolveToProtocol(ids, routeId) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
        vm.stopPrank();
    }

    function _resolveByOwnerAs(uint256[] memory ids, address dest) internal returns (bool, bytes memory) {
        vm.startPrank(EXCHEQUER);
        try queue.resolveByOwner(ids, dest) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
        vm.stopPrank();
    }
}
