// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";

/// @dev Minimal Exchequer MultiSigWallet surface (ported from
///      Sovryn-smart-contracts `scripts/contractInteraction/mainnet_contracts.json`
///      `multisig` = 0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711).
interface IMultiSigWallet {
    function isOwner(address account) external view returns (bool);
    function submitTransaction(address destination, uint256 value, bytes calldata data)
        external
        returns (uint256 transactionId);
}

/// @title  Deploy ExitFeeController
/// @notice TWO modes, auto-detected from chain state + the deployment record:
///
///         FRESH DEPLOY (no live proxy recorded): deploys the controller impl
///         + ERC1967Proxy with the broadcast wallet (the keystore account used
///         to sign this script) as the INITIAL owner. The deployer keeps owner
///         power for the bootstrap phase; ownership is handed off to the Owner
///         via Ownable2Step in `script/04_BootstrapController.s.sol`.
///
///         IMPL-ONLY (a live proxy is already recorded in
///         `deployments/<chainId>/ExitFeeController.json` AND has on-chain
///         code): deploys ONLY a new `ExitFeeController` implementation
///         (single CREATE, never initialized) and prints the staged-impl
///         warning block. This is the Phase 2 ("Perimeter Delay") step-1
///         shape: the mainnet proxy 0x99994b45...440E already exists, owned
///         by the Exchequer 3-of-7 multisig, so the upgrade itself is a
///         multisig `upgradeTo` transaction (runbook §5.2) — NEVER this
///         script, and NEVER `99_UpgradeProxy` from an EOA in production.
///
///         No configuration applied here -- the controller is left in safe
///         defaults: `exitFeeEnabled = false`, no `feeReceiver`, no policies.
///         Fresh deploys: run `04_BootstrapController.s.sol` next.
///
///         After this script runs, finalize the deployment artifact via:
///
///             tools/finalize-deployment.sh ExitFeeController 03_DeployController <chainId>
///
///         In impl-only mode that records the new implementation as
///         `pendingImplementation` WITHOUT touching the live implAddress.
contract DeployController is Script {
    using stdJson for string;

    /// @dev Exchequer 3-of-7 multisig on RSK mainnet (chain 30), per the
    ///      deployment record / runbook §5.0. Used ONLY as a printed hint when
    ///      EXCHEQUER_MULTISIG is not set; the hint is marked UNVERIFIED.
    address internal constant KNOWN_MAINNET_EXCHEQUER = 0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711;

    /// @dev Bitocracy governance timelocks on RSK mainnet (chain 30), from the
    ///      Sovryn-smart-contracts hardhat deployment data
    ///      (deployment/deployments/rskSovrynMainnet/TimelockAdmin.json and
    ///      TimelockOwner.json). Used ONLY as printed hints identifying the
    ///      proxy owner; the hints are marked UNVERIFIED.
    address internal constant KNOWN_MAINNET_TIMELOCK_ADMIN = 0x6c94c8aa97C08fC31fb06fbFDa90e1E09529FB13;
    address internal constant KNOWN_MAINNET_TIMELOCK_OWNER = 0x967c84b731679E36A344002b8E3CE50620A7F69f;

    /// @dev ERC-1967 implementation storage slot.
    bytes32 internal constant ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (address proxy, address impl) {
        // The initial owner is baked into the proxy's initialize() calldata, so
        // it becomes permanent on-chain state and must be the account that
        // actually signs -- 04_BootstrapController runs from it before handing
        // off to the Owner. (Impl-only mode initializes nothing, but the signer
        // identity still matters: it is the staged impl's deployer of record.)
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

        address existingProxy = _liveRecordedProxy();

        if (existingProxy != address(0)) {
            // ── IMPL-ONLY MODE: a live proxy is recorded. Stage ONLY the new
            //    implementation; never deploy a second proxy, never initialize
            //    the standalone impl, never call upgradeTo from the EOA. If the
            //    exact build is already deployed (recorded pendingImplementation
            //    whose on-chain code hash matches), reuse it — no new CREATE. ──
            address reusable = _reusableStagedImpl();
            if (reusable != address(0)) {
                impl = reusable;
                console2.log("Implementation already deployed with matching bytecode;");
                console2.log("reusing, no new CREATE:                ", impl);
            } else {
                vm.startBroadcast();
                impl = address(new ExitFeeController());
                vm.stopBroadcast();
            }

            proxy = existingProxy;
            _warnImplOnly(proxy, impl, deployer);
            return (proxy, impl);
        }

        // ── FRESH DEPLOY MODE: impl + proxy, initialized to the deployer. ──
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
        console2.log("      to configure + hand off to the Owner.");
    }

    /// @dev Detect an already-live controller proxy: read the deployment
    ///      artifact for THIS chain and confirm the recorded proxyAddress
    ///      actually has code on-chain. Returns address(0) when there is no
    ///      artifact, no parseable proxyAddress, or no code at the recorded
    ///      address (stale/foreign record) -- in all those cases the fresh
    ///      deploy path is the correct one.
    function _liveRecordedProxy() internal view returns (address) {
        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), "/ExitFeeController.json");
        string memory artifact;
        try vm.readFile(path) returns (string memory raw) {
            artifact = raw;
        } catch {
            return address(0);
        }
        address recorded;
        if (artifact.keyExists(".proxyAddress")) {
            recorded = artifact.readAddress(".proxyAddress");
        } else {
            return address(0);
        }
        if (recorded == address(0) || recorded.code.length == 0) {
            return address(0);
        }
        return recorded;
    }

    /// @dev Return the recorded pendingImplementation when its on-chain code
    ///      still matches the recorded bytecode hash — the exact build is
    ///      already deployed, so reuse the address instead of redeploying.
    ///      Returns address(0) when there is nothing safe to reuse.
    function _reusableStagedImpl() internal view returns (address) {
        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), "/ExitFeeController.json");
        string memory artifact;
        try vm.readFile(path) returns (string memory raw) {
            artifact = raw;
        } catch {
            return address(0);
        }
        if (!artifact.keyExists(".pendingImplementation.implAddress")) {
            return address(0);
        }
        address staged = artifact.readAddress(".pendingImplementation.implAddress");
        if (staged == address(0) || staged.code.length == 0) {
            return address(0);
        }
        if (artifact.keyExists(".pendingImplementation.implBytecodeHash")) {
            bytes32 want = artifact.readBytes32(".pendingImplementation.implBytecodeHash");
            if (keccak256(staged.code) != want) {
                return address(0);
            }
        }
        return staged;
    }

    /// @dev Staged-implementation guidance + upgrade routing. Reads go THROUGH
    ///      the proxy (owner() + ERC-1967 slot), so they describe live state.
    ///      Exchequer-owned proxy + Exchequer-owner signer: the script itself
    ///      submits the multisig upgrade transaction (submitTransaction of
    ///      upgradeTo(newImpl)). Otherwise it prints calldata/path only.
    ///      EOA upgradeTo remains forbidden.
    function _warnImplOnly(address proxy, address impl, address deployer) internal {
        address currentOwner = ExitFeeController(proxy).owner();
        address exchequerEnv = vm.envOr("EXCHEQUER_MULTISIG", address(0));
        address liveImpl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPL_SLOT))));

        console2.log("");
        console2.log(unicode"════════════════════════════════════════════════════════════════");
        console2.log(unicode"  IMPL-ONLY MODE — existing live proxy detected; NO proxy deployed");
        console2.log(unicode"════════════════════════════════════════════════════════════════");
        console2.log("  Implementation (staged target):              ", impl);
        console2.log("  Existing proxy (unchanged):                  ", proxy);
        console2.log("  Proxy live implementation (ERC-1967 slot):   ", liveImpl);
        console2.log("  Proxy current on-chain owner():              ", currentOwner);
        console2.log("  Deployer/signer of this run:                 ", deployer);
        console2.log("");

        if (liveImpl == impl) {
            console2.log("  The proxy ALREADY runs this implementation -- the upgrade is done;");
            console2.log("  nothing to submit. Finalize the record with");
            console2.log("    tools/finalize-deployment.sh --multisig-upgrade ...");
            console2.log(unicode"════════════════════════════════════════════════════════════════");
            return;
        }

        bytes memory upgradeData = abi.encodeWithSignature("upgradeTo(address)", impl);

        if (exchequerEnv != address(0) && currentOwner == exchequerEnv) {
            console2.log("  Owner matches EXCHEQUER_MULTISIG (env-confirmed Exchequer).");
            _submitOrPrintExchequerUpgrade(proxy, deployer, exchequerEnv, upgradeData);
        } else if (block.chainid == 30 && currentOwner == KNOWN_MAINNET_EXCHEQUER) {
            console2.log("  Owner matches the known mainnet Exchequer 0x924f5ad3...dc711 (UNVERIFIED:");
            console2.log("  EXCHEQUER_MULTISIG is not set, so this is a hard-coded hint, not a");
            console2.log("  confirmed identity).");
            _submitOrPrintExchequerUpgrade(proxy, deployer, KNOWN_MAINNET_EXCHEQUER, upgradeData);
        } else if (block.chainid == 30 && currentOwner == KNOWN_MAINNET_TIMELOCK_OWNER) {
            console2.log("  Owner matches the known mainnet Bitocracy TimelockOwner");
            console2.log("  0x967c84b7...A7F69f (UNVERIFIED hint). => A GovernorOwner SIP is");
            console2.log("  REQUIRED to complete this upgrade (upgradeTo through the timelock).");
            console2.log("  DO NOT MERGE this branch into any release/main branch until the SIP");
            console2.log("  has executed and getImplementation reads the staged impl on-chain.");
        } else if (block.chainid == 30 && currentOwner == KNOWN_MAINNET_TIMELOCK_ADMIN) {
            console2.log("  Owner matches the known mainnet Bitocracy TimelockAdmin");
            console2.log("  0x6c94c8aa...29FB13 (UNVERIFIED hint). => A GovernorAdmin SIP is");
            console2.log("  REQUIRED to complete this upgrade (upgradeTo through the timelock).");
            console2.log("  DO NOT MERGE this branch into any release/main branch until the SIP");
            console2.log("  has executed and getImplementation reads the staged impl on-chain.");
        } else {
            // Do NOT guess silently: print both candidate paths.
            console2.log("  Owner is NOT confirmed as the Exchequer multisig. Determine the upgrade");
            console2.log("  path manually before proceeding:");
            console2.log("   - if the owner is the Exchequer/multisig: a 3-of-7 multisig upgradeTo");
            console2.log("     transaction is required (runbook section 5.2);");
            console2.log("   - if the owner is a governance timelock: a SIP / governance proposal is");
            console2.log("     required to execute the upgrade.");
            console2.log("  DO NOT MERGE this branch into any release/main branch until the upgrade");
            console2.log("  has executed and getImplementation reads the staged impl on-chain.");
        }
        console2.log("");
        console2.log("  EOA upgrades are FORBIDDEN for production: do NOT run 99_UpgradeProxy.");
        console2.log("");
        console2.log("  Next: record the staged implementation with");
        console2.log(
            string.concat(
                "    tools/finalize-deployment.sh ExitFeeController 03_DeployController ",
                vm.toString(block.chainid)
            )
        );
        console2.log("  (writes pendingImplementation into the artifact; the live implAddress is");
        console2.log("  NOT touched until the multisig upgrade finalizes).");
        console2.log(unicode"════════════════════════════════════════════════════════════════");
    }

    /// @dev Exchequer path: submit the multisig upgrade transaction when the
    ///      signer is an Exchequer owner; otherwise print the exact calldata
    ///      and instructions. The executing confirmation must use explicit
    ///      3,000,000 gas; completion is proven by state readback only (the
    ///      MultiSigWallet swallows gas-starved inner calls).
    function _submitOrPrintExchequerUpgrade(
        address proxy,
        address deployer,
        address multisig,
        bytes memory upgradeData
    ) internal {
        console2.log("  => Completing this upgrade requires a 3-of-7 multisig upgradeTo(newImpl)");
        console2.log("     transaction from the Exchequer wallet (runbook section 5.2).");
        if (block.chainid == 30 && IMultiSigWallet(multisig).isOwner(deployer)) {
            console2.log("  Signer IS an Exchequer owner -- submitting the upgrade transaction");
            console2.log("  (submitTransaction of upgradeTo(newImpl)). It executes only after the");
            console2.log("  remaining confirmations; the EXECUTING confirmation must set explicit");
            console2.log("  3,000,000 gas, and completion must be verified by state readback");
            console2.log("  (getImplementation == staged impl), never by the outer receipt alone.");
            vm.startBroadcast();
            uint256 transactionId = IMultiSigWallet(multisig).submitTransaction(proxy, 0, upgradeData);
            vm.stopBroadcast();
            console2.log("  Exchequer transaction id submitted:        ", transactionId);
        } else {
            console2.log("  Signer is NOT an Exchequer owner -- cannot submit from this account.");
            console2.log("  Re-run this script with an Exchequer owner account to submit, or use");
            console2.log("  this exact calldata (destination = controller proxy, value = 0):");
            console2.logBytes(upgradeData);
        }
    }
}
