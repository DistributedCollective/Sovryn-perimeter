// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExitFeeVault} from "../src/ExitFeeVault.sol";

/// @title  Bootstrap ExitFeeVault
/// @notice Configures a freshly-deployed vault proxy (deployed by
///         `01_DeployVault.s.sol`, owned by the deployer wallet) and
///         queues an Ownable2Step handoff to the governance Safe.
///         Mirrors the controller's bootstrap pattern: set state with
///         the deployer wallet in one signed batch, then transfer
///         ownership.
///
///         The script does, in order:
///           1. setDefaultRecipient(EXIT_FEE_VAULT_RECIPIENT)
///              -- the sweep destination. Commonly the final owner itself
///              ("sweeps to itself"), but it is stated, never inferred.
///           2. setAdmin(EXIT_FEE_OPERATIONAL_ADMIN)
///              -- appoints the operational guardian. admin == owner is a
///              supported shape. Runs before the handoff so the vault
///              leaves the bootstrap fully configured in one batch.
///           3. transferOwnership(EXIT_FEE_VAULT_ADMIN)
///              -- queues the Ownable2Step handoff.
///
///         After this script, the governance Safe must call
///         `vault.acceptOwnership()` in a follow-up Safe transaction to
///         complete the handoff. Until then the deployer is still the
///         active owner.
///
/// @dev Usage:
///
///   export RSK_RPC=<chain-rpc-url>
///   EVERY variable below is REQUIRED. The script reverts on a missing one
///   rather than falling back to a default -- a silent default is how a
///   deployment ends up with a recipient or a role holder nobody chose.
///
///   export EXIT_FEE_VAULT_ADMIN=0x...        # final owner
///   export EXIT_FEE_VAULT_RECIPIENT=0x...    # sweep destination
///   export EXIT_FEE_OPERATIONAL_ADMIN=0x...  # operational admin role
///
///   forge script script/02_BootstrapVault.s.sol \
///       --rpc-url $RSK_RPC --broadcast --account deployer \
///       --sig "run(uint256)" <chainId>
contract BootstrapVault is Script {
    using stdJson for string;

    function run(uint256 chainId) external {
        // ─── Locate the proxy from the deployment artifact ───────────────
        string memory artifact =
            vm.readFile(string.concat("deployments/", vm.toString(chainId), "/ExitFeeVault.json"));
        address proxy = artifact.readAddress(".proxyAddress");
        ExitFeeVault vault = ExitFeeVault(payable(proxy));

        // ─── Required: final owner ───────────────────────────────────────
        address finalOwner = vm.envAddress("EXIT_FEE_VAULT_ADMIN");
        require(finalOwner != address(0), "EXIT_FEE_VAULT_ADMIN must be set");

        // ─── Default sweep recipient (required) ──────────────────────────
        address recipient = vm.envAddress("EXIT_FEE_VAULT_RECIPIENT");
        require(recipient != address(0), "EXIT_FEE_VAULT_RECIPIENT must be set");

        // ─── Operational admin (required; may equal the final owner) ─────
        // The guard below catches the misconfig where the DEPLOYER EOA would
        // silently retain operational admin power after the ownership handoff.
        address operationalAdmin = vm.envAddress("EXIT_FEE_OPERATIONAL_ADMIN");
        require(operationalAdmin != address(0), "EXIT_FEE_OPERATIONAL_ADMIN must be set");
        require(
            operationalAdmin != vault.owner(), "operational admin == deployer; set EXIT_FEE_OPERATIONAL_ADMIN"
        );

        console2.log("ExitFeeVault @", proxy);
        console2.log("  chainId:        ", chainId);
        console2.log("  current owner:  ", vault.owner());
        console2.log("  final owner:    ", finalOwner);
        console2.log("  operational admin:", operationalAdmin);
        console2.log("  defaultRecipient target:", recipient);
        console2.log("");

        vm.startBroadcast();

        // ─── 1. Set default recipient ────────────────────────────────────
        vault.setDefaultRecipient(recipient);
        console2.log("setDefaultRecipient:", recipient);

        // ─── 2. Appoint operational admin (BEFORE the handoff) ───────────
        vault.setAdmin(operationalAdmin);
        console2.log("setAdmin:", operationalAdmin);

        // ─── 3. Queue ownership handoff (Ownable2Step) ───────────────────
        vault.transferOwnership(finalOwner);

        vm.stopBroadcast();

        console2.log("");
        console2.log("transferOwnership queued -> pendingOwner =", finalOwner);
        console2.log("");
        console2.log("FINAL STEP (governance Safe): call vault.acceptOwnership()");
        console2.log("Until then, deployer is still the active owner.");
    }
}
