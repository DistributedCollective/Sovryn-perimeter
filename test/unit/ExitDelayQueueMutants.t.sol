// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

/// @dev Minimal fungible token stand-in for exit escrow.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "wrbtc withdraw");
    }

    receive() external payable {}
}

/// @dev ERC20 whose outbound `transfer` re-enters the queue. Used to prove a
///      `nonReentrant`-guarded payout path rejects a reentrant call made
///      during its own outbound transfer, mirroring the ingress-side
///      reentrancy check the main suite runs on `recordERC20Exit`.
contract ReentrantPayoutERC20 is ERC20 {
    ExitDelayQueue public queue;
    bool public armed;
    bool public reentered;
    bool public reentryReverted;
    string public reentryRevertReason;

    constructor() ERC20("ReenterOut", "ROUT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setQueue(ExitDelayQueue q) external {
        queue = q;
    }

    function arm() external {
        armed = true;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (armed && from != address(0)) {
            armed = false;
            reentered = true;
            uint256[] memory ids = new uint256[](0);
            try queue.resolveToProtocol(ids, bytes32(0)) {
                reentryReverted = false;
            } catch Error(string memory reason) {
                reentryReverted = true;
                reentryRevertReason = reason;
            } catch {
                reentryReverted = true;
            }
        }
    }
}

/// @dev A token that behaves normally until armed, then burns an extra wei
///      from the SENDER on every transfer — models an upgradeable token that
///      turns fee-on-transfer after funds are already escrowed, so only a
///      post-payout balance check (not the ingress receipt-proof) can catch
///      the shortfall.
contract SwitchableFeeERC20 is ERC20 {
    bool public burnOnTransfer;

    constructor() ERC20("Switchable", "SW") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBurnOnTransfer(bool on) external {
        burnOnTransfer = on;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (burnOnTransfer) _burn(from, 1);
    }
}

/// @dev Registered ingress source; pulls escrow from the test contract.
contract SourceHarness {
    ExitDelayQueue public queue;

    constructor(ExitDelayQueue q) {
        queue = q;
    }

    function recordERC20(
        address token,
        uint128 amount,
        uint32 d,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        ERC20(token).approve(address(queue), amount);
        return
            queue.recordERC20Exit(token, amount, d, surfaceId, subProduct, effOrig, effOwner, receiver, false);
    }
}

