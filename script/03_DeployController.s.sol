// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";

/// @title  Deploy ExitFeeController
/// @notice Deploys the controller impl + ERC1967Proxy with the broadcast
///         wallet (the keystore account used to sign this script) as the
///         INITIAL owner. The deployer keeps owner power for the bootstrap
///         phase; ownership is handed off to the governance Safe via
///         Ownable2Step in `script/04_BootstrapController.s.sol`.
///
///         No configuration applied here -- the controller is left in safe
///         defaults: `exitFeeEnabled = false`, no `feeReceiver`, no policies.
///         Run `04_BootstrapController.s.sol` next to configure and queue
///         the ownership transfer.
///
///         After this script runs, finalize the deployment artifact via:
///
///             tools/finalize-deployment.sh ExitFeeController 03_DeployController <chainId>
contract DeployController is Script {
    function run() external returns (address proxy, address impl) {
        vm.startBroadcast();

        // tx.origin under `vm.startBroadcast()` is the broadcast wallet
        // (the --account or --private-key the script was invoked with).
        // We pass it as initial owner so the deployer can run the
        // activation sequence in 04_BootstrapController before handing
        // off to the governance Safe.
        address deployer = tx.origin;

        impl = address(new ExitFeeController());
        bytes memory initData = abi.encodeCall(ExitFeeController.initialize, (deployer));
        proxy = address(new ERC1967Proxy(impl, initData));

        vm.stopBroadcast();

        console2.log("ExitFeeController impl deployed at:  ", impl);
        console2.log("ExitFeeController proxy deployed at: ", proxy);
        console2.log("Initial owner (deployer):            ", deployer);
        console2.log("");
        console2.log("Next: run tools/finalize-deployment.sh, then");
        console2.log("      forge script script/04_BootstrapController.s.sol");
        console2.log("      to configure + hand off to the governance Safe.");
    }
}
