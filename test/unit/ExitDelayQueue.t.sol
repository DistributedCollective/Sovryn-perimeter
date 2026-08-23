// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

// ─── Mocks ──────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer token: keeps 1 wei on every transfer. Used to prove the
///      receipt-proof ingress rejects a mismatched received amount.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fot", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 value) internal override {
        // OZ 4.9: split into a 1-wei burn + (value-1) delivered, so the
        // recipient measures value-1 (fee-on-transfer behavior).
        super._transfer(from, address(0xdead), 1);
        super._transfer(from, to, value - 1);
    }
}

/// @dev Minimal WRBTC: mints on deposit-equivalent, burns + sends native on
///      withdraw (unwrap path).
/// @dev A token that behaves normally until `setBurnOnTransfer` is flipped, then
///      burns an extra wei from the SENDER on every transfer. Models an
///      upgradeable token that becomes fee-on-transfer AFTER funds are escrowed
///      — the ingress receipt-proof cannot catch that, only the payout can.
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

/// @dev Charges the SENDER an extra wei, but only when paying one particular
///      recipient. Models the case that separates a solvency failure from a
///      bouncing receiver: the stored-receiver payout leaves the queue short
///      while the alternate-receiver payout would not.
contract RecipientBiasedFeeERC20 is ERC20 {
    address public taxedRecipient;

    constructor() ERC20("Biased", "BIAS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxedRecipient(address r) external {
        taxedRecipient = r;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (to == taxedRecipient && taxedRecipient != address(0)) _burn(from, 1);
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

/// @dev A source contract that pulls funds from the test and calls the queue's
///      pull-ingress. Mirrors an iToken proxy (`_allowedSource`).
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
        address receiver,
        bool unwrap
    ) external returns (uint256) {
        ERC20(token).approve(address(queue), amount);
        return queue.recordERC20Exit(
            token, amount, d, surfaceId, subProduct, effOrig, effOwner, receiver, unwrap
        );
    }

    function recordReceivedERC20(
        address token,
        uint128 amount,
        uint32 d,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        // push then record (measured-delta path)
        ERC20(token).transfer(address(queue), amount);
        return queue.recordReceivedERC20Exit(
            token, amount, d, surfaceId, subProduct, effOrig, effOwner, receiver
        );
    }

    function recordNative(
        uint128 amount,
        uint32 d,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external payable returns (uint256) {
        // Forward the caller-supplied msg.value (which may deliberately differ
        // from `amount` in the mismatch test) so the queue's msg.value==amount
        // guard is actually exercised.
        return queue.recordNativeExit{value: msg.value}(
            amount, d, surfaceId, subProduct, effOrig, effOwner, receiver
        );
    }

    function recordReceivedNative(
        uint128 amount,
        uint32 d,
        bytes32 surfaceId,
        address subProduct,
        address effOrig,
        address effOwner,
        address receiver
    ) external returns (uint256) {
        return queue.recordReceivedNativeExit(amount, d, surfaceId, subProduct, effOrig, effOwner, receiver);
    }
}

/// @dev A native pusher (Zero ActivePool). Pushes value into the queue's
///      receive() before the record call fires in the same tx.
contract NativePusherHarness {
    function push(address payable queue, uint256 amount) external {
        (bool ok,) = queue.call{value: amount}("");
        require(ok, "push");
    }

    receive() external payable {}
}

/// @dev A receiver that always reverts on receive — proves fail-closed payout.
contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @dev ERC20 whose transferFrom re-enters the queue's ingress. Proves
///      the `nonReentrant` guard on the four record* fns rejects a re-entrant
///      record during the token pull. The reentrant call MUST revert with the
///      OZ 4.9 require string "ReentrancyGuard: reentrant call"; the harness
///      surfaces both whether it reverted and the exact revert reason.
contract ReentrantERC20 is ERC20 {
    ExitDelayQueue public queue;
    bool public armed;
    bool public reentered;
    bool public reentryReverted;
    string public reentryRevertReason;

    constructor() ERC20("Reenter", "RNT") {}

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
            armed = false; // one-shot so we don't recurse forever
            reentered = true;
            // Re-enter the SAME pull ingress mid-transfer; nonReentrant must trip.
            try queue.recordERC20Exit(
                address(this),
                uint128(1),
                2 hours,
                keccak256("S"),
                address(0xB00C),
                address(0x111),
                address(0x222),
                address(0x333),
                false
            ) {
                reentryReverted = false;
            } catch Error(string memory reason) {
                // String revert (require) — capture the reason so the test can
                // assert it was specifically the ReentrancyGuard, not some other
                // require (e.g. an unregistered-source authorization revert).
                reentryReverted = true;
                reentryRevertReason = reason;
            } catch {
                // Non-string revert (custom error / panic): still record that a
                // revert happened, but leave the reason empty so a string
                // assertion in the test fails and surfaces the wrong cause.
                reentryReverted = true;
            }
        }
    }
}

