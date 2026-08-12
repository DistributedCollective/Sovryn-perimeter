// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeVault} from "../src/ExitFeeVault.sol";

/// @title  Deploy ExitFeeVault
/// @notice Deploys the vault impl + ERC1967Proxy with the broadcast wallet
///         (the keystore account used to sign this script) as the INITIAL
///         owner. The deployer keeps owner power for the bootstrap phase;
///         ownership is handed off to the governance Safe via Ownable2Step
///         in `script/02_BootstrapVault.s.sol`, which also sets
///         `defaultRecipient` before the handoff.
///
///         No configuration applied here -- the vault holds no fees and has
///         no `defaultRecipient` set. Run `02_BootstrapVault.s.sol` next.
///
///         After this script runs, finalize the deployment artifact via:
///
///             tools/finalize-deployment.sh ExitFeeVault 01_DeployVault <chainId>
contract DeployVault is Script {
    function run() external returns (address proxy, address impl) {
        vm.startBroadcast();

        // tx.origin under `vm.startBroadcast()` is the broadcast wallet.
        // Initialize sees `newOwner_ == msg.sender` and skips the
        // immediate _transferOwnership, leaving the deployer as owner
        // so 02_BootstrapVault can set defaultRecipient + transferOwnership.
        address deployer = tx.origin;

        impl = address(new ExitFeeVault());
        bytes memory initData = abi.encodeCall(ExitFeeVault.initialize, (deployer));
        proxy = address(new ERC1967Proxy(impl, initData));

        vm.stopBroadcast();

        console2.log("ExitFeeVault impl deployed at:  ", impl);
        console2.log("ExitFeeVault proxy deployed at: ", proxy);
        console2.log("Initial owner (deployer):       ", deployer);
        console2.log("");
        console2.log("Next: run tools/finalize-deployment.sh, then");
        console2.log("      forge script script/02_BootstrapVault.s.sol");
        console2.log("      to set defaultRecipient + hand off to the governance Safe.");
    }
}
