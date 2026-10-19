// SPDX-License-Identifier: MIT
// Fork adversarial probe (2026-10-20): double-spend / value-reuse attacks against
// the LIVE ExitDelayQueue proxy on Rootstock chain 30, executed on a local anvil fork.
//
//      fork:      anvil --fork-url https://mainnet-dev.sovryn.app/rpc --chain-id 30
//      queue:     0x6A281FCB0838F7a75f93d678000cb0E57ed8Dc45 (impl 0xB19C086fD3dbe31e3cEA089A535F5cA808A3c50a)
//      owner:     Exchequer 0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711 (impersonated via vm.startPrank)
//      floor:     86400 s, no hosts wired at probe time
//
// Every attack test PRINTS the attempt and the exact revert (or success) so the
// raw `forge test -vv` log is the evidence. Run with:
//   forge test --fork-url http://127.0.0.1:8547 --match-path test/doublespend/DoubleSpendProbe.t.sol -vv
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {MockQueueHost} from "../phaseG/MockQueueHost.sol";

interface IWRBTC9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IReceiver {
    function onTokenReceived(uint256 amount) external;
}

/// @dev The queue's SelfOnly payout trampoline - deliberately NOT part of
///      IExitDelayQueue's ABI surface, so declare it locally for the probe.
interface IPayoutTrampoline {
    function payoutExternal(address token, address to, uint128 amount, bool unwrap) external;
}

/// @dev Minimal contract used as a contract "owner" party (has code => the
///      executor set widens to anyone for that request).
contract ContractWallet {}

