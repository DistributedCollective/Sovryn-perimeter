// SPDX-License-Identifier: MIT
// Fork-test mock (2026-10-14): allowed-source stand-in for the product hosts.
// An allowed-source stand-in for the product hosts: wraps the queue's four
// record* ingress fns, models the fee-then-hold product flow, and doubles as a
// bouncing receiver for the recoverStuckExit leg.
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IQueueG {
    function recordERC20Exit(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver,
        bool unwrapOnDelivery
    ) external returns (uint256 id);

    function recordReceivedERC20Exit(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id);

    function recordNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external payable returns (uint256 id);

    function recordReceivedNativeExit(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id);
}

interface ICtrlG {
    struct ExitFeeQuote {
        bool active;
        uint16 rateBps;
        uint256 feeAmount;
        uint256 netAmount;
        address feeReceiver;
        uint8 reason;
    }

    function quoteExitFee(bytes32 surfaceId, address subProduct, address actor, uint256 grossAmount)
        external
        view
        returns (ExitFeeQuote memory);
}

contract MockQueueHost {
    IQueueG public immutable queue;
    bool public bounce; // when true, receive() reverts (bouncing-receiver model)

    event FeeTaken(address indexed token, address indexed to, uint256 fee);
    event NetQueued(uint256 indexed id, uint256 net);

    constructor(address queue_) {
        queue = IQueueG(queue_);
    }

    receive() external payable {
        require(!bounce, "MockQueueHost: bouncing");
    }

    function setBounce(bool b) external {
        bounce = b;
    }

    function approveToken(address token, uint256 amt) external {
        IERC20(token).approve(address(queue), amt);
    }

    function doRecordNative(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external payable returns (uint256 id) {
        id = queue.recordNativeExit{value: msg.value}(
            amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver
        );
    }

    function doRecordReceivedNative(
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id) {
        id = queue.recordReceivedNativeExit(amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver);
    }

    function doRecordERC20(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver,
        bool unwrap
    ) external returns (uint256 id) {
        id = queue.recordERC20Exit(
            token, amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, unwrap
        );
    }

    function doRecordReceivedERC20(
        address token,
        uint128 amount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id) {
        id = queue.recordReceivedERC20Exit(
            token, amount, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver
        );
    }

    /// @dev Models the product hook: quote fee on the live controller, pay the
    ///      fee leg to the vault, then escrow the NET into the queue in one tx.
    function doFeeThenHoldERC20(
        address controller,
        address vault,
        address token,
        uint256 grossAmount,
        uint32 delaySeconds,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256 id, uint256 fee) {
        ICtrlG.ExitFeeQuote memory q = ICtrlG(controller).quoteExitFee(surfaceId, subProduct, effOrig, grossAmount);
        require(q.active && q.feeAmount > 0, "MockQueueHost: quote not chargeable");
        fee = q.feeAmount;
        IERC20(token).transfer(vault, fee);
        emit FeeTaken(token, vault, fee);
        uint128 net = uint128(q.netAmount);
        id = queue.recordERC20Exit(
            token, net, delaySeconds, surfaceId, subProduct, effOrig, effOwner, receiver, false
        );
        emit NetQueued(id, net);
    }
}
