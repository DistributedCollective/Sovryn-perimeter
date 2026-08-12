// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title  Upgrade a UUPS proxy
/// @notice Generic upgrade script for the ColFee proxies. Takes the proxy
///         address and the new implementation address from env, calls
///         `upgradeTo(newImpl)`, and emits the impl pointer change to the
///         broadcast log.
///
///         Required env vars:
///           PROXY        -- address of the ERC1967Proxy to upgrade
///           NEW_IMPL     -- address of the new implementation contract
///
///         **Run upgrade-safety check FIRST**:
///           tools/check-upgrade-safety.sh <ContractName> <chainId> $NEW_IMPL
///
///         That verifies (1) the saved deployment artifact still matches
///         the on-chain active impl, (2) the candidate at NEW_IMPL is
///         deployed and non-empty (NOT a build-vs-bytecode equality check
///         -- UUPS impls embed __self as an address immutable, so two
///         impls compiled from the same source at different addresses
///         have different bytecode; auditor verifies source via
///         `forge verify-bytecode --etherscan-api-key ...` or sourcify),
///         and (3) the storage layout is upgrade-safe (variable
///         preservation with full struct/enum member equivalence,
///         __gap accounting with slot spans, no out-of-namespace spillage).
///
/// @dev    Broadcasting account must be the proxy owner -- the contract's
///         `_authorizeUpgrade(newImpl)` rejects everything else. After this
///         script runs, finalize the new deployment artifact:
///
///             tools/finalize-deployment.sh <ContractName> 99_UpgradeProxy <chainId>
contract UpgradeProxy is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY");
        address newImpl = vm.envAddress("NEW_IMPL");
        require(proxy != address(0), "PROXY must be set");
        require(newImpl != address(0), "NEW_IMPL must be set");

        vm.startBroadcast();
        UUPSUpgradeable(proxy).upgradeTo(newImpl);
        vm.stopBroadcast();

        console2.log("Upgraded proxy:  ", proxy);
        console2.log("New impl active: ", newImpl);
    }
}
