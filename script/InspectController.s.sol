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
///         index -- no log scans). Beside every stored sub-product and actor
///         row, on both the fee and the delay side, it prints the value that
///         actually resolves for that address, labelled with the sub-product
///         used, so an entry written inactive that is still exempt through a
///         broader tier reads as exempt. While the delay is switched off, each
///         delay row also shows what it would resolve to once switched on.
///
/// @dev Usage:
///
///   forge script script/InspectController.s.sol \
///       --rpc-url $RSK_RPC --sig "run(uint256)" <chainId>
///
/// Reads `deployments/<chainId>/ExitFeeController.json` to find the proxy
/// address (committed for mainnet/testnet, gitignored for local anvil).
/// It never broadcasts and produces no transaction. The only state it writes is
/// in this run's local simulation: for the "would resolve once switched on"
/// lines it writes the controller's delay switch and length word with
/// `vm.store`, quotes, and writes the original word back.
contract InspectController is Script {
    using stdJson for string;

    // Every canonical surface, including the ones that ship off -- an
    // inspector that skipped them would report "off" as silence. Keep
    // aligned with the registered surface names and the set that
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

    function run(uint256 chainId) external {
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
        bool delayOn = c.securityPerimeterEnabled();
        uint32 delayLength = c.globalDelaySeconds();
        console2.log("  securityPerimeterEnabled:", delayOn);
        console2.log(
            string.concat(
                "  globalDelaySeconds:       ",
                vm.toString(uint256(delayLength)),
                _delayLengthNote(delayOn, delayLength)
            )
        );
        console2.log("  admin:                   ", c.admin());
        console2.log("");

        // ── single-guardian identity assertion. The controller keeps its
        //    OWN local `admin` (used by the kill switch AND by setFeeReceiver,
        //    which re-points where the Perimeter fee is paid) and NEVER reads
        //    queue.admin() at runtime (that would couple those levers to queue
        //    liveness and break). Instead this tooling asserts, at
        //    deploy/inspect time, that the two guardians are ONE identity so a
        //    single Safe bundle rotates both. Off unless the queue artifact exists.
        _assertSingleGuardian(c, chainId);

        console2.log(unicode"── Surface policies + delay bypass ───────────────────");
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            _printSurface(c, surfaceNames[i]);
        }

        // ── dump EVERY delay-bypass entry via the on-chain enumeration
        //    getters — NOT the hardcoded surface list above. A bypass under an
        //    arbitrary surfaceId (never registered as a named fee surface) is
        //    still fully surfaced here.
        _printDelayBypassRegistry(c);
    }

    /// @dev What a delay length means beside its raw value. Zero is the unset
    ///      state: the controller refuses to switch the delay on while it holds,
    ///      and a switch that reads on with a zero length holds nothing. A
    ///      non-zero length needs no note.
    function _delayLengthNote(bool enabled, uint32 length) internal pure returns (string memory) {
        if (length != 0) return "";
        if (enabled) return "  WARNING: switched on with the length unset (0) - no withdrawal is held";
        return "  (0 = unset: switching the delay on is refused until the Owner sets a length)";
    }

    // ── Resolved values beside stored rows ──────────────────────────────

    /// @dev Gross used to show what a fee row resolves to; the labels print it
    ///      as 1e18. The resolved rate is what matters, the amount only makes
    ///      the charge visible.
    uint256 internal constant SAMPLE_GROSS = 1e18;

    /// @dev The sub-products an actor row is resolved at: none first, then every
    ///      sub-product stored under the same surface on the same side. What an
    ///      actor resolves to depends on the sub-product it withdraws from, so an
    ///      exemption reachable only through a sub-product entry is shown too.
    function _resolutionSubProducts(address[] memory keys) internal pure returns (address[] memory subs) {
        subs = new address[](keys.length + 1);
        for (uint256 i = 0; i < keys.length; i++) {
            subs[i + 1] = keys[i];
        }
    }

    /// @dev Names the resolution a line reports: the sub-product used and, for a
    ///      sub-product row, that no actor entry applied.
    function _resolutionLabel(address sub, address actor) internal pure returns (string memory) {
        string memory label =
            sub == address(0) ? "sub-product none" : string.concat("sub-product ", vm.toString(sub));
        return actor == address(0) ? string.concat(label, ", actor without an entry") : label;
    }

    /// @dev What `quoteExitDelay` returns for this address, in words. A zero
    ///      reads as exempt only while the delay is switched on with a length
    ///      set; a switched-off delay and an unset length are named as such.
    ///      While the delay is switched off every row reads 0s, so the line also
    ///      says what the row would resolve to once switched on.
    function _resolvedDelay(ExitFeeController c, bytes32 id, address sub, address actor)
        internal
        returns (string memory)
    {
        uint32 d = c.quoteExitDelay(id, sub, actor);
        bool switchedOn = c.securityPerimeterEnabled();
        string memory value;
        if (d != 0) value = string.concat("delayed ", vm.toString(uint256(d)), "s");
        else if (!switchedOn) value = "0s (delay switched off)";
        else if (c.globalDelaySeconds() == 0) value = "0s (length unset - nothing held)";
        else value = "exempt (0s)";
        string memory line = string.concat("resolves ", value, " for ", _resolutionLabel(sub, actor));
        if (switchedOn) return line;
        return string.concat(line, "; would resolve once switched on: ", _delayOnceSwitchedOn(c, id, sub, actor));
    }

    /// @dev Storage slot holding the controller's delay switch (lowest byte) and
    ///      delay length (the next four bytes), packed.
    uint256 internal constant DELAY_SWITCH_SLOT = 267;

    /// @dev Length written into the simulation while the real length is unset.
    ///      Any non-zero length separates held from exempt; this number is never
    ///      printed.
    uint32 internal constant PLACEHOLDER_DELAY_LENGTH = 1;

    /// @dev What `quoteExitDelay` would return for this address once the delay
    ///      is switched on, in words. Local simulation only, never broadcast:
    ///      writes the switch on (and the placeholder length when the length is
    ///      unset) into this run's copy of the controller's storage with
    ///      `vm.store`, quotes, then writes the original word back. The quote is
    ///      used only when both getters read back the written values; otherwise
    ///      the line says it could not simulate rather than reporting a value.
    function _delayOnceSwitchedOn(ExitFeeController c, bytes32 id, address sub, address actor)
        internal
        returns (string memory)
    {
        uint32 length = c.globalDelaySeconds();
        uint32 simulated = length == 0 ? PLACEHOLDER_DELAY_LENGTH : length;
        bytes32 slot = bytes32(DELAY_SWITCH_SLOT);
        bytes32 saved = vm.load(address(c), slot);
        // Replace the switch byte and the four length bytes; keep the rest of the word.
        uint256 patched = (uint256(saved) & ~uint256(0xFFFFFFFFFF)) | (uint256(simulated) << 8) | 1;
        vm.store(address(c), slot, bytes32(patched));
        bool readBack = c.securityPerimeterEnabled() && c.globalDelaySeconds() == simulated;
        uint32 d = readBack ? c.quoteExitDelay(id, sub, actor) : 0;
        vm.store(address(c), slot, saved);

        if (!readBack) return "NOT SIMULATED - the switch and length are not at the storage slot this inspector writes";
        if (d == 0) return "exempt (0s)";
        if (length == 0) return "held (length unset - the Owner sets it before switching on)";
        return string.concat("delayed ", vm.toString(uint256(d)), "s");
    }

    /// @dev What `quoteExitFee` returns for this address on SAMPLE_GROSS, in
    ///      words: the rate and fee when charged, exempt at an active 0 bps, and
    ///      the skip reason when no fee applies.
    function _resolvedFee(ExitFeeController c, bytes32 id, address sub, address actor)
        internal
        view
        returns (string memory)
    {
        IExitFeeController.ExitFeeQuote memory q = c.quoteExitFee(id, sub, actor, SAMPLE_GROSS);
        string memory value;
        if (!q.active) value = string.concat("no fee (", _skipReasonName(q.reason), ")");
        else if (q.rateBps == 0) value = "exempt (0 bps)";
        else value = string.concat(vm.toString(uint256(q.rateBps)), " bps, fee ", vm.toString(q.feeAmount));
        return string.concat("resolves ", value, " on sample gross 1e18 for ", _resolutionLabel(sub, actor));
    }

    function _skipReasonName(uint8 reason) internal pure returns (string memory) {
        if (reason == uint8(IExitFeeController.SkipReason.INACTIVE)) return "INACTIVE: fee switch off";
        if (reason == uint8(IExitFeeController.SkipReason.DISABLED)) {
            return "DISABLED: surface off or no fee receiver";
        }
        if (reason == uint8(IExitFeeController.SkipReason.INVALID_QUOTE)) return "INVALID_QUOTE";
        return string.concat("reason ", vm.toString(uint256(reason)));
    }

    /// @dev Logs `line` and records it at `rows[n]`, so a row printer returns
    ///      exactly the lines it printed. Returns the next free index.
    function _emitRow(string[] memory rows, uint256 n, string memory line) internal pure returns (uint256) {
        console2.log(line);
        rows[n] = line;
        return n + 1;
    }

    /// @dev `a` followed by `b`.
    function _concatRows(string[] memory a, string[] memory b) internal pure returns (string[] memory out) {
        out = new string[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }

    /// @dev Prints each stored fee sub-product row with the fee it resolves to.
    ///      Returns the printed lines.
    function _printFeeSubProductRows(ExitFeeController c, bytes32 id, address[] memory subs)
        internal
        view
        returns (string[] memory rows)
    {
        if (subs.length == 0) return rows;
        rows = new string[](1 + 2 * subs.length);
        uint256 n = _emitRow(rows, 0, "  sub-products:");
        for (uint256 j = 0; j < subs.length; j++) {
            IExitFeeController.RatePolicy memory p = c.subProductPolicy(id, subs[j]);
            n = _emitRow(rows, n, string.concat("    ", vm.toString(subs[j]), "  ", _fmtPolicy(p)));
            n = _emitRow(rows, n, string.concat("      ", _resolvedFee(c, id, subs[j], address(0))));
        }
    }

    /// @dev Prints each stored fee actor row with the fee it resolves to at no
    ///      sub-product and at every stored sub-product. Returns the printed
    ///      lines.
    function _printFeeActorRows(ExitFeeController c, bytes32 id, address[] memory actors, address[] memory subs)
        internal
        view
        returns (string[] memory rows)
    {
        if (actors.length == 0) return rows;
        address[] memory at = _resolutionSubProducts(subs);
        rows = new string[](1 + actors.length * (1 + at.length));
        uint256 n = _emitRow(rows, 0, "  actors:");
        for (uint256 j = 0; j < actors.length; j++) {
            IExitFeeController.RatePolicy memory p = c.actorPolicy(id, actors[j]);
            n = _emitRow(rows, n, string.concat("    ", vm.toString(actors[j]), "  ", _fmtPolicy(p)));
            for (uint256 k = 0; k < at.length; k++) {
                n = _emitRow(rows, n, string.concat("      ", _resolvedFee(c, id, at[k], actors[j])));
            }
        }
    }

    /// @dev Prints each stored delay sub-product row with the delay it resolves
    ///      to. Returns the printed lines.
    function _printDelaySubProductRows(ExitFeeController c, bytes32 id, address[] memory subs)
        internal
        returns (string[] memory rows)
    {
        rows = new string[](2 * subs.length);
        uint256 n;
        for (uint256 j = 0; j < subs.length; j++) {
            IExitFeeController.DelayBypassPolicy memory p = c.subProductBypass(id, subs[j]);
            n = _emitRow(rows, n, string.concat("    sub-product ", vm.toString(subs[j]), "  ", _fmtBypass(p)));
            n = _emitRow(rows, n, string.concat("      ", _resolvedDelay(c, id, subs[j], address(0))));
        }
    }

    /// @dev Prints each stored delay actor row with the delay it resolves to at
    ///      no sub-product and at every stored sub-product. Returns the printed
    ///      lines.
    function _printDelayActorRows(ExitFeeController c, bytes32 id, address[] memory actors, address[] memory subs)
        internal
        returns (string[] memory rows)
    {
        address[] memory at = _resolutionSubProducts(subs);
        rows = new string[](actors.length * (1 + at.length));
        uint256 n;
        for (uint256 j = 0; j < actors.length; j++) {
            IExitFeeController.DelayBypassPolicy memory p = c.actorBypass(id, actors[j]);
            n = _emitRow(rows, n, string.concat("    actor       ", vm.toString(actors[j]), "  ", _fmtBypass(p)));
            for (uint256 k = 0; k < at.length; k++) {
                n = _emitRow(rows, n, string.concat("      ", _resolvedDelay(c, id, at[k], actors[j])));
            }
        }
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

    /// @dev the complete surfaceId probe set that drives the bypass dump —
    ///        `bypassSurfaceIds()` ∪ the named surfaces.
    ///      The `bypassSurfaceIds()` master set is ANY-TIER-TOUCHED: a surface
    ///      carrying ONLY a sub-product- or actor-tier bypass is present here even
    ///      though it was never passed to `setSurfaceBypass`. The named fee surfaces
    ///      are folded in so the human-readable rows always render, and duplicates
    ///      are collapsed.
    function _probeSurfaceIds(ExitFeeController c) internal view returns (bytes32[] memory) {
        bytes32[] memory bypassIds = c.bypassSurfaceIds();

        // Upper bound on the union size; trim to the deduped count below.
        bytes32[] memory acc = new bytes32[](bypassIds.length + surfaceNames.length);
        uint256 n = 0;

        // Named fee surfaces first (stable ordering; keeps human rows at the top).
        for (uint256 i = 0; i < surfaceNames.length; i++) {
            n = _pushUnique(acc, n, keccak256(bytes(surfaceNames[i])));
        }
        for (uint256 i = 0; i < bypassIds.length; i++) {
            n = _pushUnique(acc, n, bypassIds[i]);
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
            if (id == keccak256(bytes(surfaceNames[i]))) {
                return surfaceNames[i];
            }
        }
        return vm.toString(id);
    }

    /// @dev Is `id` in the surface-bypass key index? A soft-retired surface
    ///      entry ({false,false}) is indistinguishable from never-set by its
    ///      policy alone; the key set is the source of truth for presence.
    function _surfaceBypassKeyPresent(ExitFeeController c, bytes32 id) internal view returns (bool) {
        bytes32[] memory keys = c.surfaceBypassKeys();
        for (uint256 i = 0; i < keys.length; i++) {
            if (keys[i] == id) return true;
        }
        return false;
    }

    /// @dev dump every surface / sub-product / actor delay-bypass
    ///      entry, driven by the ANY-TIER-TOUCHED probe set (`bypassSurfaceIds()` ∪
    ///      named surfaces) so a sub-product- or
    ///      actor-only bypass under an arbitrary surfaceId is never missed. A probed
    ///      surfaceId with no live bypass entry at any tier prints nothing.
    ///      Returns the stored-row lines it printed: every sub-product and actor
    ///      row with its resolved lines, in print order.
    function _printDelayBypassRegistry(ExitFeeController c) internal returns (string[] memory rows) {
        console2.log(unicode"── Delay-bypass registry (enumerated) ────────────────");
        bytes32[] memory ids = _probeSurfaceIds(c);
        bool anyPrinted = false;
        for (uint256 i = 0; i < ids.length; i++) {
            bytes32 id = ids[i];

            IExitFeeController.DelayBypassPolicy memory sb = c.surfaceBypass(id);
            address[] memory subBp = c.subProductBypassKeys(id);
            address[] memory actorBp = c.actorBypassKeys(id);
            // A surface-tier entry set then soft-retired reads {false,false} but
            // still lives in the key index; it must stay visible, since the
            // documented way to disable-while-auditable is exactly that state.
            bool surfaceEntryPresent = _surfaceBypassKeyPresent(c, id);

            // Skip a probed id that carries no bypass entry at any tier (e.g. a
            // named fee surface never given one).
            if (!surfaceEntryPresent && subBp.length == 0 && actorBp.length == 0) {
                continue;
            }
            anyPrinted = true;

            console2.log(string.concat("  surface ", _labelFor(id), "  ", _fmtBypass(sb)));
            // Beside each stored row, the delay that resolves for that address.
            // Sub-product rows print before actor rows.
            string[] memory subRows = _printDelaySubProductRows(c, id, subBp);
            string[] memory actorRows = _printDelayActorRows(c, id, actorBp, subBp);
            rows = _concatRows(rows, _concatRows(subRows, actorRows));
        }
        if (!anyPrinted) {
            console2.log("  (no delay bypasses configured at any tier)");
        }
        console2.log("");
    }



    /// @dev Prints one named surface: its id, its policy, and every stored
    ///      sub-product and actor row with the fee each resolves to. Returns the
    ///      stored-row lines it printed, sub-product rows first.
    function _printSurface(ExitFeeController c, string memory name) internal view returns (string[] memory rows) {
        bytes32 id = keccak256(bytes(name));

        console2.log(name);
        console2.log("  id:     ", vm.toString(id));

        IExitFeeController.RatePolicy memory sp = c.surfacePolicy(id);
        console2.log(string.concat("  policy: ", _fmtPolicy(sp)));

        // Beside each stored row, the fee that resolves for that address.
        // Sub-product rows print before actor rows.
        address[] memory subs = c.subProductKeys(id);
        string[] memory subRows = _printFeeSubProductRows(c, id, subs);
        string[] memory actorRows = _printFeeActorRows(c, id, c.actorKeys(id), subs);
        rows = _concatRows(subRows, actorRows);
        // NOTE: delay-bypass tiers are dumped separately in
        // `_printDelayBypassRegistry`, driven by the ANY-TIER-TOUCHED master set
        // `bypassSurfaceIds()` ∪ the named surfaces (NOT this hardcoded surface
        // list, and NOT the surface-tier-only `surfaceBypassKeys()`). Because that
        // master set is recorded by EVERY bypass writer (surface / sub-product /
        // actor), an entry under an arbitrary surfaceId — including a sub-product-
        // or actor-ONLY bypass — is discovered there.
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
