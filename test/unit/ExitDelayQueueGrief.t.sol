// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

/// @dev regression suite .
///      The measured-delta ingress fns credit EXACTLY `amount` when the current
///      non-backing surplus `delta = balanceOf/balance − totalEscrowed` is
///      `>= amount`, and revert `ReceivedAmountMismatch` ONLY when `delta < amount`.
///      This file BOTH captures the original donation-grief PoC (now proving it is
///      fixed) AND adds positive/negative coverage for the new `>= amount` rule.

contract Tok is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address a, uint256 v) external {
        _mint(a, v);
    }
}

contract WR {
    function withdraw(uint256) external {}
    receive() external payable {}
}

/// @dev A hostile token whose `transfer(to, v)` moves `v` to `to` but ALSO burns
///      an extra `drain` from the caller (the queue) in the same call. Under a
///      full-surplus sweep this pushes the queue's post-sweep balance BELOW the
///      escrowed backing, tripping the `SolvencyViolated` post-check (the
///      ERC20 arm at ExitDelayQueue.sol:772). Models a rebasing / hook token
///      that can silently reduce a holder's balance during a transfer.
contract OverDrainToken is ERC20 {
    uint256 public drainOnNextTransfer;

    constructor() ERC20("Drain", "DRN") {}

    function mint(address a, uint256 v) external {
        _mint(a, v);
    }

    function armDrain(uint256 d) external {
        drainOnNextTransfer = d;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        uint256 d = drainOnNextTransfer;
        if (d != 0) {
            drainOnNextTransfer = 0;
            // Burn extra from msg.sender (the queue) → balance drops below escrow.
            _burn(msg.sender, d);
        }
        return ok;
    }
}

/// @dev Stand-in for the 0.5.x source that pushes then records in the SAME tx.
contract Src {
    ExitDelayQueue q;

    constructor(ExitDelayQueue q_) {
        q = q_;
    }
    /// ERC20: transfer to the queue, then record (measured-delta path).

    function rec(address t, uint128 a, uint32 d, address o) external returns (uint256) {
        ERC20(t).transfer(address(q), a);
        return q.recordReceivedERC20Exit(t, a, d, keccak256("S"), address(0), o, o, o);
    }
    /// Record WITHOUT pushing enough — used for the under-delivery negative test.

    function recNoPush(address t, uint128 a, uint32 d, address o) external returns (uint256) {
        return q.recordReceivedERC20Exit(t, a, d, keccak256("S"), address(0), o, o, o);
    }
    /// Full-arg ERC20 record (distinct originator/owner/receiver) — used by the
    ///  batch-block tests to create requests spanning many parties.

    function recFull(address t, uint128 a, uint32 d, address o, address w, address r)
        external
        returns (uint256)
    {
        ERC20(t).transfer(address(q), a);
        return q.recordReceivedERC20Exit(t, a, d, keccak256("S"), address(0), o, w, r);
    }
    /// Native: forward the msg.value on to the queue, then record.

    function recNative(uint128 a, uint32 d, address o) external returns (uint256) {
        (bool ok,) = payable(address(q)).call{value: a}("");
        require(ok, "push failed");
        return q.recordReceivedNativeExit(a, d, keccak256("S"), address(0), o, o, o);
    }
}

