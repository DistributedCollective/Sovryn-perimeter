// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";
import {IExitFeeController} from "../src/interfaces/IExitFeeController.sol";

/// @title  Inspect ExitFeeController
/// @notice Prints the live state of a deployed `ExitFeeController` proxy:
///         ownership, global flags, surface policies, and every configured
///         sub-product / actor override (read from the on-chain enumeration
///         index -- no log scans).
///
/// @dev Usage:
///
///   forge script script/InspectController.s.sol \
///       --rpc-url $RSK_RPC --sig "run(uint256)" <chainId>
///
/// Reads `deployments/<chainId>/ExitFeeController.json` to find the proxy
/// address (committed for mainnet/testnet, gitignored for local anvil).
/// No broadcast: this is a read-only inspector.
contract InspectController is Script {
    using stdJson for string;

    // Every canonical surface, including the ones that ship off -- an
    // inspector that skipped them would report "off" as silence. Keep
    // aligned with docs/SURFACE_REGISTRY.md and the set that
    // 04_BootstrapController.s.sol writes.
    string[5] internal surfaceNames = [
        "PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW",
        "PERIMETER_SURFACE_LENDING_BORROWER_WITHDRAW",
        "PERIMETER_SURFACE_ZERO_WITHDRAW_COLL",
        "PERIMETER_SURFACE_ZERO_CLAIM_SURPLUS",
        "PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY"
    ];

    // EIP-1967 implementation storage slot.
    bytes32 internal constant EIP1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run(uint256 chainId) external view {
        string memory artifact =
            vm.readFile(string.concat("deployments/", vm.toString(chainId), "/ExitFeeController.json"));
        address proxy = artifact.readAddress(".proxyAddress");
        address savedImpl = artifact.readAddress(".implAddress");

        ExitFeeController c = ExitFeeController(proxy);

        console2.log("ExitFeeController @", proxy);
        console2.log("  chainId:     ", chainId);
        console2.log("  saved impl:  ", savedImpl);

        address onchainImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        if (onchainImpl != savedImpl) {
            console2.log("  WARNING on-chain impl differs:", onchainImpl);
            console2.log("  deployment artifact may be stale -- run tools/finalize-deployment.sh");
        }
        console2.log("");

        console2.log(unicode"── Ownership ─────────────────────────────────────────");
        console2.log("  owner:        ", c.owner());
        console2.log("  pendingOwner: ", c.pendingOwner());
        console2.log("  admin:        ", c.admin());
        console2.log("");

        console2.log(unicode"── Global state ──────────────────────────────────────");
        console2.log("  exitFeeEnabled:", c.exitFeeEnabled());
        console2.log("  feeReceiver:   ", c.feeReceiver());
        console2.log("  MAX_BPS:       ", uint256(c.MAX_BPS()));
        console2.log("");

        console2.log(unicode"── Surface policies ──────────────────────────────────");
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            _printSurface(c, surfaceNames[i]);
        }
    }

    function _printSurface(ExitFeeController c, string memory name) internal view {
        bytes32 id = keccak256(bytes(name));

        console2.log(name);
        console2.log("  id:     ", vm.toString(id));

        IExitFeeController.RatePolicy memory sp = c.surfacePolicy(id);
        console2.log(string.concat("  policy: ", _fmtPolicy(sp)));

        address[] memory subs = c.subProductKeys(id);
        if (subs.length > 0) {
            console2.log("  sub-products:");
            for (uint256 j = 0; j < subs.length; j++) {
                IExitFeeController.RatePolicy memory p = c.subProductPolicy(id, subs[j]);
                console2.log(string.concat("    ", vm.toString(subs[j]), "  ", _fmtPolicy(p)));
            }
        }

        address[] memory actors = c.actorKeys(id);
        if (actors.length > 0) {
            console2.log("  actors:");
            for (uint256 j = 0; j < actors.length; j++) {
                IExitFeeController.RatePolicy memory p = c.actorPolicy(id, actors[j]);
                console2.log(string.concat("    ", vm.toString(actors[j]), "  ", _fmtPolicy(p)));
            }
        }
        console2.log("");
    }

    function _fmtPolicy(IExitFeeController.RatePolicy memory p) internal pure returns (string memory) {
        return string.concat(
            "(active=", p.active ? "true" : "false", ", rateBps=", vm.toString(uint256(p.rateBps)), ")"
        );
    }
}
