// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";
import {IExitFeeController} from "../src/interfaces/IExitFeeController.sol";

/// @title  Bootstrap ExitFeeController
/// @notice Runs the canonical activation sequence on a freshly-deployed
///         controller (deployed by `03_DeployController.s.sol`, owned by
///         the deployer wallet) and queues an Ownable2Step handoff to the
///         governance Safe. Mirrors the order in `docs/OPERATIONS.md` --
///         setFeeReceiver -> surface policies -> global enable -> setAdmin
///         -> transferOwnership.
///
///         setAdmin precedes the handoff so the controller leaves the
///         bootstrap fully configured in one batch. admin == final owner
///         is a supported shape: one address may hold both roles.
///
///         After this script, the governance Safe must call
///         `controller.acceptOwnership()` in a follow-up Safe transaction
///         to complete the handoff. Until then, the deployer is still the
///         active owner but `pendingOwner()` is set to the Safe; no other
///         address can hijack the handoff.
///
/// @dev Usage:
///
///   export RSK_RPC=<chain-rpc-url>
///   EVERY variable below is REQUIRED. The script reverts on a missing one
///   rather than falling back to a default -- a silent default is how a
///   deployment ends up with a rate, a receiver or a switch nobody chose.
///
///   export EXIT_FEE_CONTROLLER_ADMIN=0x...        # final owner
///   export EXIT_FEE_OPERATIONAL_ADMIN=0x...       # operational admin role
///   export EXIT_FEE_VAULT_PROXY=0x...             # fee receiver
///   export PERIMETER_LENDING_LENDER_BPS=10
///   export PERIMETER_LENDING_BORROWER_BPS=10
///   export PERIMETER_ZERO_WITHDRAW_COLL_BPS=10
///   export PERIMETER_ZERO_CLAIM_SURPLUS_BPS=10
///   export PERIMETER_ENABLE_AT_DEPLOY=false          # mainnet: false
///
///   forge script script/04_BootstrapController.s.sol \
///       --rpc-url $RSK_RPC --broadcast --account deployer \
///       --sig "run(uint256)" <chainId>
///
///      Surface IDs are derived as `keccak256("PERIMETER:<NAME>")` per
///      `docs/SURFACE_REGISTRY.md`.
///
///      ALL five registered surfaces are written here — the deploy
///      transaction is a complete statement of intent, so no surface can be
///      silently forgotten and no absence has to be interpreted.
///
///      The four surfaces with a consumer go in ACTIVE at the rate given (0
///      included — a 0-bps active surface is live and free, and its
///      per-pool/per-actor overrides still apply). The AMM surface has no
///      consumer in this release and goes in OFF (`active = false, 0`): the
///      gate is shut, so no override beneath it can charge either. Turning it
///      on later is one owner `setSurfacePolicy` call with the intended rate.
contract BootstrapController is Script {
    using stdJson for string;

    uint16 internal constant MAX_BPS = 10_000;

    function run(uint256 chainId) external {
        // ─── Locate the proxy from the deployment artifact ───────────────
        string memory artifact =
            vm.readFile(string.concat("deployments/", vm.toString(chainId), "/ExitFeeController.json"));
        address proxy = artifact.readAddress(".proxyAddress");
        ExitFeeController controller = ExitFeeController(proxy);

        // ─── Required: final owner ───────────────────────────────────────
        address finalOwner = vm.envAddress("EXIT_FEE_CONTROLLER_ADMIN");
        require(finalOwner != address(0), "EXIT_FEE_CONTROLLER_ADMIN must be set");

        // ─── Operational admin (required; may equal the final owner) ─────
        // The guard below catches the misconfig where the DEPLOYER EOA would
        // silently retain operational admin power after the ownership handoff.
        address operationalAdmin = vm.envAddress("EXIT_FEE_OPERATIONAL_ADMIN");
        require(operationalAdmin != address(0), "EXIT_FEE_OPERATIONAL_ADMIN must be set");
        require(
            operationalAdmin != controller.owner(),
            "operational admin == deployer; set EXIT_FEE_OPERATIONAL_ADMIN"
        );

        // ─── Activation config (all required — no silent defaults) ───────
        // vm.envAddress/envUint/envBool revert when the variable is absent,
        // so a forgotten value stops the deploy instead of shipping a zero.
        address vaultProxy = vm.envAddress("EXIT_FEE_VAULT_PROXY");
        require(vaultProxy != address(0), "EXIT_FEE_VAULT_PROXY must be set");
        uint256 lenderBps = vm.envUint("PERIMETER_LENDING_LENDER_BPS");
        uint256 borrowerBps = vm.envUint("PERIMETER_LENDING_BORROWER_BPS");
        uint256 zeroBps = vm.envUint("PERIMETER_ZERO_WITHDRAW_COLL_BPS");
        uint256 surplusBps = vm.envUint("PERIMETER_ZERO_CLAIM_SURPLUS_BPS");
        bool enableNow = vm.envBool("PERIMETER_ENABLE_AT_DEPLOY");

        console2.log("ExitFeeController @", proxy);
        console2.log("  chainId:        ", chainId);
        console2.log("  current owner:  ", controller.owner());
        console2.log("  final owner:    ", finalOwner);
        console2.log("  operational admin:", operationalAdmin);
        console2.log("");

        vm.startBroadcast();

        // ─── 1. Wire fee receiver ────────────────────────────────────────
        controller.setFeeReceiver(vaultProxy);
        console2.log("setFeeReceiver:", vaultProxy);

        // ─── 2-6. Surface policies — all five written, no exceptions ──────
        // Writing every surface leaves the deploy transaction as a complete
        // statement of intent: no surface can be silently forgotten, and
        // "absent" is never mistaken for "deliberate".
        _setSurface(controller, "PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW", lenderBps, true);
        _setSurface(controller, "PERIMETER_SURFACE_LENDING_BORROWER_WITHDRAW", borrowerBps, true);
        _setSurface(controller, "PERIMETER_SURFACE_ZERO_WITHDRAW_COLL", zeroBps, true);
        _setSurface(controller, "PERIMETER_SURFACE_ZERO_CLAIM_SURPLUS", surplusBps, true);
        // AMM has no consumer in this release: written explicitly OFF so the
        // deploy log carries the decision rather than an absence.
        _setSurface(controller, "PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY", 0, false);

        // ─── 7. Global switch ────────────────────────────────────────────
        if (enableNow) {
            controller.setExitFeeEnabled(true);
            console2.log("setExitFeeEnabled: true");
        } else {
            console2.log("setExitFeeEnabled: NOT enabled (PERIMETER_ENABLE_AT_DEPLOY=false)");
        }

        // ─── 8. Appoint operational admin (BEFORE the handoff) ───────────
        controller.setAdmin(operationalAdmin);
        console2.log("setAdmin:", operationalAdmin);

        // ─── 9. Queue ownership handoff (Ownable2Step) ───────────────────
        controller.transferOwnership(finalOwner);

        vm.stopBroadcast();

        console2.log("");
        console2.log("transferOwnership queued -> pendingOwner =", finalOwner);
        console2.log("");
        console2.log("FINAL STEP (governance Safe): call controller.acceptOwnership()");
        console2.log("Until then, deployer is still the active owner.");
        console2.log("Verify state: forge script script/InspectController.s.sol \\");
        console2.log("              --rpc-url $RSK_RPC --sig 'run(uint256)' <chainId>");
    }

    /// @dev Writes `name`'s surface policy. `active = false` lands the same
    ///      gate state an untouched surface reads; its value is the
    ///      `SurfacePolicySet` event, which puts the deliberate "off" on the
    ///      record instead of leaving an absence to interpret. A rate may be
    ///      stored on an inactive surface — the gate, not the rate, decides
    ///      whether anything is charged.
    function _setSurface(ExitFeeController c, string memory name, uint256 rateBps, bool active) internal {
        require(rateBps <= MAX_BPS, "rateBps > MAX_BPS");
        bytes32 id = keccak256(abi.encodePacked("PERIMETER:", name));
        c.setSurfacePolicy(id, IExitFeeController.RatePolicy({active: active, rateBps: uint16(rateBps)}));
        console2.log(
            string.concat("setSurfacePolicy ", name, active ? " (active)" : " (OFF - no consumer)"), rateBps
        );
    }
}
