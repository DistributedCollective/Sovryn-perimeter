// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitFeeController} from "../../src/interfaces/IExitFeeController.sol";

interface IQueueActorBlockSingle {
    function blacklist(address actor) external;
    function unfreeze(address actor) external;
    function unblacklist(address actor) external;
}

interface IQueueActorBlockBatch {
    function freeze(address[] calldata actors) external;
    function blacklist(address[] calldata actors) external;
    function unfreeze(address[] calldata actors) external;
    function unblacklist(address[] calldata actors) external;
    function downgradeToFrozen(address[] calldata actors) external;
}

interface IPerimeterOwnershipUpgrade {
    function transferOwnership(address newOwner) external;
    function upgradeToAndCall(address implementation, bytes calldata data) external payable;
}

contract PerimeterAccessTest is Test {
    ExitDelayQueue internal queue;
    ExitFeeController internal controller;
    address internal constant ADMIN = address(0xA01);
    address internal constant OUTSIDER = address(0xA02);
    address internal constant ACTOR = address(0xA03);
    bytes32 internal constant SURFACE = bytes32("withdrawal");

    function setUp() public {
        queue = ExitDelayQueue(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new ExitDelayQueue()),
                        abi.encodeCall(
                            ExitDelayQueue.initialize,
                            (address(this), ADMIN, address(0xA04), uint32(86400), new address[](0))
                        )
                    )
                )
            )
        );
        controller = ExitFeeController(
            address(
                new ERC1967Proxy(
                    address(new ExitFeeController()),
                    abi.encodeCall(ExitFeeController.initialize, (address(this)))
                )
            )
        );
        controller.setAdmin(ADMIN);
    }

    function _denied(address target, bytes memory data, bytes memory expected) internal {
        vm.prank(OUTSIDER);
        (bool ok, bytes memory reason) = target.call(data);
        assertFalse(ok, "unauthorized call succeeded");
        assertEq(reason, expected, "wrong access error");
    }

    function _ownerDenied(address target, bytes memory data) internal {
        _denied(target, data, abi.encodeWithSignature("Error(string)", "Ownable: caller is not the owner"));
    }

    function _actors() internal pure returns (address[] memory actors) {
        actors = new address[](1);
        actors[0] = ACTOR;
    }

    function test_queueScalarAndBatchBlockVariantsRejectOutsider() public {
        address[] memory actors = _actors();
        bytes memory reason = abi.encodeWithSelector(IExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockSingle.blacklist, (ACTOR)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockSingle.unfreeze, (ACTOR)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockSingle.unblacklist, (ACTOR)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockBatch.freeze, (actors)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockBatch.blacklist, (actors)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockBatch.unfreeze, (actors)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockBatch.unblacklist, (actors)), reason);
        _denied(address(queue), abi.encodeCall(IQueueActorBlockBatch.downgradeToFrozen, (actors)), reason);
    }

    function test_queueConfigurationVariantsRejectOutsider() public {
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: ACTOR,
            token: address(0),
            destination: ACTOR,
            topUpPool: false
        });
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.removeAllowedSource, (ACTOR)));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.removeRecoveryRoute, (SURFACE)));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.setAdmin, (ACTOR)));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.setMinimumDelaySeconds, (uint32(86400))));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.setNativePusher, (ACTOR)));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.setRecoveryRoute, (route)));
        _ownerDenied(address(queue), abi.encodeCall(ExitDelayQueue.setTopUpFeasible, (SURFACE, true)));
    }

    function test_queueOwnershipAndUpgradeCallRejectOutsider() public {
        _ownerDenied(address(queue), abi.encodeCall(IPerimeterOwnershipUpgrade.transferOwnership, (ACTOR)));
        _ownerDenied(
            address(queue), abi.encodeCall(IPerimeterOwnershipUpgrade.upgradeToAndCall, (ACTOR, bytes("")))
        );
    }

    function test_controllerPolicyVariantsRejectOutsider() public {
        address[] memory actors = _actors();
        IExitFeeController.RatePolicy memory policy = IExitFeeController.RatePolicy(true, 10);
        IExitFeeController.RatePolicy[] memory policies = new IExitFeeController.RatePolicy[](1);
        policies[0] = policy;
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setSubProductPolicy, (SURFACE, ACTOR, policy))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.setActorPolicy, (SURFACE, ACTOR, policy))
        );
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setSubProductPolicies, (SURFACE, actors, policies))
        );
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setActorPolicies, (SURFACE, actors, policies))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeActorPolicy, (SURFACE, ACTOR))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeSubProductPolicies, (SURFACE, actors))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeActorPolicies, (SURFACE, actors))
        );
    }

    function test_controllerBypassVariantsRejectOutsider() public {
        address[] memory actors = _actors();
        IExitFeeController.DelayBypassPolicy memory policy = IExitFeeController.DelayBypassPolicy(true, true);
        IExitFeeController.DelayBypassPolicy[] memory policies = new IExitFeeController.DelayBypassPolicy[](1);
        policies[0] = policy;
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setSubProductBypass, (SURFACE, ACTOR, policy))
        );
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setSubProductBypasses, (SURFACE, actors, policies))
        );
        _ownerDenied(
            address(controller),
            abi.encodeCall(ExitFeeController.setActorBypasses, (SURFACE, actors, policies))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeSubProductBypass, (SURFACE, ACTOR))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeActorBypass, (SURFACE, ACTOR))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeSubProductBypasses, (SURFACE, actors))
        );
        _ownerDenied(
            address(controller), abi.encodeCall(ExitFeeController.removeActorBypasses, (SURFACE, actors))
        );
    }

    function test_controllerOwnershipAndUpgradeCallRejectOutsider() public {
        _ownerDenied(
            address(controller), abi.encodeCall(IPerimeterOwnershipUpgrade.transferOwnership, (ACTOR))
        );
        _ownerDenied(
            address(controller),
            abi.encodeCall(IPerimeterOwnershipUpgrade.upgradeToAndCall, (ACTOR, bytes("")))
        );
    }
}
