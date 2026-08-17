// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../../src/ExitFeeController.sol";
import {ExitDelayQueue} from "../../src/ExitDelayQueue.sol";
import {IExitDelayQueueHost} from "../../src/interfaces/IExitDelayQueueHost.sol";
import {VerifyActivation} from "../../script/06_VerifyActivation.s.sol";

/// @dev Test harness exposing the internal host-resolution helpers so the C1
///      defer/warning/require logic is driveable on in-memory addresses WITHOUT
///      `vm.setEnv` (which mutates process-global env forge does not isolate
///      between parallel test functions — a genuine race).
contract VerifyActivationHarness is VerifyActivation {
    function resolveHosts(bool deferHosts, address sovrynHost, address zeroHost)
        external
        view
        returns (address[] memory)
    {
        return _resolveHosts(deferHosts, sovrynHost, zeroHost);
    }

    /// Expose the banner emitter so BOTH legs — the unqualified "safe to run step 8"
    /// banner (anyHostDeferred==false) and the qualified/warned downgrade
    /// (anyHostDeferred==true) — are exercised deterministically WITHOUT the env→run
    /// path (G5R2-02 coverage). View-only, no state, no revert.
    function reportPass(bool anyHostDeferred) external view {
        _reportPass(anyHostDeferred);
    }
}

/// @dev Minimal WRBTC stand-in for the queue's `wrbtc_` init param.
contract MockWRBTC is ERC20 {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}
    receive() external payable {}
}

/// @dev Minimal product-host stand-in implementing the `setExitDelayQueue` pointer
///       so the C2 wiring assertions can be driven end-to-end.
contract MockProductHost is IExitDelayQueueHost {
    address public exitDelayQueue;

    function setExitDelayQueue(address queue) external override {
        exitDelayQueue = queue;
    }
}

