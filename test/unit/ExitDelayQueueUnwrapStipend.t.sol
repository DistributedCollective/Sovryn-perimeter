// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueue} from "../../src/interfaces/IExitDelayQueue.sol";

/// @title  ExitDelayQueueUnwrapStipend
/// @notice (HIGH) regression. Reproduces the empirically-
///         proven OutOfGas brick and proves the unconditional `receive()` fix.
///
///         The real Rootstock WRBTC `withdraw()` returns native RBTC to the caller
///         via a **2300-gas `transfer` stipend** (WETH9 semantics). When the queue
///         unwraps an `unwrapOnDelivery` request at `executeExit`, WRBTC sends the
///         native back into the queue's `receive()`. A `receive()` that reads any
///         storage slot to gate the sender (SLOAD ≥ 2100 cold under EIP-2929 /
///         Paris) exceeds the 2300 stipend and reverts OutOfGas — permanently
///         bricking every native `burnToBTC` (unwrapOnDelivery) payout after unlock.
///
///         Run under `forge test --isolate` so EIP-2929 cold/warm access gas is
///         charged realistically. The production-path test
///         (`test_unwrap_payout_succeeds_under_transfer_stipend`) passes in BOTH
///         modes and is the mode-independent gate; the apples-to-apples control
///         (`..._control_ISOLATE_ONLY`) reproduces the pre-fix brick only when
///         cold-access gas is charged (isolate) and self-skips otherwise.
contract ExitDelayQueueUnwrapStipendTest is Test {
    ExitDelayQueue queue;
    WETH9StyleWRBTC wrbtc;
    Source source;

    address constant OWNER = address(0x0E1);
    address constant ADMIN = address(0xAd11);
    address constant ORIG = address(0x0111);
    address constant OWNR = address(0x0222);
    address payable constant RCVR = payable(address(0x0333));

    bytes32 constant SURFACE = keccak256("COLFEE:LENDING_LENDER_WITHDRAW");
    address constant SUBPRODUCT = address(0xB00C);
    uint32 constant MIN_DELAY = 1 hours;
    uint32 constant DELAY = 2 hours;

    function setUp() public {
        wrbtc = new WETH9StyleWRBTC();

        ExitDelayQueue impl = new ExitDelayQueue();
        address[] memory sources = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, sources
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        queue = ExitDelayQueue(payable(address(proxy)));

        source = new Source(queue);
        vm.prank(OWNER);
        queue.addAllowedSource(address(source));

        // Fund the source with WRBTC (backed 1:1 by native inside the WRBTC).
        wrbtc.depositTo{value: 1_000 ether}(address(source));
        vm.deal(address(this), 1_000 ether);
    }

    /// @notice The production fix: with the UNCONDITIONAL receive(), unwrapping a
    ///         WRBTC-escrowed request via the 2300-stipend WRBTC.withdraw succeeds
    ///         and the user receives native RBTC. Under `--isolate` the queue's
    ///         `receive()` slots are cold, so this would OutOfGas-revert if
    ///         `receive()` did ANY storage read (the pre-fix gate).
    function test_unwrap_payout_succeeds_under_transfer_stipend() public {
        uint128 amount = 5 ether;
        uint256 id = source.record(address(wrbtc), amount, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, true);

        vm.warp(block.timestamp + DELAY);
        uint256 before = RCVR.balance;

        vm.prank(OWNR);
        queue.executeExit(id);

        assertEq(RCVR.balance, before + amount, "receiver got native RBTC");
        assertEq(wrbtc.balanceOf(RCVR), 0, "receiver holds no WRBTC");
        assertEq(uint256(queue.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Executed));
        assertEq(queue.totalEscrowed(address(wrbtc)), 0);
    }

    /// @notice APPLES-TO-APPLES CONTROL (isolate-only): the identical unwrap-payout
    ///         flow, but the proxy runs an impl whose `receive()` reads ONE storage
    ///         slot to gate the sender (the exact pre-fix gate). Under `--isolate`
    ///         the queue's slots are COLD at the moment WRBTC.withdraw forwards
    ///         native, so the cold SLOAD (2100 gas, EIP-2929/Paris) on top of the
    ///         proxy delegatecall exceeds the 2300 `transfer` stipend → OutOfGas,
    ///         bricking the payout. The SOLE difference from the passing production
    ///         case above is whether `receive()` touches storage.
    ///
    ///         The brick ONLY reproduces with cold access accounting, i.e. under
    ///         `forge test --isolate`. Without `--isolate` the queue's slots are
    ///         warmed earlier in the same tx (warm SLOAD = 100 gas, fits the
    ///         stipend), so the brick does not manifest and this control self-skips
    ///         — the production regression above is the real, mode-independent gate.
    function test_gated_receive_bricks_unwrap_payout_control_ISOLATE_ONLY() public {
        if (!_coldSloadExceedsStipend()) {
            emit log("skip: cold-access gas not charged (run with --isolate to exercise this control)");
            return;
        }

        // Stand up a second proxy running the sender-GATED impl.
        GatedReceiveQueue gatedImpl = new GatedReceiveQueue();
        address[] memory sources = new address[](0);
        bytes memory init = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, OWNER, ADMIN, address(wrbtc), MIN_DELAY, sources
        );
        ERC1967Proxy gatedProxy = new ERC1967Proxy(address(gatedImpl), init);
        ExitDelayQueue gq = ExitDelayQueue(payable(address(gatedProxy)));

        Source gsource = new Source(gq);
        vm.prank(OWNER);
        gq.addAllowedSource(address(gsource));
        wrbtc.depositTo{value: 100 ether}(address(gsource));

        uint128 amount = 5 ether;
        uint256 id =
            gsource.record(address(wrbtc), amount, DELAY, SURFACE, SUBPRODUCT, ORIG, OWNR, RCVR, true);
        vm.warp(block.timestamp + DELAY);

        // The gated receive() OutOfGas-reverts the WRBTC unwrap transfer; the whole
        // executeExit rolls back (fail-closed), the request stays Queued — the
        // permanent brick the fix removes.
        vm.prank(OWNR);
        vm.expectRevert();
        gq.executeExit(id);
        assertEq(uint256(gq.getRequest(id).status), uint256(IExitDelayQueue.ExitStatus.Queued));
    }

    /// @dev Detects whether the run charges EIP-2929 cold-access gas (i.e. we are
    ///      under `--isolate`). Probes a fresh contract's cold storage slot: a cold
    ///      SLOAD costs ~2100 gas, a warm one ~100. Returns true when the measured
    ///      cost is high enough that a cold SLOAD would blow the 2300 stipend.
    function _coldSloadExceedsStipend() internal returns (bool) {
        ColdSlotProbe p = new ColdSlotProbe();
        uint256 used = p.measureColdSload();
        // Cold SLOAD ≈ 2100; warm ≈ 100. Threshold well between the two.
        return used > 1500;
    }
}