/// @dev Plain ERC20 stand-in for an arbitrary escrow token.
contract ProbeToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev ERC20 that calls a recipient hook on transfer (both on `to` during any
///      transfer and on `from` during transferFrom) - the ERC20-side reentrancy
///      carrier for attack 2, on payout AND on the ingress pull.
contract HookERC20 is ERC20 {
    constructor() ERC20("HookToken", "HOOK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _hook(address who) internal {
        if (who.code.length > 0) {
            // Low-level, failure-tolerant delivery: a contract without the hook
            // (e.g. the queue itself, an EOA-like host) must not brick the transfer.
            who.call(abi.encodeWithSelector(IReceiver.onTokenReceived.selector, 0));
        }
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        _hook(to);
        return super.transfer(to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        _hook(from);
        _hook(to);
        return super.transferFrom(from, to, amt);
    }
}

/// @dev Simple 10%-fee-on-transfer token (charges on every transfer) - the
///      ingress mis-escrow probe: recordERC20Exit must measure and refuse.
contract FOTToken is ERC20 {
    constructor() ERC20("FOT", "FOT") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _transfer(address from, address to, uint256 amt) internal override {
        uint256 fee = amt / 10;
        super._transfer(from, address(0xdead), fee);
        super._transfer(from, to, amt - fee);
    }
}

/// @dev A token that is completely standard at ingress (transferFrom costs no fee)
///      but charges an EXTRA 100% on any transfer OUT of the queue (`from == queue`),
///      i.e. value leaves double-fast on payout. Probes the post-payout solvency
///      check: one payout must not be able to strand later queued requests.
contract SneakyFOT is ERC20 {
    address public immutable queue;

    constructor(address queue_) ERC20("SneakyFOT", "SNF") {
        queue = queue_;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _transfer(address from, address to, uint256 amt) internal override {
        if (from == queue) {
            super._transfer(from, to, amt);
            super._transfer(from, address(0xdead), amt); // fee charged ON TOP
        } else {
            super._transfer(from, to, amt);
        }
    }
}

/// @dev The double-spend attacker: a contract that receives payouts and, inside its
///      receive()/onTokenReceived() hooks, tries every value-moving re-entry -
///      same-id re-execute, next-id execute, recoverStuckExit, both native record*
///      paths, the owner-only sweep, and the payout trampoline directly.
contract MaliciousReceiver is IReceiver {
    IExitDelayQueue public queue;
    uint256 public sameId;
    uint256 public nextId;
    bytes32 public surf;
    bool public armed;

    uint256 public attempts;
    uint256 public guardReverts;
    uint256 public selfOnlyReverts;
    uint256 public succeeded;

    uint256 public statusSeen;
    uint256 public escrowSeen;
    uint256 public nativeSeen;

    constructor(IExitDelayQueue q) {
        queue = q;
    }

    function arm(uint256 sameId_, uint256 nextId_, bytes32 surf_) external {
        sameId = sameId_;
        nextId = nextId_;
        surf = surf_;
        armed = true;
    }

    function callExecute(uint256 id) external {
        queue.executeExit(id);
    }

    function callRecordERC20(address token, uint128 amt, uint32 delay, bytes32 surf_, address sub, address o, address ow, address r, bool unwrap)
        external
    {
        queue.recordERC20Exit(token, amt, delay, surf_, sub, o, ow, r, unwrap);
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
        statusSeen = uint256(queue.getRequest(sameId).status);
        escrowSeen = queue.totalEscrowed(address(0));
        nativeSeen = address(queue).balance;

        try queue.executeExit(sameId) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        uint256[] memory one = new uint256[](1);
        one[0] = nextId;
        try queue.executeExits(one) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recoverStuckExit(sameId, address(0xA17)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recordNativeExit{value: 0}(1, 1 days, surf, address(0), address(this), address(this), address(this))
        {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.recordReceivedNativeExit(1, 1 days, surf, address(0), address(this), address(this), address(this)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try queue.sweepSurplus(address(0), address(this)) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
        try IPayoutTrampoline(address(queue)).payoutExternal(address(0), address(this), 1, false) {
            succeeded++;
        } catch (bytes memory e) {
            _classify(e);
        }
    }

    receive() external payable {
        if (armed) _reenter();
    }

    function onTokenReceived(uint256) external {
        if (armed) _reenter();
    }
}

contract DoubleSpendProbe is Test {
    // ─── Live chain-30 deployment ─────────────────────────────
    IExitDelayQueue internal constant queue =
        IExitDelayQueue(0x6A281FCB0838F7a75f93d678000cb0E57ed8Dc45);
    address internal constant CONTROLLER = 0x99994b4522483DE17F31a5bC010c5901AdD3440E;
    address internal constant VAULT = 0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B;
    IWRBTC9 internal constant wrbtc = IWRBTC9(0x542fDA317318eBF1d3DEAf76E0b632741A7e677d);
    IERC20 internal constant WRBTC_ERC20 = IERC20(0x542fDA317318eBF1d3DEAf76E0b632741A7e677d);
    address internal constant EXCHEQUER = 0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711;
    uint32 internal constant FLOOR = 86400;

    // PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW - live, active, 10 bps (fee ON)
    bytes32 internal constant SURFACE_LENDING =
        0xd4896528a9fba849e3d3db442dea05ef8f08c93e00cc760acac34c42a7dacffe;
    // PERIMETER_SURFACE_ZERO_WITHDRAW_COLL - live, active, 10 bps
    bytes32 internal constant SURFACE_ZERO =
        0xfb3234ca0cf70fe9c90b73939f36a37fadcfdef4628afc42dd57d1f26dfd8fb5;

    // ─── Actors ───────────────────────────────────────────────
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0x000000000000000000000000000000000000cA20);

    // ─── Fixtures ─────────────────────────────────────────────
    MockQueueHost internal host; // trusted product-host stand-in (allowed source)
    MaliciousReceiver internal hostile; // attacker receiver / attacker source
    ProbeToken internal token; // plain ERC20
    HookERC20 internal hookToken; // callback ERC20
    SneakyFOT internal sneaky; // standard-in, fee-on-outbound ERC20

    function setUp() public {
        console2.log("=== DoubleSpendProbe on fork block:", block.number, "===");
        host = new MockQueueHost(address(queue));
        hostile = new MaliciousReceiver(queue);
        token = new ProbeToken("ProbeUSD", "pUSD");
        hookToken = new HookERC20();
        sneaky = new SneakyFOT(address(queue));

        // Owner (Exchequer) wires the two stand-in sources on the fork only.
        vm.startPrank(EXCHEQUER);
        queue.addAllowedSource(address(host));
        queue.addAllowedSource(address(hostile)); // so hostile re-entries reach the guard, not the allowlist
        vm.stopPrank();

        // Fund the fixture actors.
        vm.deal(address(this), 100_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(address(host), 1_000 ether);
        token.mint(address(this), 1_000_000 ether);
        token.mint(address(host), 1_000_000 ether);
        hookToken.mint(address(host), 1_000_000 ether);
        sneaky.mint(address(host), 1_000_000 ether);

        // Wrap RBTC into WRBTC for the test + host.
        wrbtc.deposit{value: 10_000 ether}();
        WRBTC_ERC20.transfer(address(host), 5_000 ether);
        host.approveToken(address(wrbtc), type(uint256).max);
        host.approveToken(address(token), type(uint256).max);
        host.approveToken(address(hookToken), type(uint256).max);
        host.approveToken(address(sneaky), type(uint256).max);
    }

    // ─── Attempt harness: show the attempt and the exact revert ──

    function _report(string memory name, bool ok, bytes memory err) internal {
        if (ok) {
            console2.log("  [ATTEMPT]", name, "=> SUCCESS (no revert)");
        } else {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            console2.log("  [ATTEMPT]", name, "=> REVERT, selector:");
            console2.logBytes(abi.encodePacked(sel));
            if (err.length <= 200) {
                console2.log("  [ATTEMPT] full error:");
                console2.logBytes(err);
            }
        }
    }

    function _tryExecute(uint256 id) internal returns (bool ok, bytes memory err) {
        try queue.executeExit(id) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _execAs(address who, uint256 id) internal returns (bool ok, bytes memory err) {
        vm.startPrank(who);
        (ok, err) = _tryExecute(id);
        vm.stopPrank();
    }

    function _tryExecuteMany(uint256[] memory ids) internal returns (bool ok, bytes memory err) {
        try queue.executeExits(ids) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _execManyAs(address who, uint256[] memory ids) internal returns (bool ok, bytes memory err) {
        vm.startPrank(who);
        (ok, err) = _tryExecuteMany(ids);
        vm.stopPrank();
    }

    function _tryRecover(uint256 id, address alt) internal returns (bool ok, bytes memory err) {
        try queue.recoverStuckExit(id, alt) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _recoverAs(address who, uint256 id, address alt) internal returns (bool ok, bytes memory err) {
        vm.startPrank(who);
        (ok, err) = _tryRecover(id, alt);
        vm.stopPrank();
    }

    function _tryRecordReceivedERC20ViaHost(address tok, uint128 amt, address orig, address owner_, address rcvr)
        internal
        returns (bool ok, bytes memory err)
    {
        try host.doRecordReceivedERC20(tok, amt, FLOOR, SURFACE_LENDING, address(0), orig, owner_, rcvr) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _tryResolveByOwner(uint256[] memory ids, address dest) internal returns (bool ok, bytes memory err) {
        vm.startPrank(EXCHEQUER);
        try queue.resolveByOwner(ids, dest) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _tryResolveToProtocol(uint256[] memory ids, bytes32 routeId)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.startPrank(EXCHEQUER);
        try queue.resolveToProtocol(ids, routeId) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _trySweep(address tok, address to) internal returns (bool ok, bytes memory err) {
        vm.startPrank(EXCHEQUER);
        try queue.sweepSurplus(tok, to) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _recordNativeViaHost(uint128 amt, address orig, address owner_, address rcvr)
        internal
        returns (uint256 id)
    {
        id = host.doRecordNative{value: amt}(amt, FLOOR, SURFACE_ZERO, address(0), orig, owner_, rcvr);
    }

    function _recordERC20ViaHost(address tok, uint128 amt, address orig, address owner_, address rcvr, bool unwrap)
        internal
        returns (uint256 id)
    {
        id = host.doRecordERC20(tok, amt, FLOOR, SURFACE_LENDING, address(0), orig, owner_, rcvr, unwrap);
    }

    function _status(uint256 id) internal view returns (IExitDelayQueue.ExitStatus) {
        return queue.getRequest(id).status;
    }

    // ══════════════════════════════════════════════════════════════════
    // POSITIVE CONTROL - the probe must prove it CAN move funds legitimately
    // ══════════════════════════════════════════════════════════════════

    function test_PC1_native_record_warp_execute_pays_exactly_once() public {
        console2.log("== POSITIVE CONTROL 1: native record -> warp -> execute ==");
        uint256 bobBefore = bob.balance;
        uint128 amt = 7 ether;

        uint256 id = _recordNativeViaHost(amt, alice, alice, bob);
        assertEq(uint256(_status(id)), 1, "Queued");
        assertEq(queue.totalEscrowed(address(0)), amt);

        vm.warp(block.timestamp + FLOOR); // exactly unlockAt
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("executeExit(native) at t == unlockAt, by originator", ok, err);
        assertTrue(ok, "positive control must pay");

        assertEq(bob.balance, bobBefore + amt, "receiver paid exactly once, exact amount");
        assertEq(address(queue).balance, 0, "queue drained");
        assertEq(queue.totalEscrowed(address(0)), 0, "escrow decremented");
        assertEq(uint256(_status(id)), 2, "Executed");
    }

    function test_PC2_fee_then_hold_WRBTC_10bps_pays_fee_once_net_once() public {
        console2.log("== POSITIVE CONTROL 2: live controller fee-then-hold (10 bps) ==");
        uint256 gross = 1_000 ether;
        uint256 vaultBefore = WRBTC_ERC20.balanceOf(VAULT);

        (uint256 id, uint256 fee) = host.doFeeThenHoldERC20(
            CONTROLLER, VAULT, address(wrbtc), gross, FLOOR, SURFACE_LENDING, address(0), alice, alice, bob
        );
        console2.log("  fee taken:", fee, "net queued:", gross - fee);
        assertEq(fee, gross * 10 / 10_000, "live quote = 10 bps");

        assertEq(WRBTC_ERC20.balanceOf(VAULT), vaultBefore + fee, "vault fee exactly once");
        assertEq(WRBTC_ERC20.balanceOf(address(queue)), gross - fee, "queue holds net");
        assertEq(queue.totalEscrowed(address(wrbtc)), gross - fee);

        vm.warp(block.timestamp + FLOOR + 1);
        uint256 bobBefore = WRBTC_ERC20.balanceOf(bob);
        (bool ok, bytes memory err) = _execAs(bob, id);
        _report("executeExit(fee-then-hold WRBTC), by receiver", ok, err);
        assertTrue(ok);

        assertEq(WRBTC_ERC20.balanceOf(bob), bobBefore + gross - fee, "receiver gets net exactly once");
        assertEq(WRBTC_ERC20.balanceOf(VAULT), vaultBefore + fee, "vault unchanged on execute");
        assertEq(WRBTC_ERC20.balanceOf(address(queue)), 0);
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 1 - replay / double-execute
    // ══════════════════════════════════════════════════════════════════

    function test_A1a_same_id_twice_same_block() public {
        console2.log("== ATTACK 1a: execute same id twice, same block ==");
        uint256 id = _recordERC20ViaHost(address(token), 100 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);

        uint256 bobBefore = token.balanceOf(bob);
        (bool ok1,) = _execAs(alice, id);
        _report("execute #1 (same block)", ok1, "");
        (bool ok2, bytes memory err2) = _execAs(alice, id);
        _report("execute #2 (same block)", ok2, err2);

        assertTrue(ok1);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector, "guard: AlreadyTerminal");
        assertEq(token.balanceOf(bob), bobBefore + 100 ether, "paid exactly once");
        assertEq(uint256(_status(id)), 2);
    }

    function test_A1b_same_id_again_after_warp() public {
        console2.log("== ATTACK 1b: execute same id again after warp ==");
        uint256 id = _recordERC20ViaHost(address(token), 50 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok1,) = _execAs(alice, id);
        vm.warp(block.timestamp + 30 days);
        (bool ok2, bytes memory err2) = _execAs(alice, id);
        _report("execute again after +30 days", ok2, err2);
        assertTrue(ok1 && !ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector, "terminal is permanent");
    }

    function test_A1c_two_parties_racing_same_id() public {
        console2.log("== ATTACK 1c: originator then receiver race the same id ==");
        uint256 id = _recordNativeViaHost(3 ether, alice, alice, bob);
        vm.warp(block.timestamp + FLOOR + 1);

        (bool ok1,) = _execAs(alice, id); // originator delivers
        _report("originator executes", ok1, "");
        (bool ok2, bytes memory err2) = _execAs(bob, id); // receiver races after
        _report("receiver executes after originator", ok2, err2);
        assertTrue(ok1 && !ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(bob.balance, 1_000 ether + 3 ether, "bob paid exactly once");
    }

    function test_A1d_batch_with_duplicated_id() public {
        console2.log("== ATTACK 1d: executeExits([id, id]) duplicated id in batch ==");
        uint256 id = _recordERC20ViaHost(address(token), 25 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);

        uint256 bobBefore = token.balanceOf(bob);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        (bool ok, bytes memory err) = _execManyAs(alice, ids);
        _report("batch [id, id]", ok, err);

        assertFalse(ok, "whole batch must revert atomically");
        assertEq(bytes4(err), IExitDelayQueue.AlreadyTerminal.selector, "guard: AlreadyTerminal on 2nd pass");
        assertEq(token.balanceOf(bob), bobBefore, "nothing paid");
        assertEq(uint256(_status(id)), 1, "still Queued");
    }

    function test_A1e_batch_two_distinct_ids_pays_both() public {
        console2.log("== ATTACK 1e (control): batch of two distinct ids ==");
        uint256 a = _recordERC20ViaHost(address(token), 10 ether, alice, alice, bob, false);
        uint256 b = _recordERC20ViaHost(address(token), 20 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        uint256 bobBefore = token.balanceOf(bob);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        (bool ok, bytes memory err) = _execManyAs(alice, ids);
        _report("batch [a, b]", ok, err);
        assertTrue(ok);
        assertEq(token.balanceOf(bob), bobBefore + 30 ether, "both paid once each");
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 2 - reentrancy on payout
    // ══════════════════════════════════════════════════════════════════

    function _assertHostileBlocked(uint256 expectedStatus, uint256 expectedNativeBal, uint256 expectedEscrowSeen)
        internal
    {
        assertEq(hostile.attempts(), 7, "every re-entry attempt ran");
        assertEq(hostile.succeeded(), 0, "no re-entry succeeded");
        assertEq(hostile.guardReverts(), 6, "6 attempts stopped by ReentrancyGuard");
        assertEq(hostile.selfOnlyReverts(), 1, "payoutExternal trampoline refused non-self caller");
        assertEq(hostile.statusSeen(), expectedStatus, "status already terminal mid-payout (CEI)");
        assertEq(hostile.escrowSeen(), expectedEscrowSeen, "escrow already decremented mid-payout (CEI)");
        assertEq(address(hostile).balance, expectedNativeBal, "payout arrived exactly once");
    }

    function test_A2a_native_payout_reentrancy() public {
        console2.log("== ATTACK 2a: malicious receiver re-enters during native payout ==");
        uint256 a = _recordNativeViaHost(10 ether, alice, alice, address(hostile));
        uint256 b = _recordNativeViaHost(5 ether, alice, alice, address(hostile));
        vm.warp(block.timestamp + FLOOR + 1);
        hostile.arm(a, b, SURFACE_ZERO);

        (bool ok, bytes memory err) = _execAs(alice, a);
        _report("executeExit(native) against hostile receiver", ok, err);
        assertTrue(ok, "outer payout must succeed (attacks caught)");
        _assertHostileBlocked(2, 10 ether, 5 ether);
        assertEq(queue.totalEscrowed(address(0)), 5 ether, "other request untouched");
        assertEq(uint256(_status(b)), 1);
    }

    function test_A2b_erc20_hook_reentrancy_on_payout() public {
        console2.log("== ATTACK 2b: re-enters via ERC20 transfer hook on payout ==");
        uint256 a = _recordERC20ViaHost(address(hookToken), 40 ether, alice, alice, address(hostile), false);
        uint256 b = _recordERC20ViaHost(address(hookToken), 8 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        hostile.arm(a, b, SURFACE_LENDING);

        (bool ok, bytes memory err) = _execAs(alice, a);
        _report("executeExit(hookERC20) against hostile receiver", ok, err);
        assertTrue(ok);
        _assertHostileBlocked(2, 0, 0);
        assertEq(hookToken.balanceOf(address(hostile)), 40 ether, "ERC20 paid exactly once");
        assertEq(uint256(_status(b)), 1, "other request untouched");
    }

    function test_A2c_wrbtc_unwrap_leg_reentrancy() public {
        console2.log("== ATTACK 2c: re-enters via WRBTC unwrap payout leg ==");
        uint256 a = _recordERC20ViaHost(address(wrbtc), 12 ether, alice, alice, address(hostile), true);
        uint256 b = _recordERC20ViaHost(address(wrbtc), 6 ether, alice, alice, bob, true);
        vm.warp(block.timestamp + FLOOR + 1);
        hostile.arm(a, b, SURFACE_LENDING);

        uint256 hostileWrbtcBefore = WRBTC_ERC20.balanceOf(address(hostile));
        (bool ok, bytes memory err) = _execAs(alice, a);
        _report("executeExit(unwrapOnDelivery) hostile receiver", ok, err);
        assertTrue(ok);
        _assertHostileBlocked(2, 12 ether, 0);
        assertEq(WRBTC_ERC20.balanceOf(address(hostile)), hostileWrbtcBefore, "no WRBTC leg paid");
        assertEq(queue.totalEscrowed(address(wrbtc)), 6 ether, "other request untouched");
        assertEq(address(queue).balance, 0, "no native left in queue");
    }

    function test_A2d_ingress_reentrancy_during_record_pull() public {
        console2.log("== ATTACK 2d: hostile source re-enters during recordERC20Exit pull ==");
        // hostile is the allowed SOURCE. HookERC20.transferFrom fires its holder
        // hook BEFORE the transfer, so hostile.onTokenReceived runs mid-ingress
        // (before _record writes any state). Every re-entry must still die on the
        // reentrancy guard, and the outer record must complete exactly once.
        hookToken.mint(address(hostile), 1_000 ether);
        vm.prank(address(hostile));
        hookToken.approve(address(queue), type(uint256).max);
        hostile.arm(0, 0, SURFACE_LENDING);

        uint256 before = queue.lastRequestId();
        vm.prank(address(hostile));
        try hostile.callRecordERC20(address(hookToken), 50 ether, FLOOR, SURFACE_LENDING, address(0), alice, alice, bob, false)
        {
            console2.log("  [ATTEMPT] hostile-sourced recordERC20(hookToken) => SUCCESS (attacks caught)");
        } catch (bytes memory e) {
            _report("hostile-sourced recordERC20(hookToken)", false, e);
        }
        assertEq(hostile.attempts(), 7, "re-entry attempts ran mid-ingress");
        assertEq(hostile.succeeded(), 0, "no re-entry succeeded");
        assertEq(hostile.guardReverts(), 6, "guard held even before any ingress state write");
        assertEq(hostile.selfOnlyReverts(), 1);
        assertEq(queue.lastRequestId(), before + 1, "outer record completed exactly once");
        assertEq(hookToken.balanceOf(address(queue)), 50 ether, "exactly the pulled amount held");
        assertEq(queue.totalEscrowed(address(hookToken)), 50 ether, "no mis-escrow from re-entry");
    }

    function test_A2e_unwrap_stipend_queue_receive_gas() public {
        console2.log("== ATTACK 2e: WRBTC 2300-stipend vs queue receive() during withdraw ==");
        // The queue's receive() is EMPTY on purpose: WRBTC.withdraw pays the queue
        // via a 2300-gas transfer. A receive() doing any storage work would OOG
        // and brick every unwrap payout; an empty one is stipend-safe.
        uint256 a = _recordERC20ViaHost(address(wrbtc), 2 ether, alice, alice, bob, true);
        vm.warp(block.timestamp + FLOOR + 1);
        uint256 bobBefore = bob.balance;
        (bool ok, bytes memory err) = _execAs(alice, a);
        _report("unwrap payout (queue receive() under 2300 stipend)", ok, err);
        assertTrue(ok, "stipend-compatible receive() must not brick unwrap");
        assertEq(bob.balance, bobBefore + 2 ether);
        // Receiver-side re-entry on this leg is blocked by the guard, not by gas:
        // demonstrated in A2c (succeeded == 0 on the same leg).
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 3 - credit without debit
    // ══════════════════════════════════════════════════════════════════

    function test_A3a_non_source_cannot_record_any_path() public {
        console2.log("== ATTACK 3a: unregistered caller tries every record path directly ==");
        vm.startPrank(carol);
        (bool ok1, bytes memory e1) = _tryRecordERC20Direct();
        _report("recordERC20 (pull) from non-source", ok1, e1);
        (bool ok2, bytes memory e2) = _tryRecordNativeDirect();
        _report("recordNative from non-source", ok2, e2);
        (bool ok3, bytes memory e3) = _tryRecordReceivedERC20Direct();
        _report("recordReceivedERC20 from non-source", ok3, e3);
        (bool ok4, bytes memory e4) = _tryRecordReceivedNativeDirect();
        _report("recordReceivedNative from non-source", ok4, e4);
        vm.stopPrank();
        assertFalse(ok1 && ok2 && ok3 && ok4, "all four blocked");
        assertEq(bytes4(e1), IExitDelayQueue.UnregisteredSource.selector, "guard: onlyAllowedSource");
        assertEq(bytes4(e2), IExitDelayQueue.UnregisteredSource.selector);
        assertEq(bytes4(e3), IExitDelayQueue.UnregisteredSource.selector);
        assertEq(bytes4(e4), IExitDelayQueue.UnregisteredSource.selector);
        assertEq(queue.lastRequestId(), 0, "no request fabricated");
    }

    function _tryRecordERC20Direct() internal returns (bool, bytes memory) {
        try queue.recordERC20Exit(address(token), 1 ether, FLOOR, SURFACE_LENDING, address(0), carol, carol, carol, false)
        {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _tryRecordNativeDirect() internal returns (bool, bytes memory) {
        try queue.recordNativeExit{value: 1 ether}(1 ether, FLOOR, SURFACE_ZERO, address(0), carol, carol, carol) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _tryRecordReceivedERC20Direct() internal returns (bool, bytes memory) {
        try queue.recordReceivedERC20Exit(address(token), 1 ether, FLOOR, SURFACE_LENDING, address(0), carol, carol, carol)
        {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _tryRecordReceivedNativeDirect() internal returns (bool, bytes memory) {
        try queue.recordReceivedNativeExit(1 ether, FLOOR, SURFACE_ZERO, address(0), carol, carol, carol) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function test_A3b_allowed_source_cannot_record_without_value() public {
        console2.log("== ATTACK 3b: allowed source with NO funds fabricates an exit ==");
        vm.startPrank(address(hostile));
        (bool ok1, bytes memory e1) = _tryRecordERC20AsHostile();
        _report("recordERC20(pull 1000) with zero balance", ok1, e1);
        vm.stopPrank();
        // OZ transferFrom spends allowance before moving balance; hostile has neither.
        assertEq(
            keccak256(e1),
            keccak256(abi.encodeWithSignature("Error(string)", "ERC20: insufficient allowance")),
            "dies in the token's transferFrom"
        );

        (bool ok2, bytes memory e2) = _tryRecordReceivedNativeViaHost(5 ether, address(hostile), address(hostile), address(hostile));
        _report("recordReceivedNative(5) with empty queue", ok2, e2);
        assertFalse(ok2, "measured path cannot be constructed");
        assertEq(bytes4(e2), IExitDelayQueue.ReceivedAmountMismatch.selector, "guard: delta >= amount");
        assertEq(queue.lastRequestId(), 0);
    }

    function _tryRecordERC20AsHostile() internal returns (bool, bytes memory) {
        try queue.recordERC20Exit(address(token), 1000 ether, FLOOR, SURFACE_LENDING, address(0), address(hostile), address(hostile), address(hostile), false)
        {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _tryRecordReceivedNativeViaHost(uint128 amt, address o, address ow, address r)
        internal
        returns (bool, bytes memory)
    {
        try host.doRecordReceivedNative(amt, FLOOR, SURFACE_ZERO, address(0), o, ow, r) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function test_A3c_fabricate_against_future_funds() public {
        console2.log("== ATTACK 3c: record now, withdraw later when queue has funds ==");
        // Make the queue fully backed first: a normal record consumes all balance.
        _recordERC20ViaHost(address(token), 100 ether, alice, alice, bob, false);
        // Queue balance == escrowed == 100 => delta 0. Any further record reverts
        // AT RECORD TIME, so a claim against FUTURE inflows cannot be created.
        (bool ok, bytes memory err) = _tryRecordReceivedERC20ViaHost(address(token), 1 ether, carol, carol, carol);
        _report("recordReceivedERC20(1) with delta=0", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.ReceivedAmountMismatch.selector, "guard: measured delta at record time");
        assertEq(token.balanceOf(address(queue)), queue.totalEscrowed(address(token)), "escrowed never exceeds balance");
        assertEq(queue.lastRequestId(), 1, "no fabricated claim exists");
    }

    function test_A3d_allowed_source_captures_EXISTING_donation() public {
        console2.log("== ATTACK 3d: allowed source captures a PRE-EXISTING donation (by design) ==");
        // Donate 500 tokens BEFORE any record -> they are non-backing surplus.
        token.transfer(address(queue), 500 ether);
        assertEq(token.balanceOf(address(queue)), 500 ether);
        assertEq(queue.totalEscrowed(address(token)), 0, "donation is surplus, not escrow");

        // The allowed source fabricates an exit against the donation (no push of its own).
        uint256 carolBefore = token.balanceOf(carol);
        (bool ok, bytes memory err) = _tryRecordReceivedERC20ViaHost(address(token), 400 ether, carol, carol, carol);
        _report("recordReceivedERC20(400) against donation", ok, err);
        assertTrue(ok, "allowed source CAN consume surplus (by design - no on-chain block)");

        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok2, bytes memory err2) = _execAs(carol, queue.lastRequestId());
        _report("executeExit of the donation-backed claim", ok2, err2);
        assertTrue(ok2);
        assertEq(token.balanceOf(carol), carolBefore + 400 ether, "donation paid to fabricated receiver");

        // Native variant: raw donation lands in the unconditional receive(),
        // and the same capture works.
        vm.deal(address(queue), 2 ether);
        assertEq(address(queue).balance, 2 ether);
        (bool ok3, bytes memory err3) = _tryRecordReceivedNativeViaHost(1 ether, address(hostile), address(hostile), address(hostile));
        _report("recordReceivedNative(1) against native donation", ok3, err3);
        assertTrue(ok3, "same by-design capture for native");
        vm.warp(block.timestamp + FLOOR + 1);
        hostile.callExecute(queue.lastRequestId());
        assertEq(address(hostile).balance, 1 ether, "native donation captured by allowed source");
    }

    function test_A3e_fee_on_transfer_misescrow_blocked() public {
        console2.log("== ATTACK 3e: fee-on-transfer token cannot mis-escrow ==");
        FOTToken fot = new FOTToken();
        fot.mint(address(host), 1_000 ether);
        vm.startPrank(address(host));
        fot.approve(address(queue), type(uint256).max);
        (bool ok, bytes memory err) = _tryRecordERC20FOT(fot);
        vm.stopPrank();
        _report("recordERC20Exit(FOT token, 100) by allowed source", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.ReceivedAmountMismatch.selector, "guard: measured receipt");
        assertEq(queue.totalEscrowed(address(fot)), 0);
    }

    function _tryRecordERC20FOT(FOTToken fot) internal returns (bool, bytes memory) {
        try queue.recordERC20Exit(address(fot), 100 ether, FLOOR, SURFACE_LENDING, address(0), alice, alice, bob, false)
        {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 4 - double-resolution
    // ══════════════════════════════════════════════════════════════════

    function test_A4a_recover_on_executed_id() public {
        console2.log("== ATTACK 4a: recoverStuckExit on already-executed id ==");
        uint256 id = _recordERC20ViaHost(address(token), 33 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok1,) = _execAs(alice, id);
        assertTrue(ok1);
        uint256 bobBefore = token.balanceOf(bob);
        (bool ok2, bytes memory err2) = _tryRecover(id, carol);
        _report("recoverStuckExit(executedId, carol)", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector, "guard: status check");
        assertEq(token.balanceOf(bob), bobBefore, "no second payout");
        assertEq(token.balanceOf(carol), 0);
    }

    function test_A4b_resolveToProtocol_then_resolveByOwner() public {
        console2.log("== ATTACK 4b: Leg-2 then Leg-3 on same id ==");
        bytes32 routeId = _setupRoute(address(token));
        uint256 id = _recordERC20ViaHost(address(token), 44 ether, alice, alice, bob, false);
        _blacklist(alice);

        uint256 vaultBefore = token.balanceOf(VAULT);
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        (bool ok1, bytes memory err1) = _tryResolveToProtocol(one, routeId);
        _report("resolveToProtocol (Leg-2)", ok1, err1);
        assertTrue(ok1);
        assertEq(token.balanceOf(VAULT), vaultBefore + 44 ether, "routed once");
        assertEq(uint256(_status(id)), 3);

        (bool ok2, bytes memory err2) = _tryResolveByOwner(one, carol);
        _report("resolveByOwner after Leg-2", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(token.balanceOf(carol), 0, "no second resolution payout");
    }

    function test_A4c_resolveByOwner_then_everything_else() public {
        console2.log("== ATTACK 4c: Leg-3 then Leg-2 / recover / execute on same id ==");
        bytes32 routeId = _setupRoute(address(token));
        uint256 id = _recordERC20ViaHost(address(token), 21 ether, alice, alice, bob, false);
        _blacklist(bob); // receiver blacklisted -> owner resolvable

        uint256[] memory one = new uint256[](1);
        one[0] = id;
        uint256 carolBefore = token.balanceOf(carol);
        (bool ok1,) = _tryResolveByOwner(one, carol);
        _report("resolveByOwner (Leg-3)", ok1, "");
        assertTrue(ok1);
        assertEq(token.balanceOf(carol), carolBefore + 21 ether);
        assertEq(uint256(_status(id)), 4);

        (bool ok2, bytes memory e2) = _tryResolveToProtocol(one, routeId);
        _report("resolveToProtocol after Leg-3", ok2, e2);
        (bool ok3, bytes memory e3) = _tryRecover(id, carol);
        _report("recoverStuckExit after Leg-3", ok3, e3);
        (bool ok4, bytes memory e4) = _execAs(alice, id);
        _report("executeExit after Leg-3", ok4, e4);
        assertFalse(ok2 && ok3 && ok4);
        assertEq(bytes4(e2), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(bytes4(e3), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(bytes4(e4), IExitDelayQueue.AlreadyTerminal.selector);
    }

    function test_A4d_recover_then_execute() public {
        console2.log("== ATTACK 4d: recoverStuckExit then executeExit ==");
        uint256 id = _recordERC20ViaHost(address(token), 9 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok1,) = _recoverAs(alice, id, carol);
        _report("recoverStuckExit (stored receiver healthy -> paid stored)", ok1, "");
        assertTrue(ok1);
        assertEq(token.balanceOf(bob), 9 ether, "stored receiver paid, alt unused");
        assertEq(token.balanceOf(carol), 0);
        (bool ok2, bytes memory err2) = _execAs(alice, id);
        _report("executeExit after recover", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
    }

    function test_A4e_redirect_after_execution_impossible() public {
        console2.log("== ATTACK 4e: redirect (party change) after execution ==");
        uint256 id = _recordERC20ViaHost(address(token), 15 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        _execAs(alice, id);
        // No setter exists on the request; recoverStuckExit refuses terminal ids.
        (bool ok, bytes memory err) = _tryRecover(id, carol);
        _report("recover with new alt after execution", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(queue.getRequest(id).receiver, bob, "receiver immutable - no in-ABI redirect exists");
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 5 - payout double-dip across legs
    // ══════════════════════════════════════════════════════════════════

    function test_A5a_wrbtc_unwrap_pays_exactly_one_leg() public {
        console2.log("== ATTACK 5a: WRBTC unwrap - receiver tries to get WRBTC AND native ==");
        uint256 id = _recordERC20ViaHost(address(wrbtc), 30 ether, alice, alice, address(hostile), true);
        vm.warp(block.timestamp + FLOOR + 1);
        hostile.arm(id, 0, SURFACE_LENDING);

        uint256 wrbtcBefore = WRBTC_ERC20.balanceOf(address(hostile));
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("executeExit(unwrap)", ok, err);
        assertTrue(ok);
        assertEq(address(hostile).balance, 30 ether, "exactly one native leg");
        assertEq(WRBTC_ERC20.balanceOf(address(hostile)), wrbtcBefore, "no WRBTC leg");
        assertEq(address(queue).balance, 0);
        assertEq(WRBTC_ERC20.balanceOf(address(queue)), 0);
    }

    function test_A5b_unwrap_flag_on_non_wrbtc_blocked() public {
        console2.log("== ATTACK 5b: unwrapOnDelivery on non-WRBTC token ==");
        vm.startPrank(address(host));
        (bool ok, bytes memory err) = _tryRecordERC20Unwrap();
        vm.stopPrank();
        _report("recordERC20Exit(unwrap=true, token != WRBTC)", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.UnwrapNonWrbtc.selector, "guard: unwrap only on WRBTC escrow");
    }

    function _tryRecordERC20Unwrap() internal returns (bool, bytes memory) {
        try queue.recordERC20Exit(address(token), 10 ether, FLOOR, SURFACE_LENDING, address(0), alice, alice, bob, true)
        {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function test_A5c_fee_leg_not_double_charged_by_queue() public {
        console2.log("== ATTACK 5c: re-execution must not re-charge or re-pay any leg ==");
        uint256 gross = 500 ether;
        (uint256 id, uint256 fee) = host.doFeeThenHoldERC20(
            CONTROLLER, VAULT, address(wrbtc), gross, FLOOR, SURFACE_LENDING, address(0), alice, alice, bob
        );
        vm.warp(block.timestamp + FLOOR + 1);
        uint256 vaultBefore = WRBTC_ERC20.balanceOf(VAULT);
        uint256 bobBefore = WRBTC_ERC20.balanceOf(bob);

        (bool ok1,) = _execAs(bob, id);
        assertTrue(ok1);
        (bool ok2, bytes memory err2) = _execAs(bob, id);
        _report("second execute on fee-then-hold id", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
        assertEq(WRBTC_ERC20.balanceOf(VAULT), vaultBefore, "fee leg untouched by re-execution");
        assertEq(WRBTC_ERC20.balanceOf(bob), bobBefore + gross - fee, "net paid exactly once");
        assertEq(WRBTC_ERC20.balanceOf(address(queue)), 0, "queue never held gross+net");
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 6 - donation / surplus theft
    // ══════════════════════════════════════════════════════════════════

    function test_A6a_non_owner_sweep_blocked() public {
        console2.log("== ATTACK 6a: strangers try to sweep donations ==");
        token.transfer(address(queue), 77 ether);
        (bool ok1, bytes memory e1) = _sweepAs(carol, address(token), carol);
        _report("sweepSurplus(token) as stranger", ok1, e1);
        (bool ok2, bytes memory e2) = _sweepAs(bob, address(0), bob);
        _report("sweepSurplus(native) as stranger", ok2, e2);
        assertFalse(ok1 && ok2);
        assertEq(
            keccak256(e1),
            keccak256(abi.encodeWithSignature("Error(string)", "Ownable: caller is not the owner")),
            "guard: onlyOwner (OZ 4.9 string)"
        );
        assertEq(token.balanceOf(address(queue)), 77 ether, "donation unmoved");
    }

    function _sweepAs(address who, address tok, address to) internal returns (bool, bytes memory) {
        vm.prank(who);
        try queue.sweepSurplus(tok, to) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function test_A6b_non_source_fabricated_exit_to_drain_donation() public {
        console2.log("== ATTACK 6b: small fabricated exit to swallow the donation ==");
        token.transfer(address(queue), 200 ether);
        vm.startPrank(carol);
        (bool ok, bytes memory err) = _tryRecordReceivedERC20Direct();
        vm.stopPrank();
        _report("carol recordReceivedERC20(1) against donation", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.UnregisteredSource.selector, "guard: onlyAllowedSource");
        assertEq(token.balanceOf(address(queue)), 200 ether, "donation intact");
        assertEq(queue.lastRequestId(), 0);
    }

    function test_A6c_owner_sweep_moves_only_surplus() public {
        console2.log("== ATTACK 6c: owner sweep after a legit record (surplus isolated) ==");
        _recordERC20ViaHost(address(token), 60 ether, alice, alice, bob, false);
        token.transfer(address(queue), 25 ether); // donation on top of escrow
        assertEq(token.balanceOf(address(queue)), 85 ether);
        assertEq(queue.totalEscrowed(address(token)), 60 ether);

        uint256 excBefore = token.balanceOf(EXCHEQUER);
        (bool ok, bytes memory err) = _trySweep(address(token), EXCHEQUER);
        _report("sweepSurplus(token) as owner", ok, err);
        assertTrue(ok);
        assertEq(token.balanceOf(EXCHEQUER), excBefore + 25 ether, "exactly the surplus swept");
        assertEq(token.balanceOf(address(queue)), 60 ether, "escrow untouched");
        assertEq(token.balanceOf(address(queue)), queue.totalEscrowed(address(token)), "post-sweep solvency");
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 7 - cancel / redirect races
    // ══════════════════════════════════════════════════════════════════

    function test_A7a_no_cancel_path_freeze_then_execute() public {
        console2.log("== ATTACK 7a: cancel-then-execute (no cancel exists; freeze holds) ==");
        uint256 id = _recordERC20ViaHost(address(token), 11 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        _freeze(alice);
        (bool ok, bytes memory err) = _execAs(alice, id);
        _report("executeExit while originator frozen", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.ActorBlocked.selector, "guard: all-party block gate");
        assertEq(uint256(_status(id)), 1, "still Queued (held, not cancelled)");
        _unfreeze(alice);
        (bool ok2,) = _execAs(alice, id);
        _report("executeExit after unfreeze", ok2, "");
        assertTrue(ok2, "unfreeze restores the exit");
        assertEq(token.balanceOf(bob), 11 ether);
    }

    function test_A7b_recover_redirect_pays_stored_first() public {
        console2.log("== ATTACK 7b: redirect party then execute as old party ==");
        uint256 id = _recordERC20ViaHost(address(token), 14 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        // Redirect attempt: recover naming carol as alt - stored receiver is healthy,
        // so stored must win and the redirect must NOT take effect.
        (bool ok,) = _recoverAs(alice, id, carol);
        _report("recoverStuckExit(alt=carol) with healthy stored receiver", ok, "");
        assertTrue(ok);
        assertEq(token.balanceOf(bob), 14 ether, "stored receiver paid");
        assertEq(token.balanceOf(carol), 0, "alt not paid");
        assertEq(queue.getRequest(id).receiver, bob, "request never re-targeted");
        (bool ok2, bytes memory err2) = _execAs(alice, id);
        _report("execute after recover", ok2, err2);
        assertFalse(ok2);
        assertEq(bytes4(err2), IExitDelayQueue.AlreadyTerminal.selector);
    }

    function test_A7c_alt_receiver_guard() public {
        console2.log("== ATTACK 7c: altReceiver guard values ==");
        uint256 id = _recordERC20ViaHost(address(token), 5 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok1, bytes memory e1) = _recoverAs(alice, id, address(0));
        _report("alt = address(0)", ok1, e1);
        (bool ok2, bytes memory e2) = _recoverAs(alice, id, address(queue));
        _report("alt = queue itself", ok2, e2);
        (bool ok3, bytes memory e3) = _recoverAs(alice, id, address(token));
        _report("alt = escrowed token", ok3, e3);
        assertFalse(ok1 && ok2 && ok3);
        assertEq(bytes4(e1), IExitDelayQueue.InvalidAltReceiver.selector);
        assertEq(bytes4(e2), IExitDelayQueue.InvalidAltReceiver.selector);
        assertEq(bytes4(e3), IExitDelayQueue.InvalidAltReceiver.selector);
        assertEq(uint256(_status(id)), 1, "request untouched");
    }

    // ══════════════════════════════════════════════════════════════════
    // ATTACK 8 - everything else
    // ══════════════════════════════════════════════════════════════════

    function test_A8a_unlock_off_by_one() public {
        console2.log("== ATTACK 8a: second-early around unlocksAt ==");
        uint256 id = _recordERC20ViaHost(address(token), 4 ether, alice, alice, bob, false);
        uint64 unlockAt = queue.getRequest(id).unlockAt;

        vm.warp(unlockAt - 1);
        (bool ok1, bytes memory e1) = _execAs(alice, id);
        _report("execute at unlockAt - 1s", ok1, e1);
        assertFalse(ok1);
        assertEq(bytes4(e1), IExitDelayQueue.NotUnlocked.selector, "guard: block.timestamp < unlockAt");

        vm.warp(unlockAt);
        (bool ok2,) = _execAs(alice, id);
        _report("execute at exactly unlockAt", ok2, "");
        assertTrue(ok2, "no off-by-one: t == unlockAt pays");
    }

    function test_A8b_unknown_and_zero_ids() public {
        console2.log("== ATTACK 8b: unknown id / id 0 ==");
        (bool ok1, bytes memory e1) = _tryExecute(999_999);
        _report("executeExit(999999)", ok1, e1);
        (bool ok2, bytes memory e2) = _tryExecute(0);
        _report("executeExit(0)", ok2, e2);
        assertEq(bytes4(e1), IExitDelayQueue.UnknownRequest.selector);
        assertEq(bytes4(e2), IExitDelayQueue.UnknownRequest.selector);
    }

    function test_A8c_batch_atomicity_unknown_id_rolls_back() public {
        console2.log("== ATTACK 8c: batch with one unknown id rolls back the whole batch ==");
        uint256 a = _recordERC20ViaHost(address(token), 8 ether, alice, alice, bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        uint256 bobBefore = token.balanceOf(bob);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = 424_242;
        (bool ok, bytes memory err) = _execManyAs(alice, ids);
        _report("batch [valid, unknown]", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.UnknownRequest.selector);
        assertEq(token.balanceOf(bob), bobBefore, "valid id not paid - atomic");
        assertEq(uint256(_status(a)), 1);
    }

    function test_A8d_pause_blocks_users_but_ingress_stays_live() public {
        console2.log("== ATTACK 8d: pause race ==");
        uint256 id = _recordERC20ViaHost(address(token), 17 ether, alice, alice, bob, false);
        token.transfer(address(queue), 10 ether); // surplus so a paused-era record can cover itself
        _setPaused(true);
        (bool ok1, bytes memory e1) = _execAs(alice, id);
        _report("execute while paused", ok1, e1);
        assertFalse(ok1);
        assertEq(bytes4(e1), IExitDelayQueue.QueuePaused.selector, "guard: pause");
        // ingress stays live while paused (records still escrow):
        (bool ok2, bytes memory e2) = _tryRecordReceivedERC20ViaHost(address(token), 3 ether, alice, alice, bob);
        _report("record while paused (surplus present)", ok2, e2);
        assertTrue(ok2, "ingress is not paused by design");
        _setPaused(false);
        vm.warp(block.timestamp + FLOOR + 1);
        (bool ok3,) = _execAs(alice, id);
        _report("execute after unpause", ok3, "");
        assertTrue(ok3);
    }

    function _setPaused(bool p) internal {
        vm.prank(EXCHEQUER);
        queue.setSecurityPerimeterPaused(p);
    }

    function test_A8e_anyone_executes_contract_owned_request_but_pays_receiver() public {
        console2.log("== ATTACK 8e: executor widening - anyone delivers a contract-owned request ==");
        ContractWallet ow = new ContractWallet();
        uint256 id = _recordERC20ViaHost(address(token), 19 ether, alice, address(ow), bob, false);
        vm.warp(block.timestamp + FLOOR + 1);
        // carol is nobody; the recorded owner has code -> she may deliver:
        (bool ok,) = _execAs(carol, id);
        _report("non-party executes contract-owned request", ok, "");
        assertTrue(ok);
        assertEq(token.balanceOf(bob), 19 ether, "paid only the recorded receiver");
        assertEq(token.balanceOf(carol), 0, "executor keeps nothing");
    }

    function test_A8f_post_payout_solvency_blocks_stranding_later_exits() public {
        console2.log("== ATTACK 8f: sneaky token tries to strand another depositor ==");
        // A and B each record 100 sneaky (queue balance 200, escrowed 200).
        uint256 a = _recordERC20ViaHost(address(sneaky), 100 ether, alice, alice, bob, false);
        uint256 b = _recordERC20ViaHost(address(sneaky), 100 ether, carol, carol, carol, false);
        assertEq(sneaky.balanceOf(address(queue)), 200 ether);
        vm.warp(block.timestamp + FLOOR + 1);

        // Execute A: outbound transfer moves 100 to bob + 100 fee to dead ->
        // post-payout balance 0 < escrowed 100 -> payout must revert wholesale.
        (bool ok, bytes memory err) = _execAs(alice, a);
        _report("executeExit(A) with fee-on-outbound token", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.SolvencyViolated.selector, "guard: post-payout solvency");
        assertEq(uint256(_status(a)), 1, "A rolled back to Queued");
        assertEq(sneaky.balanceOf(bob), 0, "no partial payout");
        assertEq(sneaky.balanceOf(address(queue)), 200 ether, "B's backing intact");
    }

    function test_A8g_receive_is_unconditional_but_never_credited() public {
        console2.log("== ATTACK 8g: raw native donation is never auto-credited ==");
        vm.deal(address(queue), 3 ether); // lands in empty receive()
        assertEq(address(queue).balance, 3 ether);
        assertEq(queue.totalEscrowed(address(0)), 0, "receive() credits nothing");
        (bool ok, bytes memory err) = _tryRecordReceivedNativeViaHost(10 ether, alice, alice, bob);
        _report("recordReceivedNative(10) with only 3 surplus", ok, err);
        assertFalse(ok);
        assertEq(bytes4(err), IExitDelayQueue.ReceivedAmountMismatch.selector);
    }

    // ══════════════════════════════════════════════════════════════════
    // Helpers: owner-side recovery setup
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

    function _blacklist(address who) internal {
        vm.prank(EXCHEQUER);
        queue.blacklist(who);
    }

    function _freeze(address who) internal {
        vm.prank(EXCHEQUER);
        queue.freeze(who);
    }

    function _unfreeze(address who) internal {
        vm.prank(EXCHEQUER);
        queue.unfreeze(who);
    }
}
