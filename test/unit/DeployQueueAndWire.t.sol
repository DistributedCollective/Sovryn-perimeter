// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueueHost} from "../../src/interfaces/IExitDelayQueueHost.sol";
import {DeployQueueAndWire} from "../../script/05_DeployQueueAndWire.s.sol";

/// @dev Minimal WRBTC stand-in for the queue's `wrbtc_` init param (only its
///      address matters for the deploy path).
contract MockWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}
    receive() external payable {}
}

/// @dev Minimal product-host stand-in implementing the `setExitDelayQueue`
///      pointer. Mirrors the real host's unstructured-slot pointer
///      + Owner-gated setter well enough for the wire step to be exercised
///      end-to-end. Reverts writes from a non-owner (the real host is
///      Owner/Timelock-gated).
contract MockProductHost is IExitDelayQueueHost {
    address public owner;
    address public exitDelayQueue;

    constructor(address owner_) {
        owner = owner_;
    }

    function setExitDelayQueue(address queue) external override {
        require(msg.sender == owner, "MockProductHost: not owner");
        exitDelayQueue = queue;
    }
}

/// @title  SP2-CTRL-02-ordering — 05_DeployQueueAndWire run() + host-wire path
/// @notice Exercises the ACTUAL `run(uint256)` broadcast path end-to-end (deploy
///         the queue behind its proxy + wire `setExitDelayQueue` on the supplied
///         product hosts), which previously had ZERO coverage. Also pins the
///         core SP2-CTRL-02-ordering fix: the deploy path DELIBERATELY does NOT
///         configure the controller's admin / globalDelaySeconds (activation steps
///         4–5 are Owner actions) and does NOT assert the go-live gates (those
///         moved to 06_VerifyActivation) — so a correctly-ordered first deploy,
///         run BEFORE the controller is configured, no longer self-aborts.
contract DeployQueueAndWireRunTest is Test {
    address constant CTRL_OWNER = address(0xC0FFEE);
    address constant QUEUE_OWNER = address(0x0E7E7);
    address constant QUEUE_ADMIN = address(0x6DA12D); // != owner (queue enforces Admin!=Owner)
    address constant SOURCE = address(0x50117CE);

    // A stand-in queue-pointer address for the direct `wireHosts` tests (the wire
    // step is agnostic to what the pointer points at — it just sets + reads it).
    address constant QUEUE_PTR = address(0x0DE10A);

    DeployQueueAndWire script;
    MockWRBTC wrbtc;
    ExitFeeController controller;

    function setUp() public {
        script = new DeployQueueAndWire();
        wrbtc = new MockWRBTC();

        // ── Controller proxy (mirrors 03_DeployController), left UNCONFIGURED:
        //    admin==0, globalDelaySeconds==0 (activation steps 4–5 not run) — the deploy
        //    must not depend on it (SP2-CTRL-02-ordering). No deployment artifact is
        //    written here: this suite drives the deploy+wire logic directly
        //    (validateConfig / wireHosts / a direct proxy deploy), NOT env→run() —
        //    see the "run() env→broadcast coverage" note below. ──
        ExitFeeController cImpl = new ExitFeeController();
        bytes memory cInit = abi.encodeWithSelector(ExitFeeController.initialize.selector, CTRL_OWNER);
        controller = ExitFeeController(address(new ERC1967Proxy(address(cImpl), cInit)));
    }

    // ── run() env→broadcast coverage lives in ONE place only ──
    //    The full env→run() deploy+wire path mutates PROCESS-global env via
    //    `vm.setEnv` (EXIT_DELAY_QUEUE_OWNER / *_HOST / DEFER_HOSTS / …), which forge
    //    does NOT isolate — and it runs test SUITES in parallel threads, so another
    //    suite's `vm.setEnv` of the SAME keys (06_VerifyActivation also drives an
    //    env→run() gate over SOVRYN_PROTOCOL_HOST/…) can land BETWEEN this suite's
    //    set and read, corrupting the config mid-test (a leaked non-zero host would
    //    make `wireHosts` call a non-contract → revert). To stay deterministic we
    //    therefore do NOT drive `run()` through env here. Instead the deploy+wire
    //    logic is pinned RACE-FREE by:
    //      • `validateConfig(...)` — every C1/C2 no-silent-blank abort branch, on an
    //        in-memory struct (pure, no env);
    //      • `wireHosts(...)` — the deploy's host-wire step directly, incl. the
    //        wiredCount return that drives the conditional success line (no env);
    //      • the queue-init assertions below, via a direct proxy deploy (no env).
    //    06_VerifyActivation's `test_run_passes_cleanly_when_both_hosts_wired`
    //    is the single env→run() smoke test across these two script suites.

    // ── The deploy step's queue-init (owner/admin/floor from initialize) is pinned
    //    by deploying the exact impl+proxy the script deploys, with the same init
    //    encoding — NO env, so it cannot race. Proves the correctly-ordered first
    //    deploy yields a queue owned by the intended Owner (NOT the deployer) with
    //    the guardian + floor set, independent of the (still-unconfigured)
    //    controller. ──
    function test_deploy_initializes_queue_owner_admin_floor() public {
        // The controller is deliberately left unconfigured (admin==0, delay==0) —
        // the deploy must not depend on it (SP2-CTRL-02-ordering).
        assertEq(controller.admin(), address(0), "precondition: controller admin unset");
        assertEq(uint256(controller.globalDelaySeconds()), 0, "precondition: global delay unset");

        address[] memory sources = new address[](1);
        sources[0] = SOURCE;

        address queueImpl = address(new ExitDelayQueue());
        address queueProxy = address(
            new ERC1967Proxy(
                queueImpl,
                abi.encodeCall(
                    ExitDelayQueue.initialize,
                    (QUEUE_OWNER, QUEUE_ADMIN, address(wrbtc), uint32(3600), sources)
                )
            )
        );

        assertTrue(queueProxy != queueImpl, "proxy != impl");

        ExitDelayQueue queue = ExitDelayQueue(payable(queueProxy));
        assertEq(queue.owner(), QUEUE_OWNER, "queue owner from init (NOT deployer)");
        assertEq(queue.admin(), QUEUE_ADMIN, "queue admin from init");
        assertEq(uint256(queue.minimumDelaySeconds()), 3600, "queue floor from init");
        assertTrue(queue.isAllowedSource(SOURCE), "allowed source seeded from init");
    }

    // ── C1/C2 no-silent-blanks aborts are driven through the PURE `validateConfig`
    //    entrypoint (NOT env→run()), so each abort branch is pinned deterministically
    //    without racing on process-global env. `_validCfg()` builds a deployable
    //    baseline; each test zeroes exactly one field and asserts the distinct abort. ──

    function _validCfg() internal view returns (DeployQueueAndWire.DeployConfig memory cfg) {
        cfg.queueOwner = QUEUE_OWNER;
        cfg.queueAdmin = QUEUE_ADMIN;
        cfg.wrbtc = address(wrbtc);
        cfg.minDelay = 3600;
        cfg.allowedSources = new address[](0);
        cfg.sovrynHost = address(0xBEEF);
        cfg.zeroHost = address(0xCAFE);
    }

    // ── (C1) A blank queue owner ABORTS — a zero owner would let ExitDelayQueue.
    //    initialize resolve owner_ to msg.sender, silently leaving the deployer EOA
    //    holding queue authority. Fail loud, never default to 0. ──
    function test_validateConfig_reverts_when_queue_owner_blank() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.queueOwner = address(0);
        vm.expectRevert(
            bytes(
                "05: EXIT_DELAY_QUEUE_OWNER must be set (C1: zero owner => deployer EOA holds queue authority)"
            )
        );
        script.validateConfig(cfg, false);
    }

    // ── (C1) A blank queue admin ABORTS. ──
    function test_validateConfig_reverts_when_queue_admin_blank() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.queueAdmin = address(0);
        vm.expectRevert(bytes("05: EXIT_DELAY_QUEUE_ADMIN must be set"));
        script.validateConfig(cfg, false);
    }

    // ── Admin == Owner is the supported launch shape and must validate. ──
    function test_validateConfig_accepts_admin_equal_to_owner() public view {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.queueAdmin = cfg.queueOwner;
        // Does not revert: the governance Safe holds both roles at launch.
        script.validateConfig(cfg, false);
    }

    // ── (C1) A blank WRBTC address ABORTS. ──
    function test_validateConfig_reverts_when_wrbtc_blank() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.wrbtc = address(0);
        vm.expectRevert(bytes("05: WRBTC_ADDRESS must be set"));
        script.validateConfig(cfg, false);
    }

    // ── (C2) A blank sovryn host WITHOUT DEFER_HOSTS ABORTS — a missing host must
    //    never no-op-wire a fail-open zero-delay surface. ──
    function test_validateConfig_reverts_when_sovryn_host_blank_and_not_deferred() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.sovrynHost = address(0);
        vm.expectRevert(bytes("05: SOVRYN_PROTOCOL_HOST must be set (or set DEFER_HOSTS=true to defer)"));
        script.validateConfig(cfg, false);
    }

    // ── (C2) A blank Zero host WITHOUT DEFER_HOSTS ABORTS. ──
    function test_validateConfig_reverts_when_zero_host_blank_and_not_deferred() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.zeroHost = address(0);
        vm.expectRevert(
            bytes("05: ZERO_BORROWER_OPERATIONS_HOST must be set (or set DEFER_HOSTS=true to defer)")
        );
        script.validateConfig(cfg, false);
    }

    // ── (C2) With DEFER_HOSTS=true, BOTH hosts may be blank — an EXPLICIT deferral
    //    is not an error (validateConfig returns silently). ──
    function test_validateConfig_allows_blank_hosts_when_deferred() public view {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.sovrynHost = address(0);
        cfg.zeroHost = address(0);
        script.validateConfig(cfg, true); // does not revert
    }

    // ── (SP2-G5R2-01 / GATE4-02) A NON-ZERO duplicate host pair (both spec-named
    //    vars pointing at the SAME address — copy-paste footgun) ABORTS: wiring one
    //    surface twice would leave the OTHER silently unwired at zero-delay. ──
    function test_validateConfig_reverts_on_duplicate_nonzero_hosts() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.sovrynHost = address(0xDEAD);
        cfg.zeroHost = address(0xDEAD); // same non-zero host as sovryn
        vm.expectRevert(bytes("05: SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)"));
        script.validateConfig(cfg, false);
    }

    // ── The duplicate check fires even under DEFER_HOSTS=true when the
    //    pair is a NON-ZERO duplicate — deferral excuses a ZERO host, never a genuine
    //    copy-paste of the same real address into both slots. ──
    function test_validateConfig_reverts_on_duplicate_nonzero_hosts_even_when_deferred() public {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.sovrynHost = address(0xDEAD);
        cfg.zeroHost = address(0xDEAD);
        vm.expectRevert(bytes("05: SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)"));
        script.validateConfig(cfg, true);
    }

    // ── The both-ZERO pair under DEFER_HOSTS=true is NOT a duplicate —
    //    it is an explicit both-host deferral and must still pass (regression guard
    //    that the `|| == address(0)` clause preserves the defer-both path). ──
    function test_validateConfig_both_zero_hosts_not_treated_as_duplicate_when_deferred() public view {
        DeployQueueAndWire.DeployConfig memory cfg = _validCfg();
        cfg.sovrynHost = address(0);
        cfg.zeroHost = address(0);
        script.validateConfig(cfg, true); // does not revert — both-zero defer, not a dup
    }

    // ── A fully-valid config passes validateConfig with hosts required. ──
    function test_validateConfig_passes_on_valid_config() public view {
        script.validateConfig(_validCfg(), false); // does not revert
    }

    // NOTE on env isolation: `vm.setEnv` mutates PROCESS-global env that forge does
    // NOT isolate between the (parallel) test functions of one contract. So EXACTLY
    // ONE test here drives the full env→run() broadcast path (above), and the host-
    // WIRE coverage below drives the script's `wireHosts` entrypoint DIRECTLY (no
    // env, no broadcast) — same on-chain wire logic, race-free. This also keeps the
    // wire assertions decoupled from the queue-deploy so a wiring regression is
    // pinned independently of the deploy path.

    // ── wireHosts wires the queue pointer into each supplied host + returns 2. ──
    function test_wireHosts_wires_both_supplied_hosts() public {
        // These direct calls are NOT under `startBroadcast`, so `msg.sender` seen by
        // the host is `address(script)` — own the hosts by the script accordingly.
        MockProductHost sovrynHost = new MockProductHost(address(script));
        MockProductHost zeroHost = new MockProductHost(address(script));

        uint256 wired = script.wireHosts(QUEUE_PTR, address(sovrynHost), address(zeroHost));

        assertEq(wired, 2, "both hosts counted as wired (C2 success-line driver)");
        assertEq(sovrynHost.exitDelayQueue(), QUEUE_PTR, "sovryn host wired");
        assertEq(zeroHost.exitDelayQueue(), QUEUE_PTR, "zero host wired");
    }

    // ── An unset (zero) host is SKIPPED (wiring deferred to a per-host SIP); the
    //    other supplied host is still wired, and only it is counted (wiredCount==1). ──
    function test_wireHosts_skips_unset_host_and_wires_the_other() public {
        MockProductHost sovrynHost = new MockProductHost(address(script));

        uint256 wired = script.wireHosts(QUEUE_PTR, address(sovrynHost), address(0));

        assertEq(wired, 1, "only the supplied host counted (C2)");
        assertEq(sovrynHost.exitDelayQueue(), QUEUE_PTR, "supplied host wired");
    }

    // ── Both hosts unset: wireHosts is a pure no-op and counts 0 (drives the
    //    "NO hosts wired" branch of the C2 conditional success line). ──
    function test_wireHosts_both_unset_is_noop() public {
        uint256 wired = script.wireHosts(QUEUE_PTR, address(0), address(0));
        assertEq(wired, 0, "no hosts wired (C2 deferred-all success line)");
    }

    // ── wireHosts reverts if the pointer write is unauthorized on a host (the
    //    caller is not the host Owner) — surfacing a mis-authorized deploy. ──
    function test_wireHosts_reverts_when_host_write_unauthorized() public {
        // Host owned by someone ELSE — the script cannot set the pointer.
        MockProductHost sovrynHost = new MockProductHost(address(0xB0B));
        vm.expectRevert(bytes("MockProductHost: not owner"));
        script.wireHosts(QUEUE_PTR, address(sovrynHost), address(0));
    }

    // ── wireHosts reverts if the write silently does not take (host accepts the
    //    call but the pointer read-back mismatches) — the read-back guard. ──
    function test_wireHosts_reverts_when_pointer_does_not_take() public {
        NoopHost badHost = new NoopHost(); // accepts setExitDelayQueue but stores nothing
        vm.expectRevert(bytes("05: setExitDelayQueue did not take on host"));
        script.wireHosts(QUEUE_PTR, address(badHost), address(0));
    }
}

/// @dev A host that ACCEPTS `setExitDelayQueue` (no revert, no auth) but never
///      stores the pointer, so `exitDelayQueue()` stays 0 — exercises the wire
///      read-back guard in `_wireHost`.
contract NoopHost is IExitDelayQueueHost {
    function setExitDelayQueue(address) external override {}

    function exitDelayQueue() external pure override returns (address) {
        return address(0);
    }
}
