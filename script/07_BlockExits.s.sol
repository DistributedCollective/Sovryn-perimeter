// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ExitDelayQueue} from "../src/ExitDelayQueue.sol";
import {ExitFeeController} from "../src/ExitFeeController.sol";
import {IExitDelayQueue} from "../src/interfaces/IExitDelayQueue.sol";

/// @title  Block Exits - emergency stop for queued withdrawals
/// @notice READ-ONLY. Resolves who would be blocked, checks the call would not
///         revert, prints the exact calldata to submit from the Admin Safe, and
///         prints the command that verifies the result afterwards. It never
///         broadcasts: both block levers are `onlyAdminOrOwner`, and neither the
///         Admin nor the Owner is an EOA this script could sign for.
///
///         TWO LEVERS, DELIBERATELY DIFFERENT IN BLAST RADIUS:
///
///         `freeze` / `blacklist` - per-actor. A blocked originator, owner or
///         receiver cannot `executeExit` and cannot `recoverStuckExit`, so the
///         funds stay escrowed in the queue until the block is cleared or the
///         Owner resolves the request away. Everyone else keeps exiting
///         normally. `freeze` is the reversible hold (cleared by `unfreeze`);
///         `blacklist` is the confirmed state (cleared only by `unblacklist`).
///         A frozen address escalates to blacklisted in place. A blacklisted
///         address comes back down only through `downgrade`, which moves it to
///         frozen in one call with no window in which it is unblocked; the flat
///         `freeze` over a blacklisted address REVERTS on chain, which is why
///         this script refuses it here.
///
///         `pause` - global. Halts `executeExit` and `recoverStuckExit` for
///         everyone. It does NOT stop new exits entering the queue: escrow still
///         records normally, so the products keep working and nothing leaves.
///         Use it when the target is not yet identified; use the per-actor lever
///         once it is.
///
///         WHAT NEITHER LEVER DOES: they do not stop a withdrawal from being
///         initiated on the product. Exits keep escrowing; what stops is the
///         payout at the far end of the delay. Disabling the perimeter itself
///         (`setSecurityPerimeterEnabled(false)` on the controller) is the
///         OPPOSITE action - it makes exits pay out directly, with no delay and
///         no queue. It is a liveness escape, not an incident lever.
///
///         BY-REQUEST MODE resolves each request's `originator` and `owner` (and
///         its `receiver` when `BLOCK_FREEZE_RECEIVER=true`) and blocks all of
///         them in one transaction. That is the speed lever: given a list of
///         malicious request ids from the watcher, it blocks every party behind
///         them without the operator transcribing addresses under pressure. The
///         on-chain batch is atomic - one unknown id reverts the whole call - so
///         unknown ids are rejected here rather than after signatures are
///         collected.
///
/// @dev Usage:
///
///   export EXIT_DELAY_QUEUE=0x...            # the queue (required)
///   export EXIT_FEE_CONTROLLER=0x...         # controller; only the delay switch actions and their verify actions need it
///   export BLOCK_ACTION=freeze               # freeze|blacklist|downgrade|unfreeze|unblacklist|verify
///                                            # |pause|unpause|verify-pause|verify-unpause
///                                            # |disable-perimeter|enable-perimeter (controller kill switch)
///                                            # |verify-disable-perimeter|verify-enable-perimeter
///
///   # exactly one of these two for freeze/blacklist; actors only for downgrade and the clears:
///   export BLOCK_ACTORS=0xaaa,0xbbb          # addresses to block or clear
///   export BLOCK_REQUEST_IDS=41,42,43        # resolve the parties behind these requests
///
///   export BLOCK_FREEZE_RECEIVER=true        # by-request only; also block the payout address
///   export BLOCK_REASON="incident 2026-08-20"  # by-request only; hashed into the event
///
///   forge script script/07_BlockExits.s.sol --rpc-url $RPC
///
///   Then submit the printed calldata from the Admin Safe and re-run with the
///   verify action the preview prints. The multisig reports success even when
///   the call inside it failed, so the state is read back rather than assumed:
///   `verify` after a block, downgrade or clear reads the parties' block states
///   (keep BLOCK_ACTORS or BLOCK_REQUEST_IDS set); `verify-pause` and
///   `verify-unpause` read the pause state; `verify-disable-perimeter` and
///   `verify-enable-perimeter` read the delay switch and its length. Each
///   verify-* action refuses unless the state matches the call.
contract BlockExits is Script {
    ExitDelayQueue internal queue;
    ExitFeeController internal controller;

    function run() external {
        _init(vm.envAddress("EXIT_DELAY_QUEUE"));
        address ctrl = vm.envOr("EXIT_FEE_CONTROLLER", address(0));
        if (ctrl != address(0)) {
            _initController(ctrl);
        }
        _dispatch(
            vm.envString("BLOCK_ACTION"),
            vm.envOr("BLOCK_ACTORS", ",", new address[](0)),
            vm.envOr("BLOCK_REQUEST_IDS", ",", new uint256[](0)),
            vm.envOr("BLOCK_FREEZE_RECEIVER", false),
            vm.envOr("BLOCK_REASON", string(""))
        );
    }

    function _init(address q) internal {
        queue = ExitDelayQueue(payable(q));
    }

    function _initController(address c) internal {
        controller = ExitFeeController(c);
    }

    /// @dev Every input is an explicit argument so the decision logic is
    ///      driveable without process-global env, which forge does not isolate
    ///      between parallel tests.
    function _dispatch(
        string memory action,
        address[] memory actors,
        uint256[] memory ids,
        bool freezeReceiver,
        string memory reason
    ) internal view {
        console2.log("=== Perimeter: block exits ===");
        console2.log("queue                :", address(queue));
        console2.log("admin                :", queue.admin());
        console2.log("owner                :", queue.owner());
        console2.log("perimeter paused     :", queue.securityPerimeterPaused());
        console2.log("action               :", action);
        console2.log("");

        bytes32 a = keccak256(bytes(action));
        if (a == keccak256("pause")) {
            _pause(true);
        } else if (a == keccak256("unpause")) {
            _pause(false);
        } else if (a == keccak256("freeze")) {
            _blockActors(true, actors, ids, freezeReceiver, reason);
        } else if (a == keccak256("blacklist")) {
            _blockActors(false, actors, ids, freezeReceiver, reason);
        } else if (a == keccak256("downgrade")) {
            _downgrade(actors, ids);
        } else if (a == keccak256("unfreeze")) {
            _clear(true, actors, ids);
        } else if (a == keccak256("unblacklist")) {
            _clear(false, actors, ids);
        } else if (a == keccak256("verify")) {
            _verify(actors, ids, freezeReceiver);
        } else if (a == keccak256("verify-pause")) {
            _verifyPause(true);
        } else if (a == keccak256("verify-unpause")) {
            _verifyPause(false);
        } else if (a == keccak256("disable-perimeter")) {
            _killSwitch(false);
        } else if (a == keccak256("enable-perimeter")) {
            _killSwitch(true);
        } else if (a == keccak256("verify-disable-perimeter")) {
            _verifyDelaySwitch(false);
        } else if (a == keccak256("verify-enable-perimeter")) {
            _verifyDelaySwitch(true);
        } else {
            revert(
                "BLOCK_ACTION must be one of: freeze, blacklist, downgrade, unfreeze, unblacklist, verify, pause, unpause, verify-pause, verify-unpause, disable-perimeter, enable-perimeter, verify-disable-perimeter, verify-enable-perimeter"
            );
        }
    }

    // --- Global pause ---------------------------------------------------

    function _pause(bool on) internal view {
        if (queue.securityPerimeterPaused() == on) {
            console2.log("ALREADY in the requested state - nothing to submit.");
            return;
        }
        console2.log(
            on
                ? "Halts executeExit and recoverStuckExit for EVERYONE. New exits keep escrowing."
                : "Resumes executeExit and recoverStuckExit. Per-actor blocks are unaffected."
        );
        _emitCalldata(
            address(queue), abi.encodeCall(IExitDelayQueue.setSecurityPerimeterPaused, (on)), on ? "pause" : "unpause"
        );
    }

    // --- Controller kill switch -----------------------------------------

    /// @dev The OPPOSITE lever to everything else in this script: switching
    ///      the withdrawal delay off makes every hooked withdrawal pay straight
    ///      out - nothing is held and nothing escrows. The Perimeter fee has its
    ///      own switch and is not touched here. It is a LIVENESS escape for a
    ///      broken perimeter, not an incident response; during an attack it is
    ///      the last thing to touch. Funds already escrowed are NOT released by
    ///      it - they stay in the queue behind their own holds and blocks.
    ///
    ///      Switching on reverts on the controller while the global delay length
    ///      is unset (0), and the multisig records a failed inner call without
    ///      reverting its own transaction. So the length is read first and the
    ///      preview refuses, rather than handing out calldata that fails silently.
    ///      The unset length is checked before the current state: a switch that
    ///      already reads on with no length holds nothing, so it is reported as
    ///      unset, never as already done.
    function _killSwitch(bool enabled) internal view {
        _requireController();
        console2.log("controller           :", address(controller));
        console2.log("controller admin     :", controller.admin());
        console2.log("controller owner     :", controller.owner());
        bool current = controller.securityPerimeterEnabled();
        uint32 length = controller.globalDelaySeconds();
        console2.log("perimeter enabled    :", current);
        console2.log("global delay length  :", uint256(length), "seconds (0 = unset)");
        if (enabled && length == 0) {
            if (current) {
                console2.log("The switch already reads on, but with the length unset no withdrawal is held.");
            }
            console2.log("WOULD REVERT (DelayUnset): the controller refuses to switch the delay on while");
            console2.log("its length is unset. The Owner sets it first with setGlobalDelaySeconds.");
            revert(
                "enable-perimeter would revert: the global delay length is unset (0) - the Owner must call setGlobalDelaySeconds first"
            );
        }
        if (current == enabled) {
            console2.log("ALREADY in the requested state - nothing to submit.");
            return;
        }
        console2.log(
            enabled
                ? "Switches the withdrawal delay back on: every hooked withdrawal that is not exempt is held for the global delay length again. The Perimeter fee has its own switch."
                : "LIVENESS ESCAPE: every hooked withdrawal pays straight out - nothing is held, nothing escrows. The Perimeter fee has its own switch. Already-escrowed funds stay held in the queue."
        );
        _emitCalldata(
            address(controller),
            abi.encodeCall(ExitFeeController.setSecurityPerimeterEnabled, (enabled)),
            enabled ? "enable-perimeter" : "disable-perimeter"
        );
    }

    // --- Per-actor block ------------------------------------------------

    /// @dev `freezing == false` means blacklist. Actor mode and by-request mode
    ///      build different calls; both are previewed the same way.
    function _blockActors(
        bool freezing,
        address[] memory actorsIn,
        uint256[] memory ids,
        bool freezeReceiver,
        string memory reason
    ) internal view {
        address[] memory actors;
        bytes memory data;

        if (ids.length > 0) {
            require(
                actorsIn.length == 0,
                "set BLOCK_ACTORS or BLOCK_REQUEST_IDS, not both - they build different calls"
            );
            bytes32 reasonHash = _reasonHash(reason);
            actors = _partiesBehind(ids, freezeReceiver);
            data = freezing
                ? abi.encodeWithSignature(
                    "freezeFromRequest(uint256[],bool,bytes32)", ids, freezeReceiver, reasonHash
                )
                : abi.encodeWithSignature(
                    "blacklistFromRequest(uint256[],bool,bytes32)", ids, freezeReceiver, reasonHash
                );
            console2.log("freezeReceiver       :", freezeReceiver);
            console2.log("reason hash          :", vm.toString(reasonHash));
            console2.log("");
        } else {
            actors = actorsIn;
            require(actors.length > 0, "set BLOCK_ACTORS or BLOCK_REQUEST_IDS");
            data = freezing
                ? abi.encodeWithSignature("freeze(address[])", actors)
                : abi.encodeWithSignature("blacklist(address[])", actors);
        }

        IExitDelayQueue.BlockState target =
            freezing ? IExitDelayQueue.BlockState.Frozen : IExitDelayQueue.BlockState.Blacklisted;

        // A by-request call carries a trigger and a reason, which is what lets
        // the queue accept it over an already-blacklisted party (it holds the
        // stronger state and records the evidence). The flat by-address call
        // carries neither, so the same shape REVERTS there.
        bool carriesEvidence = ids.length > 0;

        uint256 changing;
        bool wouldRevert;
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState from = queue.blockStateOf(actors[i]);
            IExitDelayQueue.BlockState to = target;
            string memory note;
            if (
                from == IExitDelayQueue.BlockState.Blacklisted && target == IExitDelayQueue.BlockState.Frozen
            ) {
                to = from;
                if (carriesEvidence) {
                    note = "already blacklisted - holds the stronger state, evidence refreshed";
                } else {
                    note = "WOULD REVERT (already blacklisted - use BLOCK_ACTION=downgrade)";
                    wouldRevert = true;
                }
            } else if (from == target) {
                note = carriesEvidence
                    ? "already in this state (evidence refreshed, no state change)"
                    : "already in this state (no state change, recorded evidence kept)";
            } else {
                note = "WILL CHANGE";
                ++changing;
            }
            console2.log(
                string.concat(
                    "  ", vm.toString(actors[i]), "  ", _stateName(from), " -> ", _stateName(to), "   ", note
                )
            );
        }
        console2.log("");
        console2.log("actors resolved      :", actors.length);
        console2.log("state changes        :", changing);
        // The on-chain batch is atomic, so one refused address wastes the whole
        // Safe round. Refuse here instead, while it costs nothing.
        require(
            !wouldRevert,
            "freeze would revert: an address is already blacklisted - use BLOCK_ACTION=downgrade to move it to frozen"
        );
        if (changing == 0) {
            console2.log("NOTE: no state changes. The call still succeeds and re-emits AccountBlocked.");
        }
        _emitCalldata(address(queue), data, freezing ? "freeze" : "blacklist");
    }

    // --- Blacklisted -> Frozen ------------------------------------------

    /// @dev The one call that weakens a block without unblocking first, for an
    ///      address blacklisted in haste that should only be held while it is
    ///      investigated. The queue reverts on any address that is not
    ///      Blacklisted and the batch is atomic, so every address is checked here.
    function _downgrade(address[] memory actors, uint256[] memory ids) internal view {
        require(actors.length > 0, "set BLOCK_ACTORS");
        require(ids.length == 0, "downgrade is by address only - the queue has no by-request downgrade");

        bool wouldRevert;
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState from = queue.blockStateOf(actors[i]);
            bool ok = from == IExitDelayQueue.BlockState.Blacklisted;
            if (!ok) wouldRevert = true;
            console2.log(
                string.concat(
                    "  ",
                    vm.toString(actors[i]),
                    "  ",
                    _stateName(from),
                    ok ? " -> Frozen" : "   WOULD REVERT (not blacklisted)"
                )
            );
        }
        console2.log("");
        require(
            !wouldRevert,
            "downgrade requires every address to be Blacklisted - freeze is how a clear address is held"
        );
        console2.log("NOTE: the recorded trigger is kept - a downgrade is still a block.");
        _emitCalldata(
            address(queue), abi.encodeWithSignature("downgradeToFrozen(address[])", actors), "downgrade"
        );
    }

    // --- Per-actor clear ------------------------------------------------

    /// @dev `unfreezing == false` means unblacklist. The contract reverts when
    ///      the current state does not match the clear being run, and the batch
    ///      is atomic, so one wrong address would waste a whole Safe round. Every
    ///      address is checked here first.
    function _clear(bool unfreezing, address[] memory actors, uint256[] memory ids) internal view {
        require(actors.length > 0, "set BLOCK_ACTORS");
        require(ids.length == 0, "clears are by address only - the queue has no by-request clear");

        IExitDelayQueue.BlockState required =
            unfreezing ? IExitDelayQueue.BlockState.Frozen : IExitDelayQueue.BlockState.Blacklisted;

        bool wouldRevert;
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState from = queue.blockStateOf(actors[i]);
            bool ok = from == required;
            if (!ok) wouldRevert = true;
            console2.log(
                string.concat(
                    "  ",
                    vm.toString(actors[i]),
                    "  ",
                    _stateName(from),
                    ok ? " -> None" : "   WOULD REVERT (wrong clear for this state)"
                )
            );
        }
        console2.log("");
        require(
            !wouldRevert,
            unfreezing
                ? "unfreeze requires every address to be Frozen - use unblacklist for blacklisted ones"
                : "unblacklist requires every address to be Blacklisted - use unfreeze for frozen ones"
        );

        _emitCalldata(
            address(queue),
            unfreezing
                ? abi.encodeWithSignature("unfreeze(address[])", actors)
                : abi.encodeWithSignature("unblacklist(address[])", actors),
            unfreezing ? "unfreeze" : "unblacklist"
        );
    }

    // --- Verify ---------------------------------------------------------

    /// @dev Run after a pause or unpause executes. The multisig reports success
    ///      even when the call inside it failed, so the pause state is read back
    ///      and the check refuses unless it matches the call that was emitted.
    function _verifyPause(bool paused) internal view {
        if (queue.securityPerimeterPaused() != paused) {
            revert(
                paused
                    ? "NOT CONFIRMED: the queue reads unpaused - the pause did not take effect"
                    : "NOT CONFIRMED: the queue still reads paused - the resume did not take effect"
            );
        }
        console2.log(paused ? "CONFIRMED: the queue reads paused." : "CONFIRMED: the queue reads unpaused.");
    }

    /// @dev Run after the delay switch executes. Reads the switch and the length
    ///      back and refuses unless they match the call that was emitted. A
    ///      switch-on is confirmed only with a length set: a switch that reads on
    ///      with the length unset holds no withdrawal.
    function _verifyDelaySwitch(bool enabled) internal view {
        _requireController();
        bool current = controller.securityPerimeterEnabled();
        uint32 length = controller.globalDelaySeconds();
        console2.log("controller           :", address(controller));
        console2.log("perimeter enabled    :", current);
        console2.log("global delay length  :", uint256(length), "seconds (0 = unset)");
        if (enabled) {
            if (!current) revert("NOT CONFIRMED: the delay switch reads off - the switch-on did not take effect");
            if (length == 0) {
                revert("NOT CONFIRMED: the delay switch reads on but the length is unset (0) - no withdrawal is held");
            }
            console2.log("CONFIRMED: the delay switch reads on with a length set.");
        } else {
            if (current) {
                revert("NOT CONFIRMED: the delay switch still reads on - the switch-off did not take effect");
            }
            console2.log("CONFIRMED: the delay switch reads off - hooked withdrawals pay straight out.");
        }
    }

    /// @dev Run after a block, downgrade or clear executes. Prints the live state
    ///      of every address named directly, plus the parties behind the request
    ///      ids, so the operator confirms the outcome rather than assuming it
    ///      from a successful transaction.
    function _verify(address[] memory actorsIn, uint256[] memory ids, bool freezeReceiver) internal view {
        address[] memory actors = ids.length > 0 ? _partiesBehind(ids, freezeReceiver) : actorsIn;
        require(actors.length > 0, "set BLOCK_ACTORS or BLOCK_REQUEST_IDS");

        for (uint256 i = 0; i < actors.length; ++i) {
            console2.log(
                string.concat(
                    "  ",
                    vm.toString(actors[i]),
                    "  ",
                    _stateName(queue.blockStateOf(actors[i])),
                    "  trigger request #",
                    vm.toString(queue.blockTrigger(actors[i]))
                )
            );
        }
    }

    // --- Helpers --------------------------------------------------------

    /// @dev Resolve every party the on-chain batch would block, with the same
    ///      rules the contract uses: originator always, owner when distinct,
    ///      receiver only when flagged. Rejects unknown ids so the Safe never
    ///      signs a call that reverts on-chain.
    function _partiesBehind(uint256[] memory ids, bool freezeReceiver)
        internal
        view
        returns (address[] memory)
    {
        address[] memory buf = new address[](ids.length * 3);
        uint256 n;
        for (uint256 i = 0; i < ids.length; ++i) {
            IExitDelayQueue.ExitRequest memory r = queue.getRequest(ids[i]);
            require(
                r.status != IExitDelayQueue.ExitStatus.None,
                string.concat("unknown request id ", vm.toString(ids[i]), " - the batch is atomic")
            );
            console2.log(
                string.concat(
                    "  request #",
                    vm.toString(ids[i]),
                    "  status ",
                    vm.toString(uint256(uint8(r.status))),
                    "  amount ",
                    vm.toString(uint256(r.amount)),
                    "  token ",
                    vm.toString(r.token),
                    "  unlockAt ",
                    vm.toString(uint256(r.unlockAt))
                )
            );
            n = _push(buf, n, r.originator);
            if (r.owner != r.originator) n = _push(buf, n, r.owner);
            if (freezeReceiver) n = _push(buf, n, r.receiver);
        }
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = buf[i];
        }
        console2.log("");
        return out;
    }

    /// @dev Append unless already present - the same address behind several
    ///      requests should be listed once in the preview.
    function _push(address[] memory buf, uint256 n, address a) internal pure returns (uint256) {
        for (uint256 i = 0; i < n; ++i) {
            if (buf[i] == a) return n;
        }
        buf[n] = a;
        return n + 1;
    }

    /// @dev The reason is hashed, not stored: the event carries the digest and
    ///      the incident record carries the text. An empty reason is allowed but
    ///      called out, because the digest is the only on-chain link to why.
    function _reasonHash(string memory reason) internal view returns (bytes32) {
        if (bytes(reason).length == 0) {
            console2.log("WARNING: BLOCK_REASON is empty - the event will carry a zero digest.");
            return bytes32(0);
        }
        return keccak256(bytes(reason));
    }

    /// @dev Prints the calldata to submit for `action`, then the verify action
    ///      that reads back what it changed.
    function _emitCalldata(address to, bytes memory data, string memory action) internal view {
        console2.log("--- submit from the Admin multisig ---");
        console2.log("to   :", to);
        console2.log("value: 0");
        console2.log("data :", vm.toString(data));
        console2.log("");
        console2.log("Submit via the multisig's Read/Write contract tab on Blockscout:");
        console2.log(
            "  https://rootstock.blockscout.com/address/<ADMIN_MULTISIG>?tab=read_write_contract"
        );
        console2.log("  method 20. submitTransaction: destination = `to` above, value = 0,");
        console2.log("  data = the hex above. Simulate first, then Write. Further owners");
        console2.log("  confirm the emitted transactionId via method 4. confirmTransaction;");
        console2.log("  the threshold confirmation executes the call in the same transaction.");
        console2.log("");
        console2.log("--- then confirm the result ---");
        console2.log(
            "The multisig reports success even when the call inside it failed, so read the state after it executes:"
        );
        console2.log(
            string.concat(
                "BLOCK_ACTION=", _verifyActionFor(action), " forge script script/07_BlockExits.s.sol --rpc-url $RPC"
            )
        );
    }

    /// @dev The verify action that reads back what `action` changed: the pause
    ///      state after pause or unpause, the switch and length after the delay
    ///      switch, and the block states of the parties after a block, downgrade
    ///      or clear.
    function _verifyActionFor(string memory action) internal pure returns (string memory) {
        bytes32 a = keccak256(bytes(action));
        if (
            a == keccak256("pause") || a == keccak256("unpause") || a == keccak256("disable-perimeter")
                || a == keccak256("enable-perimeter")
        ) {
            return string.concat("verify-", action);
        }
        return "verify";
    }

    /// @dev The delay switch lives on the controller, so its actions and their
    ///      verification need its address.
    function _requireController() internal view {
        require(
            address(controller) != address(0),
            "set EXIT_FEE_CONTROLLER for disable-perimeter / enable-perimeter and their verify actions"
        );
    }

    function _stateName(IExitDelayQueue.BlockState s) internal pure returns (string memory) {
        if (s == IExitDelayQueue.BlockState.Frozen) return "Frozen";
        if (s == IExitDelayQueue.BlockState.Blacklisted) return "Blacklisted";
        return "None";
    }
}
