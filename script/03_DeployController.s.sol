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
        // The initial owner is baked into the proxy's initialize() calldata, so
        // it becomes permanent on-chain state and must be the account that
        // actually signs -- 04_BootstrapController runs from it before handing
        // off to the governance Safe.
        //
        // Read it from the unlocked signer, NOT from tx.origin: forge resolves
        // tx.origin during the SIMULATION pass, where it is a placeholder of
        // forge's own (a hash-derived address with no private key). Encoding
        // that placeholder would sign the deploy correctly while installing an
        // owner nobody controls, bricking the proxy. `vm.getWallets()` returns
        // the wallets forge has actually unlocked, during simulation, so it is
        // the same address that will sign the broadcast. Exactly one is
        // required: zero means no signer was supplied, more than one is
        // ambiguous about who ends up owning the proxy.
        address[] memory wallets = vm.getWallets();
        require(
            wallets.length == 1,
            "expected exactly one unlocked signer (pass a single --account or --private-key)"
        );
        address deployer = wallets[0];

        vm.startBroadcast();

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
