// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {UnderpayingWRBTC} from "../mocks/UnderpayingWRBTC.sol";

contract ExitDelayQueueFloorTest is Test {
    enum Ingress {
        PullERC20,
        ReceivedERC20,
        Native,
        ReceivedNative
    }

    ExitDelayQueue internal queue;
    UnderpayingWRBTC internal token;
    address internal constant ORIGINATOR = address(0xC01);
    address internal constant CLAIM_OWNER = address(0xC02);
    address internal constant RECEIVER = address(0xC03);
    uint32 internal constant FLOOR = 86400;
    uint128 internal constant AMOUNT = 1 ether;

    function setUp() public {
        token = new UnderpayingWRBTC();
        address[] memory sources = new address[](1);
        sources[0] = address(this);
        queue = ExitDelayQueue(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new ExitDelayQueue()),
                        abi.encodeCall(
                            ExitDelayQueue.initialize,
                            (address(this), address(0xAD), address(token), FLOOR, sources)
                        )
                    )
                )
            )
        );
        token.mint(address(this), 4 * AMOUNT);
        token.approve(address(queue), 4 * AMOUNT);
        vm.deal(address(this), 4 * AMOUNT);
    }

    // Push and record share one outer call so a rejected record must undo the push.
    function recordExit(Ingress mode, uint32 delay) external returns (uint256) {
        require(msg.sender == address(this), "self only");
        if (mode == Ingress.PullERC20) {
            return queue.recordERC20Exit(
                address(token),
                AMOUNT,
                delay,
                bytes32("floor"),
                address(0),
                ORIGINATOR,
                CLAIM_OWNER,
                RECEIVER,
                false
            );
        }
        if (mode == Ingress.ReceivedERC20) {
            token.transfer(address(queue), AMOUNT);
            return queue.recordReceivedERC20Exit(
                address(token), AMOUNT, delay, bytes32("floor"), address(0), ORIGINATOR, CLAIM_OWNER, RECEIVER
            );
        }
        if (mode == Ingress.Native) {
            return queue.recordNativeExit{value: AMOUNT}(
                AMOUNT, delay, bytes32("floor"), address(0), ORIGINATOR, CLAIM_OWNER, RECEIVER
            );
        }
        (bool ok,) = address(queue).call{value: AMOUNT}("");
        require(ok, "native push failed");
        return queue.recordReceivedNativeExit(
            AMOUNT, delay, bytes32("floor"), address(0), ORIGINATOR, CLAIM_OWNER, RECEIVER
        );
    }

    function _assertIndexes(uint256 count) internal view {
        address[3] memory parties = [ORIGINATOR, CLAIM_OWNER, RECEIVER];
        for (uint256 p; p < parties.length; ++p) {
            (uint256[] memory ids, uint256 nextCursor) = queue.getActive(parties[p], 0, 10);
            assertEq(nextCursor, 0);
            assertEq(ids.length, count);
            for (uint256 i; i < count; ++i) {
                assertEq(ids[i], i + 1);
            }
        }
    }

    function test_allIngressRejects86399AndRollsBackPushesAndAllowance() public {
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IExitDelayQueue.DelayBelowFloor.selector, uint32(86399), FLOOR)
            );
            this.recordExit(Ingress(i), 86399);
            assertEq(queue.lastRequestId(), 0);
            assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.None));
            assertEq(queue.totalEscrowed(address(token)), 0);
            assertEq(queue.totalEscrowed(address(0)), 0);
            assertEq(token.balanceOf(address(queue)), 0);
            assertEq(address(queue).balance, 0);
            assertEq(token.balanceOf(address(this)), 4 * AMOUNT);
            assertEq(address(this).balance, 4 * AMOUNT);
            assertEq(token.allowance(address(this), address(queue)), 4 * AMOUNT);
            _assertIndexes(0);
        }
    }

    function _assertHeld(uint64 createdAt) internal view {
        assertEq(queue.lastRequestId(), 4);
        assertEq(queue.totalEscrowed(address(token)), 2 * AMOUNT);
        assertEq(queue.totalEscrowed(address(0)), 2 * AMOUNT);
        assertEq(token.balanceOf(address(queue)), 2 * AMOUNT);
        assertEq(address(queue).balance, 2 * AMOUNT);
        assertEq(token.balanceOf(RECEIVER), 0);
        assertEq(RECEIVER.balance, 0);
        assertEq(token.allowance(address(this), address(queue)), 3 * AMOUNT);
        for (uint256 id = 1; id <= 4; ++id) {
            IExitDelayQueue.ExitRequest memory request = queue.getRequest(id);
            assertEq(uint256(request.status), uint256(IExitDelayQueue.ExitStatus.Queued));
            assertEq(request.amount, AMOUNT);
            assertEq(request.createdAt, createdAt);
            assertEq(request.unlockAt, createdAt + FLOOR);
            assertEq(request.token, id <= 2 ? address(token) : address(0));
            assertEq(request.originator, ORIGINATOR);
            assertEq(request.owner, CLAIM_OWNER);
            assertEq(request.receiver, RECEIVER);
            assertEq(request.surfaceId, bytes32("floor"));
            assertEq(request.subProduct, address(0));
            assertFalse(request.unwrapOnDelivery);
        }
        _assertIndexes(4);
    }

    function test_allIngressAcceptsExactFloorAndKeepsOffMinuteUnlock() public {
        vm.warp(86401);
        uint64 createdAt = uint64(block.timestamp);
        for (uint256 i; i < 4; ++i) {
            assertEq(this.recordExit(Ingress(i), FLOOR), i + 1);
        }
        _assertHeld(createdAt);
        IExitDelayQueue.ExitRequest[4] memory expected;
        for (uint256 i; i < 4; ++i) {
            expected[i] = queue.getRequest(i + 1);
        }

        vm.warp(uint256(createdAt) + FLOOR - 1);
        for (uint256 id = 1; id <= 4; ++id) {
            vm.prank(CLAIM_OWNER);
            vm.expectRevert(
                abi.encodeWithSelector(IExitDelayQueue.NotUnlocked.selector, id, createdAt + FLOOR)
            );
            queue.executeExit(id);
            _assertHeld(createdAt);
        }
        vm.warp(uint256(createdAt) + FLOOR);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(CLAIM_OWNER);
        queue.executeExits(ids);
        assertEq(token.balanceOf(RECEIVER), 2 * AMOUNT);
        assertEq(RECEIVER.balance, 2 * AMOUNT);
        assertEq(queue.totalEscrowed(address(token)), 0);
        assertEq(queue.totalEscrowed(address(0)), 0);
        assertEq(token.balanceOf(address(queue)), 0);
        assertEq(address(queue).balance, 0);
        assertEq(token.allowance(address(this), address(queue)), 3 * AMOUNT);
        _assertIndexes(0);
        for (uint256 id = 1; id <= 4; ++id) {
            expected[id - 1].status = IExitDelayQueue.ExitStatus.Executed;
            assertEq(abi.encode(queue.getRequest(id)), abi.encode(expected[id - 1]));
        }
    }
}
