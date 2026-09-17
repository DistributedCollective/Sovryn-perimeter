// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";
import {BlockExits} from "../../script/07_BlockExits.s.sol";

/// @dev Minimal WRBTC stand-in for the queue's `wrbtc_` init param.
contract MockWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}
    receive() external payable {}
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Allowed-source stand-in so real requests can be recorded, giving the
///      by-request resolution something to resolve.
contract SourceHarness {
    ExitDelayQueue public queue;

    constructor(ExitDelayQueue q) {
        queue = q;
    }

    function record(
        address token,
        uint128 amount,
        uint32 d,
        bytes32 surfaceId,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        ERC20(token).approve(address(queue), amount);
        return
            queue.recordERC20Exit(token, amount, d, surfaceId, address(0), effOrig, effOwner, receiver, false);
    }
}

/// @dev Exposes the script's decision logic with explicit arguments, so it is
///      driveable without `vm.setEnv` (process-global, not isolated between
///      parallel tests). Also surfaces the resolved party list and the
///      clean/held split, which is the part an operator relies on and the part
///      that must not drift from the contract's own `_blockFromRequest` rules.
contract BlockExitsHarness is BlockExits {
    function init(address q) external {
        _init(q);
    }

    function initController(address c) external {
        _initController(c);
    }

    function dispatch(
        string memory action,
        address[] memory actors,
        uint256[] memory ids,
        string memory reason
    ) external view {
        _dispatch(action, actors, ids, reason);
    }

    function partiesBehind(uint256[] memory ids, bool freezeReceiver)
        external
        view
        returns (address[] memory)
    {
        return _partiesBehind(ids, freezeReceiver);
    }

    function splitByHeldState(uint256[] memory ids)
        external
        view
        returns (uint256[] memory clean, uint256[] memory held)
    {
        return _splitByHeldState(ids);
    }

    function verifyActionFor(string memory action) external pure returns (string memory) {
        return _verifyActionFor(action);
    }

    function requestEvidenced(uint256 id) external view returns (bool) {
        return _requestEvidenced(id);
    }
}