/// @dev Minimal UUPS-upgrade target used to prove `_authorizeUpgrade` accepts a
///      valid, non-zero implementation from the Owner (the happy branch that the
///      `UpgradeImplZero` guard does NOT trip). Adds one new getter so we can
///      confirm the proxy is now running the v2 code post-upgrade.
contract ExitDelayQueueV2 is ExitDelayQueue {
    function version() external pure returns (uint256) {
        return 2;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

contract ExitDelayQueueTest is Test {
    // Local event redecls for vm.expectEmit (0.8.20 can't `emit Iface.Event`).
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
    event ExitExecuted(uint256 indexed id, address indexed receiver, address token, uint128 amount);
    event AccountBlocked(
        address indexed account,
        IExitDelayQueue.BlockState state,
        uint256 indexed triggerRequestId,
        bytes32 reasonHash
    );
    event SurplusSwept(address indexed token, address indexed to, uint256 amount);

    ExitDelayQueue queue;
    MockERC20 token;
    MockWRBTC wrbtc;
    SourceHarness source;
    NativePusherHarness pusher;

    address constant OWNER = address(0x0E1);
    address constant ADMIN = address(0xAd11);
    address constant OUTSIDER = address(0xC0);
    address constant ORIG = address(0x0111);
    address constant OWNR = address(0x0222);
    address constant RCVR = address(0x0333);

    bytes32 constant SURFACE = keccak256("PERIMETER:LENDING_LENDER_WITHDRAW");
    bytes32 constant SURFACE_ZERO = keccak256("PERIMETER:ZERO_WITHDRAW_COLL");
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
        pusher = new NativePusherHarness();

        vm.prank(OWNER);
        queue.addAllowedSource(address(source));

        // fund the source & pusher
        token.mint(address(source), 1_000_000 ether);
        vm.deal(address(source), 1_000_000 ether);
        vm.deal(address(pusher), 1_000_000 ether);
        wrbtc.mint(address(source), 1_000_000 ether);
        vm.deal(address(wrbtc), 1_000_000 ether); // back the unwrap
    }

    // ── helpers ──

    function _queueErc20(uint128 amount) internal returns (uint256 id) {
        vm.prank(address(this));
        id = source.recordERC20(address(token), amount, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
    }

    // ── initialization ──

    function test_initialize_sets_state() public view {
        assertEq(queue.owner(), OWNER);
        assertEq(queue.admin(), ADMIN);
        assertEq(queue.wrbtc(), address(wrbtc));
        assertEq(queue.minimumDelaySeconds(), MIN_DELAY);
        assertEq(queue.lastRequestId(), 0);
    }

    function test_initialize_admin_may_equal_owner() public {
        //  admin == owner is a
        // supported shape (the governance Safe holds both roles at launch).
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory s = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, OWNER, address(wrbtc), MIN_DELAY, s
        );
        ExitDelayQueue q = ExitDelayQueue(payable(address(new ERC1967Proxy(address(impl), init))));
        assertEq(q.owner(), OWNER);
        assertEq(q.admin(), OWNER);
    }

    function test_initialize_reverts_zero_wrbtc() public {
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory s = new address[](0);
        bytes memory init =
            abi.encodeWithSelector(ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(0), MIN_DELAY, s);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_constructor_disables_initializers() public {
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory s = new address[](0);
        vm.expectRevert();
        impl.initialize(OWNER, ADMIN, address(wrbtc), MIN_DELAY, s);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(OWNER);
        vm.expectRevert(ExitDelayQueue.OwnershipCannotBeRenounced.selector);
        queue.renounceOwnership();
    }

    // ── ingress: ERC20 pull ──

    function test_recordERC20_happy() public {
        uint128 amount = 100 ether;
        uint256 id = _queueErc20(amount);
        assertEq(id, 1);

        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        assertEq(r.amount, amount);
        assertEq(r.originator, ORIG);
        assertEq(r.owner, OWNR);
        assertEq(r.receiver, RCVR);
        assertEq(r.token, address(token));
        assertEq(uint256(r.status), uint256(IExitDelayQueue.ExitStatus.Queued));
        assertEq(r.unlockAt, uint64(block.timestamp + DELAY));
        assertEq(r.createdAt, uint64(block.timestamp));
        assertEq(queue.totalEscrowed(address(token)), amount);
        assertEq(token.balanceOf(address(queue)), amount);
    }

    function test_recordERC20_reverts_unregistered_source() public {
        token.mint(OUTSIDER, 10 ether);
        vm.startPrank(OUTSIDER);
        token.approve(address(queue), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnregisteredSource.selector, OUTSIDER));
        queue.recordERC20Exit(address(token), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
        vm.stopPrank();
    }

    function test_recordERC20_reverts_below_floor() public {
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.DelayBelowFloor.selector, uint32(MIN_DELAY - 1), MIN_DELAY)
        );
        source.recordERC20(
            address(token), 1 ether, MIN_DELAY - 1, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false
        );
    }

    function test_recordERC20_reverts_zero_amount() public {
        vm.expectRevert(IExitDelayQueue.ZeroAmount.selector);
        source.recordERC20(address(token), 0, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
    }

    function test_recordERC20_reverts_zero_party() public {
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        source.recordERC20(address(token), 1 ether, DELAY, SURFACE, SUBPRODUCT, address(0), OWNR, RCVR, false);
    }

    function test_recordERC20_fee_on_transfer_rejected() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        fot.mint(address(source), 100 ether);
        vm.expectRevert(); // ReceivedAmountMismatch
        source.recordERC20(address(fot), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
    }

    function test_recordERC20_unwrap_flag_requires_wrbtc() public {
        vm.expectRevert(IExitDelayQueue.UnwrapNonWrbtc.selector);
        source.recordERC20(
            address(token), 1 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, /*unwrap=*/ true
        );
    }

    function test_recordERC20_wrbtc_unwrap_ok() public {
        uint256 id =
            source.recordERC20(address(wrbtc), 5 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, true);
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        assertTrue(r.unwrapOnDelivery);
        assertEq(r.token, address(wrbtc));
    }

    // ── ingress: measured-delta ERC20 ──

    function test_recordReceivedERC20_happy() public {
        uint256 id =
            source.recordReceivedERC20(address(token), 50 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
        assertEq(id, 1);
        assertEq(queue.totalEscrowed(address(token)), 50 ether);
    }

    function test_recordReceivedERC20_reverts_on_short_push() public {
        // push only 40 but claim 50 → delta mismatch
        vm.prank(address(source));
        token.transfer(address(queue), 40 ether);
        vm.prank(address(source));
        vm.expectRevert();
        queue.recordReceivedERC20Exit(address(token), 50 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR);
    }

    // ── ingress: native ──

    function test_recordNative_happy() public {
        uint256 id =
            source.recordNative{value: 3 ether}(3 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        assertEq(queue.totalEscrowed(address(0)), 3 ether);
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        assertEq(r.token, address(0));
        assertEq(address(queue).balance, 3 ether);
    }

    function test_recordNative_reverts_value_mismatch() public {
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AmountMismatch.selector, 2 ether, 3 ether));
        source.recordNative{value: 2 ether}(3 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
    }

    /// @dev `receive` is now UNCONDITIONAL — it accepts
    ///      native from ANYONE with no sender gate. Stray/donated RBTC only accrues
    ///      as sweepable surplus (never mis-credited, per the), and the gate
    ///      had to go because a storage-reading receive() OutOfGas-bricks the
    ///      2300-stipend WRBTC unwrap (see ExitDelayQueueUnwrapStipend.t.sol).
    function test_receive_accepts_from_anyone_unconditional() public {
        vm.deal(OUTSIDER, 1 ether);
        vm.prank(OUTSIDER);
        (bool ok,) = payable(address(queue)).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(queue).balance, 1 ether);
        // The donated native is sweepable surplus, not backing (totalEscrowed==0).
        assertEq(queue.totalEscrowed(address(0)), 0);
        address to = address(0x5EEE);
        vm.prank(OWNER);
        queue.sweepSurplus(address(0), to);
        assertEq(to.balance, 1 ether);
        assertEq(address(queue).balance, 0);
    }

    function test_recordReceivedNative_via_pusher() public {
        vm.prank(OWNER);
        queue.setNativePusher(address(pusher));
        // register the source that does the record (a source can be the pusher's
        // caller in the real flow; here we register `source` and have IT record).
        // Push 4 ether into the queue via the pusher, then record from source.
        pusher.push(payable(address(queue)), 4 ether);
        uint256 id = source.recordReceivedNative(4 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        assertEq(queue.totalEscrowed(address(0)), 4 ether);
        assertEq(id, 1);
    }

    // ── execution ──

    function test_executeExit_by_owner_after_unlock() public {
        uint128 amount = 100 ether;
        _queueErc20(amount);
        vm.warp(block.timestamp + DELAY);
        uint256 rcvrBefore = token.balanceOf(RCVR);
        vm.prank(OWNR);
        queue.executeExit(1);
        assertEq(token.balanceOf(RCVR), rcvrBefore + amount);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(queue.totalEscrowed(address(token)), 0);
    }

    function test_executeExit_by_originator() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ORIG);
        queue.executeExit(1);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Executed));
    }

    function test_executeExit_reverts_receiver_not_executor() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(RCVR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotExecutor.selector, RCVR));
        queue.executeExit(1);
    }

    function test_executeExit_reverts_before_unlock() public {
        _queueErc20(10 ether);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.NotUnlocked.selector, 1, uint64(block.timestamp + DELAY))
        );
        queue.executeExit(1);
    }

    function test_executeExit_at_exact_unlock_ok() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY); // inclusive boundary
        vm.prank(OWNR);
        queue.executeExit(1); // must not revert
    }

    function test_executeExit_reverts_unknown() public {
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 99));
        queue.executeExit(99);
    }

    function test_executeExit_reverts_double_execute() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.executeExit(1);
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.executeExit(1);
    }

    function test_executeExit_reverts_when_paused() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        vm.prank(OWNR);
        vm.expectRevert(IExitDelayQueue.QueuePaused.selector);
        queue.executeExit(1);
    }

    function test_executeExit_native_pays_receiver() public {
        source.recordNative{value: 5 ether}(5 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        uint256 before = RCVR.balance;
        vm.prank(OWNR);
        queue.executeExit(1);
        assertEq(RCVR.balance, before + 5 ether);
    }

    function test_executeExit_wrbtc_unwraps_to_native() public {
        uint256 id =
            source.recordERC20(address(wrbtc), 5 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, true);
        vm.warp(block.timestamp + DELAY);
        uint256 before = RCVR.balance;
        vm.prank(OWNR);
        queue.executeExit(id);
        assertEq(RCVR.balance, before + 5 ether); // native received, not WRBTC
        assertEq(wrbtc.balanceOf(RCVR), 0);
    }

    function test_executeExit_reverting_receiver_holds_request() public {
        RevertingReceiver rr = new RevertingReceiver();
        source.recordNative{value: 1 ether}(1 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, address(rr));
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(); // Address.sendValue bubbles
        queue.executeExit(1);
        // still Queued (whole call rolled back) → recoverable via Leg-3
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Queued));
    }

    // ── batch execution ──

    function test_executeExits_batch_happy() public {
        _queueErc20(1 ether);
        _queueErc20(2 ether);
        vm.warp(block.timestamp + DELAY);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.prank(OWNR);
        queue.executeExits(ids);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(uint256(queue.getRequest(2).status), uint256(IExitDelayQueue.ExitStatus.Executed));
    }

    function test_executeExits_reverts_whole_batch_on_invalid() public {
        _queueErc20(1 ether);
        _queueErc20(2 ether);
        vm.warp(block.timestamp + DELAY);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 99; // unknown → whole batch reverts
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 99));
        queue.executeExits(ids);
        // id 1 must NOT have executed (atomicity)
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Queued));
    }

    function test_executeExits_duplicate_id_reverts() public {
        _queueErc20(1 ether);
        vm.warp(block.timestamp + DELAY);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1; // duplicate → second hits AlreadyTerminal
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.executeExits(ids);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Queued));
    }

    function test_executeExits_empty_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(OWNR);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.executeExits(ids);
    }

    // ── block model ──

    function test_freeze_blocks_execution() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, ORIG, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.executeExit(1);
    }

    function test_freeze_receiver_blocks_execution() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(RCVR);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, RCVR, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.executeExit(1);
    }

    function test_unfreeze_restores_execution() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.prank(ADMIN);
        queue.unfreeze(ORIG);
        vm.prank(OWNR);
        queue.executeExit(1); // executes fine now
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Executed));
    }

    function test_freeze_only_admin_or_owner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER));
        queue.freeze(ORIG);
    }

    function test_blacklist_escalates_from_frozen_atomically() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Frozen));
        vm.prank(ADMIN);
        queue.blacklist(ORIG); // no unfreeze first
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    function test_unblacklist_on_frozen_reverts() public {
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotBlacklisted.selector, ORIG));
        queue.unblacklist(ORIG);
    }

    function test_unfreeze_on_blacklisted_reverts() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotFrozen.selector, ORIG));
        queue.unfreeze(ORIG);
    }

    function test_unfreeze_absent_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotFrozen.selector, ORIG));
        queue.unfreeze(ORIG);
    }

    function test_freeze_on_blacklisted_no_downgrade() public {
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.prank(ADMIN);
        queue.freeze(ORIG); // must NOT downgrade
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    function test_freezeFromRequest_blocks_orig_and_owner() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.freezeFromRequest(1, false, bytes32(0));
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.None)); // freezeReceiver=false
        assertEq(queue.blockTrigger(ORIG), 1);
    }

    function test_freezeFromRequest_receiver_flag() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.freezeFromRequest(1, true, bytes32(0));
        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Frozen));
    }

    function test_blockedAccounts_enumeration() public {
        vm.startPrank(ADMIN);
        queue.freeze(ORIG);
        queue.blacklist(OWNR);
        vm.stopPrank();
        (address[] memory got, uint256 total) = queue.blockedAccounts(0, 10);
        assertEq(got.length, 2);
        assertEq(total, 2);
    }

    function test_batch_freeze() public {
        address[] memory a = new address[](2);
        a[0] = ORIG;
        a[1] = OWNR;
        vm.prank(ADMIN);
        queue.freeze(a);
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.Frozen));
    }

    // ── recovery: Leg 2 ──

    function _setupRoute(bool topUp) internal returns (bytes32 routeId) {
        if (topUp) {
            vm.prank(OWNER);
            queue.setTopUpFeasible(SURFACE, true);
        }
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: topUp ? SUBPRODUCT : address(0xDE57),
            topUpPool: topUp
        });
        vm.prank(OWNER);
        routeId = queue.setRecoveryRoute(route);
    }

    function test_resolveToProtocol_requires_blacklisted_source() public {
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // no blacklist yet → SourceNotBlacklisted
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.SourceNotBlacklisted.selector, ORIG));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_happy_on_blacklisted_originator() public {
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 destBefore = token.balanceOf(address(0xDE57));
        vm.prank(ADMIN);
        queue.resolveToProtocol(ids, routeId);
        assertEq(token.balanceOf(address(0xDE57)), destBefore + 10 ether);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.ResolvedToProtocol));
        assertEq(queue.totalEscrowed(address(token)), 0);
    }

    function test_resolveToProtocol_authorized_by_owner_blacklist() public {
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        vm.prank(ADMIN);
        queue.blacklist(OWNR); // owner blacklisted (OR predicate)
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        queue.resolveToProtocol(ids, routeId);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.ResolvedToProtocol));
    }

    function test_resolveToProtocol_receiver_block_does_not_authorize() public {
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        vm.prank(ADMIN);
        queue.blacklist(RCVR); // receiver-only → NEVER authorizes Leg-2
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.SourceNotBlacklisted.selector, ORIG));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_provenance_mismatch() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        // route with a different token
        MockERC20 other = new MockERC20();
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(other),
            destination: address(0xDE57),
            topUpPool: false
        });
        vm.prank(OWNER);
        bytes32 routeId = queue.setRecoveryRoute(route);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.RouteProvenanceMismatch.selector, 1, routeId));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_setRecoveryRoute_topup_requires_feasible() public {
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: SUBPRODUCT,
            topUpPool: true
        });
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.TopUpInfeasibleSurface.selector, SURFACE));
        queue.setRecoveryRoute(route);
    }

    function test_setRecoveryRoute_topup_rejects_native() public {
        vm.prank(OWNER);
        queue.setTopUpFeasible(SURFACE, true);
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(0), // native → can never be Leg-2a
            destination: SUBPRODUCT,
            topUpPool: true
        });
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.TopUpInfeasibleSurface.selector, SURFACE));
        queue.setRecoveryRoute(route);
    }

    /// @dev A top-up route means "restore the pool this exit came from". The
    ///      struct documented that; registration did not check it, so a route
    ///      could be registered as a top-up while paying somewhere else, and a
    ///      Leg-2 recovery would carry a blocked user's escrow there under the
    ///      top-up label.
    function test_setRecoveryRoute_topup_requires_destination_is_the_pool() public {
        vm.prank(OWNER);
        queue.setTopUpFeasible(SURFACE, true);
        address elsewhere = address(0xDE57);
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: elsewhere,
            topUpPool: true
        });
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.TopUpDestinationMismatch.selector, elsewhere, SUBPRODUCT)
        );
        queue.setRecoveryRoute(route);
    }

    /// @dev The same route with the destination bound to its own pool is fine —
    ///      proving the guard rejects the mismatch, not top-ups as such.
    function test_setRecoveryRoute_topup_accepts_its_own_pool() public {
        vm.prank(OWNER);
        queue.setTopUpFeasible(SURFACE, true);
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: SUBPRODUCT,
            topUpPool: true
        });
        vm.prank(OWNER);
        queue.setRecoveryRoute(route);
    }

    /// @dev A successful `safeTransfer` proves only that the token did not
    ///      revert. A token that charges the SENDER on transfer moves more than
    ///      `amount` out while `_totalEscrowed` drops by exactly `amount`,
    ///      leaving every remaining request short. The escrow is created with a
    ///      well-behaved token and the fee is switched on afterwards, which is
    ///      what an upgradeable token can really do.
    function test_executeExit_reverts_when_a_payout_would_leave_the_queue_short() public {
        SwitchableFeeERC20 sneaky = new SwitchableFeeERC20();
        sneaky.mint(address(source), 100 ether);

        vm.prank(OWNER);
        queue.addAllowedSource(address(source));
        uint256 id =
            source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);

        // A second escrow so there is somebody left to shortchange.
        source.recordERC20(address(sneaky), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);

        sneaky.setBurnOnTransfer(true);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(ORIG);
        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        queue.executeExit(id);
    }

    /// @dev `recoverStuckExit` attempts the stored receiver inside a try/catch
    ///      whose bare `catch` reads ANY revert as that receiver bouncing. A
    ///      solvency failure raised inside the payout would therefore be taken
    ///      for a bounce and redirect the funds to the CALLER-SELECTED alternate
    ///      receiver — bypassing the immutable receiver and hiding the alarm.
    ///      The check belongs outside that frame, and this pins it there.
    function test_recoverStuckExit_does_not_redirect_on_a_solvency_failure() public {
        RecipientBiasedFeeERC20 biased = new RecipientBiasedFeeERC20();
        biased.mint(address(source), 100 ether);
        vm.prank(OWNER);
        queue.addAllowedSource(address(source));

        uint256 id =
            source.recordERC20(address(biased), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
        // A second escrow, so there is somebody left to be shortchanged.
        source.recordERC20(address(biased), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);

        // Only the stored receiver is taxed; the alternate one is not.
        address alt = address(0xA17E);
        biased.setTaxedRecipient(RCVR);

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(ORIG);
        vm.expectRevert(IExitDelayQueue.SolvencyViolated.selector);
        queue.recoverStuckExit(id, alt);

        assertEq(biased.balanceOf(alt), 0, "funds were redirected to the caller's address");
    }

    function test_resolveToProtocol_only_admin_or_owner() public {
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER));
        queue.resolveToProtocol(ids, routeId);
    }

    // ── recovery: Leg 3 ──

    function test_resolveBySIP_on_blocked_request() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.freeze(RCVR); // receiver-only block → held, resolvable by SIP
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        address dest = address(0x7EEA);
        vm.prank(OWNER);
        queue.resolveBySIP(ids, dest);
        assertEq(token.balanceOf(dest), 10 ether);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.ResolvedBySIP));
    }

    function test_resolveBySIP_on_paused() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OWNER);
        queue.resolveBySIP(ids, address(0x7EEA));
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.ResolvedBySIP));
    }

    function test_resolveBySIP_on_not_yet_unlocked() public {
        _queueErc20(10 ether);
        // still locked → resolvable
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OWNER);
        queue.resolveBySIP(ids, address(0x7EEA));
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.ResolvedBySIP));
    }

    function test_resolveBySIP_rejects_honest_unlocked_request() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY); // unlocked, unblocked, not paused
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotResolvableBySIP.selector, 1));
        queue.resolveBySIP(ids, address(0x7EEA));
    }

    function test_resolveBySIP_only_owner() public {
        _queueErc20(10 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN); // admin cannot Leg-3
        vm.expectRevert();
        queue.resolveBySIP(ids, address(0x7EEA));
    }

    // ── recoverStuckExit(id, altReceiver) — verify-by-attempting redirect leg ──

    address constant ALT = address(0x0A17); // healthy alternate receiver (no code)

    /// @notice (a) bouncing original receiver + clean actors → recoverStuckExit
    ///         attempts the stored receiver (bounces), then pays altReceiver;
    ///         status Executed, escrow cleared.
    function test_recover_bouncing_original_pays_altReceiver() public {
        RevertingReceiver rr = new RevertingReceiver();
        uint256 id = source.recordNative{value: 4 ether}(
            4 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, address(rr)
        );
        vm.warp(block.timestamp + DELAY);

        // A straight execute bounces (fail-closed payout, request held).
        vm.prank(OWNR);
        vm.expectRevert();
        queue.executeExit(id);
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Queued));

        uint256 altBefore = ALT.balance;
        // The ExitExecuted event names the party that actually got paid: ALT.
        vm.expectEmit(true, true, false, true, address(queue));
        emit ExitExecuted(id, ALT, address(0), 4 ether);

        vm.prank(OWNR);
        queue.recoverStuckExit(id, ALT);

        assertEq(ALT.balance, altBefore + 4 ether, "alt paid on bounce");
        assertEq(address(rr).balance, 0, "bouncing original got nothing");
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(queue.totalEscrowed(address(0)), 0);
    }

    /// @notice (a') bouncing original for a WRBTC-escrowed (unwrapOnDelivery)
    ///         request: the stored-receiver unwrap+send bounces, then altReceiver is
    ///         paid NATIVE RBTC (the unwrap is re-done on the altReceiver leg).
    function test_recover_bouncing_original_unwrap_pays_native_alt() public {
        RevertingReceiver rr = new RevertingReceiver();
        uint128 amount = 5 ether;
        uint256 id = source.recordERC20(
            address(wrbtc), amount, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, address(rr), true
        );
        vm.warp(block.timestamp + DELAY);

        uint256 altBefore = ALT.balance;
        vm.prank(OWNR);
        queue.recoverStuckExit(id, ALT);

        assertEq(ALT.balance, altBefore + amount, "alt gets native (unwrapped)");
        assertEq(queue.totalEscrowed(address(wrbtc)), 0);
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Executed));
    }

    /// @notice (b) HEALTHY original receiver → recoverStuckExit pays the STORED
    ///         receiver; altReceiver is IGNORED (proves no arbitrary redirect —
    ///         a healthy exit can never be diverted, verify-by-attempting).
    function test_recover_healthy_original_pays_stored_receiver_alt_ignored() public {
        uint128 amount = 100 ether;
        _queueErc20(amount); // stored receiver = RCVR (healthy, no code)
        vm.warp(block.timestamp + DELAY);

        uint256 rcvrBefore = token.balanceOf(RCVR);
        uint256 altBefore = token.balanceOf(ALT);

        // Event names the STORED receiver — altReceiver is not the payee.
        vm.expectEmit(true, true, false, true, address(queue));
        emit ExitExecuted(1, RCVR, address(token), amount);

        vm.prank(OWNR);
        queue.recoverStuckExit(1, ALT);

        assertEq(token.balanceOf(RCVR), rcvrBefore + amount, "stored receiver paid");
        assertEq(token.balanceOf(ALT), altBefore, "altReceiver ignored on a healthy exit");
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(queue.totalEscrowed(address(token)), 0);
    }

    /// @notice (b') healthy original for a NATIVE request → stored receiver paid,
    ///         altReceiver ignored.
    function test_recover_healthy_native_pays_stored_receiver() public {
        source.recordNative{value: 3 ether}(3 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        uint256 rcvrBefore = RCVR.balance;
        uint256 altBefore = ALT.balance;
        vm.prank(ORIG);
        queue.recoverStuckExit(1, ALT);
        assertEq(RCVR.balance, rcvrBefore + 3 ether, "stored receiver paid");
        assertEq(ALT.balance, altBefore, "alt ignored");
    }

    /// @notice (b'') altReceiver == stored receiver on a HEALTHY exit pays EXACTLY
    ///         ONCE (regression for the double-pay the invariant suite caught: a
    ///         successful stored-receiver attempt must never also fire the
    ///         altReceiver leg just because the two addresses are equal).
    function test_recover_healthy_alt_equals_receiver_pays_once() public {
        source.recordNative{value: 3 ether}(3 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        vm.warp(block.timestamp + DELAY);
        uint256 rcvrBefore = RCVR.balance;
        uint256 queueBefore = address(queue).balance;
        vm.prank(OWNR);
        queue.recoverStuckExit(1, RCVR); // altReceiver == stored receiver
        assertEq(RCVR.balance, rcvrBefore + 3 ether, "paid exactly once");
        assertEq(address(queue).balance, queueBefore - 3 ether, "queue drained exactly once");
        assertEq(queue.totalEscrowed(address(0)), 0);
    }

    /// @notice (c) blocked STORED receiver → recoverStuckExit reverts
    ///         ActorBlocked(receiver) EVEN WITH a clean altReceiver. This is the
    ///         must-fix regression: a blocked/hacked original receiver refuses
    ///         recovery entirely (→ Leg-3), so it can never be bypassed by naming a
    ///         fresh altReceiver. The exact bypass the review caught.
    function test_recover_reverts_if_stored_receiver_blocked_even_with_clean_alt() public {
        _queueErc20(10 ether); // stored receiver = RCVR
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.blacklist(RCVR); // the STORED receiver is a confirmed-hack address

        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, RCVR, IExitDelayQueue.BlockState.Blacklisted
            )
        );
        queue.recoverStuckExit(1, ALT); // clean alt, but stored receiver is blocked

        // Nothing moved — still Queued, escrow intact (falls to Leg-3).
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Queued));
        assertEq(queue.totalEscrowed(address(token)), 10 ether);
    }

    /// @notice (c') a merely-Frozen stored receiver also refuses recovery (both
    ///         block states gate).
    function test_recover_reverts_if_stored_receiver_frozen() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(RCVR);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, RCVR, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice (d-alt) blocked altReceiver → reverts ActorBlocked(altReceiver).
    function test_recover_reverts_if_altReceiver_frozen() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(ALT);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, ALT, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.recoverStuckExit(1, ALT);
        assertEq(uint256(queue.getRequest(1).status), uint256(IExitDelayQueue.ExitStatus.Queued));
    }

    /// @notice (d-alt-bl) blacklisted altReceiver → reverts.
    function test_recover_reverts_if_altReceiver_blacklisted() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.blacklist(ALT);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, ALT, IExitDelayQueue.BlockState.Blacklisted
            )
        );
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice (d-orig) blocked ORIGINATOR → reverts (a hacked source cannot escape
    ///         a freeze via the recovery leg).
    function test_recover_reverts_if_originator_blocked() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        vm.prank(OWNR);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, ORIG, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice (d-owner) blocked OWNER → reverts.
    function test_recover_reverts_if_owner_blocked() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.freeze(OWNR);
        vm.prank(ORIG);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ActorBlocked.selector, OWNR, IExitDelayQueue.BlockState.Frozen
            )
        );
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice (e) altReceiver guard: reverts if altReceiver is
    ///         {0, this, token, wrbtc}.
    function test_recover_reverts_if_altReceiver_zero() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.InvalidAltReceiver.selector, address(0)));
        queue.recoverStuckExit(1, address(0));
    }

    function test_recover_reverts_if_altReceiver_is_queue() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.InvalidAltReceiver.selector, address(queue)));
        queue.recoverStuckExit(1, address(queue));
    }

    function test_recover_reverts_if_altReceiver_is_token() public {
        _queueErc20(10 ether); // request token == token
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.InvalidAltReceiver.selector, address(token)));
        queue.recoverStuckExit(1, address(token));
    }

    function test_recover_reverts_if_altReceiver_is_wrbtc() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.InvalidAltReceiver.selector, address(wrbtc)));
        queue.recoverStuckExit(1, address(wrbtc));
    }

    /// @notice (f) caller not in {originator, owner} → reverts NotExecutor. The
    ///         receiver may NOT recover (authorization matches executeExit).
    function test_recover_reverts_if_caller_not_executor() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        // The stored receiver is not an executor.
        vm.prank(RCVR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotExecutor.selector, RCVR));
        queue.recoverStuckExit(1, ALT);
        // Neither is an arbitrary outsider.
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotExecutor.selector, OUTSIDER));
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice recoverStuckExit still enforces the unlock gate.
    function test_recover_reverts_if_locked() public {
        _queueErc20(10 ether);
        uint64 unlockAt = queue.getRequest(1).unlockAt;
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.NotUnlocked.selector, 1, unlockAt));
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice recoverStuckExit still enforces the pause gate.
    function test_recover_reverts_if_paused() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(ADMIN);
        queue.setSecurityPerimeterPaused(true);
        vm.prank(OWNR);
        vm.expectRevert(IExitDelayQueue.QueuePaused.selector);
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice recoverStuckExit reverts UnknownRequest / AlreadyTerminal like execute.
    function test_recover_reverts_unknown_and_terminal() public {
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 999));
        queue.recoverStuckExit(999, ALT);

        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.executeExit(1); // terminal now (healthy pay to RCVR)
        vm.prank(OWNR);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.recoverStuckExit(1, ALT);
    }

    /// @notice Both original AND altReceiver bounce → the whole call reverts and the
    ///         funds stay Queued (CEI rollback; no partial spend).
    function test_recover_reverts_if_both_bounce() public {
        RevertingReceiver rr1 = new RevertingReceiver();
        RevertingReceiver rr2 = new RevertingReceiver();
        uint256 id = source.recordNative{value: 2 ether}(
            2 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, address(rr1)
        );
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        vm.expectRevert(); // altReceiver (rr2) sendValue reverts → whole call rolls back
        queue.recoverStuckExit(id, address(rr2));
        // Still Queued, escrow intact.
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Queued));
        assertEq(queue.totalEscrowed(address(0)), 2 ether);
    }

    /// @notice payoutExternal (the internal try/catch trampoline) is self-call-only:
    ///         a direct external call reverts SelfOnly, so the leg's catchable payout
    ///         cannot be abused as an arbitrary transfer primitive.
    function test_payoutExternal_is_self_only() public {
        _queueErc20(10 ether);
        vm.prank(OUTSIDER);
        vm.expectRevert(IExitDelayQueue.SelfOnly.selector);
        queue.payoutExternal(address(token), OUTSIDER, 1 ether, false);
    }

    /// @notice Property: recoverStuckExit is solvency-safe and never double-spends
    ///         across {healthy | bouncing original} × {unlocked | locked} ×
    ///         {altBlocked | clean} × {unpaused | paused}. Exactly one of two
    ///         outcomes holds: a successful terminal recover (escrow decremented by
    ///         amount, paid to stored-receiver-if-healthy else altReceiver) or a
    ///         whole-call revert (nothing changed).
    function testFuzz_recover_is_solvency_safe(
        bool bouncing,
        bool unlocked,
        bool altBlocked,
        bool paused,
        uint128 amount
    ) public {
        amount = uint128(bound(amount, 1, 1e24));

        // Stored receiver: either a plain payable EOA (healthy) or a reverting
        // contract (bouncing). ORIG/OWNR/ALT are plain payable no-code addrs.
        address storedReceiver = bouncing ? address(new RevertingReceiver()) : RCVR;
        uint256 id = source.recordNative{value: amount}(
            amount, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, storedReceiver
        );
        uint256 escrowBefore = queue.totalEscrowed(address(0));
        assertEq(escrowBefore, amount);

        // On a healthy exit the STORED receiver is paid (alt ignored); on a bounce
        // the ALT is paid. Either way the payee is a distinct plain address here.
        address effReceiver = bouncing ? ALT : storedReceiver;
        uint256 effBefore = effReceiver.balance;

        if (unlocked) vm.warp(block.timestamp + DELAY);
        if (altBlocked) {
            vm.prank(ADMIN);
            queue.freeze(ALT);
        }
        if (paused) {
            vm.prank(ADMIN);
            queue.setSecurityPerimeterPaused(true);
        }

        vm.prank(OWNR);
        try queue.recoverStuckExit(id, ALT) {
            // Success: terminal, escrow decremented exactly once, paid to effReceiver.
            assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Executed));
            assertEq(queue.totalEscrowed(address(0)), escrowBefore - amount);
            assertEq(effReceiver.balance, effBefore + amount);
            // Success requires all gates satisfied. Note: altBlocked always fails the
            // gate (altReceiver is checked unconditionally, even on a healthy exit).
            assertTrue(unlocked && !paused && !altBlocked, "success needs clean gates");
        } catch {
            // Revert: nothing changed, still Queued, escrow intact.
            assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Queued));
            assertEq(queue.totalEscrowed(address(0)), escrowBefore);
            assertTrue(!unlocked || paused || altBlocked, "revert requires a failing gate");
        }
    }

    // ── sweepSurplus ──

    function test_sweepSurplus_moves_only_surplus() public {
        _queueErc20(10 ether); // escrowed backing = 10
        // force-send 3 ether of dust
        token.mint(address(queue), 3 ether);
        uint256 destBefore = token.balanceOf(OWNER);
        vm.prank(OWNER);
        queue.sweepSurplus(address(token), OWNER);
        assertEq(token.balanceOf(OWNER), destBefore + 3 ether); // only surplus
        assertEq(token.balanceOf(address(queue)), 10 ether); // backing intact
        assertEq(queue.totalEscrowed(address(token)), 10 ether);
    }

    function test_sweepSurplus_native() public {
        source.recordNative{value: 5 ether}(5 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
        vm.deal(address(queue), address(queue).balance + 2 ether); // dust
        uint256 destBefore = address(0x5EE).balance;
        vm.prank(OWNER);
        queue.sweepSurplus(address(0), address(0x5EE));
        assertEq(address(0x5EE).balance, destBefore + 2 ether);
        assertEq(address(queue).balance, 5 ether);
    }

    function test_sweepSurplus_no_surplus_noop() public {
        _queueErc20(10 ether);
        vm.prank(OWNER);
        queue.sweepSurplus(address(token), OWNER); // 0 surplus, must not revert
        assertEq(token.balanceOf(address(queue)), 10 ether);
    }

    function test_sweepSurplus_only_owner() public {
        vm.prank(ADMIN);
        vm.expectRevert();
        queue.sweepSurplus(address(token), ADMIN);
    }

    // ── active index / views ──

    function test_getActive_pagination() public {
        _queueErc20(1 ether);
        _queueErc20(1 ether);
        _queueErc20(1 ether);
        (uint256[] memory ids, uint256 next) = queue.getActive(OWNR, 0, 2);
        assertEq(ids.length, 2);
        assertEq(next, 2);
        (uint256[] memory ids2, uint256 next2) = queue.getActive(OWNR, 2, 2);
        assertEq(ids2.length, 1);
        assertEq(next2, 0); // end
    }

    function test_getActive_removed_on_execute() public {
        _queueErc20(1 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.executeExit(1);
        (uint256[] memory ids,) = queue.getActive(OWNR, 0, 10);
        assertEq(ids.length, 0);
        (uint256[] memory ids2,) = queue.getActive(ORIG, 0, 10);
        assertEq(ids2.length, 0); // removed from BOTH sets
    }

    function test_getActive_dual_key_dedup_when_equal() public {
        // originator == owner → single set entry
        source.recordERC20(address(token), 1 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, ORIG, RCVR, false);
        (uint256[] memory ids,) = queue.getActive(ORIG, 0, 10);
        assertEq(ids.length, 1);
    }

    function test_freeze_does_not_remove_from_active() public {
        _queueErc20(1 ether);
        vm.prank(ADMIN);
        queue.freeze(ORIG);
        (uint256[] memory ids,) = queue.getActive(ORIG, 0, 10);
        assertEq(ids.length, 1); // freeze holds, does not remove
    }

    // ── config ──

    function test_addAllowedSource_only_owner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert();
        queue.addAllowedSource(OUTSIDER);
    }

    function test_removeAllowedSource() public {
        vm.prank(OWNER);
        queue.removeAllowedSource(address(source));
        assertFalse(queue.isAllowedSource(address(source)));
    }

    function test_setAdmin_may_equal_owner() public {
        // Admin may equal Owner.
        vm.prank(OWNER);
        queue.setAdmin(OWNER);
        assertEq(queue.admin(), OWNER);
    }

    function test_setMinimumDelaySeconds() public {
        vm.prank(OWNER);
        queue.setMinimumDelaySeconds(3 hours);
        assertEq(queue.minimumDelaySeconds(), 3 hours);
    }

    /// @dev C3 / (creation-time): the floor is enforced ONCE, at record time.
    ///      Raising minimumDelaySeconds after a request is already Queued must NOT
    ///      retroactively extend that request's unlockAt — the raise governs only
    ///      NEW requests. The already-Queued exit remains executable at its
    ///      original unlockAt even though its (unlockAt − createdAt) is now BELOW
    ///      the raised live floor.
    function test_floorRaise_does_not_extend_queued_request() public {
        // Queue with DELAY (2h) under the initial 1h floor.
        uint256 id = _queueErc20(10 ether);
        IExitDelayQueue.ExitRequest memory r = queue.getRequest(id);
        uint64 unlockAtBefore = r.unlockAt;
        assertEq(uint256(r.unlockAt) - uint256(r.createdAt), DELAY);

        // Raise the floor to 10h — ABOVE this request's 2h span.
        vm.prank(OWNER);
        queue.setMinimumDelaySeconds(10 hours);
        assertEq(queue.minimumDelaySeconds(), 10 hours);

        // The stored unlockAt is unchanged (immutable post-record).
        IExitDelayQueue.ExitRequest memory r2 = queue.getRequest(id);
        assertEq(r2.unlockAt, unlockAtBefore);
        assertLt(uint256(r2.unlockAt) - uint256(r2.createdAt), queue.minimumDelaySeconds());

        // And it is still executable at its ORIGINAL unlockAt (the raise did not
        // push the gate out). Warp to the original unlock and execute.
        vm.warp(unlockAtBefore);
        uint256 balBefore = token.balanceOf(RCVR);
        vm.prank(ORIG);
        queue.executeExit(id);
        assertEq(token.balanceOf(RCVR) - balBefore, 10 ether);
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Executed));
    }

    /// @dev Complement to the above: a NEW request recorded AFTER the raise IS
    ///      subject to the new floor (DelayBelowFloor on a sub-floor delay).
    function test_floorRaise_applies_to_new_requests() public {
        vm.prank(OWNER);
        queue.setMinimumDelaySeconds(10 hours);
        // DELAY (2h) is now below the 10h floor → the new record is rejected.
        vm.expectRevert(
            abi.encodeWithSelector(IExitDelayQueue.DelayBelowFloor.selector, DELAY, uint32(10 hours))
        );
        vm.prank(address(this));
        source.recordERC20(address(token), 10 ether, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false);
    }

    function test_setSecurityPerimeterPaused_authority() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER));
        queue.setSecurityPerimeterPaused(true);
    }

    // ── batch by-request-id block variants ──

    /// @dev Queue a request with an explicit {orig, owner, receiver} so a batch can
    ///      span multiple distinct parties. Returns the new id.
    function _queueErc20With(uint128 amount, address orig, address ownr, address rcvr)
        internal
        returns (uint256 id)
    {
        vm.prank(address(this));
        id = source.recordERC20(address(token), amount, DELAY, SURFACE, SUBPRODUCT, orig, ownr, rcvr, false);
    }

    function test_freezeFromRequest_batch_blocks_all_parties() public {
        // two requests, four distinct parties (orig/owner each) plus receivers.
        address o1 = address(0xA100);
        address w1 = address(0xA101);
        address o2 = address(0xA200);
        address w2 = address(0xA201);
        uint256 id1 = _queueErc20With(10 ether, o1, w1, address(0xA1CE));
        uint256 id2 = _queueErc20With(11 ether, o2, w2, address(0xA2CE));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        vm.prank(ADMIN);
        queue.freezeFromRequest(ids, false, keccak256("case-1"));

        // all four source parties are frozen in ONE tx.
        assertEq(uint256(queue.blockStateOf(o1)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(w1)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(o2)), uint256(IExitDelayQueue.BlockState.Frozen));
        assertEq(uint256(queue.blockStateOf(w2)), uint256(IExitDelayQueue.BlockState.Frozen));
        // receivers untouched (freezeReceiver=false); trigger links to the id.
        assertEq(uint256(queue.blockStateOf(address(0xA1CE))), uint256(IExitDelayQueue.BlockState.None));
        assertEq(queue.blockTrigger(o1), id1);
        assertEq(queue.blockTrigger(o2), id2);
    }

    function test_freezeFromRequest_batch_freezeReceiver_true() public {
        uint256 id1 = _queueErc20With(10 ether, address(0xB100), address(0xB101), address(0xB1CE));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        vm.prank(ADMIN);
        queue.freezeFromRequest(ids, true, bytes32(0));
        assertEq(uint256(queue.blockStateOf(address(0xB1CE))), uint256(IExitDelayQueue.BlockState.Frozen));
    }

    function test_blacklistFromRequest_batch_blocks_all_parties() public {
        uint256 id1 = _queueErc20With(10 ether, address(0xC100), address(0xC101), address(0xC1CE));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        vm.prank(ADMIN);
        queue.blacklistFromRequest(ids, false, bytes32(0));
        assertEq(
            uint256(queue.blockStateOf(address(0xC100))), uint256(IExitDelayQueue.BlockState.Blacklisted)
        );
        assertEq(
            uint256(queue.blockStateOf(address(0xC101))), uint256(IExitDelayQueue.BlockState.Blacklisted)
        );
    }

    /// @dev One unknown id reverts the WHOLE batch (atomic, like executeExits) —
    ///      no party from the valid id is left blocked.
    function test_freezeFromRequest_batch_one_bad_id_reverts_whole_batch() public {
        uint256 id1 = _queueErc20With(10 ether, address(0xD100), address(0xD101), address(0xD1CE));
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = 999; // never recorded
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 999));
        queue.freezeFromRequest(ids, false, bytes32(0));
        // valid id's parties are NOT blocked (whole batch rolled back).
        assertEq(uint256(queue.blockStateOf(address(0xD100))), uint256(IExitDelayQueue.BlockState.None));
        assertEq(uint256(queue.blockStateOf(address(0xD101))), uint256(IExitDelayQueue.BlockState.None));
    }

    /// @dev Frozen→Blacklisted escalation WITHIN a batch: a party frozen by an
    ///      earlier op is escalated to Blacklisted by a later blacklist batch that
    ///      names its request (atomic escalation, last-write-wins trigger).
    function test_blacklistFromRequest_batch_escalates_frozen_party() public {
        address o1 = address(0xE100);
        address w1 = address(0xE101);
        uint256 id1 = _queueErc20With(10 ether, o1, w1, address(0xE1CE));

        // first freeze via the single-id path.
        vm.prank(ADMIN);
        queue.freezeFromRequest(id1, false, keccak256("first"));
        assertEq(uint256(queue.blockStateOf(o1)), uint256(IExitDelayQueue.BlockState.Frozen));

        // now a batch blacklist over the same request escalates directly.
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        vm.prank(ADMIN);
        queue.blacklistFromRequest(ids, false, keccak256("confirmed"));
        assertEq(uint256(queue.blockStateOf(o1)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        assertEq(uint256(queue.blockStateOf(w1)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    function test_freezeFromRequest_batch_empty_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.freezeFromRequest(ids, false, bytes32(0));
    }

    function test_blacklistFromRequest_batch_empty_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.blacklistFromRequest(ids, false, bytes32(0));
    }

    function test_freezeFromRequest_batch_only_admin_or_owner() public {
        _queueErc20(10 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER));
        queue.freezeFromRequest(ids, false, bytes32(0));
    }

    function test_blacklistFromRequest_batch_by_owner_allowed() public {
        uint256 id1 = _queueErc20With(10 ether, address(0xF100), address(0xF101), address(0xF1CE));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        // Owner (not just Admin) may also block (onlyAdminOrOwner).
        vm.prank(OWNER);
        queue.blacklistFromRequest(ids, false, bytes32(0));
        assertEq(
            uint256(queue.blockStateOf(address(0xF100))), uint256(IExitDelayQueue.BlockState.Blacklisted)
        );
    }

    // ── Admin == Owner supported (chokepoint retired) ──

    /// @dev The 2-step handoff to the current Admin now succeeds and merges the
    ///      roles — a deliberate decision (launch shape: governance Safe holds
    ///      both). While merged, the Leg-2/Leg-3 split is intentionally
    ///      vacuous; it becomes real when ownership moves to Bitocracy.
    function test_transferOwnership_to_admin_then_accept_merges_roles() public {
        vm.prank(OWNER);
        queue.transferOwnership(ADMIN); // pending only; no merge yet
        assertEq(queue.owner(), OWNER); // still the old owner

        vm.prank(ADMIN);
        queue.acceptOwnership();
        assertEq(queue.owner(), ADMIN, "roles merged: admin is now owner");
        assertEq(queue.admin(), ADMIN, "admin unchanged");
    }

    // ── record* are nonReentrant ──

    function test_recordERC20_is_nonReentrant() public {
        ReentrantERC20 rnt = new ReentrantERC20();
        rnt.setQueue(queue);
        // Register two sources so the ONLY remaining revert cause on the inner
        // re-entrant call is the ReentrancyGuard:
        //   - address(this): the source that pulls rnt and calls recordERC20Exit
        //     (the outer call);
        //   - address(rnt): the source the re-entrant inner call passes as
        //     msg.sender (rnt._transfer re-enters, so msg.sender == rnt). Without
        //     this, the inner call would revert on the source-authorization check
        //     even with nonReentrant removed, masking the guard.
        vm.startPrank(OWNER);
        queue.addAllowedSource(address(this)); // this test contract is the source
        queue.addAllowedSource(address(rnt)); // rnt is the inner re-entrant caller
        vm.stopPrank();
        rnt.mint(address(this), 1000 ether);
        rnt.approve(address(queue), type(uint256).max);
        rnt.arm(); // next transferFrom re-enters the queue

        // outer record triggers the pull → rnt._transfer re-enters recordERC20Exit.
        queue.recordERC20Exit(
            address(rnt), uint128(5 ether), DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, false
        );
        // the outer call succeeded; the re-entrant inner call was attempted AND
        // reverted (nonReentrant tripped).
        assertTrue(rnt.reentered(), "reentrancy path not exercised");
        assertTrue(rnt.reentryReverted(), "nonReentrant did not block the re-entrant record");
        // Assert the revert was SPECIFICALLY the ReentrancyGuard, not some other
        // require. This is the exact OZ 4.9.6 require string
        // (lib/openzeppelin-contracts-upgradeable ReentrancyGuardUpgradeable.sol).
        assertEq(
            rnt.reentryRevertReason(), "ReentrancyGuard: reentrant call", "revert was not the ReentrancyGuard"
        );
    }

    // ── blockedAccounts page cap / no overflow-revert ──

    function test_blockedAccounts_large_offset_and_limit_no_overflow() public {
        vm.startPrank(ADMIN);
        queue.freeze(ORIG);
        queue.blacklist(OWNR);
        vm.stopPrank();
        // A near-max offset+limit used to overflow-revert (unchecked add). Now the
        // limit is capped and offset>=len returns empty — never reverts. `total`
        // is still the true set size even when the page is empty.
        (address[] memory got, uint256 total) = queue.blockedAccounts(type(uint256).max, type(uint256).max);
        assertEq(got.length, 0);
        assertEq(total, 2);
    }

    function test_blockedAccounts_limit_capped_to_page_max() public {
        // With only 2 blocked accounts and a huge limit, we get exactly 2 back and
        // no overflow (limit clamped to MAX_GET_ACTIVE_PAGE internally).
        vm.startPrank(ADMIN);
        queue.freeze(ORIG);
        queue.blacklist(OWNR);
        vm.stopPrank();
        (address[] memory got, uint256 total) = queue.blockedAccounts(0, type(uint256).max);
        assertEq(got.length, 2);
        assertEq(total, 2);
    }

    /// @dev `total` reports the FULL blocked-set size even when a
    ///      caller pages past the 500-entry cap — so a monitor never silently
    ///      undercounts. Block 600 accounts, then read page 0 with a huge limit:
    ///      page is clamped to 500 but `total` reads back the true 600.
    function test_blockedAccounts_total_reports_full_size_past_page_cap() public {
        uint256 n = 600;
        address[] memory many = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            // start at 1 so no address is 0 (ZeroAddress guard in _setBlock)
            many[i] = address(uint160(i + 1));
        }
        vm.prank(ADMIN);
        queue.freeze(many);

        (address[] memory page, uint256 total) = queue.blockedAccounts(0, type(uint256).max);
        assertEq(page.length, 500); // clamped to MAX_GET_ACTIVE_PAGE
        assertEq(total, n); // but total reads back the full 600

        // The tail past the cap is reachable by advancing the offset; total is
        // invariant across pages.
        (address[] memory page2, uint256 total2) = queue.blockedAccounts(500, 500);
        assertEq(page2.length, 100);
        assertEq(total2, n);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Coverage-gap fill (previous-cycle report): uncovered guard/revert arms
    // and 0-hit fns. Fund-relevant Leg-2/Leg-3/solvency/ingress paths first.
    // ─────────────────────────────────────────────────────────────────────

    // ── single-id blacklistFromRequest (was 0 hits; only batch tested) ──

    function test_blacklistFromRequest_single_blocks_orig_and_owner() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.blacklistFromRequest(uint256(1), false, keccak256("bad"));
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        // receiver NOT blocked (freezeReceiver == false)
        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.None));
        assertEq(queue.blockTrigger(ORIG), 1);
    }

    function test_blacklistFromRequest_single_freezeReceiver_true() public {
        _queueErc20(10 ether);
        vm.prank(ADMIN);
        queue.blacklistFromRequest(uint256(1), true, keccak256("bad"));
        assertEq(uint256(queue.blockStateOf(RCVR)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    function test_blacklistFromRequest_single_unknown_id_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 99));
        queue.blacklistFromRequest(uint256(99), false, bytes32(0));
    }

    // ── batch address-list variants (blacklist/unfreeze/unblacklist: 0 hits) ──

    function test_batch_blacklist_address_list() public {
        address[] memory who = new address[](2);
        who[0] = ORIG;
        who[1] = OWNR;
        vm.prank(ADMIN);
        queue.blacklist(who);
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.Blacklisted));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.Blacklisted));
    }

    function test_batch_unfreeze_address_list() public {
        address[] memory who = new address[](2);
        who[0] = ORIG;
        who[1] = OWNR;
        vm.startPrank(ADMIN);
        queue.freeze(who);
        queue.unfreeze(who);
        vm.stopPrank();
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.None));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.None));
    }

    function test_batch_unblacklist_address_list() public {
        address[] memory who = new address[](2);
        who[0] = ORIG;
        who[1] = OWNR;
        vm.startPrank(ADMIN);
        queue.blacklist(who);
        queue.unblacklist(who);
        vm.stopPrank();
        assertEq(uint256(queue.blockStateOf(ORIG)), uint256(IExitDelayQueue.BlockState.None));
        assertEq(uint256(queue.blockStateOf(OWNR)), uint256(IExitDelayQueue.BlockState.None));
    }

    // ── EmptyIds on the four address-array block fns ──

    function test_freeze_address_batch_empty_reverts() public {
        address[] memory who = new address[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.freeze(who);
    }

    function test_blacklist_address_batch_empty_reverts() public {
        address[] memory who = new address[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.blacklist(who);
    }

    function test_unfreeze_address_batch_empty_reverts() public {
        address[] memory who = new address[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.unfreeze(who);
    }

    function test_unblacklist_address_batch_empty_reverts() public {
        address[] memory who = new address[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.unblacklist(who);
    }

    // ── MAX_GET_ACTIVE_PAGE is a public constant ──

    function test_MAX_GET_ACTIVE_PAGE_public_constant() public view {
        assertEq(queue.MAX_GET_ACTIVE_PAGE(), 500);
        // Reachable through the interface type too (self-describing on-chain).
        assertEq(IExitDelayQueue(address(queue)).MAX_GET_ACTIVE_PAGE(), 500);
    }

    // ── batch blacklistFromRequest authority arm (only freeze variant tested) ──

    function test_blacklistFromRequest_batch_only_admin_or_owner() public {
        _queueErc20(10 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitDelayQueue.NotAdminOrOwner.selector, OUTSIDER));
        queue.blacklistFromRequest(ids, false, bytes32(0));
    }

    // ── _setBlock ZeroAddress guard (freeze/blacklist address(0)) ──

    function test_freeze_zero_address_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        queue.freeze(address(0));
    }

    // ── recordReceivedNativeExit short-push mismatch (native twin of ERC20) ──

    function test_recordReceivedNative_reverts_on_short_push() public {
        vm.prank(OWNER);
        queue.setNativePusher(address(pusher));
        // Push only 3 ether but claim 5 → measured delta (3) < amount (5).
        pusher.push(payable(address(queue)), 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExitDelayQueue.ReceivedAmountMismatch.selector, address(0), 3 ether, 5 ether
            )
        );
        source.recordReceivedNative(5 ether, DELAY, SURFACE_ZERO, address(0), ORIG, OWNR, RCVR);
    }

    // ── resolveToProtocol guard arms: EmptyIds / RouteInactive / UnknownRequest / AlreadyTerminal ──

    function test_resolveToProtocol_empty_ids_reverts() public {
        bytes32 routeId = _setupRoute(false);
        uint256[] memory ids = new uint256[](0);
        vm.prank(ADMIN);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_inactive_route_reverts() public {
        _queueErc20(10 ether);
        // route id that was never registered → route.active == false
        bytes32 routeId = keccak256("nonexistent-route");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.RouteInactive.selector, routeId));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_reverts_after_route_removed() public {
        // removeRecoveryRoute (0 hits) → the route deactivates → RouteInactive.
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        vm.prank(OWNER);
        queue.removeRecoveryRoute(routeId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.RouteInactive.selector, routeId));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_unknown_request_reverts() public {
        bytes32 routeId = _setupRoute(false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99; // never queued
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 99));
        queue.resolveToProtocol(ids, routeId);
    }

    function test_resolveToProtocol_already_terminal_reverts() public {
        // Execute the request first (→ Executed, a terminal status), then try to
        // Leg-2 it → AlreadyTerminal.
        _queueErc20(10 ether);
        bytes32 routeId = _setupRoute(false);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.executeExit(1);
        vm.prank(ADMIN);
        queue.blacklist(ORIG);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.resolveToProtocol(ids, routeId);
    }

    // ── resolveBySIP guard arms: EmptyIds / ZeroAddress / UnknownRequest / AlreadyTerminal ──

    function test_resolveBySIP_empty_ids_reverts() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.EmptyIds.selector);
        queue.resolveBySIP(ids, address(0x7EEA));
    }

    function test_resolveBySIP_zero_destination_reverts() public {
        _queueErc20(10 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        queue.resolveBySIP(ids, address(0));
    }

    function test_resolveBySIP_unknown_request_reverts() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.UnknownRequest.selector, 99));
        queue.resolveBySIP(ids, address(0x7EEA));
    }

    function test_resolveBySIP_already_terminal_reverts() public {
        _queueErc20(10 ether);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNR);
        queue.executeExit(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IExitDelayQueue.AlreadyTerminal.selector, 1));
        queue.resolveBySIP(ids, address(0x7EEA));
    }

    // ── sweepSurplus backstop arms: SweepToZero + SolvencyViolated (native & ERC20) ──

    function test_sweepSurplus_to_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.SweepToZero.selector);
        queue.sweepSurplus(address(token), address(0));
    }

    // The SolvencyViolated post-sweep checks (766 native / 772 ERC20) are the
    //  backstop: with correct accounting `surplus == bal - escrowed`, so the
    // post-sweep balance lands at exactly `escrowed` and the require passes.
    // Here we drive a legitimate full-surplus sweep so the ERC20 require at 772
    // is REACHED and passes (the pass-branch was the uncovered arm). The FAIL
    // branch (a token whose transfer drains more than `surplus` from the queue)
    // is exercised in ExitDelayQueueGrief.t.sol::test_sweepSurplus_solvency_violated
    // with a bespoke over-draining token mock.
    function test_sweepSurplus_erc20_reaches_solvency_check() public {
        // Queue escrows 10; mint an extra 5 surplus directly to the queue.
        _queueErc20(10 ether);
        token.mint(address(queue), 5 ether);
        uint256 before = token.balanceOf(address(0xBEEF));
        vm.prank(OWNER);
        queue.sweepSurplus(address(token), address(0xBEEF));
        // exactly the 5 surplus moved; escrow backing (10) untouched → check passed
        assertEq(token.balanceOf(address(0xBEEF)), before + 5 ether);
        assertEq(token.balanceOf(address(queue)), 10 ether);
    }

    // ── initialize with a non-empty initialAllowedSources (loop + guards) ──

    function test_initialize_with_initial_sources_and_dup() public {
        ExitDelayQueue impl = new ExitDelayQueue();
        address a = address(0xA1);
        address b = address(0xB2);
        address[] memory s = new address[](3);
        s[0] = a;
        s[1] = b;
        s[2] = a; // duplicate → set.add returns false → skip branch (line 210)
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, s
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ExitDelayQueue q = ExitDelayQueue(payable(address(proxy)));
        assertTrue(q.isAllowedSource(a));
        assertTrue(q.isAllowedSource(b));
        assertEq(q.allowedSources().length, 2); // dup collapsed
    }

    function test_initialize_reverts_zero_source() public {
        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory s = new address[](1);
        s[0] = address(0); // ZeroAddress-source revert (line 209)
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, s
        );
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    // ── _authorizeUpgrade (UUPS): happy upgrade + UpgradeImplZero + only-owner ──

    function test_upgrade_to_v2_by_owner() public {
        ExitDelayQueueV2 v2 = new ExitDelayQueueV2();
        vm.prank(OWNER);
        queue.upgradeTo(address(v2));
        assertEq(ExitDelayQueueV2(payable(address(queue))).version(), 2);
        // state preserved across upgrade
        assertEq(queue.owner(), OWNER);
        assertEq(queue.admin(), ADMIN);
    }

    function test_upgrade_zero_impl_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(ExitDelayQueue.UpgradeImplZero.selector);
        queue.upgradeTo(address(0));
    }

    function test_upgrade_only_owner() public {
        ExitDelayQueueV2 v2 = new ExitDelayQueueV2();
        vm.prank(OUTSIDER);
        vm.expectRevert("Ownable: caller is not the owner");
        queue.upgradeTo(address(v2));
    }

    // ── getActive n > MAX_GET_ACTIVE_PAGE cap (the original mirrored) ──

    function test_getActive_n_capped_no_overflow() public {
        _queueErc20(1 ether);
        _queueErc20(1 ether);
        // A near-max `n` used to risk `cursor + n` overflow; it is clamped to the
        // page cap and returns only the 2 active ids without reverting.
        (uint256[] memory ids, uint256 nextCursor) = queue.getActive(ORIG, 0, type(uint256).max);
        assertEq(ids.length, 2);
        assertEq(nextCursor, 0);
    }

    // ── ZeroAddress guards on setRecoveryRoute / addAllowedSource / setAdmin ──

    function test_setRecoveryRoute_zero_destination_reverts() public {
        IExitDelayQueue.RecoveryRoute memory route = IExitDelayQueue.RecoveryRoute({
            active: true,
            surfaceId: SURFACE,
            subProduct: SUBPRODUCT,
            token: address(token),
            destination: address(0),
            topUpPool: false
        });
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        queue.setRecoveryRoute(route);
    }

    function test_addAllowedSource_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        queue.addAllowedSource(address(0));
    }

    function test_setAdmin_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(IExitDelayQueue.ZeroAddress.selector);
        queue.setAdmin(address(0));
    }

    // ── view getters (read-only, low risk): exercise the 0-hit accessors ──

    function test_view_getters() public {
        bytes32 routeId = _setupRoute(false);
        IExitDelayQueue.RecoveryRoute memory got = queue.getRecoveryRoute(routeId);
        assertEq(got.destination, address(0xDE57));
        assertTrue(got.active);

        address[] memory srcs = queue.allowedSources();
        assertEq(srcs.length, 1); // the SourceHarness registered in setUp
        assertEq(srcs[0], address(source));

        bytes32[] memory ids = queue.recoveryRouteIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], routeId);

        // topUpFeasible getter: false for an un-flagged surface, true after set
        assertFalse(queue.topUpFeasible(SURFACE_ZERO));
        vm.prank(OWNER);
        queue.setTopUpFeasible(SURFACE_ZERO, true);
        assertTrue(queue.topUpFeasible(SURFACE_ZERO));
    }
}