/// @dev Force-sends native RBTC to an arbitrary target via selfdestruct — the
///      `receive()` gate cannot stop this, which is the whole point of `>= amount`.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract Grief is Test {
    ExitDelayQueue q;
    Tok tok;
    WR wr;
    Src src;

    address constant PARTY = address(0x111);

    function setUp() public {
        wr = new WR();
        tok = new Tok();
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory s = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, address(this), address(0xAD), address(wr), uint32(1 hours), s
        );
        q = ExitDelayQueue(payable(address(new ERC1967Proxy(address(impl), init))));
        src = new Src(q);
        q.addAllowedSource(address(src));
        // The queue must be a registered native pusher target so the Src forward
        // (which goes through the queue's receive()) is accepted for native tests.
        // ActivePool == the Src here for the native push.
        // (addAllowedSource already done; the receive() gate keys on nativePusher.)
        tok.mint(address(src), 1000 ether);
    }

    // ─── ERC20 measured-delta ───────────────────────────────────────────

    /// @notice REGRESSION (the original grief PoC, now PROVING the fix): a 1-wei
    ///         token force-send before a legit same-tx push must NOT brick the
    ///         record. Under the old `delta == amount` rule this reverted; under
    ///         the `delta >= amount` rule it records and credits exactly
    ///         `amount`, leaving the 1-wei as sweepable surplus.
    function test_dust_donation_does_not_brick_measured_delta() public {
        // Griefer force-sends 1 wei of the token to the queue.
        tok.mint(address(this), 1);
        tok.transfer(address(q), 1);

        // Legit exit of 50 ether now SUCCEEDS (delta = 50e18 + 1 >= 50e18).
        uint256 id = src.rec(address(tok), 50 ether, 2 hours, PARTY);

        // Credited EXACTLY amount — the 1-wei donation is NOT mis-credited.
        assertEq(q.totalEscrowed(address(tok)), 50 ether, "credit exactly amount");
        IExitDelayQueue.ExitRequest memory r = q.getRequest(id);
        assertEq(r.amount, 50 ether, "request amount");
        assertEq(uint8(r.status), uint8(IExitDelayQueue.ExitStatus.Queued), "queued");

        // The 1-wei excess remains as non-backing surplus, sweepable by Owner.
        assertEq(tok.balanceOf(address(q)), 50 ether + 1, "balance = escrow + donation");
        q.sweepSurplus(address(tok), address(0xBEEF));
        assertEq(tok.balanceOf(address(0xBEEF)), 1, "surplus swept");
        assertEq(tok.balanceOf(address(q)), 50 ether, "backing intact post-sweep");
        assertEq(q.totalEscrowed(address(tok)), 50 ether, "escrow unchanged by sweep");
    }

    /// @notice POSITIVE: a 1-wei donation before a legit push still records and
    ///         credits exactly amount (the fix-list's explicit positive case).
    function test_positive_donation_then_push_credits_exactly_amount() public {
        tok.mint(address(this), 1);
        tok.transfer(address(q), 1); // donation

        uint256 id = src.rec(address(tok), 10 ether, 3 hours, PARTY);
        assertEq(q.totalEscrowed(address(tok)), 10 ether);
        assertEq(q.getRequest(id).amount, 10 ether);
    }

    /// @notice Repeated records after a donation each consume exactly amount and
    ///         never re-brick (a donation only raises surplus, so >= still holds).
    function test_multiple_records_after_donation() public {
        tok.mint(address(this), 5);
        tok.transfer(address(q), 5); // 5-wei donation sits as surplus

        src.rec(address(tok), 20 ether, 2 hours, PARTY);
        src.rec(address(tok), 30 ether, 2 hours, address(0x222));
        assertEq(q.totalEscrowed(address(tok)), 50 ether, "each record consumed exactly amount");
        assertEq(tok.balanceOf(address(q)), 50 ether + 5, "donation still surplus");
    }

    /// @notice NEGATIVE: an under-delivered push (delta < amount) STILL reverts
    ///         ReceivedAmountMismatch — the fix relaxes only the upper bound.
    function test_under_delivery_still_reverts() public {
        // No push at all: delta = 0 < amount.
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ReceivedAmountMismatch.selector, address(tok), uint256(0), uint256(1 ether)
            )
        );
        src.recNoPush(address(tok), 1 ether, 2 hours, PARTY);
    }

    /// @notice NEGATIVE: partial delivery (a donation smaller than amount) reverts.
    function test_partial_delivery_reverts() public {
        tok.mint(address(this), 1 ether);
        tok.transfer(address(q), 1 ether); // only 1 ether present
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ReceivedAmountMismatch.selector,
                address(tok),
                uint256(1 ether),
                uint256(5 ether)
            )
        );
        src.recNoPush(address(tok), 5 ether, 2 hours, PARTY);
    }

    // ─── Native measured-receipt ────────────────────────────────────────

    /// @notice REGRESSION (native): a `selfdestruct` force-send of native RBTC
    ///         (which the `receive()` gate CANNOT block) before a legit push must
    ///         not brick recordReceivedNativeExit. Credits exactly amount; the
    ///         force-sent wei stays as sweepable surplus.
    function test_native_forcesend_does_not_brick_measured_delta() public {
        // Register the Src as the native pusher so the queue's receive() accepts
        // the Src's forward. (The Src plays ActivePool here.)
        q.setNativePusher(address(src));

        // Force-send 1 wei via selfdestruct — bypasses receive() entirely.
        vm.deal(address(this), 1);
        new ForceSender{value: 1}(payable(address(q)));
        assertEq(address(q).balance, 1, "force-sent wei present");

        // Legit native exit of 5 ether now records (delta = 5e18 + 1 >= 5e18).
        vm.deal(address(src), 5 ether);
        uint256 id = src.recNative(5 ether, 2 hours, PARTY);

        assertEq(q.totalEscrowed(address(0)), 5 ether, "credit exactly amount (native)");
        assertEq(q.getRequest(id).amount, 5 ether);
        assertEq(address(q).balance, 5 ether + 1, "balance = escrow + force-send");

        // Sweep the 1-wei surplus; backing stays intact.
        q.sweepSurplus(address(0), address(0xBEEF));
        assertEq(address(q).balance, 5 ether, "backing intact post-sweep");
    }

    // ─── batch by-request-id block — emergency speed lever ─────────

    /// @notice The emergency lever: several known-malicious requests, each opened
    ///         by a distinct delegate for a distinct owner, are all blocked
    ///         (owner + delegate) in ONE `blacklistFromRequest(uint256[])` call —
    ///         the single-Admin-multisig-tx incident response describes.
    function test_batch_blacklistFromRequest_blocks_many_parties_one_tx() public {
        uint256 id1 = _queueDistinct(1);
        uint256 id2 = _queueDistinct(2);
        uint256 id3 = _queueDistinct(3);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;
        // Admin (the fast guardian) blocks all six parties in one tx.
        vm.prank(address(0xAD));
        q.blacklistFromRequest(ids, false, keccak256("incident-42"));

        for (uint160 k = 1; k <= 3; ++k) {
            assertEq(
                uint8(q.blockStateOf(_orig(k))), uint8(IExitDelayQueue.BlockState.Blacklisted), "orig blocked"
            );
            assertEq(
                uint8(q.blockStateOf(_ownr(k))),
                uint8(IExitDelayQueue.BlockState.Blacklisted),
                "owner blocked"
            );
        }
    }

    /// @notice ATOMICITY grief guard: an operator who accidentally (or a griefer who
    ///         maliciously) slips ONE unknown id into the batch gets the WHOLE batch
    ///         reverted — no half-applied block state that would need manual cleanup.
    function test_batch_blockFromRequest_is_atomic_on_bad_id() public {
        uint256 id1 = _queueDistinct(1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = type(uint256).max; // never recorded
        vm.prank(address(0xAD));
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, type(uint256).max));
        q.freezeFromRequest(ids, false, bytes32(0));
        // id1's parties are untouched — the whole batch rolled back.
        assertEq(uint8(q.blockStateOf(_orig(1))), uint8(IExitDelayQueue.BlockState.None));
        assertEq(uint8(q.blockStateOf(_ownr(1))), uint8(IExitDelayQueue.BlockState.None));
    }

    // ─── solvency backstop (SolvencyViolated) ───────────────────────

    /// @notice The post-sweep solvency require (ERC20 arm, src:772) MUST trip
    ///         if a hostile/rebasing token drains more than the computed surplus
    ///         from the queue during `safeTransfer`, dropping backing below the
    ///         escrowed total. Proves the backstop reverts the whole sweep rather
    ///         than silently leaking escrowed backing.
    function test_sweepSurplus_solvency_violated_erc20() public {
        OverDrainToken drn = new OverDrainToken();
        drn.mint(address(src), 1000 ether);

        // Escrow 50 of the drain token via the measured-delta path.
        uint256 id = src.rec(address(drn), 50 ether, 2 hours, PARTY);
        assertEq(q.totalEscrowed(address(drn)), 50 ether);
        assertEq(uint8(q.getRequest(id).status), uint8(IExitDelayQueue.ExitStatus.Queued));

        // Add 5 surplus so the sweep computes surplus = 5 and calls transfer.
        drn.mint(address(q), 5 ether);
        // Arm the token to burn an extra 10 from the queue during the transfer —
        // post-sweep balance = 50 (escrow) - 10 = 40 < 50 escrowed → revert.
        drn.armDrain(10 ether);

        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        q.sweepSurplus(address(drn), address(0xBEEF));
    }

    // ── helpers for the batch-block tests ──

    function _orig(uint160 k) internal pure returns (address) {
        return address(0xB0000 + k * 2);
    }

    function _ownr(uint160 k) internal pure returns (address) {
        return address(0xB0000 + k * 2 + 1);
    }

    /// Queue one ERC20 request with distinct originator/owner/receiver derived
    /// from `k` via the measured-delta source's full-arg record.
    function _queueDistinct(uint160 k) internal returns (uint256 id) {
        tok.mint(address(src), 100 ether);
        id = src.recFull(address(tok), 10 ether, 2 hours, _orig(k), _ownr(k), address(0xDCE0 + k));
    }
}