/// @title  Emergency block preview - 07_BlockExits
/// @notice Proves the operator script refuses, up front, every call that would
///         revert on-chain after the Safe had already collected signatures,
///         that its by-request party resolution matches the parties the queue
///         itself blocks, and that a by-request block reaches the receiver only
///         for a request whose originator and owner are not already blocked.
contract BlockExitsTest is Test {
    address constant OWNER = address(0x0E7E7);
    address constant ADMIN = address(0x6DA12D);
    address constant ORIG = address(0x0121);
    address constant OWNR = address(0x0233);
    address constant RCVR = address(0x0455);
    address constant STRANGER = address(0x5747);

    // A second, independent request's parties - for tests that mix a clean
    // and a held request in the same batch.
    address constant ORIG2 = address(0x0126);
    address constant OWNR2 = address(0x0237);
    address constant RCVR2 = address(0x0459);

    bytes32 constant SURFACE = keccak256("PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW");
    uint32 constant MIN_DELAY = 60;
    uint32 constant DELAY = 3600;

    ExitDelayQueue queue;
    MockWRBTC wrbtc;
    MockERC20 token;
    SourceHarness source;
    BlockExitsHarness script;

    function setUp() public {
        wrbtc = new MockWRBTC();
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory sources = new address[](0);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, sources
            )
        );
        queue = ExitDelayQueue(payable(address(proxy)));

        token = new MockERC20();
        source = new SourceHarness(queue);
        vm.prank(OWNER);
        queue.addAllowedSource(address(source));
        token.mint(address(source), 1_000_000 ether);

        script = new BlockExitsHarness();
        script.init(address(queue));
    }

    // --- helpers --------------------------------------------------------

    function _record(address orig, address ownr, address rcvr) internal returns (uint256) {
        return source.record(address(token), 1 ether, DELAY, SURFACE, orig, ownr, rcvr);
    }

    function _addrs(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _noAddrs() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noIds() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // --- by-request resolution matches the contract ---------------------

    function test_partiesBehind_matches_contract_rules() public {
        uint256 id = _record(ORIG, OWNR, RCVR);

        address[] memory without = script.partiesBehind(_ids(id), false);
        assertEq(without.length, 2, "originator + owner");
        assertEq(without[0], ORIG);
        assertEq(without[1], OWNR);

        address[] memory withReceiver = script.partiesBehind(_ids(id), true);
        assertEq(withReceiver.length, 3, "originator + owner + receiver");
        assertEq(withReceiver[2], RCVR);

        // The queue itself blocks exactly this set - proven by executing the
        // real batch and reading the resulting states back.
        vm.prank(ADMIN);
        queue.freezeFromRequest(_ids(id), true, keccak256("drill"));
        for (uint256 i = 0; i < withReceiver.length; ++i) {
            assertEq(
                uint256(queue.blockStateOf(withReceiver[i])),
                uint256(IExitDelayQueue.BlockState.Frozen),
                "party resolved by the script was not blocked by the contract"
            );
        }
    }

    /// @dev originator == owner must collapse to one entry, as the contract's
    ///      `if (r.owner != r.originator)` does.
    function test_partiesBehind_collapses_identical_parties() public {
        uint256 id = _record(ORIG, ORIG, RCVR);
        address[] memory parties = script.partiesBehind(_ids(id), false);
        assertEq(parties.length, 1);
        assertEq(parties[0], ORIG);
    }

    /// @dev The same address behind two requests appears once in the preview,
    ///      so the operator does not read a doubled blast radius.
    function test_partiesBehind_dedupes_across_requests() public {
        uint256 a = _record(ORIG, OWNR, RCVR);
        uint256 b = _record(ORIG, OWNR, RCVR);
        assertEq(script.partiesBehind(_ids2(a, b), true).length, 3);
    }

    /// @dev The on-chain batch is atomic, so an unknown id must be rejected
    ///      before signatures are collected, not after.
    function test_unknown_request_id_is_rejected_up_front() public {
        vm.expectRevert(bytes("unknown request id 99 - the batch is atomic"));
        script.partiesBehind(_ids(99), false);
    }

    // --- clean / held split -----------------------------------------------

    /// @dev A party whose block state reads None counts as clean - the base
    ///      case, and the one every fresh incident id starts in.
    function test_split_a_fresh_request_is_clean() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        (uint256[] memory clean, uint256[] memory held) = script.splitByHeldState(_ids(id));
        assertEq(clean.length, 1);
        assertEq(clean[0], id);
        assertEq(held.length, 0);
    }

    /// @dev Either party already frozen or blacklisted moves the whole request
    ///      to the held group.
    function test_split_an_already_blocked_party_holds_the_whole_request() public {
        uint256 frozenOrig = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.freeze(ORIG);

        uint256 blacklistedOwner = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.blacklist(OWNR2);

        (uint256[] memory clean, uint256[] memory held) =
            script.splitByHeldState(_ids2(frozenOrig, blacklistedOwner));
        assertEq(clean.length, 0);
        assertEq(held.length, 2);
        assertEq(held[0], frozenOrig);
        assertEq(held[1], blacklistedOwner);
    }

    /// @dev A batch mixing a clean and a held request splits into exactly one
    ///      id on each side.
    function test_split_a_mixed_batch() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        uint256 held = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.blacklist(ORIG2);

        (uint256[] memory cleanIds, uint256[] memory heldIds) = script.splitByHeldState(_ids2(clean, held));
        assertEq(cleanIds.length, 1);
        assertEq(cleanIds[0], clean);
        assertEq(heldIds.length, 1);
        assertEq(heldIds[0], held);
    }

    function test_split_rejects_an_unknown_id() public {
        vm.expectRevert(bytes("unknown request id 99 - the batch is atomic"));
        script.splitByHeldState(_ids(99));
    }

    // --- by-request freeze: clean group only -----------------------------

    /// @dev A batch of entirely clean requests previews as one freeze call
    ///      that reaches every originator, owner and receiver.
    function test_freeze_by_request_all_clean_reaches_every_receiver() public {
        uint256 a = _record(ORIG, OWNR, RCVR);
        uint256 b = _record(ORIG2, OWNR2, RCVR2);
        script.dispatch("freeze", _noAddrs(), _ids2(a, b), "incident drill");
    }

    /// @dev A held request is left out of a freeze batch rather than sent for
    ///      a no-op, and the console-facing count is printed. The clean
    ///      request in the same batch still goes out.
    function test_freeze_by_request_skips_the_held_group() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        uint256 held = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.freeze(ORIG2);

        // Preview does not revert - the clean id alone is still submittable.
        script.dispatch("freeze", _noAddrs(), _ids2(clean, held), "incident drill");
    }

    /// @dev When every id in the batch is already held, freeze has nothing
    ///      left to submit and refuses rather than emitting an empty call.
    function test_freeze_by_request_refuses_when_every_id_is_held() public {
        uint256 held = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);

        vm.expectRevert(bytes("1 request(s) skipped: already held"));
        script.dispatch("freeze", _noAddrs(), _ids(held), "incident drill");
    }

    // --- by-request blacklist: both groups --------------------------------

    /// @dev Blacklist escalates a held party exactly as it does a clean one,
    ///      so a batch mixing both groups previews without reverting and does
    ///      not skip the held id the way freeze does.
    function test_blacklist_by_request_sends_both_groups() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        uint256 held = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.freeze(ORIG2);

        script.dispatch("blacklist", _noAddrs(), _ids2(clean, held), "incident drill");

        // Unaffected by the preview (read-only) - state is exactly as set up.
        assertEq(uint256(queue.blockStateOf(ORIG2)), uint256(IExitDelayQueue.BlockState.Frozen));
    }

    /// @dev A batch entirely in the held group still previews for blacklist
    ///      (unlike freeze, which would refuse it).
    function test_blacklist_by_request_all_held_previews() public {
        uint256 held = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        script.dispatch("blacklist", _noAddrs(), _ids(held), "incident drill");
    }

    // --- clears ---------------------------------------------------------

    function test_unfreeze_refuses_when_an_address_is_not_frozen() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);

        address[] memory two = new address[](2);
        two[0] = ORIG; // Frozen - fine
        two[1] = STRANGER; // None - would revert on-chain
        vm.expectRevert(
            bytes("unfreeze requires every address to be Frozen - use unblacklist for blacklisted ones")
        );
        script.dispatch("unfreeze", two, _noIds(), "");
    }

    function test_unfreeze_refuses_a_blacklisted_address() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.expectRevert(
            bytes("unfreeze requires every address to be Frozen - use unblacklist for blacklisted ones")
        );
        script.dispatch("unfreeze", _addrs(ORIG), _noIds(), "");
    }

    function test_unblacklist_refuses_a_frozen_address() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.expectRevert(
            bytes("unblacklist requires every address to be Blacklisted - use unfreeze for frozen ones")
        );
        script.dispatch("unblacklist", _addrs(ORIG), _noIds(), "");
    }

    function test_unfreeze_accepts_a_frozen_address() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        script.dispatch("unfreeze", _addrs(ORIG), _noIds(), "");
    }

    function test_clear_rejects_request_ids() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert(bytes("clears are by address only - the queue has no by-request clear"));
        script.dispatch("unfreeze", _addrs(ORIG), _ids(id), "");
    }

    // --- input discipline -----------------------------------------------

    // --- the flat freeze / the explicit downgrade ------------------------

    /// @notice The queue refuses an evidence-free freeze over a blacklisted
    ///         address, so the preview must refuse it too rather than print
    ///         "no state change" and let a Safe round be spent on a revert.
    function test_freeze_refuses_a_blacklisted_address() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.expectRevert(
            bytes(
                "freeze would revert: an address is already blacklisted - use BLOCK_ACTION=downgrade to move it to frozen"
            )
        );
        script.dispatch("freeze", _addrs(ORIG), _noIds(), "");
    }

    function test_downgrade_previews_a_blacklisted_address() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        script.dispatch("downgrade", _addrs(ORIG), _noIds(), "");
    }

    function test_downgrade_refuses_an_address_that_is_not_blacklisted() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.expectRevert(
            bytes(
                "downgrade requires every address to be Blacklisted - freeze is how a clear address is held"
            )
        );
        script.dispatch("downgrade", _addrs(ORIG), _noIds(), "");
    }

    function test_downgrade_rejects_request_ids() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert(bytes("downgrade is by address only - the queue has no by-request downgrade"));
        script.dispatch("downgrade", _addrs(ORIG), _ids(id), "");
    }

    function test_downgrade_requires_some_input() public {
        vm.expectRevert(bytes("set BLOCK_ACTORS"));
        script.dispatch("downgrade", _noAddrs(), _noIds(), "");
    }

    function test_freeze_rejects_both_input_modes_at_once() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS, not both - they build different calls"));
        script.dispatch("freeze", _addrs(STRANGER), _ids(id), "");
    }

    function test_freeze_requires_some_input() public {
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS"));
        script.dispatch("freeze", _noAddrs(), _noIds(), "");
    }

    function test_unknown_action_is_rejected() public {
        vm.expectRevert(
            bytes(
                "BLOCK_ACTION must be one of: freeze, blacklist, downgrade, unfreeze, unblacklist, verify-freeze, verify-blacklist, verify-downgrade, verify-unfreeze, verify-unblacklist, pause, unpause, verify-pause, verify-unpause, disable-perimeter, enable-perimeter, verify-disable-perimeter, verify-enable-perimeter"
            )
        );
        script.dispatch("halt", _addrs(ORIG), _noIds(), "");
    }

    // --- happy paths ----------------------------------------------------

    function test_freeze_and_blacklist_preview_by_actor() public view {
        script.dispatch("freeze", _addrs(ORIG), _noIds(), "");
        script.dispatch("blacklist", _addrs(ORIG), _noIds(), "");
    }

    function test_pause_and_unpause_preview() public {
        script.dispatch("pause", _noAddrs(), _noIds(), "");
        // Already unpaused: the script reports nothing to submit rather than
        // emitting calldata for a no-op Safe transaction.
        script.dispatch("unpause", _noAddrs(), _noIds(), "");

        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        script.dispatch("unpause", _noAddrs(), _noIds(), "");
    }

    // --- verify: by-request, both groups ---------------------------------

    /// @notice After a freeze that skipped the held group, verify must confirm
    ///         the clean request's receiver reached Frozen and the held
    ///         request's receiver was left alone - untouched by this batch.
    function test_verify_freeze_confirms_the_clean_group_and_leaves_the_held_group_alone() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        uint256 held = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.freeze(ORIG2);

        vm.prank(ADMIN);
        queue.freezeFromRequest(_ids(clean), true, keccak256("drill"));

        script.dispatch("verify-freeze", _noAddrs(), _ids2(clean, held), "");

        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(RCVR2)), uint256(IExitDelayQueue.BlockState.None));
    }

    /// @notice The multisig reports success even when the call inside it
    ///         failed, so before the freeze executes, verify must refuse.
    function test_verify_freeze_refuses_before_the_call_executes() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert();
        script.dispatch("verify-freeze", _noAddrs(), _ids(id), "");
    }

    /// @notice Blacklist escalates the held group too, so verify must confirm
    ///         both groups' originator and owner reached Blacklisted, while
    ///         only the clean group's receiver did.
    function test_verify_blacklist_confirms_both_groups() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        uint256 held = _record(ORIG2, OWNR2, RCVR2);
        vm.prank(ADMIN);
        queue.freeze(ORIG2);

        vm.prank(ADMIN);
        queue.blacklistFromRequest(_ids(clean), true, keccak256("drill"));
        vm.prank(ADMIN);
        queue.blacklistFromRequest(_ids(held), false, keccak256("drill"));

        script.dispatch("verify-blacklist", _noAddrs(), _ids2(clean, held), "");

        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        assertEq(uint256(queue.blockStateOf(RCVR2)), uint256(IExitDelayQueue.BlockState.None));
        assertEq(uint256(queue.blockStateOf(ORIG2)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        assertEq(uint256(queue.blockStateOf(OWNR2)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    /// @notice Two clean requests routed to the same receiver - the shape a set
    ///         of malicious withdrawals sharing one payout address produces -
    ///         must both confirm. `_blockTrigger` keeps only the id that
    ///         processed the receiver last, so the earlier of the two cannot
    ///         be read as clean from its own id alone; verify must still
    ///         confirm both rather than mistake the earlier one for held.
    function test_verify_freeze_confirms_two_clean_requests_sharing_one_receiver() public {
        uint256 a = _record(ORIG, OWNR, RCVR);
        uint256 b = _record(ORIG2, OWNR2, RCVR);

        vm.prank(ADMIN);
        queue.freezeFromRequest(_ids2(a, b), true, keccak256("drill"));

        script.dispatch("verify-freeze", _noAddrs(), _ids2(a, b), "");

        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Frozen));
    }

    /// @notice Same shape under blacklist: both clean requests sharing a
    ///         receiver must confirm, not only the one whose id happens to be
    ///         the last to have touched the shared receiver's trigger.
    function test_verify_blacklist_confirms_two_clean_requests_sharing_one_receiver() public {
        uint256 a = _record(ORIG, OWNR, RCVR);
        uint256 b = _record(ORIG2, OWNR2, RCVR);

        vm.prank(ADMIN);
        queue.blacklistFromRequest(_ids2(a, b), true, keccak256("drill"));

        script.dispatch("verify-blacklist", _noAddrs(), _ids2(a, b), "");

        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    /// @notice The held group's receiver must read below `target` to confirm -
    ///         it is not enough for it to merely differ from the id under
    ///         test. Here the receiver is already blocked for an unrelated
    ///         reason (a flat freeze, not this batch), and verify must still
    ///         refuse: a held request's receiver reading blocked is exactly
    ///         the state the split exists to prevent, whatever blocked it.
    function test_verify_by_request_refuses_a_blocked_receiver_on_a_held_request() public {
        uint256 held = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.prank(ADMIN);
        queue.freeze(RCVR);

        // The freeze itself correctly skips the held id and never touches
        // RCVR (proven by the earlier split/skip tests) - this checks that
        // verify does not wave an already-blocked held receiver through.
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(RCVR),
                    " - receiver was blocked but belongs to an already-held request - it should have been left alone - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-freeze", _noAddrs(), _ids(held), "");
    }

    /// @notice A held request's parties can already read the target state
    ///         through an action unrelated to the request being verified -
    ///         here, the originator was blacklisted before `held` was ever
    ///         recorded, so no by-request call for `held` ran at all. Verify
    ///         must not claim this incident's own evidence was written on
    ///         chain for `held`: the state comparison alone cannot tell "this
    ///         id's call ran" apart from "the party was already blocked", but
    ///         `_requestEvidenced` can, and must read false here even though
    ///         `dispatch` itself does not revert - the party is still
    ///         genuinely blocked, so refusing outright would be wrong.
    function test_verify_by_request_flags_state_reached_without_this_ids_own_evidence() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        uint256 held = _record(ORIG, OWNR, RCVR);

        // Never executed: no freezeFromRequest/blacklistFromRequest call for
        // `held` - simulating the on-chain call reverting or being skipped
        // outright, with the state comparison alone unable to tell which.
        assertFalse(script.requestEvidenced(held));

        // The party is genuinely still blocked, so verification still
        // succeeds - it is the CONFIRMED banner's honesty that was at stake,
        // not whether the exit is held.
        script.dispatch("verify-freeze", _noAddrs(), _ids(held), "");
        assertFalse(script.requestEvidenced(held));
    }

    /// @notice The positive case: once the by-request call actually runs,
    ///         `_requestEvidenced` reads true for the id that ran it.
    function test_verify_by_request_evidence_matches_a_call_that_actually_ran() public {
        uint256 clean = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.freezeFromRequest(_ids(clean), true, keccak256("drill"));

        assertTrue(script.requestEvidenced(clean));
        script.dispatch("verify-freeze", _noAddrs(), _ids(clean), "");
    }

    function test_verify_requires_input() public {
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS"));
        script.dispatch("verify-freeze", _noAddrs(), _noIds(), "");
    }

    // --- verify: by address -----------------------------------------------

    /// @notice The multisig reports success even when the call inside it failed,
    ///         so after a freeze the operator reads the block state back. The
    ///         check refuses while any resolved party still reads a state other
    ///         than Frozen, and confirms once every one of them does.
    function test_verify_freeze_by_address_confirms_only_a_frozen_party() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(ORIG),
                    " reads None, not Frozen - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-freeze", _addrs(ORIG), _noIds(), "");

        vm.prank(ADMIN);
        queue.freeze(ORIG);
        script.dispatch("verify-freeze", _addrs(ORIG), _noIds(), "");
    }

    /// @notice Same shape for blacklist: unconfirmed while the party still reads
    ///         None, confirmed once it reads Blacklisted.
    function test_verify_blacklist_confirms_only_a_blacklisted_party() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(ORIG),
                    " reads None, not Blacklisted - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-blacklist", _addrs(ORIG), _noIds(), "");

        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        script.dispatch("verify-blacklist", _addrs(ORIG), _noIds(), "");
    }

    /// @notice A downgrade moves Blacklisted to Frozen, so the unconfirmed case
    ///         here is the party still reading Blacklisted, not None.
    function test_verify_downgrade_confirms_only_a_frozen_party() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(ORIG),
                    " reads Blacklisted, not Frozen - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-downgrade", _addrs(ORIG), _noIds(), "");

        vm.prank(ADMIN);
        queue.downgradeToFrozen(ORIG);
        script.dispatch("verify-downgrade", _addrs(ORIG), _noIds(), "");
    }

    /// @notice A clear moves the party back to None, so the unconfirmed case is
    ///         the party still reading its blocked state.
    function test_verify_unfreeze_confirms_only_a_cleared_party() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(ORIG),
                    " reads Frozen, not None - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-unfreeze", _addrs(ORIG), _noIds(), "");

        vm.prank(ADMIN);
        queue.unfreeze(ORIG);
        script.dispatch("verify-unfreeze", _addrs(ORIG), _noIds(), "");
    }

    function test_verify_unblacklist_confirms_only_a_cleared_party() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.expectRevert(
            bytes(
                string.concat(
                    "NOT CONFIRMED: ",
                    vm.toString(ORIG),
                    " reads Blacklisted, not None - the call did not take effect"
                )
            )
        );
        script.dispatch("verify-unblacklist", _addrs(ORIG), _noIds(), "");

        vm.prank(ADMIN);
        queue.unblacklist(ORIG);
        script.dispatch("verify-unblacklist", _addrs(ORIG), _noIds(), "");
    }

    // --- controller kill switch -----------------------------------------

    function _deployController() internal returns (ExitFeeController ctrl) {
        ExitFeeController impl = new ExitFeeController();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ExitFeeController.initialize.selector, address(0))
        );
        ctrl = ExitFeeController(address(proxy));
    }

    function test_kill_switch_requires_the_controller_address() public {
        vm.expectRevert(
            bytes("set EXIT_FEE_CONTROLLER for disable-perimeter / enable-perimeter and their verify actions")
        );
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), "");
    }

    // --- verifying what an emitted call changed --------------------------

    /// @notice The multisig reports success even when the call inside it failed,
    ///         so after a pause the operator reads the pause state back. The
    ///         check refuses while the queue still reads unpaused.
    function test_verify_pause_confirms_only_a_paused_queue() public {
        vm.expectRevert(bytes("NOT CONFIRMED: the queue reads unpaused - the pause did not take effect"));
        script.dispatch("verify-pause", _noAddrs(), _noIds(), "");

        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        script.dispatch("verify-pause", _noAddrs(), _noIds(), "");
    }

    function test_verify_unpause_confirms_only_an_unpaused_queue() public {
        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        vm.expectRevert(bytes("NOT CONFIRMED: the queue still reads paused - the resume did not take effect"));
        script.dispatch("verify-unpause", _noAddrs(), _noIds(), "");

        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(false);
        script.dispatch("verify-unpause", _noAddrs(), _noIds(), "");
    }

    /// @notice After a switch-on the check reads both the switch and the length:
    ///         a switch that reads on with the length unset holds nothing and is
    ///         not confirmed.
    function test_verify_enable_perimeter_confirms_the_switch_and_the_length() public {
        ExitFeeController ctrl = _deployController();
        script.initController(address(ctrl));
        vm.expectRevert(
            bytes("NOT CONFIRMED: the delay switch reads off - the switch-on did not take effect")
        );
        script.dispatch("verify-enable-perimeter", _noAddrs(), _noIds(), "");

        _switchOnWithLengthUnset(ctrl);
        vm.expectRevert(
            bytes(
                "NOT CONFIRMED: the delay switch reads on but the length is unset (0) - no withdrawal is held"
            )
        );
        script.dispatch("verify-enable-perimeter", _noAddrs(), _noIds(), "");

        ctrl.setGlobalDelaySeconds(1 days);
        script.dispatch("verify-enable-perimeter", _noAddrs(), _noIds(), "");
    }

    function test_verify_disable_perimeter_confirms_only_a_switched_off_delay() public {
        ExitFeeController ctrl = _deployController();
        ctrl.setGlobalDelaySeconds(1 days);
        ctrl.setSecurityPerimeterEnabled(true);
        script.initController(address(ctrl));
        vm.expectRevert(
            bytes("NOT CONFIRMED: the delay switch still reads on - the switch-off did not take effect")
        );
        script.dispatch("verify-disable-perimeter", _noAddrs(), _noIds(), "");

        ctrl.setSecurityPerimeterEnabled(false);
        script.dispatch("verify-disable-perimeter", _noAddrs(), _noIds(), "");
    }

    function test_verify_of_the_delay_switch_requires_the_controller_address() public {
        vm.expectRevert(
            bytes("set EXIT_FEE_CONTROLLER for disable-perimeter / enable-perimeter and their verify actions")
        );
        script.dispatch("verify-enable-perimeter", _noAddrs(), _noIds(), "");
        vm.expectRevert(
            bytes("set EXIT_FEE_CONTROLLER for disable-perimeter / enable-perimeter and their verify actions")
        );
        script.dispatch("verify-disable-perimeter", _noAddrs(), _noIds(), "");
    }

    /// @notice Every emitted call names the verify action that reads back what
    ///         that call changed: the pause state, the delay switch and length,
    ///         or the block states of the parties.
    function test_each_emitted_call_names_the_verify_action_for_what_it_changed() public view {
        assertEq(script.verifyActionFor("pause"), "verify-pause");
        assertEq(script.verifyActionFor("unpause"), "verify-unpause");
        assertEq(script.verifyActionFor("disable-perimeter"), "verify-disable-perimeter");
        assertEq(script.verifyActionFor("enable-perimeter"), "verify-enable-perimeter");
        assertEq(script.verifyActionFor("freeze"), "verify-freeze");
        assertEq(script.verifyActionFor("blacklist"), "verify-blacklist");
        assertEq(script.verifyActionFor("downgrade"), "verify-downgrade");
        assertEq(script.verifyActionFor("unfreeze"), "verify-unfreeze");
        assertEq(script.verifyActionFor("unblacklist"), "verify-unblacklist");
    }

    function test_disable_perimeter_previews_when_enabled() public {
        ExitFeeController ctrl = _deployController();
        ctrl.setGlobalDelaySeconds(1 days);
        ctrl.setSecurityPerimeterEnabled(true);
        script.initController(address(ctrl));
        // preview only - the on-chain state must be untouched afterwards
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), "");
        assertTrue(ctrl.securityPerimeterEnabled(), "preview must not change state");
    }

    function test_disable_perimeter_refuses_nothing_to_submit_silently() public {
        ExitFeeController ctrl = _deployController();
        script.initController(address(ctrl));
        // already disabled: the preview reports ALREADY and emits no calldata,
        // and state stays untouched
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), "");
        assertFalse(ctrl.securityPerimeterEnabled());
    }

    function test_enable_perimeter_previews_when_disabled() public {
        ExitFeeController ctrl = _deployController();
        ctrl.setGlobalDelaySeconds(1 days);
        script.initController(address(ctrl));
        script.dispatch("enable-perimeter", _noAddrs(), _noIds(), "");
        assertFalse(ctrl.securityPerimeterEnabled(), "preview must not change state");
    }

    /// @notice The controller refuses to switch the delay on while its length
    ///         is unset, and through the multisig that refusal does not revert
    ///         the outer transaction. The preview must refuse before any
    ///         calldata is produced.
    function test_enable_perimeter_refuses_while_the_delay_length_is_unset() public {
        ExitFeeController ctrl = _deployController();
        script.initController(address(ctrl));
        vm.expectRevert(
            bytes(
                "enable-perimeter would revert: the global delay length is unset (0) - the Owner must call setGlobalDelaySeconds first"
            )
        );
        script.dispatch("enable-perimeter", _noAddrs(), _noIds(), "");
    }

    /// @dev The controller keeps the delay switch (lowest byte) and length (next
    ///      four bytes) packed in this slot.
    bytes32 constant DELAY_SWITCH_SLOT = bytes32(uint256(267));

    /// @dev Writes the switch on with the length unset. The controller's setters
    ///      refuse this state, so it is written straight into storage.
    function _switchOnWithLengthUnset(ExitFeeController ctrl) internal {
        vm.store(address(ctrl), DELAY_SWITCH_SLOT, bytes32(uint256(1)));
        assertTrue(ctrl.securityPerimeterEnabled(), "switch reads on");
        assertEq(ctrl.globalDelaySeconds(), 0, "length unset");
    }

    /// @notice A switch that reads on with the length unset holds nothing, and
    ///         the controller still refuses to switch on. The preview reports the
    ///         unset length, never that the delay is already on.
    function test_enable_perimeter_reports_an_unset_length_when_the_switch_already_reads_on() public {
        ExitFeeController ctrl = _deployController();
        _switchOnWithLengthUnset(ctrl);
        script.initController(address(ctrl));
        vm.expectRevert(
            bytes(
                "enable-perimeter would revert: the global delay length is unset (0) - the Owner must call setGlobalDelaySeconds first"
            )
        );
        script.dispatch("enable-perimeter", _noAddrs(), _noIds(), "");
    }
}
