// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {UnderpayingWRBTC} from "../mocks/UnderpayingWRBTC.sol";

contract SwitchableNativeReceiver {
    bool public accepts;

    function setAccepts(bool enabled) external {
        accepts = enabled;
    }

    receive() external payable {
        require(accepts, "native payment refused");
    }
}

contract ExitDelayQueueAssetAccountingTest is Test {
    ExitDelayQueue internal queue;
    UnderpayingWRBTC internal token;
    SwitchableNativeReceiver internal stored;
    SwitchableNativeReceiver internal alternate;
    IExitDelayQueue.ExitRequest internal wrappedRequest;
    IExitDelayQueue.ExitRequest internal nativeRequest;

    address internal constant ORIGINATOR = address(0xB01);
    address internal constant CLAIM_OWNER = address(0xB02);
    address internal constant NATIVE_PARTY = address(0xB03);
    uint32 internal constant DELAY = 86400;

    function setUp() public {
        token = new UnderpayingWRBTC();
        stored = new SwitchableNativeReceiver();
        alternate = new SwitchableNativeReceiver();
        address[] memory sources = new address[](1);
        sources[0] = address(this);
        queue = ExitDelayQueue(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new ExitDelayQueue()),
                        abi.encodeCall(
                            ExitDelayQueue.initialize,
                            (address(this), address(0xAD), address(token), DELAY, sources)
                        )
                    )
                )
            )
        );
    }

    function _recordMixedClaims(uint128 wrappedAmount, uint128 nativeAmount) internal {
        vm.deal(address(token), wrappedAmount);
        token.mint(address(this), wrappedAmount);
        token.approve(address(queue), wrappedAmount);
        queue.recordERC20Exit(
            address(token),
            wrappedAmount,
            DELAY,
            bytes32("wrapped"),
            address(token),
            ORIGINATOR,
            CLAIM_OWNER,
            address(stored),
            true
        );
        vm.deal(address(this), nativeAmount);
        queue.recordNativeExit{value: nativeAmount}(
            nativeAmount, DELAY, bytes32("native"), address(0), NATIVE_PARTY, NATIVE_PARTY, NATIVE_PARTY
        );
        wrappedRequest = queue.getRequest(1);
        nativeRequest = queue.getRequest(2);
        vm.warp(block.timestamp + DELAY);
    }

    function _assertIndex(address party, uint256 id, bool active) internal view {
        (uint256[] memory ids, uint256 nextCursor) = queue.getActive(party, 0, 10);
        assertEq(nextCursor, 0, "complete party index page");
        assertEq(ids.length, active ? 1 : 0, "party index length");
        if (active) assertEq(ids[0], id, "party index request");
    }

    function _assertWrappedRequest(bool executed) internal view {
        IExitDelayQueue.ExitRequest memory expected = wrappedRequest;
        if (executed) expected.status = IExitDelayQueue.ExitStatus.Executed;
        assertEq(abi.encode(queue.getRequest(1)), abi.encode(expected), "stored request metadata");
        _assertIndex(ORIGINATOR, 1, !executed);
        _assertIndex(CLAIM_OWNER, 1, !executed);
        _assertIndex(address(stored), 1, !executed);
        _assertIndex(address(alternate), 1, false);
    }

    function _assertNativeHeld(uint128 nativeAmount) internal view {
        assertEq(queue.totalEscrowed(address(0)), nativeAmount, "independent native ledger");
        assertEq(address(queue).balance, nativeAmount, "independent native backing");
        assertEq(abi.encode(queue.getRequest(2)), abi.encode(nativeRequest), "independent native request");
        _assertIndex(NATIVE_PARTY, 2, true);
    }

    function _assertHeld(uint128 wrappedAmount, uint128 nativeAmount) internal view {
        _assertWrappedRequest(false);
        _assertNativeHeld(nativeAmount);
        assertEq(queue.lastRequestId(), 2);
        assertEq(queue.totalEscrowed(address(token)), wrappedAmount, "wrapped ledger");
        assertEq(token.balanceOf(address(queue)), wrappedAmount, "wrapped backing");
        assertEq(address(token).balance, wrappedAmount, "unwrap reserve rollback");
        assertEq(token.totalSupply(), wrappedAmount, "unwrap burn rollback");
        assertEq(token.allowance(address(this), address(queue)), 0, "exact allowance consumed once");
        assertEq(address(stored).balance, 0);
        assertEq(address(alternate).balance, 0);
    }

    function _assertReleased(uint128 wrappedAmount, uint128 nativeAmount, bool paidStored) internal {
        _assertWrappedRequest(true);
        _assertNativeHeld(nativeAmount);
        assertEq(queue.totalEscrowed(address(token)), 0);
        assertEq(token.balanceOf(address(queue)), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(address(token).balance, 0);
        assertEq(token.allowance(address(this), address(queue)), 0);
        assertEq(address(stored).balance, paidStored ? wrappedAmount : 0);
        assertEq(address(alternate).balance, paidStored ? 0 : wrappedAmount);

        vm.prank(ORIGINATOR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.executeExit(1);
        vm.prank(CLAIM_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.recoverStuckExit(1, address(alternate));

        vm.prank(NATIVE_PARTY);
        queue.executeExit(2);
        assertEq(NATIVE_PARTY.balance, nativeAmount);
        assertEq(address(queue).balance, 0);
        assertEq(queue.totalEscrowed(address(0)), 0);
        IExitDelayQueue.ExitRequest memory expected = nativeRequest;
        expected.status = IExitDelayQueue.ExitStatus.Executed;
        assertEq(abi.encode(queue.getRequest(2)), abi.encode(expected));
        _assertIndex(NATIVE_PARTY, 2, false);
    }

    function _failedRecoveryThenAlternate(uint128 wrappedAmount, uint128 nativeAmount) internal {
        _recordMixedClaims(wrappedAmount, nativeAmount);
        vm.prank(ORIGINATOR);
        vm.expectRevert(bytes("Address: unable to send value, recipient may have reverted"));
        queue.recoverStuckExit(1, address(alternate));
        _assertHeld(wrappedAmount, nativeAmount);

        alternate.setAccepts(true);
        vm.prank(CLAIM_OWNER);
        queue.recoverStuckExit(1, address(alternate));
        _assertReleased(wrappedAmount, nativeAmount, false);
    }

    function _underpayThenStored(uint128 wrappedAmount, uint128 nativeAmount) internal {
        _recordMixedClaims(wrappedAmount, nativeAmount);
        stored.setAccepts(true);
        alternate.setAccepts(true);
        token.setUnderpay(true);
        vm.prank(ORIGINATOR);
        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        queue.recoverStuckExit(1, address(alternate));
        _assertHeld(wrappedAmount, nativeAmount);

        token.setUnderpay(false);
        vm.prank(ORIGINATOR);
        queue.recoverStuckExit(1, address(alternate));
        _assertReleased(wrappedAmount, nativeAmount, true);
    }

    function test_failedUnwrapRecoveryRollsBackBothLedgersThenPaysAlternate() public {
        _failedRecoveryThenAlternate(1 ether, 7 ether);
    }

    function test_underpaidUnwrapCannotSpendIndependentNativeEscrow() public {
        _underpayThenStored(1 ether, 7 ether);
    }

    function test_oneWeiUnderpaidUnwrapRollsBackWithoutRedirecting() public {
        _underpayThenStored(1, 1);
    }

    function test_maximumClaimsRollbackThenReleaseExactly() public {
        _failedRecoveryThenAlternate(type(uint128).max, type(uint128).max);
    }

    // Manual properties; CI runs the deterministic cases above.
    function testFuzz_failedUnwrapRecoveryPreservesIndependentNativeEscrow(uint128 a, uint128 b) public {
        _failedRecoveryThenAlternate(
            uint128(bound(a, 1, type(uint128).max)), uint128(bound(b, 1, type(uint128).max))
        );
    }

    function testFuzz_underpaidUnwrapNeverRedirectsOrConsumesNativeEscrow(uint128 a, uint128 b) public {
        _underpayThenStored(uint128(bound(a, 1, type(uint128).max)), uint128(bound(b, 1, type(uint128).max)));
    }
}