/// @dev Measures the gas cost of a single (cold) SLOAD in the current run's
///      access-accounting mode. Under `--isolate` a first-touch SLOAD is cold
///      (~2100 gas); otherwise the framework may have warmed it (~100 gas).
contract ColdSlotProbe {
    uint256 private slot = 7;

    function measureColdSload() external view returns (uint256 used) {
        uint256 g0 = gasleft();
        uint256 v = slot; // the SLOAD under measurement
        uint256 g1 = gasleft();
        // touch v so the optimizer cannot elide the load
        used = (g0 - g1) + (v & 0);
    }
}

// ─── Mocks ────────────────────────────────────────────────────────────────

/// @dev WETH9-style WRBTC: withdraw() forwards native via `transfer` (2300-gas
///      stipend), exactly like the real Rootstock WRBTC. This is the mock that
///      surfaces the brick — a `.call{value}` mock (unlimited gas) would not.
contract WETH9StyleWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function depositTo(address to) external payable {
        _mint(to, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        // 2300-gas stipend forward — the load-bearing difference from a
        // `.call{value: amount}("")` mock.
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

/// @dev Registered ingress source (mirrors an iToken proxy). Pulls WRBTC then
///      records with unwrapOnDelivery.
contract Source {
    ExitDelayQueue public queue;

    constructor(ExitDelayQueue q) {
        queue = q;
    }

    function record(
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
}

/// @dev Control impl: identical to production ExitDelayQueue EXCEPT `receive()`
///      reads a storage slot to gate the sender (the exact PRE-FIX gate). Deployed
///      behind the same proxy pattern so the ONLY behavioral difference from the
///      production impl is the storage read in `receive()`. Under the WRBTC
///      2300-gas `transfer` stipend that read OutOfGas-bricks the unwrap payout.
contract GatedReceiveQueue is ExitDelayQueue {
    receive() external payable override {
        // Cold SLOAD of `wrbtc` (2100 gas under EIP-2929/Paris) + the comparison
        // exceeds the 2300 stipend the WRBTC withdraw forwards → OutOfGas. This is
        // the empirically-proven brick the unconditional receive() removes.
        if (msg.sender != nativePusher && msg.sender != wrbtc) revert UnregisteredSource(msg.sender);
    }
}
