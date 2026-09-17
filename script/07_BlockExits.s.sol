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
///         `pause` - global. Stops `executeExit`, `executeExits` and
///         `recoverStuckExit` for every caller - the originator, the owner, and
///         anyone delivering a contract-owned request - so users have no path of
///         their own while it holds. It does NOT stop new exits entering the
///         queue: the four `record*` functions and `receive` keep escrowing, so
///         the products keep working. It does NOT stop the block levers, the
///         Admin-or-Owner `resolveToProtocol` (still bound to a blacklisted
///         originator or owner and a matching active route), or the Owner's
///         `resolveByOwner`, which reaches only requests with a blacklisted party,
///         paused or not. Owner configuration and `sweepSurplus` are unaffected.
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
///         BY-REQUEST MODE resolves each request's `originator` and `owner`, then
///         splits the ids into a CLEAN group (neither is already frozen or
///         blacklisted) and a HELD group (at least one of them already is). Only
///         a clean request's `receiver` is blocked alongside it - a request that
///         already has a blocked party is left with its receiver untouched,
///         because a blocked actor can set up an honest-looking receiver to move
///         funds through it. `freeze` sends only the clean group: a held request
///         is already covered by its existing block, so freezing it again would
///         change nothing, and the script skips it rather than submit a no-op;
///         it refuses outright when every id resolves to the held group.
///         `blacklist` sends both groups - it escalates a held party the same as
///         a clean one, just without its receiver. This is the speed lever:
///         given a list of malicious request ids from the watcher, it blocks
///         every clean party behind them, correctly holding receivers back where
///         they should be, without the operator transcribing addresses or
///         judging a receiver under pressure. The on-chain batch is atomic - one
///         unknown id reverts the whole call - so unknown ids are rejected here
///         rather than after signatures are collected.
///
/// @dev Usage:
///
///   export EXIT_DELAY_QUEUE=0x...            # the queue (required)
///   export EXIT_FEE_CONTROLLER=0x...         # controller; only the delay switch actions and their verify actions need it
///   export BLOCK_ACTION=freeze               # freeze|blacklist|downgrade|unfreeze|unblacklist
///                                            # |verify-freeze|verify-blacklist|verify-downgrade
///                                            # |verify-unfreeze|verify-unblacklist
///                                            # |pause|unpause|verify-pause|verify-unpause
///                                            # |disable-perimeter|enable-perimeter (controller kill switch)
///                                            # |verify-disable-perimeter|verify-enable-perimeter
///
///   # exactly one of these two for freeze/blacklist; actors only for downgrade and the clears:
///   export BLOCK_ACTORS=0xaaa,0xbbb          # addresses to block or clear
///   export BLOCK_REQUEST_IDS=41,42,43        # resolve the parties behind these requests
///
///   export BLOCK_REASON="incident label"     # by-request only; hashed into the event
///
///   forge script script/07_BlockExits.s.sol --rpc-url $RPC
///
///   Then submit the printed calldata from the Admin Safe and re-run with the
///   verify action the preview prints. The multisig reports success even when
///   the call inside it failed, so the state is read back rather than assumed:
///   `verify-freeze` and `verify-blacklist` read every resolved request's
///   parties back - the clean group's receiver must now read blocked, and the
///   held group's receiver must still read untouched; `verify-downgrade`,
///   `verify-unfreeze` and `verify-unblacklist` read the block states of the
///   named addresses (keep BLOCK_ACTORS or BLOCK_REQUEST_IDS set); `verify-pause`
///   and `verify-unpause` read the pause state; `verify-disable-perimeter` and
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
            _blockActors(true, actors, ids, reason);
        } else if (a == keccak256("blacklist")) {
            _blockActors(false, actors, ids, reason);
        } else if (a == keccak256("downgrade")) {
            _downgrade(actors, ids);
        } else if (a == keccak256("unfreeze")) {
            _clear(true, actors, ids);
        } else if (a == keccak256("unblacklist")) {
            _clear(false, actors, ids);
        } else if (a == keccak256("verify-freeze")) {
            _verify(actors, ids, IExitDelayQueue.BlockState.Frozen, true);
        } else if (a == keccak256("verify-blacklist")) {
            _verify(actors, ids, IExitDelayQueue.BlockState.Blacklisted, true);
        } else if (a == keccak256("verify-downgrade")) {
            _verify(actors, ids, IExitDelayQueue.BlockState.Frozen, false);
        } else if (a == keccak256("verify-unfreeze")) {
            _verify(actors, ids, IExitDelayQueue.BlockState.None, false);
        } else if (a == keccak256("verify-unblacklist")) {
            _verify(actors, ids, IExitDelayQueue.BlockState.None, false);
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
                "BLOCK_ACTION must be one of: freeze, blacklist, downgrade, unfreeze, unblacklist, verify-freeze, verify-blacklist, verify-downgrade, verify-unfreeze, verify-unblacklist, pause, unpause, verify-pause, verify-unpause, disable-perimeter, enable-perimeter, verify-disable-perimeter, verify-enable-perimeter"
            );
        }
    }

    // --- Global pause ---------------------------------------------------

    function _pause(bool on) internal view {
        if (queue.securityPerimeterPaused() == on) {
            console2.log("ALREADY in the requested state - nothing to submit.");
            return;
        }
        if (on) {
            console2.log(
                "Stops executeExit, executeExits and recoverStuckExit for every caller - the originator, the"
            );
            console2.log("owner, and anyone delivering a contract-owned request. New exits keep escrowing.");
            console2.log(
                "Still live, and still paying out: the Admin-or-Owner resolveToProtocol (a blacklisted"
            );
            console2.log(
                "originator or owner with a matching active route) and the Owner's resolveByOwner, which"
            );
            console2.log(
                "reaches only requests with a blacklisted party, paused or not. The block levers, Owner"
            );
            console2.log("configuration and sweepSurplus are unaffected.");
        } else {
            console2.log(
                "Resumes executeExit, executeExits and recoverStuckExit. Per-actor blocks are unaffected."
            );
            console2.log("resolveByOwner is unchanged: it reaches only requests with a blacklisted party.");
        }
        _emitCalldata(
            address(queue),
            abi.encodeCall(IExitDelayQueue.setSecurityPerimeterPaused, (on)),
            on ? "pause" : "unpause"
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
                ?
                "Switches the withdrawal delay back on: every hooked withdrawal that is not exempt is held for the global delay length again. The Perimeter fee has its own switch."
                :
                "LIVENESS ESCAPE: every hooked withdrawal pays straight out - nothing is held, nothing escrows. The Perimeter fee has its own switch. Already-escrowed funds stay held in the queue."
        );
        _emitCalldata(
            address(controller),
            abi.encodeCall(ExitFeeController.setSecurityPerimeterEnabled, (enabled)),
            enabled ? "enable-perimeter" : "disable-perimeter"
        );
    }

    // --- Per-actor block ------------------------------------------------

    /// @dev `freezing == false` means blacklist. Actor mode and by-request mode
    ///      build calls differently enough - one flat call against another that
    ///      may split into two - that each gets its own function; both are
    ///      previewed with the same vocabulary.
    function _blockActors(
        bool freezing,
        address[] memory actorsIn,
        uint256[] memory ids,
        string memory reason
    ) internal view {
        if (ids.length > 0) {
            require(
                actorsIn.length == 0,
                "set BLOCK_ACTORS or BLOCK_REQUEST_IDS, not both - they build different calls"
            );
            _blockByRequest(freezing, ids, reason);
            return;
        }
        _blockByAddress(freezing, actorsIn);
    }

    /// @dev Flat block by address. No request evidence rides on this call, so a
    ///      freeze over an already-blacklisted address is a caller mistake the
    ///      queue reverts on (`AlreadyBlacklisted`) - refused here instead,
    ///      while it costs nothing.
    function _blockByAddress(bool freezing, address[] memory actors) internal view {
        require(actors.length > 0, "set BLOCK_ACTORS or BLOCK_REQUEST_IDS");
        bytes memory data = freezing
            ? abi.encodeWithSignature("freeze(address[])", actors)
            : abi.encodeWithSignature("blacklist(address[])", actors);

        IExitDelayQueue.BlockState target =
            freezing ? IExitDelayQueue.BlockState.Frozen : IExitDelayQueue.BlockState.Blacklisted;

        uint256 changing;
        bool wouldRevert;
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState from = queue.blockStateOf(actors[i]);
            IExitDelayQueue.BlockState to = target;
            string memory note;
            if (from == IExitDelayQueue.BlockState.Blacklisted && target == IExitDelayQueue.BlockState.Frozen)
            {
                to = from;
                note = "WOULD REVERT (already blacklisted - use BLOCK_ACTION=downgrade)";
                wouldRevert = true;
            } else if (from == target) {
                note = "already in this state (no state change, recorded evidence kept)";
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

    /// @dev By-request block. Splits `ids` into a CLEAN group (originator and
    ///      owner both unblocked) and a HELD group (at least one of them
    ///      already frozen or blacklisted), then builds the call(s) the
    ///      Admin-or-Owner reach describes: `freeze` submits the clean group
    ///      only - a held request needs nothing more from a freeze, so it is
    ///      left out rather than sent for a no-op - and refuses outright when
    ///      every id is held; `blacklist` submits both groups, the held one
    ///      without its receiver, since escalating an already-frozen party is
    ///      exactly what blacklist is for.
    function _blockByRequest(bool freezing, uint256[] memory ids, string memory reason) internal view {
        bytes32 reasonHash = _reasonHash(reason);
        (uint256[] memory cleanIds, uint256[] memory heldIds) = _splitByHeldState(ids);

        console2.log("clean requests       :", cleanIds.length, "(neither party already blocked)");
        console2.log("held requests        :", heldIds.length, "(originator or owner already blocked)");
        console2.log("reason hash          :", vm.toString(reasonHash));
        console2.log("");

        if (freezing) {
            if (heldIds.length > 0) {
                console2.log(string.concat(vm.toString(heldIds.length), " request(s) skipped: already held"));
            }
            require(
                cleanIds.length > 0,
                string.concat(vm.toString(heldIds.length), " request(s) skipped: already held")
            );
            _previewByRequestGroup(cleanIds, true, IExitDelayQueue.BlockState.Frozen);
            bytes memory data = abi.encodeWithSignature(
                "freezeFromRequest(uint256[],bool,bytes32)", cleanIds, true, reasonHash
            );
            _emitCalldata(address(queue), data, "freeze");
            return;
        }

        // Blacklist escalates a held party exactly as it does a clean one, so
        // both groups go out - the held group just never reaches its receiver.
        if (cleanIds.length > 0) {
            _previewByRequestGroup(cleanIds, true, IExitDelayQueue.BlockState.Blacklisted);
            bytes memory cleanData = abi.encodeWithSignature(
                "blacklistFromRequest(uint256[],bool,bytes32)", cleanIds, true, reasonHash
            );
            _emitCalldata(address(queue), cleanData, "blacklist");
        }
        if (heldIds.length > 0) {
            _previewByRequestGroup(heldIds, false, IExitDelayQueue.BlockState.Blacklisted);
            bytes memory heldData = abi.encodeWithSignature(
                "blacklistFromRequest(uint256[],bool,bytes32)", heldIds, false, reasonHash
            );
            _emitCalldata(address(queue), heldData, "blacklist");
        }
    }

    /// @dev Prints the parties a by-request group resolves to and the state
    ///      change each one is headed for.
    function _previewByRequestGroup(
        uint256[] memory ids,
        bool includeReceiver,
        IExitDelayQueue.BlockState target
    ) internal view {
        console2.log(
            includeReceiver ? "  clean group (receiver included):" : "  held group (receiver left alone):"
        );
        address[] memory actors = _partiesBehind(ids, includeReceiver);
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState from = queue.blockStateOf(actors[i]);
            console2.log(
                string.concat(
                    "    ", vm.toString(actors[i]), "  ", _stateName(from), " -> ", _stateName(target)
                )
            );
        }
        console2.log("");
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
            if (!current) {
                revert("NOT CONFIRMED: the delay switch reads off - the switch-on did not take effect");
            }
            if (length == 0) {
                revert(
                    "NOT CONFIRMED: the delay switch reads on but the length is unset (0) - no withdrawal is held"
                );
            }
            console2.log("CONFIRMED: the delay switch reads on with a length set.");
        } else {
            if (current) {
                revert("NOT CONFIRMED: the delay switch still reads on - the switch-off did not take effect");
            }
            console2.log("CONFIRMED: the delay switch reads off - hooked withdrawals pay straight out.");
        }
    }

    /// @dev Run after a block, downgrade or clear executes. By address
    ///      (`ids.length == 0`, or a downgrade/clear verify), this reads the
    ///      live state of every named address and refuses unless every one of
    ///      them reads `target` - the state the submitted call was supposed to
    ///      produce - so a failed inner call is not read as confirmation from a
    ///      multisig transaction that itself reported success. `acceptStronger`
    ///      widens the check to "at least as strong as `target`": a freeze over
    ///      an already-blacklisted party correctly holds the stronger state
    ///      instead of moving to Frozen, and that must read as confirmed, not as
    ///      a freeze that failed. A downgrade or a clear never sets it - there, a
    ///      party still reading a stronger state than the target is the genuine
    ///      unconfirmed case.
    ///
    ///      By request, with `acceptStronger` set (`verify-freeze` /
    ///      `verify-blacklist`), the check instead goes through `_verifyByRequest`,
    ///      which reads the clean and held groups apart.
    function _verify(
        address[] memory actorsIn,
        uint256[] memory ids,
        IExitDelayQueue.BlockState target,
        bool acceptStronger
    ) internal view {
        if (ids.length > 0 && acceptStronger) {
            _verifyByRequest(ids, target);
            return;
        }

        address[] memory actors = ids.length > 0 ? _partiesBehind(ids, false) : actorsIn;
        require(actors.length > 0, "set BLOCK_ACTORS or BLOCK_REQUEST_IDS");

        bool mismatchFound;
        address mismatchAddr;
        IExitDelayQueue.BlockState mismatchState;
        bool anyStronger;
        for (uint256 i = 0; i < actors.length; ++i) {
            IExitDelayQueue.BlockState state = queue.blockStateOf(actors[i]);
            console2.log(
                string.concat(
                    "  ",
                    vm.toString(actors[i]),
                    "  ",
                    _stateName(state),
                    "  trigger request #",
                    vm.toString(queue.blockTrigger(actors[i]))
                )
            );
            bool strongerThanAsked = acceptStronger && uint8(state) > uint8(target);
            if (strongerThanAsked) anyStronger = true;
            if (!mismatchFound && state != target && !strongerThanAsked) {
                mismatchFound = true;
                mismatchAddr = actors[i];
                mismatchState = state;
            }
        }
        if (mismatchFound) {
            revert(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(mismatchAddr),
                    " reads ",
                    _stateName(mismatchState),
                    ", not ",
                    _stateName(target),
                    " - the call did not take effect"
                )
            );
        }
        console2.log(
            anyStronger
                ? string.concat(
                    "CONFIRMED: every resolved address reads ",
                    _stateName(target),
                    " or a stronger block state it already held."
                )
                : string.concat("CONFIRMED: every resolved address reads ", _stateName(target), ".")
        );
    }

    /// @dev Verifies a by-request freeze or blacklist, reading the clean and
    ///      held groups apart rather than re-deriving them from the current
    ///      originator/owner state - after a blacklist both groups read the
    ///      same target state on those two parties, so that state alone cannot
    ///      say which group a request was in. `_receiverIncludedInBatch` reads
    ///      the group instead: a receiver counts as included when its recorded
    ///      trigger names ANY id in this same batch that also resolves to that
    ///      receiver, not only `ids[i]` itself - the trigger keeps only the
    ///      last id that wrote it, so two ids sharing a receiver in the same
    ///      clean-group call would otherwise leave the earlier one unmatched
    ///      even though its receiver was blocked alongside it. This reads true
    ///      only for the clean group, under either action - a receiver an
    ///      unrelated batch or a flat lever blocked still names an id outside
    ///      this batch, or no id at all. For a request that reads clean this
    ///      way, originator, owner and receiver must all reach `target` or
    ///      stronger. For one that reads held, the receiver must still read
    ///      below `target` (the call left it alone); its originator and owner
    ///      are checked at the strength each action actually gives a held
    ///      request - freeze never touches it, so only the party that was
    ///      already blocked is guaranteed to still read blocked, not both;
    ///      blacklist escalates it exactly as it does a clean request, so both
    ///      must reach `target`.
    function _verifyByRequest(uint256[] memory ids, IExitDelayQueue.BlockState target) internal view {
        bool mismatchFound;
        address mismatchAddr;
        string memory mismatchNote;

        for (uint256 i = 0; i < ids.length; ++i) {
            IExitDelayQueue.ExitRequest memory r = queue.getRequest(ids[i]);
            require(
                r.status != IExitDelayQueue.ExitStatus.None,
                string.concat("unknown request id ", vm.toString(ids[i]), " - the batch is atomic")
            );

            IExitDelayQueue.BlockState oState = queue.blockStateOf(r.originator);
            IExitDelayQueue.BlockState wState = queue.blockStateOf(r.owner);
            IExitDelayQueue.BlockState rState = queue.blockStateOf(r.receiver);
            bool receiverIncluded = _receiverIncludedInBatch(ids, i, r.receiver);

            console2.log(
                string.concat(
                    "  request #",
                    vm.toString(ids[i]),
                    "  originator ",
                    _stateName(oState),
                    "  owner ",
                    _stateName(wState),
                    "  receiver ",
                    _stateName(rState),
                    receiverIncluded ? "  (clean group)" : "  (held group - receiver left alone)"
                )
            );

            bool partiesOk;
            if (receiverIncluded || target == IExitDelayQueue.BlockState.Blacklisted) {
                // Clean group under either action, or held group under
                // blacklist: both parties are always processed, so both must
                // reach target.
                partiesOk = uint8(oState) >= uint8(target) && uint8(wState) >= uint8(target);
            } else {
                // Held group under freeze: the request was skipped outright, so
                // only the party that was already blocked is guaranteed to
                // still read blocked - not both.
                partiesOk = uint8(oState) >= uint8(target) || uint8(wState) >= uint8(target);
            }
            if (!mismatchFound && !partiesOk) {
                mismatchFound = true;
                mismatchAddr = r.originator;
                mismatchNote = "originator/owner did not reach the expected block state";
            }

            bool receiverOk =
                receiverIncluded ? uint8(rState) >= uint8(target) : uint8(rState) < uint8(target);
            if (!mismatchFound && !receiverOk) {
                mismatchFound = true;
                mismatchAddr = r.receiver;
                mismatchNote = receiverIncluded
                    ? "receiver did not reach the expected block state"
                    :
                    "receiver was blocked but belongs to an already-held request - it should have been left alone";
            }

            // Evidence check, independent of the state comparison above: a
            // party reading `target` or stronger is not proof that THIS id's
            // own call is what put it there. `_setBlock` only writes
            // `_blockTrigger` for a party when the call touching it actually
            // ran, so `blockTrigger(party) == ids[i]` is the on-chain link
            // back to this exact request. Without it, the state comparison
            // may have passed only because the party already sat at or above
            // `target` from an earlier, unrelated action while this specific
            // call never ran (it reverted, or - for a held request under
            // freeze - was never submitted). Either way no withdrawal
            // escapes, so this does not fail verification; it only keeps the
            // CONFIRMED banner honest about whose evidence backs it.
            if (partiesOk && !mismatchFound && !_requestEvidenced(ids[i])) {
                console2.log(
                    string.concat(
                        "    NOTE: request #",
                        vm.toString(ids[i]),
                        " reads the expected state, but this action's own evidence was not recorded",
                        " - the block predates it."
                    )
                );
            }
        }

        if (mismatchFound) {
            revert(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(mismatchAddr),
                    " - ",
                    mismatchNote,
                    " - the call did not take effect"
                )
            );
        }
        console2.log(
            "CONFIRMED: every clean request's receiver is blocked and every held request's receiver is untouched."
        );
    }

    /// @dev True when `receiver`'s recorded trigger names this batch's own
    ///      handling of it: `ids[i]` itself, or another id in `ids` that also
    ///      resolves to `receiver`. `_blockTrigger` keeps only the last id that
    ///      wrote it, so checking `ids[i]` alone misreads every id but the last
    ///      one when several ids in the same batch share a receiver - the
    ///      shape a set of malicious withdrawals routed to one payout address
    ///      produces. Checking the whole batch instead is still specific to
    ///      it: a trigger of 0 (never blocked, or blocked by a flat lever that
    ///      carries no id) or one naming an id outside `ids` (an earlier,
    ///      unrelated action) correctly reads not included.
    function _receiverIncludedInBatch(uint256[] memory ids, uint256 i, address receiver)
        internal
        view
        returns (bool)
    {
        uint256 trigger = queue.blockTrigger(receiver);
        if (trigger == ids[i]) return true;
        if (trigger == 0) return false;
        for (uint256 k = 0; k < ids.length; ++k) {
            if (k == i || trigger != ids[k]) continue;
            if (queue.getRequest(ids[k]).receiver == receiver) return true;
        }
        return false;
    }

    /// @dev True when request `id`'s own by-request call is the reason its
    ///      resolved originator (and owner, if distinct) currently carry the
    ///      block they read - i.e. `_setBlock` actually ran while processing
    ///      `id` and last wrote `_blockTrigger` for both. False means their
    ///      current state, whatever it is, was not produced by this id's own
    ///      call - it predates it or comes from a different one. Read after
    ///      the fact, so this deliberately does not (cannot) distinguish "the
    ///      call for this id was skipped by design" from "it was submitted
    ///      and reverted" - both leave the same on-chain trace, which is
    ///      exactly the ambiguity `_verifyByRequest` surfaces rather than
    ///      papering over.
    function _requestEvidenced(uint256 id) internal view returns (bool) {
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        if (queue.blockTrigger(r.originator) != id) return false;
        if (r.owner != r.originator && queue.blockTrigger(r.owner) != id) return false;
        return true;
    }

    // --- Helpers --------------------------------------------------------

    /// @dev Splits by-request ids into a CLEAN group (originator and owner both
    ///      unblocked) and a HELD group (at least one of them already frozen or
    ///      blacklisted), read live - the same rule and the same live state
    ///      `_partiesBehind` resolves against, so the split reflects exactly
    ///      what the multisig will see. Rejects unknown ids up front, same as
    ///      `_partiesBehind`.
    function _splitByHeldState(uint256[] memory ids)
        internal
        view
        returns (uint256[] memory clean, uint256[] memory held)
    {
        uint256[] memory cleanBuf = new uint256[](ids.length);
        uint256[] memory heldBuf = new uint256[](ids.length);
        uint256 nc;
        uint256 nh;
        for (uint256 i = 0; i < ids.length; ++i) {
            IExitDelayQueue.ExitRequest memory r = queue.getRequest(ids[i]);
            require(
                r.status != IExitDelayQueue.ExitStatus.None,
                string.concat("unknown request id ", vm.toString(ids[i]), " - the batch is atomic")
            );
            bool isClean = queue.blockStateOf(r.originator) == IExitDelayQueue.BlockState.None
                && queue.blockStateOf(r.owner) == IExitDelayQueue.BlockState.None;
            if (isClean) {
                cleanBuf[nc++] = ids[i];
            } else {
                heldBuf[nh++] = ids[i];
            }
        }
        clean = new uint256[](nc);
        for (uint256 i = 0; i < nc; ++i) {
            clean[i] = cleanBuf[i];
        }
        held = new uint256[](nh);
        for (uint256 i = 0; i < nh; ++i) {
            held[i] = heldBuf[i];
        }
    }

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
        console2.log("  https://rootstock.blockscout.com/address/<ADMIN_MULTISIG>?tab=read_write_contract");
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
                "BLOCK_ACTION=",
                _verifyActionFor(action),
                " forge script script/07_BlockExits.s.sol --rpc-url $RPC"
            )
        );
    }

    /// @dev The verify action that reads back what `action` changed - the pause
    ///      state after pause or unpause, the switch and length after the delay
    ///      switch, or the block states of the parties after a block, downgrade
    ///      or clear. Every action's verify action is its own name prefixed with
    ///      "verify-", so each one refuses on the exact state it is named for.
    function _verifyActionFor(string memory action) internal pure returns (string memory) {
        return string.concat("verify-", action);
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
