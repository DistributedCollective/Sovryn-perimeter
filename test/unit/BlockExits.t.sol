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
///      parallel tests). Also surfaces the resolved party list, which is the
///      part an operator relies on and the part that must not drift from the
///      contract's own `_blockFromRequest` rules.
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
        bool freezeReceiver,
        string memory reason
    ) external view {
        _dispatch(action, actors, ids, freezeReceiver, reason);
    }

    function partiesBehind(uint256[] memory ids, bool freezeReceiver)
        external
        view
        returns (address[] memory)
    {
        return _partiesBehind(ids, freezeReceiver);
    }
}

/// @title  Emergency block preview - 07_BlockExits
/// @notice Proves the operator script refuses, up front, every call that would
///         revert on-chain after the Safe had already collected signatures, and
///         that its by-request party resolution matches the parties the queue
///         itself blocks.
contract BlockExitsTest is Test {
    address constant OWNER = address(0x0E7E7);
    address constant ADMIN = address(0x6DA12D);
    address constant ORIG = address(0x0121);
    address constant OWNR = address(0x0233);
    address constant RCVR = address(0x0455);
    address constant STRANGER = address(0x5747);

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
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        assertEq(script.partiesBehind(ids, true).length, 3);
    }

    /// @dev The on-chain batch is atomic, so an unknown id must be rejected
    ///      before signatures are collected, not after.
    function test_unknown_request_id_is_rejected_up_front() public {
        vm.expectRevert(bytes("unknown request id 99 - the batch is atomic"));
        script.partiesBehind(_ids(99), false);
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
        script.dispatch("unfreeze", two, _noIds(), false, "");
    }

    function test_unfreeze_refuses_a_blacklisted_address() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.expectRevert(
            bytes("unfreeze requires every address to be Frozen - use unblacklist for blacklisted ones")
        );
        script.dispatch("unfreeze", _addrs(ORIG), _noIds(), false, "");
    }

    function test_unblacklist_refuses_a_frozen_address() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.expectRevert(
            bytes("unblacklist requires every address to be Blacklisted - use unfreeze for frozen ones")
        );
        script.dispatch("unblacklist", _addrs(ORIG), _noIds(), false, "");
    }

    function test_unfreeze_accepts_a_frozen_address() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        script.dispatch("unfreeze", _addrs(ORIG), _noIds(), false, "");
    }

    function test_clear_rejects_request_ids() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert(bytes("clears are by address only - the queue has no by-request clear"));
        script.dispatch("unfreeze", _addrs(ORIG), _ids(id), false, "");
    }

    // --- input discipline -----------------------------------------------

    function test_freeze_rejects_both_input_modes_at_once() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS, not both - they build different calls"));
        script.dispatch("freeze", _addrs(STRANGER), _ids(id), false, "");
    }

    function test_freeze_requires_some_input() public {
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS"));
        script.dispatch("freeze", _noAddrs(), _noIds(), false, "");
    }

    function test_unknown_action_is_rejected() public {
        vm.expectRevert(
            bytes(
                "BLOCK_ACTION must be one of: freeze, blacklist, unfreeze, unblacklist, pause, unpause, verify, disable-perimeter, enable-perimeter"
            )
        );
        script.dispatch("halt", _addrs(ORIG), _noIds(), false, "");
    }

    // --- happy paths ----------------------------------------------------

    function test_freeze_and_blacklist_preview_by_actor() public view {
        script.dispatch("freeze", _addrs(ORIG), _noIds(), false, "");
        script.dispatch("blacklist", _addrs(ORIG), _noIds(), false, "");
    }

    function test_block_preview_by_request() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        script.dispatch("freeze", _noAddrs(), _ids(id), true, "incident drill");
        script.dispatch("blacklist", _noAddrs(), _ids(id), false, "");
    }

    function test_pause_and_unpause_preview() public {
        script.dispatch("pause", _noAddrs(), _noIds(), false, "");
        // Already unpaused: the script reports nothing to submit rather than
        // emitting calldata for a no-op Safe transaction.
        script.dispatch("unpause", _noAddrs(), _noIds(), false, "");

        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        script.dispatch("unpause", _noAddrs(), _noIds(), false, "");
    }

    function test_verify_reads_live_state() public {
        uint256 id = _record(ORIG, OWNR, RCVR);
        vm.prank(ADMIN);
        queue.freezeFromRequest(_ids(id), true, keccak256("drill"));
        script.dispatch("verify", _noAddrs(), _ids(id), true, "");
        script.dispatch("verify", _addrs(ORIG), _noIds(), false, "");
    }

    function test_verify_requires_input() public {
        vm.expectRevert(bytes("set BLOCK_ACTORS or BLOCK_REQUEST_IDS"));
        script.dispatch("verify", _noAddrs(), _noIds(), false, "");
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
        vm.expectRevert(bytes("set EXIT_FEE_CONTROLLER for disable-perimeter / enable-perimeter"));
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), false, "");
    }

    function test_disable_perimeter_previews_when_enabled() public {
        ExitFeeController ctrl = _deployController();
        ctrl.setSecurityPerimeterEnabled(true);
        script.initController(address(ctrl));
        // preview only - the on-chain state must be untouched afterwards
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), false, "");
        assertTrue(ctrl.securityPerimeterEnabled(), "preview must not change state");
    }

    function test_disable_perimeter_refuses_nothing_to_submit_silently() public {
        ExitFeeController ctrl = _deployController();
        script.initController(address(ctrl));
        // already disabled: the preview reports ALREADY and emits no calldata,
        // and state stays untouched
        script.dispatch("disable-perimeter", _noAddrs(), _noIds(), false, "");
        assertFalse(ctrl.securityPerimeterEnabled());
    }

    function test_enable_perimeter_previews_when_disabled() public {
        ExitFeeController ctrl = _deployController();
        script.initController(address(ctrl));
        script.dispatch("enable-perimeter", _noAddrs(), _noIds(), false, "");
        assertFalse(ctrl.securityPerimeterEnabled(), "preview must not change state");
    }
}