/// @title  Queue guard pins
/// @notice Each test here pins one statement the rest of the suite reaches
///         but never depends on: the code runs on some path, but no
///         assertion checks its effect, so silently dropping it would leave
///         every other test green. Each test fails if the statement it names
///         is skipped and passes against the unmodified source.
contract ExitDelayQueueMutantsTest is Test {
    event AccountBlocked(
        address indexed account, IExitDelayQueue.BlockState state, uint256 indexed triggerRequestId, bytes32 reasonHash
    );
    event AllowedSourceSet(address indexed source, bool allowed);
    event AccountUnblocked(address indexed account, IExitDelayQueue.BlockState fromState);
    event SecurityPerimeterPausedSet(bool paused);
    event ExitResolvedToProtocol(
        uint256 indexed id, bytes32 indexed routeId, address destination, uint128 amount
    );
    event ExitResolvedBySIP(uint256 indexed id, address indexed destination, uint128 amount);
    event RecoveryRouteRemoved(bytes32 indexed routeId);
    event TopUpFeasibleSet(bytes32 indexed surfaceId, bool feasible);
    event NativePusherSet(address indexed pusher);
    event AdminSet(address indexed admin);
    event MinimumDelaySet(uint32 seconds_);
    event SurplusSwept(address indexed token, address indexed to, uint256 amount);
    event ExitExecuted(uint256 indexed id, address indexed receiver, address token, uint128 amount);
    event ExitQueued(
        uint256 indexed id,
        address indexed originator,
        address indexed owner,
        address receiver,
        address token,
        uint128 amount,
        uint64 unlockAt,
        bytes32 surfaceId,
        address subProduct
    );

    ExitDelayQueue queue;
    MockERC20 token;
    MockWRBTC wrbtc;
    SourceHarness source;

    address constant OWNER = address(0x0E1);
    address constant ADMIN = address(0xAd11);
    address constant ORIG = address(0x0111);
    address constant OWNR = address(0x0222);
    address constant RCVR = address(0x0333);

    bytes32 constant SURFACE = keccak256("PERIMETER:LENDING_LENDER_WITHDRAW");
    address constant SUBPRODUCT = address(0xB00C);

    uint32 constant MIN_DELAY = 1 hours;
    uint32 constant DELAY = 2 hours;

    function setUp() public {
        wrbtc = new MockWRBTC();

        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory sources = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, sources
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        queue = ExitDelayQueue(payable(address(proxy)));

        token = new MockERC20();
        source = new SourceHarness(queue);

        vm.prank(OWNER);
        queue.addAllowedSource(address(source));
        token.mint(address(source), 1_000_000 ether);
    }

    function _queueErc20(address orig, address ownr, address rcvr) internal returns (uint256 id) {
        id = source.recordERC20(address(token), 10 ether, DELAY, SURFACE, SUBPRODUCT, orig, ownr, rcvr);
    }

    /// @notice A by-request freeze that carries real evidence (a live request id
    ///         and reason) against a party who is ALREADY Blacklisted must still
    ///         hold Blacklisted (no downgrade) but REFRESH the recorded trigger
    ///         and reason to the new evidence, and announce it under the
    ///         held-state (`from`), not the requested one. The existing suite
    ///         only drives the sibling no-evidence path (a plain `freeze` on a
    ///         Blacklisted party, which must leave the old trigger untouched),
    ///         so the refresh-with-evidence branch had never been observed.
    function test_mutant_ExitDelayQueue_747_setBlock_refreshes_trigger_on_blacklisted_with_evidence()
        public
    {
        uint256 firstId = _queueErc20(ORIG, OWNR, RCVR);
        uint256 secondId = _queueErc20(ORIG, OWNR, RCVR);

        vm.prank(ADMIN);
        queue.blacklistFromRequest(firstId, false, keccak256("first"));
        assertEq(queue.blockTrigger(ORIG), firstId, "initial trigger recorded");

        vm.expectEmit(true, true, false, true, address(queue));
        emit AccountBlocked(ORIG, IExitDelayQueue.BlockState.Blacklisted, secondId, keccak256("second"));

        vm.prank(ADMIN);
        queue.freezeFromRequest(secondId, false, keccak256("second"));

        assertEq(
            uint256(queue.blockStateOf(ORIG)),
            uint256(IExitDelayQueue.BlockState.Blacklisted),
            "no downgrade from an evidence-carrying re-block"
        );
        assertEq(queue.blockTrigger(ORIG), secondId, "trigger refreshed to the new evidence");
    }

    /// @notice `initialize` announces every pre-registered source with
    ///         `AllowedSourceSet`, the same event `addAllowedSource` emits later
    ///         for sources added post-deployment — an indexer watching that event
    ///         must see the launch-time set too, not just later additions. The
    ///         existing initializer test only reads back `isAllowedSource` /
    ///         `allowedSources()`, which the state writes a few lines above the
    ///         emit already satisfy, so the emit itself had no observer.
    function test_mutant_ExitDelayQueue_234_initialize_emits_AllowedSourceSet_for_each_source() public {
        ExitDelayQueue impl = new ExitDelayQueue();
        address src = address(0xF00D);
        address[] memory s = new address[](1);
        s[0] = src;
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, s
        );

        vm.recordLogs();
        ExitDelayQueue q = ExitDelayQueue(payable(address(new ERC1967Proxy(address(impl), init))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic0 = keccak256("AllowedSourceSet(address,bool)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(q)) continue;
            if (logs[i].topics.length < 2 || logs[i].topics[0] != topic0) continue;
            address loggedSource = address(uint160(uint256(logs[i].topics[1])));
            bool loggedAllowed = abi.decode(logs[i].data, (bool));
            if (loggedSource == src && loggedAllowed) {
                found = true;
                break;
            }
        }
        assertTrue(found, "AllowedSourceSet not emitted for a source registered at initialize");
    }

    /// @notice The measured-delta ERC20 ingress runs the same shared entry
    ///         guard (`_validateIngress`) as the pull-based path: a zero amount
    ///         must revert `ZeroAmount` before any balance delta is computed.
    ///         Every existing negative test for that guard drives it through
    ///         `recordERC20Exit`; this path had none, so the guard call could be
    ///         dropped here without any test noticing (a zero-amount request
    ///         would simply queue, since a delta of 0 against an amount of 0
    ///         still clears the `ReceivedAmountMismatch` check further down).
    function test_mutant_ExitDelayQueue_295_recordReceivedERC20_validates_ingress() public {
        vm.prank(address(source));
        vm.expectRevert(IExitDelayQueue.ZeroAmount.selector);
        queue.recordReceivedERC20Exit(address(token), 0, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    /// @notice The native push-and-record path runs the same shared entry guard
    ///         as the ERC20 pull path: a zero amount must revert `ZeroAmount`.
    ///         No existing test drives a validation failure through
    ///         `recordNativeExit` (only the value/amount-mismatch guard is
    ///         covered there), so the guard call could be dropped without any
    ///         test noticing.
    function test_mutant_ExitDelayQueue_320_recordNativeExit_validates_ingress() public {
        vm.prank(address(source));
        vm.expectRevert(IExitDelayQueue.ZeroAmount.selector);
        queue.recordNativeExit(0, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    /// @notice The native measured-delta path runs the same shared entry guard
    ///         as the other three ingress functions: a zero amount must revert
    ///         `ZeroAmount` before the balance-delta check. No existing test
    ///         drives a validation failure through `recordReceivedNativeExit`,
    ///         so the guard call could be dropped without any test noticing (a
    ///         zero delta against a zero amount still clears the
    ///         `ReceivedAmountMismatch` check further down).
    function test_mutant_ExitDelayQueue_345_recordReceivedNativeExit_validates_ingress() public {
        vm.prank(address(source));
        vm.expectRevert(IExitDelayQueue.ZeroAmount.selector);
        queue.recordReceivedNativeExit(0, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    /// @notice `ExitQueued` is the authoritative off-chain reconstruction event
    ///         for every escrowed request (per the `getActive` pagination
    ///         NatSpec: a monitor rebuilds the active set from
    ///         `ExitQueued`/`ExitExecuted`, not from iterating storage). No
    ///         existing test asserts it fires, or that its fields match the
    ///         request actually stored, so a wrong receiver/amount/unlock time
    ///         reaching the log — while storage stayed correct — would go
    ///         unnoticed by every off-chain consumer.
    function test_mutant_ExitDelayQueue_435_record_emits_ExitQueued() public {
        vm.expectEmit(true, true, true, true, address(queue));
        emit ExitQueued(
            1, ORIG, OWNR, RCVR, address(token), 10 ether, uint64(block.timestamp + DELAY), SURFACE, SUBPRODUCT
        );
        _queueErc20(ORIG, OWNR, RCVR);
    }

    /// @notice `_executeOne`'s block gate covers all three parties
    ///         {originator, owner, receiver} independently. Every existing
    ///         freeze/blacklist-blocks-execution test blocks either the
    ///         originator or the receiver; none blocks the owner alone (with
    ///         the originator executing on the owner's behalf), so the owner
    ///         check specifically could be dropped from the gate without any
    ///         test noticing.
    function test_mutant_ExitDelayQueue_474_executeOne_checks_owner_blocked() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(OWNR);
        vm.prank(ORIG);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, OWNR, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.executeExit(id);
    }

    /// @notice `ExitExecuted` from the plain `executeExit`/`executeExits` path
    ///         is a distinct emit statement from the one `recoverStuckExit`
    ///         raises on its own terminal payout. The existing tests that check
    ///         `ExitExecuted`'s fields only exercise the recovery leg; the
    ///         ordinary execution path's own emit had no observer.
    function test_mutant_ExitDelayQueue_486_executeOne_emits_ExitExecuted() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(true, true, false, true, address(queue));
        emit ExitExecuted(id, RCVR, address(token), 10 ether);
        vm.prank(OWNR);
        queue.executeExit(id);
    }

    /// @notice `recoverStuckExit` prunes the terminated request from both
    ///         parties' active-index sets, the same as the plain execution
    ///         path does. The existing `getActive`-removal test only exercises
    ///         `executeExit`; a request settled through the recovery leg
    ///         instead would stay listed as active forever without this.
    function test_mutant_ExitDelayQueue_549_recoverStuckExit_removes_from_active() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.recoverStuckExit(id, address(0xA17E));

        (uint256[] memory origActive,) = queue.getActive(ORIG, 0, 10);
        (uint256[] memory ownrActive,) = queue.getActive(OWNR, 0, 10);
        assertEq(origActive.length, 0, "originator's active set not pruned by recovery");
        assertEq(ownrActive.length, 0, "owner's active set not pruned by recovery");
    }

    /// @notice The single-id `freezeFromRequest` overload is gated
    ///         `onlyAdminOrOwner`, same as its batch sibling. Only the batch
    ///         (`uint256[]`) overload has an authority test; the single-id
    ///         overload's own modifier attachment had no observer, so it could
    ///         be dropped without any test noticing.
    function test_mutant_ExitDelayQueue_620_freezeFromRequest_single_only_admin_or_owner() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        address outsider = address(0xBAD1);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, outsider));
        queue.freezeFromRequest(id, false, bytes32(0));
    }

    /// @notice The single-id `blacklistFromRequest` overload is gated
    ///         `onlyAdminOrOwner`, same as its batch sibling. Only the batch
    ///         overload has an authority test; the single-id overload's own
    ///         modifier attachment had no observer.
    function test_mutant_ExitDelayQueue_628_blacklistFromRequest_single_only_admin_or_owner() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        address outsider = address(0xBAD2);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, outsider));
        queue.blacklistFromRequest(id, false, bytes32(0));
    }

    /// @notice A plain freeze/blacklist (the ordinary `_setBlock` path — an
    ///         address moving out of `None`, not the already-Blacklisted hold
    ///         branch) announces the new state via `AccountBlocked`. No
    ///         existing test asserts this emit for that ordinary path, only
    ///         for the hold-branch refresh, so it had no observer.
    function test_mutant_ExitDelayQueue_757_setBlock_emits_AccountBlocked() public {
        vm.expectEmit(true, true, false, true, address(queue));
        emit AccountBlocked(ORIG, IExitDelayQueue.BlockState.Frozen, 0, bytes32(0));
        vm.prank(ADMIN);
        queue.freeze(ORIG);
    }

    /// @notice Clearing a block resets every piece of state a block set: the
    ///         recorded trigger goes back to 0, the address drops out of the
    ///         `blockedAccounts` enumeration, and `AccountUnblocked` announces
    ///         it. No existing unfreeze/unblacklist test reads back the
    ///         trigger, the enumeration, or the event after clearing — only
    ///         that `blockStateOf` returns `None` — so each of those three
    ///         effects could be dropped independently without any test
    ///         noticing a stale trigger or a stuck enumeration entry.
    function test_mutant_ExitDelayQueue_772_774_clearBlock_resets_trigger_enumeration_and_emits() public {
        // A single-party request so the by-request freeze blocks exactly ORIG.
        uint256 id = _queueErc20(ORIG, ORIG, RCVR);
        vm.prank(ADMIN);
        queue.freezeFromRequest(id, false, keccak256("evidence"));
        assertEq(queue.blockTrigger(ORIG), id, "trigger recorded by the freeze");
        (address[] memory before,) = queue.blockedAccounts(0, 10);
        assertEq(before.length, 1, "ORIG enumerated while blocked");

        vm.expectEmit(true, false, false, true, address(queue));
        emit AccountUnblocked(ORIG, IExitDelayQueue.BlockState.Frozen);
        vm.prank(ADMIN);
        queue.unfreeze(ORIG);

        assertEq(queue.blockTrigger(ORIG), 0, "trigger reset on clear");
        (address[] memory after_,) = queue.blockedAccounts(0, 10);
        assertEq(after_.length, 0, "ORIG dropped from the blocked enumeration");
    }

    /// @notice `setSecurityPerimeterPaused` announces every change via
    ///         `SecurityPerimeterPausedSet`. No existing test asserts the
    ///         emit — only the resulting paused/unpaused behaviour on other
    ///         entry points — so it had no observer.
    function test_mutant_ExitDelayQueue_787_setSecurityPerimeterPaused_emits() public {
        vm.expectEmit(false, false, false, true, address(queue));
        emit SecurityPerimeterPausedSet(true);
        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
    }

    /// @notice `resolveToProtocol` prunes the resolved request from both
    ///         parties' active-index sets, the same as execution and the
    ///         recovery leg do, and announces the resolution via
    ///         `ExitResolvedToProtocol`. No existing Leg-2 test reads
    ///         `getActive` afterward or asserts the emit, so a request
    ///         resolved to the protocol would stay listed as active forever,
    ///         or the event could go missing, without either being noticed.
    function test_mutant_ExitDelayQueue_825_828_resolveToProtocol_removes_from_active_and_emits()
        public
    {
        uint128 amount = 10 ether;
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0xDE57),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);

        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.expectEmit(true, true, false, true, address(queue));
        emit ExitResolvedToProtocol(id, routeId, address(0xDE57), amount);
        vm.prank(ADMIN);
        queue.resolveToProtocol(ids, routeId);

        (uint256[] memory origActive,) = queue.getActive(ORIG, 0, 10);
        (uint256[] memory ownrActive,) = queue.getActive(OWNR, 0, 10);
        assertEq(origActive.length, 0, "originator's active set not pruned by resolveToProtocol");
        assertEq(ownrActive.length, 0, "owner's active set not pruned by resolveToProtocol");
    }

    /// @notice `resolveToProtocol` is `nonReentrant`, guarding its own
    ///         cross-contract payout the same way ingress and execution do.
    ///         No existing test drives a reentrant call through this specific
    ///         payout, so the modifier's attachment here had no observer: a
    ///         hostile escrow token that calls back into the queue during its
    ///         outbound `transfer` must have that reentrant call rejected, not
    ///         allowed to run concurrently with the in-flight resolution.
    function test_mutant_ExitDelayQueue_798_resolveToProtocol_is_nonReentrant() public {
        ReentrantPayoutERC20 hostile = new ReentrantPayoutERC20();
        hostile.setQueue(queue);
        hostile.mint(address(source), 1000 ether);

        vm.prank(OWNER);
        queue.addAllowedSource(address(source));
        uint256 id = source.recordERC20(address(hostile), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);

        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(hostile),
            destination: address(0xDE57),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);

        hostile.arm();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(ADMIN);
        queue.resolveToProtocol(ids, routeId);

        assertTrue(hostile.reentered(), "reentrancy path not exercised");
        assertTrue(hostile.reentryReverted(), "nonReentrant did not block the reentrant call");
        assertEq(
            hostile.reentryRevertReason(),
            "ReentrancyGuard: reentrant call",
            "revert was not the ReentrancyGuard"
        );
    }

    /// @notice `resolveToProtocol`'s payout must leave the queue fully backed
    ///         for every request still Queued, the same post-payout solvency
    ///         floor `executeExit`, `recoverStuckExit`, and `sweepSurplus`
    ///         already enforce. No existing test drives a solvency failure
    ///         through this specific leg, so its own solvency check could be
    ///         dropped without any test noticing — a token that turns
    ///         fee-on-transfer after escrow would then silently drain a
    ///         second party's backing.
    function test_mutant_ExitDelayQueue_832_resolveToProtocol_checks_solvency() public {
        SwitchableFeeERC20 sneaky = new SwitchableFeeERC20();
        sneaky.mint(address(source), 100 ether);
        vm.prank(OWNER);
        queue.addAllowedSource(address(source));

        uint256 id = source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        // A second escrow so there is somebody left to shortchange.
        source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);

        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(sneaky),
            destination: address(0xDE57),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);

        sneaky.setBurnOnTransfer(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        queue.resolveToProtocol(ids, routeId);
    }

    /// @notice `resolveBySIP` prunes the resolved request from both parties'
    ///         active-index sets, announces the resolution via
    ///         `ExitResolvedBySIP`, and (like the other two payout legs)
    ///         enforces the post-payout solvency floor. No existing Leg-3 test
    ///         reads `getActive` afterward, asserts the emit, or drives a
    ///         solvency failure through this leg, so all three could be
    ///         dropped independently without any test noticing.
    function test_mutant_ExitDelayQueue_870_875_resolveBySIP_removes_emits_and_checks_solvency()
        public
    {
        uint128 amount = 10 ether;
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        address dest = address(0x7EEA);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectEmit(true, true, false, true, address(queue));
        emit ExitResolvedBySIP(id, dest, amount);
        vm.prank(OWNER);
        queue.resolveBySIP(ids, dest); // still locked -> resolvable regardless of block state

        (uint256[] memory origActive,) = queue.getActive(ORIG, 0, 10);
        (uint256[] memory ownrActive,) = queue.getActive(OWNR, 0, 10);
        assertEq(origActive.length, 0, "originator's active set not pruned by resolveBySIP");
        assertEq(ownrActive.length, 0, "owner's active set not pruned by resolveBySIP");

        // Solvency: a token that turns fee-on-transfer after escrow must still
        // trip the post-payout backstop on this leg.
        SwitchableFeeERC20 sneaky = new SwitchableFeeERC20();
        sneaky.mint(address(source), 100 ether);
        vm.prank(OWNER);
        queue.addAllowedSource(address(source));
        uint256 id2 =
            source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        sneaky.setBurnOnTransfer(true);
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = id2;
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        queue.resolveBySIP(ids2, dest);
    }

    /// @notice `resolveBySIP`'s bounded predicate admits a request that is
    ///         still locked or paused OR has a blocked party — three
    ///         independent reasons combined with OR. Every existing positive
    ///         test for the blocked-party reason queues the request without
    ///         warping past `unlockAt`, so the "still locked" clause alone
    ///         already makes it resolvable; the blocked-party check itself
    ///         (`_isBlocked`) never had to evaluate true to pass those tests,
    ///         and could be dropped (always reading "not blocked") without
    ///         any of them noticing.
    function test_mutant_ExitDelayQueue_880_resolveBySIP_blocked_party_alone_is_resolvable() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY); // unlocked and unpaused: only a blocked party can admit it
        vm.prank(ADMIN);
        queue.freeze(RCVR);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(OWNER);
        queue.resolveBySIP(ids, address(0x7EEA)); // must not revert NotResolvableBySIP
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.ResolvedBySIP));
    }

    /// @notice `setRecoveryRoute`'s id is a deterministic hash of the route's
    ///         own identifying fields, not an arbitrary handle — two distinct
    ///         routes must resolve to two distinct, independently addressable
    ///         storage entries. Every existing route test registers exactly
    ///         one route per queue and simply reuses whatever id came back, so
    ///         the derivation could collapse to a constant (colliding every
    ///         route into one storage slot) without any test noticing.
    function test_mutant_ExitDelayQueue_906_setRecoveryRoute_id_is_derived_per_route() public {
        IExitDelayQueue.RecoveryRoute memory routeA = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0xAAAA),
            topUpPool: false
        });
        IExitDelayQueue.RecoveryRoute memory routeB = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: keccak256("OTHER_SURFACE"),
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0xBBBB),
            topUpPool: false
        });
        vm.startPrank(OWNER);
        bytes32 idA = queue.setRecoveryRoute(routeA);
        bytes32 idB = queue.setRecoveryRoute(routeB);
        vm.stopPrank();

        assertTrue(idA != idB, "distinct routes must get distinct ids");
        assertEq(queue.getRecoveryRoute(idA).destination, address(0xAAAA), "route A not overwritten by B");
        assertEq(queue.getRecoveryRoute(idB).destination, address(0xBBBB), "route B independently stored");
    }

    /// @notice `removeRecoveryRoute` drops the id from the enumeration
    ///         (`recoveryRouteIds`) and announces the removal via
    ///         `RecoveryRouteRemoved`. The existing removal test only checks
    ///         that resolving THROUGH the removed route now fails; it never
    ///         reads the enumeration back or asserts the emit, so a route
    ///         removed from the routing table could still linger in the
    ///         id listing forever without any test noticing.
    function test_mutant_ExitDelayQueue_917_918_removeRecoveryRoute_updates_enumeration_and_emits()
        public
    {
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0xAAAA),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);
        assertEq(queue.recoveryRouteIds().length, 1, "route enumerated after set");

        vm.expectEmit(true, false, false, true, address(queue));
        emit RecoveryRouteRemoved(routeId);
        vm.prank(OWNER);
        queue.removeRecoveryRoute(routeId);

        assertEq(queue.recoveryRouteIds().length, 0, "route dropped from the enumeration on removal");
    }

    /// @notice `setTopUpFeasible` announces every change via
    ///         `TopUpFeasibleSet`. No existing test asserts the emit, only
    ///         the resulting `topUpFeasible` readback and its downstream
    ///         effect on `setRecoveryRoute`.
    function test_mutant_ExitDelayQueue_924_setTopUpFeasible_emits() public {
        vm.expectEmit(true, false, false, true, address(queue));
        emit TopUpFeasibleSet(SURFACE, true);
        vm.prank(OWNER);
        queue.setTopUpFeasible(SURFACE, true);
    }

    /// @notice `addAllowedSource` announces every newly-registered source via
    ///         `AllowedSourceSet`. No existing test asserts the emit, only
    ///         the resulting `isAllowedSource` readback.
    function test_mutant_ExitDelayQueue_934_addAllowedSource_emits() public {
        address src = address(0xF00D1);
        vm.expectEmit(true, false, false, true, address(queue));
        emit AllowedSourceSet(src, true);
        vm.prank(OWNER);
        queue.addAllowedSource(src);
    }

    /// @notice `removeAllowedSource` announces every removal via
    ///         `AllowedSourceSet(src, false)`. No existing test asserts the
    ///         emit, only the resulting `isAllowedSource` readback.
    function test_mutant_ExitDelayQueue_942_removeAllowedSource_emits() public {
        vm.prank(OWNER);
        queue.addAllowedSource(address(0xF00D2));
        vm.expectEmit(true, false, false, true, address(queue));
        emit AllowedSourceSet(address(0xF00D2), false);
        vm.prank(OWNER);
        queue.removeAllowedSource(address(0xF00D2));
    }

    /// @notice `setNativePusher` persists the new address for the public
    ///         `nativePusher` getter and announces it via `NativePusherSet`.
    ///         The field is documented as vestigial (no execution path reads
    ///         it any more), so the getter and the event are its ONLY
    ///         observable effects — and no existing test reads either back.
    function test_mutant_ExitDelayQueue_948_949_setNativePusher_persists_and_emits() public {
        address pusher = address(0xF00D3);
        vm.expectEmit(true, false, false, true, address(queue));
        emit NativePusherSet(pusher);
        vm.prank(OWNER);
        queue.setNativePusher(pusher);
        assertEq(queue.nativePusher(), pusher, "nativePusher getter not updated");
    }

    /// @notice `setAdmin` announces the rotation via `AdminSet`. No existing
    ///         test asserts the emit, only the resulting `admin` readback.
    function test_mutant_ExitDelayQueue_956_setAdmin_emits() public {
        address newAdmin = address(0xF00D4);
        vm.expectEmit(true, false, false, true, address(queue));
        emit AdminSet(newAdmin);
        vm.prank(OWNER);
        queue.setAdmin(newAdmin);
    }

    /// @notice `setMinimumDelaySeconds` announces the new floor via
    ///         `MinimumDelaySet`. No existing test asserts the emit, only the
    ///         resulting `minimumDelaySeconds` readback.
    function test_mutant_ExitDelayQueue_964_setMinimumDelaySeconds_emits() public {
        vm.expectEmit(false, false, false, true, address(queue));
        emit MinimumDelaySet(2 hours);
        vm.prank(OWNER);
        queue.setMinimumDelaySeconds(2 hours);
    }

    /// @notice `sweepSurplus` announces every sweep (native and ERC20 arms)
    ///         via `SurplusSwept`. No existing test asserts either emit, only
    ///         the resulting balance movement.
    function test_mutant_ExitDelayQueue_977_983_sweepSurplus_emits_for_both_arms() public {
        // Native arm.
        vm.deal(address(source), 5 ether);
        vm.prank(address(source));
        queue.recordNativeExit{value: 5 ether}(5 ether, DELAY, SURFACE, address(0), ORIG, OWNR, RCVR);
        vm.deal(address(queue), address(queue).balance + 2 ether);
        vm.expectEmit(true, true, false, true, address(queue));
        emit SurplusSwept(address(0), address(0x5EE), 2 ether);
        vm.prank(OWNER);
        queue.sweepSurplus(address(0), address(0x5EE));

        // ERC20 arm.
        _queueErc20(ORIG, OWNR, RCVR);
        token.mint(address(queue), 3 ether);
        vm.expectEmit(true, true, false, true, address(queue));
        emit SurplusSwept(address(token), address(0x5EE), 3 ether);
        vm.prank(OWNER);
        queue.sweepSurplus(address(token), address(0x5EE));
    }

    /// @notice `getActive`'s early-out for an out-of-range cursor is what
    ///         keeps the page arithmetic safe: past it, `end - cursor` can
    ///         only underflow when `cursor` exceeds the set's length. Every
    ///         existing pagination test either stays within range or hits
    ///         `cursor == len` exactly (a degenerate case the general
    ///         arithmetic also happens to handle without underflowing), so a
    ///         cursor placed strictly PAST the set's length had never been
    ///         tried.
    function test_mutant_ExitDelayQueue_1062_getActive_cursor_past_length_returns_empty() public {
        _queueErc20(ORIG, OWNR, RCVR); // one active id for ORIG
        (uint256[] memory ids, uint256 next) = queue.getActive(ORIG, 100, 5);
        assertEq(ids.length, 0, "cursor past the set length yields an empty page");
        assertEq(next, 0, "no further cursor past the set length");
    }

    /// @notice `getActive` must return the party's ACTUAL request ids, not
    ///         merely a correctly-sized page. Every existing pagination test
    ///         asserts only `ids.length` and `nextCursor`; none reads back a
    ///         single element, so the loop body that actually populates the
    ///         page could be dropped (leaving every slot at its zero default)
    ///         without any test noticing.
    function test_mutant_ExitDelayQueue_1068_getActive_returns_actual_ids() public {
        uint256 id1 = _queueErc20(ORIG, OWNR, RCVR);
        uint256 id2 = _queueErc20(ORIG, OWNR, RCVR);
        (uint256[] memory ids,) = queue.getActive(ORIG, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1, "first page slot must be the first queued id, not the zero default");
        assertEq(ids[1], id2, "second page slot must be the second queued id, not the zero default");
    }

    /// @notice `blockedAccounts` must return the ACTUAL blocked addresses,
    ///         not merely a correctly-sized page. The existing enumeration
    ///         test asserts only the page length and the total, never a
    ///         single element, so the loop body that populates the page could
    ///         be dropped (leaving every slot at its zero-address default)
    ///         without any test noticing.
    function test_mutant_ExitDelayQueue_1102_blockedAccounts_returns_actual_addresses() public {
        vm.startPrank(ADMIN);
        queue.freeze(ORIG);
        queue.blacklist(OWNR);
        vm.stopPrank();
        (address[] memory got,) = queue.blockedAccounts(0, 10);
        assertEq(got.length, 2);
        assertEq(got[0], ORIG, "first page slot must be the first blocked address, not the zero default");
        assertEq(got[1], OWNR, "second page slot must be the second blocked address, not the zero default");
    }

    /// @notice The measured-delta ERC20 ingress must compute its non-backing
    ///         surplus as `backing - escrowed`, not merely SOME function that
    ///         happens to clear the `>= amount` check on a first-ever record
    ///         (where `escrowed` is still 0 and subtraction and addition
    ///         coincide). With a nonzero pre-existing `escrowed` from an
    ///         earlier request on the same token, an under-delivered second
    ///         push must still revert `ReceivedAmountMismatch` — a wrong
    ///         (larger) delta would silently record the shortfall against the
    ///         FIRST request's already-escrowed backing.
    function test_mutant_ExitDelayQueue_303_recordReceivedERC20_delta_uses_subtraction() public {
        // First request establishes escrowed = 10 ether backing.
        vm.prank(address(source));
        token.transfer(address(queue), 10 ether);
        vm.prank(address(source));
        queue.recordReceivedERC20Exit(address(token), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        assertEq(queue.totalEscrowed(address(token)), 10 ether);

        // Second claim of 8 ether, but only 3 ether of NEW value is pushed:
        // correct delta = backing(13) - escrowed(10) = 3 < 8 -> must revert.
        vm.prank(address(source));
        token.transfer(address(queue), 3 ether);
        vm.prank(address(source));
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.ReceivedAmountMismatch.selector, address(token), 3 ether, 8 ether)
        );
        queue.recordReceivedERC20Exit(address(token), 8 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    /// @notice The native measured-delta ingress has the same subtraction
    ///         requirement as its ERC20 twin: with a nonzero pre-existing
    ///         `escrowed` native balance, an under-delivered second push must
    ///         still revert rather than being masked by a larger delta.
    function test_mutant_ExitDelayQueue_348_recordReceivedNativeExit_delta_uses_subtraction() public {
        vm.deal(address(source), 20 ether);
        vm.prank(address(source));
        (bool ok,) = payable(address(queue)).call{value: 10 ether}("");
        assertTrue(ok);
        vm.prank(address(source));
        queue.recordReceivedNativeExit(10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        assertEq(queue.totalEscrowed(address(0)), 10 ether);

        // Second claim of 8 ether, but only 3 ether of NEW value is pushed:
        // correct delta = backing(13) - escrowed(10) = 3 < 8 -> must revert.
        vm.prank(address(source));
        (bool ok2,) = payable(address(queue)).call{value: 3 ether}("");
        assertTrue(ok2);
        vm.prank(address(source));
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.ReceivedAmountMismatch.selector, address(0), 3 ether, 8 ether)
        );
        queue.recordReceivedNativeExit(8 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    /// @notice `recoverStuckExit`'s gas floor is exactly
    ///         `RECOVER_PAYOUT_GAS + RECOVER_GAS_FLOOR` (3,000,000 +
    ///         200,000). The existing under-budget test supplies far less
    ///         gas than either bound, so it cannot tell the sum from the
    ///         difference (2,800,000): both revert. Supplying gas strictly
    ///         between the two bounds distinguishes them — the real floor
    ///         must still revert here.
    function test_mutant_ExitDelayQueue_598_recoverStuckExit_gas_floor_is_the_sum() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(ExitDelayQueue.InsufficientGasForRecovery.selector);
        queue.recoverStuckExit{gas: 3_100_000}(id, address(0xA17E));
    }

    /// @notice `resolveToProtocol` must DECREMENT `totalEscrowed` by the
    ///         settled amount, not merely apply some operator that happens to
    ///         land on the right answer when a single request is the entire
    ///         escrowed balance for its token (where subtraction and modulo
    ///         coincide at 0). With a second request still outstanding on the
    ///         same token, the remaining balance must reflect subtraction.
    function test_mutant_ExitDelayQueue_826_resolveToProtocol_decrements_by_subtraction() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR); // 10 ether
        _queueErc20(ORIG, OWNR, RCVR); // another 10 ether, same token
        assertEq(queue.totalEscrowed(address(token)), 20 ether);

        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0xDE57),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(ADMIN);
        queue.resolveToProtocol(ids, routeId);

        assertEq(queue.totalEscrowed(address(token)), 10 ether, "remaining escrow must be 20-10, not 20%10");
    }

    /// @notice `resolveBySIP` has the same decrement requirement as
    ///         `resolveToProtocol`: with a second request still outstanding
    ///         on the same token, the remaining escrow must reflect
    ///         subtraction, not an operator that only coincides with it when
    ///         a single request is the entire escrowed balance.
    function test_mutant_ExitDelayQueue_871_resolveBySIP_decrements_by_subtraction() public {
        uint256 id = _queueErc20(ORIG, OWNR, RCVR); // 10 ether
        _queueErc20(ORIG, OWNR, RCVR); // another 10 ether, same token
        assertEq(queue.totalEscrowed(address(token)), 20 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(OWNER);
        queue.resolveBySIP(ids, address(0x7EEA)); // still locked -> resolvable

        assertEq(queue.totalEscrowed(address(token)), 10 ether, "remaining escrow must be 20-10, not 20%10");
    }

    /// @notice `sweepSurplus`'s ERC20 arm must compute the sweepable surplus
    ///         as `balance - escrowed`, not an operator that only coincides
    ///         with subtraction when the balance is less than twice the
    ///         escrowed amount (where the existing test's numbers happen to
    ///         land). A larger surplus must be swept in full.
    function test_mutant_ExitDelayQueue_982_sweepSurplus_erc20_uses_subtraction() public {
        _queueErc20(ORIG, OWNR, RCVR); // escrowed = 10 ether
        token.mint(address(queue), 15 ether); // dust >= escrowed, so mod would diverge
        vm.prank(OWNER);
        queue.sweepSurplus(address(token), address(0x5EE));
        assertEq(token.balanceOf(address(0x5EE)), 15 ether, "full surplus (25-10), not 25 mod 10");
        assertEq(token.balanceOf(address(queue)), 10 ether, "backing intact");
    }
}
