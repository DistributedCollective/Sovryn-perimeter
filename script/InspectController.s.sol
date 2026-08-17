// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";
import {IExitFeeController} from "../src/interfaces/IExitFeeController.sol";
import {ExitDelayQueue} from "../src/ExitDelayQueue.sol";

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
    // aligned with the registered surface names and the set that
    // 04_BootstrapController.s.sol writes.
    string[5] internal surfaceNames = [
        "SURFACE_LENDING_LENDER_WITHDRAW",
        "SURFACE_LENDING_BORROWER_WITHDRAW",
        "SURFACE_ZERO_WITHDRAW_COLL",
        "SURFACE_ZERO_CLAIM_SURPLUS",
        "SURFACE_AMM_REMOVE_LIQUIDITY"
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

        console2.log(unicode"── Delay perimeter (global) ──────────────────────────");
        console2.log("  securityPerimeterEnabled:", c.securityPerimeterEnabled());
        console2.log("  globalDelaySeconds:      ", uint256(c.globalDelaySeconds()));
        console2.log("  admin:                   ", c.admin());
        console2.log("");

        // ── single-guardian identity assertion. The controller keeps its
        //    OWN local `admin` (used ONLY by the kill switch) and NEVER reads
        //    queue.admin() at runtime (that would couple the kill switch to queue
        //    liveness and break). Instead this tooling asserts, at
        //    deploy/inspect time, that the two guardians are ONE identity so a
        //    single Safe bundle rotates both. Off unless the queue artifact exists.
        _assertSingleGuardian(c, chainId);

        console2.log(unicode"── Surface policies + delay bypass ───────────────────");
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            _printSurface(c, surfaceNames[i]);
        }

        // ── dump EVERY delay-bypass + passthrough entry via the
        //    on-chain enumeration getters — NOT the hardcoded surface list above.
        //    A bypass / passthrough under an arbitrary surfaceId (never registered
        //    as a named fee surface) is still fully surfaced here.
        _printDelayBypassRegistry(c);
        _printPassthroughRegistry(c);
    }

    /// @dev single-guardian assertion. Reads the queue proxy from its
    ///      deployment artifact (if present) and requires `controller.admin ==
    ///      queue.admin`. This is a DEPLOY/INSPECT-time identity check ONLY — the
    ///      controller never reads the queue at runtime (kill-switch
    ///      queue-independence). Skipped with a notice when the queue
    ///      artifact is absent (e.g. controller-only inspection).
    function _assertSingleGuardian(ExitFeeController c, uint256 chainId) internal view {
        string memory path = string.concat("deployments/", vm.toString(chainId), "/ExitDelayQueue.json");
        try vm.readFile(path) returns (string memory queueArtifact) {
            address queueProxy = queueArtifact.readAddress(".proxyAddress");
            address queueAdmin = ExitDelayQueue(payable(queueProxy)).admin();
            address ctrlAdmin = c.admin();
            console2.log(unicode"── Single-guardian identity ──────────────────");
            console2.log("  controller.admin:", ctrlAdmin);
            console2.log("  queue.admin:     ", queueAdmin);
            require(ctrlAdmin == queueAdmin, "controller.admin != queue.admin (single guardian violated)");
            console2.log("  OK: single guardian identity holds");
            console2.log("");
        } catch {
            console2.log(unicode"── Single-guardian identity ──────────────────");
            console2.log("  queue artifact absent -- skipping controller.admin==queue.admin check");
            console2.log("");
        }
    }

    /// @dev the complete surfaceId probe set that drives BOTH the
    ///      bypass and passthrough dumps —
    ///        `bypassSurfaceIds()` ∪ `passthroughSurfaceIds()` ∪ the named surfaces.
    ///      The `bypassSurfaceIds()` / `passthroughSurfaceIds()` master sets are
    ///      ANY-TIER-TOUCHED: a surface carrying ONLY a sub-product- or actor-tier
    ///      bypass (or ONLY a passthrough entry) is present here even though it was
    ///      never passed to `setSurfaceBypass`. The named fee surfaces are folded in
    ///      so the human-readable rows always render, and duplicates are collapsed.
    ///      Root cause of the old gap (`surfaceBypassKeys()`-only driver): the master
    ///      id-set was populated solely by `setSurfaceBypass`, so an actor-only bypass
    ///      or a passthrough-only entry under an arbitrary surfaceId was undiscoverable.
    function _probeSurfaceIds(ExitFeeController c) internal view returns (bytes32[] memory) {
        bytes32[] memory bypassIds = c.bypassSurfaceIds();
        bytes32[] memory passIds = c.passthroughSurfaceIds();

        // Upper bound on the union size; trim to the deduped count below.
        bytes32[] memory acc = new bytes32[](bypassIds.length + passIds.length + surfaceNames.length);
        uint256 n = 0;

        // Named fee surfaces first (stable ordering; keeps human rows at the top).
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            n = _pushUnique(acc, n, keccak256(abi.encodePacked("COLFEE:", surfaceNames[i])));
        }
        for (uint256 i = 0; i < bypassIds.length; i++) {
            n = _pushUnique(acc, n, bypassIds[i]);
        }
        for (uint256 i = 0; i < passIds.length; i++) {
            n = _pushUnique(acc, n, passIds[i]);
        }

        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = acc[i];
        }
        return out;
    }

    /// @dev Append `id` to `acc[0..n)` iff not already present; returns the new n.
    function _pushUnique(bytes32[] memory acc, uint256 n, bytes32 id) internal pure returns (uint256) {
        for (uint256 i = 0; i < n; i++) {
            if (acc[i] == id) return n;
        }
        acc[n] = id;
        return n + 1;
    }

    /// @dev Human-readable label for a surfaceId: the canonical name if it is a
    ///      named fee surface, else the raw bytes32.
    function _labelFor(bytes32 id) internal view returns (string memory) {
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            if (id == keccak256(abi.encodePacked("COLFEE:", surfaceNames[i]))) {
                return surfaceNames[i];
            }
        }
        return vm.toString(id);
    }

    /// @dev dump every surface / sub-product / actor delay-bypass
    ///      entry, driven by the ANY-TIER-TOUCHED probe set (`bypassSurfaceIds()` ∪
    ///      `passthroughSurfaceIds()` ∪ named surfaces) so a sub-product- or
    ///      actor-only bypass under an arbitrary surfaceId is never missed. A probed
    ///      surfaceId with no live bypass entry at any tier prints nothing.
    function _printDelayBypassRegistry(ExitFeeController c) internal view {
        console2.log(unicode"── Delay-bypass registry (enumerated) ────────────────");
        bytes32[] memory ids = _probeSurfaceIds(c);
        bool anyPrinted = false;
        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 id = ids[i];

            IExitFeeController.DelayBypassPolicy memory sb = c.surfaceBypass(id);
            address[] memory subBp = c.subProductBypassKeys(id);
            address[] memory actorBp = c.actorBypassKeys(id);

            // Skip a probed id that carries no bypass entry at any tier (e.g. a
            // named fee surface or a passthrough-only surface with no bypass).
            if (!sb.active && !sb.bypass && subBp.length == 0 && actorBp.length == 0) {
                continue;
            }
            anyPrinted = true;

            console2.log(string.concat("  surface ", _labelFor(id), "  ", _fmtBypass(sb)));
            for (uint256 j = 0; j < subBp.length; j++) {
                IExitFeeController.DelayBypassPolicy memory p = c.subProductBypass(id, subBp[j]);
                console2.log(string.concat("    sub-product ", vm.toString(subBp[j]), "  ", _fmtBypass(p)));
            }
            for (uint256 j = 0; j < actorBp.length; j++) {
                IExitFeeController.DelayBypassPolicy memory p = c.actorBypass(id, actorBp[j]);
                console2.log(string.concat("    actor       ", vm.toString(actorBp[j]), "  ", _fmtBypass(p)));
            }
        }
        if (!anyPrinted) {
            console2.log("  (no delay bypasses configured at any tier)");
        }
        console2.log("");
    }

    /// @dev dump the surface-scoped passthrough registry via
    ///      `passthroughKeys(surfaceId)`, driven by the SAME any-tier-touched probe
    ///      set as the bypass dump (`bypassSurfaceIds()` ∪ `passthroughSurfaceIds()`
    ///      ∪ named surfaces). A passthrough-only surface (no bypass entry, not a
    ///      named fee surface) is discoverable via `passthroughSurfaceIds()`.
    function _printPassthroughRegistry(ExitFeeController c) internal view {
        console2.log(unicode"── Passthrough registry (enumerated) ─────────────────");
        bytes32[] memory ids = _probeSurfaceIds(c);
        bool anyPrinted = false;
        for (uint256 i = 0; i < ids.length; i++) {
            anyPrinted = _printPassthroughFor(c, ids[i], _labelFor(ids[i])) || anyPrinted;
        }
        if (!anyPrinted) {
            console2.log("  (no passthrough actors configured)");
        }
        console2.log("");
    }

    function _printPassthroughFor(ExitFeeController c, bytes32 id, string memory label)
        internal
        view
        returns (bool)
    {
        address[] memory pks = c.passthroughKeys(id);
        if (pks.length == 0) return false;
        console2.log(string.concat("  ", label, ":"));
        for (uint256 j = 0; j < pks.length; j++) {
            console2.log(string.concat("    ", vm.toString(pks[j])));
        }
        return true;
    }

    function _printSurface(ExitFeeController c, string memory name) internal view {
        bytes32 id = keccak256(abi.encodePacked("COLFEE:", name));

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
        // NOTE: delay-bypass + passthrough tiers are dumped separately in
        // `_printDelayBypassRegistry` / `_printPassthroughRegistry`, driven by the
        // ANY-TIER-TOUCHED master sets `bypassSurfaceIds()` ∪ `passthroughSurfaceIds()`
        // ∪ the named surfaces (NOT this hardcoded surface list, and NOT the
        // surface-tier-only `surfaceBypassKeys()`). Because those
        // master sets are recorded by EVERY bypass writer (surface / sub-product /
        // actor) and by passthrough registration, an entry under an arbitrary
        // surfaceId — including a sub-product- or actor-ONLY bypass or a
        // passthrough-only entry — is discovered there.
        console2.log("");
    }

    function _fmtPolicy(IExitFeeController.RatePolicy memory p) internal pure returns (string memory) {
        return string.concat(
            "(active=", p.active ? "true" : "false", ", rateBps=", vm.toString(uint256(p.rateBps)), ")"
        );
    }

    function _fmtBypass(IExitFeeController.DelayBypassPolicy memory p)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "(active=", p.active ? "true" : "false", ", bypass=", p.bypass ? "true" : "false", ")"
        );
    }
}