/// @title  activation step-7 COMPREHENSIVE go-live gate — 06_VerifyActivation (C1/C2)
/// @notice Proves the read-only verify gate reverts with a DISTINCT message on each
///         misconfig and PASSES on a fully-correct config:
///           (a) guardian — "not yet configured" vs mismatch
///           (b) floor      — "not yet configured" vs sub-floor
///           (C1) ownership     — owner still deployer / owner != governance
///           (C2) wiring        — host not wired / host wired-but-not-allowed-source
///         plus the run(chainId) artifact-reading path.
contract VerifyActivationTest is Test {
    // (SP2-G5R2-02 / GATE4-03) A DEDICATED test-only chain id — NOT 31337 — so the
    // run()-path artifact writes land in deployments/31338/ and never clobber a real
    // local anvil deploy's deployments/31337/*.json. fs_permissions grants the whole
    // ./deployments tree, so no foundry.toml change is needed.
    uint256 constant CHAIN_ID = 31338;

    address constant CTRL_OWNER = address(0xC0FFEE); // controller Owner after init
    address constant GUARDIAN = address(0x6DA12D); // shared single guardian
    address constant OTHER_ADMIN = address(0xBAD); // a DIFFERENT guardian -> mis-wired
    address constant QUEUE_OWNER = address(0x0E7E7); // queue Owner after init; != guardian
    address constant GOV_OWNER = address(0x60F); // intended governance Owner (C1)
    address constant DEPLOYER = address(0xDEEDDE); // broadcast EOA (C1: must own neither)
    address constant STRAY_OWNER = address(0x57A11); // not deployer, not governance (C1)
    address constant SOURCE = address(0x50117CE);

    uint32 constant FLOOR = 3600;

    VerifyActivationHarness script;
    MockWRBTC wrbtc;

    // Distinct concrete host addresses for the C1 host-resolution tests.
    address constant SOVRYN_HOST = address(0x50147117);
    address constant ZERO_HOST = address(0x2E70117);
    ExitFeeController controller;
    ExitDelayQueue queue;

    MockProductHost host; // registered allowed-source + wired by default

    function setUp() public {
        script = new VerifyActivationHarness();
        wrbtc = new MockWRBTC();

        // ── Controller owned by CTRL_OWNER (so we later transfer it to GOV_OWNER). ──
        ExitFeeController cImpl = new ExitFeeController();
        bytes memory cInit = abi.encodeWithSelector(ExitFeeController.initialize.selector, CTRL_OWNER);
        controller = ExitFeeController(address(new ERC1967Proxy(address(cImpl), cInit)));

        // ── Queue owned by QUEUE_OWNER; guardian GUARDIAN; the host pre-registered
        //    as an allowed-source so the default (correct) config is C2-clean. ──
        host = new MockProductHost();
        address[] memory sources = new address[](2);
        sources[0] = SOURCE;
        sources[1] = address(host);
        ExitDelayQueue qImpl = new ExitDelayQueue();
        bytes memory qInit = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, QUEUE_OWNER, GUARDIAN, address(wrbtc), FLOOR, sources
        );
        queue = ExitDelayQueue(payable(address(new ERC1967Proxy(address(qImpl), qInit))));

        // Wire the host's queue pointer at THIS queue (C2 default: wired).
        host.setExitDelayQueue(address(queue));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// Run activation steps 4–5 (Owner actions) on the controller.
    function _configController(address admin_, uint32 globalDelay_) internal {
        vm.startPrank(CTRL_OWNER);
        controller.setGlobalDelaySeconds(globalDelay_); // step 4
        controller.setAdmin(admin_); // step 5
        vm.stopPrank();
    }

    /// Hand BOTH contracts to the intended governance Owner (Ownable2Step).
    function _handToGovernance() internal {
        vm.prank(CTRL_OWNER);
        controller.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        controller.acceptOwnership();

        vm.prank(QUEUE_OWNER);
        queue.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        queue.acceptOwnership();
    }

    /// The default single-host intended list.
    function _hosts() internal view returns (address[] memory hs) {
        hs = new address[](1);
        hs[0] = address(host);
    }

    /// Drive the full comprehensive gate with the canonical args (non-deferred: the
    /// default single-host list is non-empty so the C1 empty-list guard is satisfied).
    function _verify() internal view {
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, _hosts(), false);
    }

    /// A fully-correct deploy: config done, ownership handed off, host wired+allowed.
    function _makeFullyCorrect() internal {
        _configController(GUARDIAN, FLOOR);
        _handToGovernance();
    }

    // ─── (a) guardian: distinct "not yet configured" vs mismatch ─────

    function test_verify_reverts_distinctly_when_admin_unconfigured() public {
        _handToGovernance(); // ownership fine; admin still 0
        assertEq(controller.admin(), address(0), "precondition: admin unset");
        vm.expectRevert(bytes("guardian unconfigured: controller.admin()==0 -- run step 5 (setAdmin) first"));
        _verify();
    }

    function test_verify_reverts_on_admin_mismatch() public {
        _configController(OTHER_ADMIN, FLOOR); // configured, admin != queue.admin
        _handToGovernance();
        vm.expectRevert(
            bytes("single guardian violated: controller.admin() != queue.admin() -- single guardian violated")
        );
        _verify();
    }

    // ─── (b) floor: distinct "not yet configured" vs sub-floor ─────────

    function test_verify_reverts_distinctly_when_global_delay_unconfigured() public {
        vm.prank(CTRL_OWNER);
        controller.setAdmin(GUARDIAN); // step 5 only; delay still 0
        _handToGovernance();
        vm.expectRevert(
            bytes(
                "delay unconfigured: controller.globalDelaySeconds()==0 -- run step 4 (setGlobalDelaySeconds) first"
            )
        );
        _verify();
    }

    function test_verify_reverts_distinctly_on_subfloor_global_delay() public {
        _configController(GUARDIAN, FLOOR - 1);
        _handToGovernance();
        vm.expectRevert(
            bytes(
                "sub-floor delay: controller.globalDelaySeconds() < queue.minimumDelaySeconds() -- sub-floor delay self-bricks exits"
            )
        );
        _verify();
    }

    // ─── (C1) ownership: owner still deployer / owner != governance ────────

    /// Queue still owned by the deployer EOA (ownership never handed off): the
    /// still-deployer check fires with the C1 "== deployer" message.
    function test_verify_reverts_when_queue_owner_still_deployer() public {
        _configController(GUARDIAN, FLOOR);
        // Hand ONLY the controller to governance; move the queue to the DEPLOYER
        // (simulating the silent-blank-owner footgun: deployer left in control).
        vm.prank(CTRL_OWNER);
        controller.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        controller.acceptOwnership();

        vm.prank(QUEUE_OWNER);
        queue.transferOwnership(DEPLOYER);
        vm.prank(DEPLOYER);
        queue.acceptOwnership();

        vm.expectRevert(
            bytes("SP2-CTRL-02 (C1): queue.owner() == deployer EOA -- ownership not handed to governance")
        );
        _verify();
    }

    /// Controller still owned by the deployer EOA.
    function test_verify_reverts_when_controller_owner_still_deployer() public {
        _configController(GUARDIAN, FLOOR);
        // Queue -> governance; controller -> deployer.
        vm.prank(QUEUE_OWNER);
        queue.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        queue.acceptOwnership();

        vm.prank(CTRL_OWNER);
        controller.transferOwnership(DEPLOYER);
        vm.prank(DEPLOYER);
        controller.acceptOwnership();

        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1): controller.owner() == deployer EOA -- ownership not handed to governance"
            )
        );
        _verify();
    }

    /// Queue owned by a NON-deployer address that is also not the intended
    /// governance Owner: the "!= governance owner" message fires.
    function test_verify_reverts_when_queue_owner_not_governance() public {
        _configController(GUARDIAN, FLOOR);
        address strayOwner = STRAY_OWNER;
        // controller -> governance (correct)
        vm.prank(CTRL_OWNER);
        controller.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        controller.acceptOwnership();
        // queue -> stray (not deployer, not governance)
        vm.prank(QUEUE_OWNER);
        queue.transferOwnership(strayOwner);
        vm.prank(strayOwner);
        queue.acceptOwnership();

        vm.expectRevert(bytes("SP2-CTRL-02 (C1): queue.owner() != governance owner"));
        _verify();
    }

    function test_verify_reverts_when_controller_owner_not_governance() public {
        _configController(GUARDIAN, FLOOR);
        address strayOwner = STRAY_OWNER;
        // queue -> governance (correct)
        vm.prank(QUEUE_OWNER);
        queue.transferOwnership(GOV_OWNER);
        vm.prank(GOV_OWNER);
        queue.acceptOwnership();
        // controller -> stray
        vm.prank(CTRL_OWNER);
        controller.transferOwnership(strayOwner);
        vm.prank(strayOwner);
        controller.acceptOwnership();

        vm.expectRevert(bytes("SP2-CTRL-02 (C1): controller.owner() != governance owner"));
        _verify();
    }

    /// C1 arg hygiene: a zero governance-owner arg is a config error, not a pass.
    function test_verify_reverts_when_governance_owner_arg_zero() public {
        _makeFullyCorrect();
        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1 unconfigured): governance owner arg == 0 -- set EXIT_DELAY_GOVERNANCE_OWNER"
            )
        );
        script.verify(controller, queue, address(0), DEPLOYER, _hosts(), false);
    }

    function test_verify_reverts_when_deployer_arg_zero() public {
        _makeFullyCorrect();
        vm.expectRevert(bytes("SP2-CTRL-02 (C1 unconfigured): deployer arg == 0 -- set EXIT_DELAY_DEPLOYER"));
        script.verify(controller, queue, GOV_OWNER, address(0), _hosts(), false);
    }

    function test_verify_reverts_when_governance_owner_equals_deployer() public {
        _makeFullyCorrect();
        vm.expectRevert(
            bytes("SP2-CTRL-02 (C1 unconfigured): governance owner == deployer -- they must differ")
        );
        script.verify(controller, queue, GOV_OWNER, GOV_OWNER, _hosts(), false);
    }

    // ─── (C2) wiring: host not wired / host wired-but-not-allowed-source ───

    /// Host's queue pointer points elsewhere (or unset): fail-open zero-delay.
    function test_verify_reverts_when_host_not_wired() public {
        _makeFullyCorrect();
        // Re-point the host at a bogus queue address (unwired w.r.t. THIS queue).
        host.setExitDelayQueue(address(0xDEAD));
        vm.expectRevert(
            bytes(
                string.concat(
                    "SP2-CTRL-02 (C2): host ",
                    vm.toString(address(host)),
                    " not wired -- host.exitDelayQueue() != queue (fail-open zero-delay)"
                )
            )
        );
        _verify();
    }

    /// Host wired at THIS queue but NOT registered as an allowed-source: bricked
    /// fail-closed (its record*() would revert UnregisteredSource).
    function test_verify_reverts_when_host_wired_but_not_allowed_source() public {
        // Deploy a SECOND host that is wired but never registered as a source.
        MockProductHost unregHost = new MockProductHost();
        unregHost.setExitDelayQueue(address(queue));
        _makeFullyCorrect();

        address[] memory hs = new address[](1);
        hs[0] = address(unregHost);

        vm.expectRevert(
            bytes(
                string.concat(
                    "SP2-CTRL-02 (C2): host ",
                    vm.toString(address(unregHost)),
                    " not allowed-source -- queue.isAllowedSource(host)==false (bricked fail-closed)"
                )
            )
        );
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, hs, false);
    }

    /// A zero host slipped into the intended list is rejected (defensive C2).
    function test_verify_reverts_on_zero_host_in_list() public {
        _makeFullyCorrect();
        address[] memory hs = new address[](1);
        hs[0] = address(0);
        vm.expectRevert(bytes("SP2-CTRL-02 (C2): intended host == 0"));
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, hs, false);
    }

    // ─── (C1) host-input safety: required inputs + explicit VERIFY_DEFER_HOSTS ─
    //     (replaces the deleted vacuous-pass test). Drives the
    //     _resolveHosts helper: the require/defer/warning logic that gates whether
    //     an intended-host list may ever be empty. The `run` path's REQUIRED-read
    //     (non-defer branch of _readHostEnv) revert-on-unset rests on forge's
    //     `vm.envAddress` cheatcode contract — it reverts when the var is unset or
    //     mistyped — so it is NOT re-asserted through an env-driven test here (see the
    //     NOTE below for why env-driven revert assertions are deliberately omitted:
    //     the process-global env race between parallel test functions/suites).

    /// deferHosts=false + both hosts non-zero: BOTH are C2-checked (list length 2).
    function test_resolveHosts_both_present_no_defer() public view {
        address[] memory hs = script.resolveHosts(false, SOVRYN_HOST, ZERO_HOST);
        assertEq(hs.length, 2, "both hosts must be in the C2-checked list");
        assertEq(hs[0], SOVRYN_HOST, "sovryn host first");
        assertEq(hs[1], ZERO_HOST, "zero host second");
    }

    /// deferHosts=false + a zero sovryn host: HARD REVERT (no silent empty list /
    /// vacuous PASS — a surface would ship unwired at zero-delay, fail-open).
    function test_resolveHosts_reverts_on_zero_sovryn_without_defer() public {
        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1): intended host sovrynProtocol (SOVRYN_PROTOCOL_HOST) == 0 -- set it, or set VERIFY_DEFER_HOSTS=true to defer explicitly"
            )
        );
        script.resolveHosts(false, address(0), ZERO_HOST);
    }

    /// deferHosts=false + a zero Zero host: HARD REVERT (same rule, other surface).
    function test_resolveHosts_reverts_on_zero_zerohost_without_defer() public {
        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1): intended host Zero BorrowerOperations (ZERO_BORROWER_OPERATIONS_HOST) == 0 -- set it, or set VERIFY_DEFER_HOSTS=true to defer explicitly"
            )
        );
        script.resolveHosts(false, SOVRYN_HOST, address(0));
    }

    /// deferHosts=false + BOTH hosts zero (fresh-shell / all-typo'd): HARD REVERT
    /// (the sovryn host is checked first). This is the exact vacuous-pass hole the
    /// C1 fix closes — an empty list can NEVER be produced without an explicit opt-in.
    function test_resolveHosts_reverts_on_both_zero_without_defer() public {
        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1): intended host sovrynProtocol (SOVRYN_PROTOCOL_HOST) == 0 -- set it, or set VERIFY_DEFER_HOSTS=true to defer explicitly"
            )
        );
        script.resolveHosts(false, address(0), address(0));
    }

    /// deferHosts=true + one host deferred (zero): the present host is checked, the
    /// zero host is dropped WITH a loud warning (printed by _includeHost). No revert.
    function test_resolveHosts_defers_zero_host_with_warning() public view {
        address[] memory hs = script.resolveHosts(true, SOVRYN_HOST, address(0));
        assertEq(hs.length, 1, "only the wired host is C2-checked");
        assertEq(hs[0], SOVRYN_HOST, "the present host is retained");
    }

    /// deferHosts=true + BOTH hosts deferred (zero): allowed ONLY because deferral
    /// is EXPLICIT — an empty list is produced but with loud per-host warnings.
    function test_resolveHosts_defers_both_hosts_with_defer_optin() public view {
        address[] memory hs = script.resolveHosts(true, address(0), address(0));
        assertEq(hs.length, 0, "both hosts explicitly deferred");
    }

    /// deferHosts=true but BOTH hosts present: defer opt-in does NOT drop a wired
    /// host — both are still C2-checked (opt-in only excuses a ZERO host).
    function test_resolveHosts_defer_true_but_both_present_still_checks_both() public view {
        address[] memory hs = script.resolveHosts(true, SOVRYN_HOST, ZERO_HOST);
        assertEq(hs.length, 2, "present hosts are always checked, defer or not");
    }

    /// (SP2-G5R2-01 / GATE4-02) A NON-ZERO duplicate host pair (both spec-named vars
    /// pointing at the SAME address) HARD REVERTS — one surface would be C2-checked
    /// twice while the OTHER ships silently unchecked/unwired. Applies regardless of
    /// deferHosts (the check runs BEFORE the include/defer logic).
    function test_resolveHosts_reverts_on_duplicate_nonzero_hosts() public {
        vm.expectRevert(
            bytes("SP2-CTRL-02 (C1): SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)")
        );
        script.resolveHosts(false, SOVRYN_HOST, SOVRYN_HOST);
    }

    ///  The duplicate check fires even under deferHosts=true when the
    /// pair is a genuine NON-ZERO duplicate — deferral excuses a ZERO host, never a
    /// copy-paste of the same real address into both slots.
    function test_resolveHosts_reverts_on_duplicate_nonzero_hosts_even_when_deferred() public {
        vm.expectRevert(
            bytes("SP2-CTRL-02 (C1): SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)")
        );
        script.resolveHosts(true, ZERO_HOST, ZERO_HOST);
    }

    /// (SP2-G5R2-01 regression) The both-ZERO pair under deferHosts=true is NOT a
    /// duplicate — it is the explicit both-host deferral and must still yield an empty
    /// list (proves the `|| == address(0)` clause preserves the defer-both path).
    function test_resolveHosts_both_zero_not_treated_as_duplicate_when_deferred() public view {
        address[] memory hs = script.resolveHosts(true, address(0), address(0));
        assertEq(hs.length, 0, "both-zero defer is not a duplicate; empty list allowed");
    }

    // ─── (C1) verify() refuses a vacuous PASS on an EMPTY host list ─────────
    //     The dry-run entrypoint must NOT silently certify go-live when the C2 wiring
    //     loop asserts nothing (empty list). An empty list is allowed ONLY when the
    //     caller EXPLICITLY asserts deferral (deferHosts==true) — the legitimate
    //     defer-both run() path.

    /// verify(..., empty list, deferHosts=false): HARD REVERT — an empty intended-
    /// host list without an explicit defer opt-in is the exact fail-open vacuous PASS
    /// the C1 decision mandates removing.
    function test_verify_reverts_on_empty_host_list_without_defer() public {
        _makeFullyCorrect();
        address[] memory empty = new address[](0);
        vm.expectRevert(
            bytes(
                "SP2-CTRL-02 (C1): empty intended-host list without VERIFY_DEFER_HOSTS=true -- refusing vacuous wiring PASS"
            )
        );
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, empty, false);
    }

    /// verify(..., empty list, deferHosts=true): PASSES — the legitimate qualified /
    /// deferred path (both hosts explicitly deferred to a later SIP). The other four
    /// sub-checks (guardian/floor/ownership) still run and hold.
    function test_verify_passes_on_empty_host_list_with_explicit_defer() public {
        _makeFullyCorrect();
        address[] memory empty = new address[](0);
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, empty, true); // does not revert
    }

    /// (C1 regression) A NON-empty list with deferHosts=false still passes the empty-
    /// list guard and proceeds to the sub-checks (guards against an over-broad guard).
    function test_verify_nonempty_list_no_defer_passes_guard() public {
        _makeFullyCorrect();
        _verify(); // non-empty _hosts(), deferHosts=false — passes
    }

    // ─── (G5R2-02) _reportPass banner — BOTH legs, deterministically ────────
    //     Driven through the harness (no env→run), so the qualified/downgraded banner
    //     branch (previously never executed) is exercised race-free.

    /// anyHostDeferred=false ⇒ the UNQUALIFIED "safe to run step 8" banner leg runs.
    function test_reportPass_unqualified_when_no_host_deferred() public view {
        script.reportPass(false); // view, no revert — exercises the unqualified leg
    }

    /// anyHostDeferred=true ⇒ the QUALIFIED / warned downgrade banner leg runs (the
    /// branch a real deferral takes; keyed off the resolved fact, not the raw flag).
    function test_reportPass_qualified_when_a_host_deferred() public view {
        script.reportPass(true); // view, no revert — exercises the downgrade leg
    }

    // ─── (coverage 114-116) _readHostEnv deferHosts==true (envOr fallback) leg ──
    //     NOT driven here. `_readHostEnv` reads the SHARED host env keys
    //     (SOVRYN_PROTOCOL_HOST / ZERO_BORROWER_OPERATIONS_HOST); ANY test that
    //     touches them via `vm.setEnv` races the single clean-pass env→run() test
    //     (forge does not isolate process-global env between the concurrently-
    //     scheduled functions of one contract — empirically: an empty-string set here
    //     leaked into that test's `vm.envAddress` and broke its address parse). The
    //     defer leg is a one-line `vm.envOr(key, address(0))` whose "return the
    //     default on unset" behavior is a forge-cheatcode guarantee (same rationale as
    //     the REQUIRED-read revert leg, deliberately not env-tested). The DEFER
    //     SEMANTICS it feeds — a zero host dropped-with-warning vs a hard revert — are
    //     pinned deterministically on in-memory addresses by the test_resolveHosts_*
    //     suite.

    // ─── (d) PASSES on a fully-correct config ──────────────────────────────

    function test_verify_passes_when_fully_correct_at_floor() public {
        _makeFullyCorrect();
        _verify(); // does not revert
    }

    function test_verify_passes_when_delay_above_floor() public {
        _configController(GUARDIAN, FLOOR * 2);
        _handToGovernance();
        _verify();
    }

    // ─── (C2) floor MAY be 0; the `> 0` guard is on the ACTIVE delay ──

    /// @dev Redeploy the queue with a ZERO minimumDelaySeconds floor, re-wiring the
    ///      host + re-registering sources, so the C2 "floor MAY be 0" cases run
    ///      against a real zero-floor queue.
    function _redeployQueueWithZeroFloor() internal {
        host = new MockProductHost();
        address[] memory sources = new address[](2);
        sources[0] = SOURCE;
        sources[1] = address(host);
        ExitDelayQueue qImpl = new ExitDelayQueue();
        bytes memory qInit = abi.encodeWithSelector(
            ExitDelayQueue.initialize.selector, QUEUE_OWNER, GUARDIAN, address(wrbtc), uint32(0), sources
        );
        queue = ExitDelayQueue(payable(address(new ERC1967Proxy(address(qImpl), qInit))));
        host.setExitDelayQueue(address(queue));
    }

    /// A zero `minimumDelaySeconds` FLOOR is NOT a go-live blocker: with a positive
    /// globalDelaySeconds the gate PASSES (the per-request DelayBelowFloor backstop
    /// is simply inactive — Owner-remediable, not a blocker).
    function test_verify_passes_when_floor_is_zero_and_delay_positive() public {
        _redeployQueueWithZeroFloor();
        assertEq(queue.minimumDelaySeconds(), 0, "precondition: zero floor");
        _configController(GUARDIAN, 1); // smallest positive active delay
        _handToGovernance();
        _verify(); // does not revert — floor==0 is allowed, delay>0 satisfies C2
    }

    /// Even with a zero FLOOR, a zero ACTIVE globalDelaySeconds is REJECTED — a zero
    /// global delay leaves the perimeter inert (C2 `> 0` applies to the active delay).
    function test_verify_reverts_when_global_delay_zero_even_with_zero_floor() public {
        _redeployQueueWithZeroFloor();
        vm.prank(CTRL_OWNER);
        controller.setAdmin(GUARDIAN); // guardian ok; globalDelaySeconds stays 0
        _handToGovernance();
        vm.expectRevert(
            bytes(
                "delay unconfigured: controller.globalDelaySeconds()==0 -- run step 4 (setGlobalDelaySeconds) first"
            )
        );
        _verify();
    }

    /// Multiple intended hosts, all wired + allowed: passes.
    function test_verify_passes_with_multiple_hosts() public {
        MockProductHost host2 = new MockProductHost();
        host2.setExitDelayQueue(address(queue));
        vm.prank(QUEUE_OWNER);
        queue.addAllowedSource(address(host2));

        _makeFullyCorrect();

        address[] memory hs = new address[](2);
        hs[0] = address(host);
        hs[1] = address(host2);
        script.verify(controller, queue, GOV_OWNER, DEPLOYER, hs, false);
    }

    // ─── Ordering: guardian < floor < ownership < wiring (first unmet wins) ─

    /// Nothing configured: (guardian) is the FIRST unmet invariant, so its
    /// message fires ahead of the floor/ownership/wiring messages.
    function test_verify_guardian_reported_first() public {
        // admin==0, delay==0, ownership not handed, host fine.
        vm.expectRevert(bytes("guardian unconfigured: controller.admin()==0 -- run step 5 (setAdmin) first"));
        _verify();
    }

    // ─── run(chainId) artifact + env path ──────────────────────────────────

    /// @dev Write the deployment artifacts + the always-required (non-host) env vars
    ///      for the `run` path. Returns nothing; caller sets the host env vars per
    ///      the scenario under test.
    function _writeRunArtifactsAndOwners() internal {
        string memory dir = string.concat("deployments/", vm.toString(CHAIN_ID), "/");
        // (SP2-G5R2-02 / GATE4-03) Create the artifact dir first — on a FRESH clone
        // deployments/31338/ does not exist and vm.writeFile would fail. `true` =
        // recursive / no-error-if-exists.
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "ExitFeeController.json"),
            string.concat('{"proxyAddress":"', vm.toString(address(controller)), '"}')
        );
        vm.writeFile(
            string.concat(dir, "ExitDelayQueue.json"),
            string.concat('{"proxyAddress":"', vm.toString(address(queue)), '"}')
        );
        vm.setEnv("EXIT_DELAY_GOVERNANCE_OWNER", vm.toString(GOV_OWNER));
        vm.setEnv("EXIT_DELAY_DEPLOYER", vm.toString(DEPLOYER));
    }

    /// Deploy + register + wire a SECOND host so BOTH spec-named env hosts can point
    /// at real wired allowed-sources for the clean-pass run path.
    function _makeSecondWiredHost() internal returns (MockProductHost h2) {
        h2 = new MockProductHost();
        h2.setExitDelayQueue(address(queue));
        vm.prank(QUEUE_OWNER);
        queue.addAllowedSource(address(h2));
    }

    /// Clean go-live: BOTH hosts set, wired + allowed, no defer. run() passes and
    /// emits the UNQUALIFIED banner.
    function test_run_passes_cleanly_when_both_hosts_wired() public {
        MockProductHost host2 = _makeSecondWiredHost();
        _makeFullyCorrect();
        _writeRunArtifactsAndOwners();

        vm.setEnv("SOVRYN_PROTOCOL_HOST", vm.toString(address(host)));
        vm.setEnv("ZERO_BORROWER_OPERATIONS_HOST", vm.toString(address(host2)));
        vm.setEnv("VERIFY_DEFER_HOSTS", "false");

        script.run(CHAIN_ID); // does not revert; unqualified PASS banner
    }

    // NOTE — why only ONE env→run() test, and how the defer/banner branches are
    // covered instead:
    //
    // `vm.setEnv` mutates PROCESS-global env that forge does NOT isolate between the
    // (concurrently-scheduled) test functions of one contract. A SECOND env→run()
    // test that set the host keys to DIFFERENT values than this one would race: its
    // `vm.setEnv("ZERO_BORROWER_OPERATIONS_HOST", …)` can land between this test's set
    // and `run()`'s read (empirically reproduced — a leaked non-defer host makes the
    // C2 wiring check revert on a host this test never wired). So exactly ONE env→run
    // test lives here (the clean unqualified-PASS path above), pinning the artifact +
    // env + banner wiring end to end.
    //
    // The remaining C1/G5R2-02 branches are pinned DETERMINISTICALLY on in-memory
    // addresses via the harness (NO env, race-free):
    //   • the REQUIRED-read revert-on-unset (non-defer leg of _readHostEnv) rests on
    //     forge's `vm.envAddress` cheatcode contract (reverts on unset/typo);
    //   • the defer leg of _readHostEnv (returns zero when VERIFY_DEFER_HOSTS=true)
    //     is covered via the test_resolveHosts_defers_* cases below;
    //   • the require / defer-warning / duplicate-host branches of _resolveHosts →
    //     the test_resolveHosts_* suite;
    //   • the empty-list vacuous-PASS refusal + defer-both pass → the
    //     test_verify_*_empty_host_list_* tests;
    //   • BOTH banner legs (unqualified + the G5R2-02 qualified/warned DOWNGRADE) →
    //     test_reportPass_unqualified_* / test_reportPass_qualified_* (which drive the
    //     exact `_reportPass(anyHostDeferred)` the run() path calls, keyed off the
    //     resolved fact `hosts.length < 2` that the run() body computes).

    // ─── Property: gate passes IFF ALL invariants hold; each specific unmet
    //     invariant maps to its specific revert reason, checked in gate order. ───

    function testFuzz_verify_gate_and_reason(uint32 globalDelay, bool sameAdmin) public {
        address ctrlAdmin = sameAdmin ? GUARDIAN : OTHER_ADMIN;
        _configController(ctrlAdmin, globalDelay);
        _handToGovernance(); // ownership + wiring always correct here

        // Guardian is checked first, then floor. Ownership/wiring are correct, so
        // the outcome is fully determined by (sameAdmin, globalDelay).
        if (!sameAdmin) {
            vm.expectRevert(
                bytes(
                    "single guardian violated: controller.admin() != queue.admin() -- single guardian violated"
                )
            );
            _verify();
        } else if (globalDelay == 0) {
            vm.expectRevert(
                bytes(
                    "delay unconfigured: controller.globalDelaySeconds()==0 -- run step 4 (setGlobalDelaySeconds) first"
                )
            );
            _verify();
        } else if (globalDelay < FLOOR) {
            vm.expectRevert(
                bytes(
                    "sub-floor delay: controller.globalDelaySeconds() < queue.minimumDelaySeconds() -- sub-floor delay self-bricks exits"
                )
            );
            _verify();
        } else {
            _verify(); // passes
        }
    }
}
