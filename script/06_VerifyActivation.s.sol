// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";
import {ExitDelayQueue} from "../src/ExitDelayQueue.sol";
import {IExitDelayQueueHost} from "../src/interfaces/IExitDelayQueueHost.sol";

/// @title  Verify Activation — activation step-7 go-live gate (C1/C2)
/// @notice READ-ONLY. Run LAST, AFTER the Owner has configured the controller's
///         `admin` + `globalDelaySeconds` (activation steps 4–5), the guardian on both
///         contracts (step 5), the allowed-sources + host wiring (steps 1–2), and
///         BEFORE `setSecurityPerimeterEnabled(true)` (step 8): a fat-fingered
///         security-contract deploy must fail LOUD here rather than silently ship
///         fail-open (unwired host = zero-delay direct-pay) or fail-closed
///         (mis-owned / wired-but-not-allowed = bricked).
///
///         SCOPE (honest): this gate verifies the two
///         STORAGE HOSTS are wired + allowed-source, plus guardian/floor/ownership.
///         It does NOT enumerate the actual record CALLERS (iToken proxies for
///         lender burn/burnToBTC; the ActivePool native pusher) — those live in the
///         separate step-2 source SIP (QUEUE_ALLOWED_SOURCES + setNativePusher) and
///         are confirmed there. A missing record-caller source is fail-CLOSED
///         (records revert UnregisteredSource, Owner-remediable via addAllowedSource),
///         so it is out of this gate's scope by design, not an unguarded fail-open.
///
///         Asserts, each with a DISTINCT revert message:
///            controller.admin() == queue.admin(), both non-zero  -- guardian
///              controller.globalDelaySeconds() > 0 AND
///                       >= queue.minimumDelaySeconds()                   -- delay floor
///                   (C2: the `> 0` gates the ACTIVE global delay — a
///                    zero global delay leaves the perimeter inert. The queue's
///                    `minimumDelaySeconds` FLOOR itself MAY be 0; that only leaves
///                    the per-request DelayBelowFloor backstop inactive — Owner-
///                    remediable, NOT a go-live blocker.)
///           (C1)    queue.owner()      == governanceOwner != deployer
///                   controller.owner() == governanceOwner != deployer   -- ownership
///           (C2)    for each intended host:
///                     host.exitDelayQueue() == queue                    -- wired
///                     queue.isAllowedSource(host)                       -- allowed-source
///
///         C1 host-input safety: both spec-named product hosts are
///         REQUIRED inputs read via `vm.envAddress` (which REVERTS on an unset or
///         typo'd var) — a fresh-shell / mistyped run must NOT silently yield an
///         empty intended-host list and vacuously "PASS" while a surface ships
///         unwired at zero-delay (fail-open). Skipping a host is allowed ONLY via an
///         EXPLICIT, LOUD `VERIFY_DEFER_HOSTS=true` opt-in; each deferred host prints
///         a warning line and the success banner is downgraded to the qualified
///         (warned) variant. The unqualified "safe to run step 8" banner is emitted
///         ONLY when BOTH spec-named hosts were actually checked.
///
///         The assertions live HERE — NOT inside `05_DeployQueueAndWire`'s broadcast
///         (step 1, BEFORE config) — so the documented activation order does not
///         self-abort (the SP2-CTRL-02-ordering fix).
///
///         Read-only: no `vm.startBroadcast()`, no state change. verify() does NOT
///         mutate (roles-not-actors: setAdmin/setGlobalDelaySeconds stay Owner
///         actions run at steps 4–5, not here).
///
/// @dev Usage:
///
///   export EXIT_DELAY_GOVERNANCE_OWNER=0x...        # intended Owner (governance Safe/timelock)
///   export EXIT_DELAY_DEPLOYER=0x...                # the broadcast EOA that ran the deploy
///   export SOVRYN_PROTOCOL_HOST=0x...               # intended host (REQUIRED unless VERIFY_DEFER_HOSTS=true)
///   export ZERO_BORROWER_OPERATIONS_HOST=0x...      # intended host (REQUIRED unless VERIFY_DEFER_HOSTS=true)
///   # export VERIFY_DEFER_HOSTS=true                # ONLY to intentionally defer a host's wiring to a later SIP
///
///   forge script script/06_VerifyActivation.s.sol \
///       --rpc-url $RSK_RPC --sig "run(uint256)" <chainId>
///
///   Reads BOTH `deployments/<chainId>/ExitFeeController.json` and
///   `deployments/<chainId>/ExitDelayQueue.json` for the two proxy addresses, and
///   the intended-host list from the same env vars the deploy script wires from.
contract VerifyActivation is Script {
    using stdJson for string;

    /// @param chainId  the target chain (selects the deployments artifact dir)
    function run(uint256 chainId) external view {
        (ExitFeeController controller, ExitDelayQueue queue) = _loadProxies(chainId);

        // ── Intended governance Owner + deployer EOA (C1). Both REQUIRED non-zero
        //    so a blank never trivially satisfies "owner == governanceOwner" or the
        //    "owner != deployer" check. ──
        address governanceOwner = vm.envAddress("EXIT_DELAY_GOVERNANCE_OWNER");
        address deployer = vm.envAddress("EXIT_DELAY_DEPLOYER");

        // ── Intended product hosts (C1 host-input safety). BOTH spec-
        //    named hosts are REQUIRED via vm.envAddress (reverts on unset/typo) so a
        //    fresh-shell run can NEVER produce an empty list that vacuously PASSes
        //    while a surface ships unwired (fail-open zero-delay). A host may be
        //    skipped ONLY via an EXPLICIT `VERIFY_DEFER_HOSTS=true`. ──
        bool deferHosts = vm.envOr("VERIFY_DEFER_HOSTS", false);
        (address sovrynHost, address zeroHost) = _readHostEnv(deferHosts);
        address[] memory hosts = _resolveHosts(deferHosts, sovrynHost, zeroHost);

        console2.log("ExitFeeController @", address(controller));
        console2.log("ExitDelayQueue    @", address(queue));
        console2.log("governance owner  @", governanceOwner);
        console2.log("deployer EOA      @", deployer);
        console2.log("intended hosts    :", hosts.length);
        console2.log("");

        verify(controller, queue, governanceOwner, deployer, hosts, deferHosts);

        // (G5R2-02) The banner is keyed off the RESOLVED FACT — whether BOTH
        // spec-named hosts were actually C2-checked — NOT the raw VERIFY_DEFER_HOSTS
        // flag: with defer=true but both hosts present, all surfaces ARE certified
        // and the unqualified banner is correct; the qualified/warned banner is for
        // an ACTUAL deferral (a spec-named host dropped from the checked list).
        bool anyHostDeferred = hosts.length < _EXPECTED_HOST_COUNT;
        _reportPass(anyHostDeferred);
    }

    /// @dev The number of spec-named product hosts (activation step-7 scope: the
    ///      `sovrynProtocol` singleton + the Zero `BorrowerOperations` proxy). A
    ///      resolved list shorter than this means at least one host was deferred.
    uint256 private constant _EXPECTED_HOST_COUNT = 2;

    /// @dev Read the two spec-named host env vars. When NOT deferring, use
    ///      `vm.envAddress` (REQUIRED — reverts LOUD on an unset or typo'd var,
    ///      exactly like 05_DeployQueueAndWire's non-zero rule) so a fresh-shell or
    ///      mistyped run cannot silently yield an empty intended-host list and
    ///      vacuously "PASS". When deferring, fall back to `vm.envOr(..., 0)` so an
    ///      operator can leave a host unset ON PURPOSE.
    function _readHostEnv(bool deferHosts) internal view returns (address sovrynHost, address zeroHost) {
        if (deferHosts) {
            sovrynHost = vm.envOr("SOVRYN_PROTOCOL_HOST", address(0));
            zeroHost = vm.envOr("ZERO_BORROWER_OPERATIONS_HOST", address(0));
        } else {
            // REQUIRED: reverts on unset/typo — no silent empty list.
            sovrynHost = vm.envAddress("SOVRYN_PROTOCOL_HOST");
            zeroHost = vm.envAddress("ZERO_BORROWER_OPERATIONS_HOST");
        }
    }

    /// @dev Read the controller + queue proxy addresses from the deployment
    ///      artifacts. Split out of `run` to keep its live-local count low
    ///      (avoids a stack-too-deep on the non-viaIR Paris build).
    function _loadProxies(uint256 chainId)
        internal
        view
        returns (ExitFeeController controller, ExitDelayQueue queue)
    {
        string memory dir = string.concat("deployments/", vm.toString(chainId), "/");
        controller = ExitFeeController(
            vm.readFile(string.concat(dir, "ExitFeeController.json")).readAddress(".proxyAddress")
        );
        queue = ExitDelayQueue(
            payable(vm.readFile(string.concat(dir, "ExitDelayQueue.json")).readAddress(".proxyAddress"))
        );
    }

    /// @notice Build the intended-host list from the two spec-named hosts, enforcing
    ///         the C1 host-input safety rule and emitting a LOUD per-host warning for
    ///         each explicitly-deferred (zero) host. Public + pure-of-env so a unit
    ///         test drives every branch on in-memory addresses WITHOUT `vm.setEnv`
    ///         (which mutates process-global env forge does not isolate between
    ///         parallel test functions — a genuine race).
    ///
    ///         Contract:
    ///           - deferHosts == false: BOTH hosts MUST be non-zero (the caller's
    ///             `vm.envAddress` already reverts on unset; this is the belt-and-
    ///             suspenders check for a caller-supplied zero). A zero host here is
    ///             a hard REVERT — a surface would ship unwired at zero-delay.
    ///           - deferHosts == true: a zero host is an INTENTIONAL deferral; it is
    ///             dropped from the list and a LOUD warning is printed naming the
    ///             surface whose delay is NOT yet active.
    ///
    /// @param deferHosts   the explicit VERIFY_DEFER_HOSTS opt-in
    /// @param sovrynHost   SOVRYN_PROTOCOL_HOST (lending + loan/margin surfaces)
    /// @param zeroHost     ZERO_BORROWER_OPERATIONS_HOST (Zero surface)
    /// @return hosts       the tightly-sized list of hosts that WILL be C2-checked
    function _resolveHosts(bool deferHosts, address sovrynHost, address zeroHost)
        internal
        view
        returns (address[] memory hosts)
    {
        // (GATE4-02 / SP2-G5R2-01) A non-zero duplicate pair (both spec-named vars
        // pointing at the SAME host — a copy-paste footgun) would C2-check one
        // surface twice and leave the OTHER silently unchecked/unwired. Reject it.
        // The `== address(0)` clause preserves the both-zero EXPLICIT-defer path
        // (deferHosts==true, both hosts intentionally unset): that is not a dup.
        require(
            sovrynHost != zeroHost || sovrynHost == address(0),
            "SP2-CTRL-02 (C1): SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)"
        );

        bool sovrynIn = _includeHost(deferHosts, sovrynHost, "sovrynProtocol (SOVRYN_PROTOCOL_HOST)");
        bool zeroIn =
            _includeHost(deferHosts, zeroHost, "Zero BorrowerOperations (ZERO_BORROWER_OPERATIONS_HOST)");

        uint256 n;
        if (sovrynIn) n++;
        if (zeroIn) n++;

        hosts = new address[](n);
        uint256 i;
        if (sovrynIn) hosts[i++] = sovrynHost;
        if (zeroIn) hosts[i++] = zeroHost;
    }

    /// @dev Decide whether one spec-named host is included in the C2-checked list.
    ///      A non-zero host is always included. A zero host is a hard REVERT unless
    ///      deferral is EXPLICIT (VERIFY_DEFER_HOSTS=true), in which case it is
    ///      dropped with a LOUD warning naming the un-delayed surface.
    function _includeHost(bool deferHosts, address host, string memory label)
        internal
        view
        returns (bool included)
    {
        if (host != address(0)) return true;
        // host == 0
        require(
            deferHosts,
            string.concat(
                "SP2-CTRL-02 (C1): intended host ",
                label,
                " == 0 -- set it, or set VERIFY_DEFER_HOSTS=true to defer explicitly"
            )
        );
        console2.log(unicode"⚠ perimeter enabling with host UNWIRED -- that surface has NO delay:");
        console2.log(string.concat(unicode"    ", label));
        return false;
    }

    /// @dev Emit the go-live success banner. The UNQUALIFIED "safe to run step 8"
    ///      banner is emitted ONLY when BOTH spec-named hosts were actually checked
    ///      (`anyHostDeferred == false`). When at least one spec-named host was
    ///      ACTUALLY dropped from the checked list (a real deferral) the banner is
    ///      DOWNGRADED to the qualified/warned variant so a deferred surface is never
    ///      implicitly certified. (G5R2-02: keyed off the resolved fact, NOT the raw
    ///      VERIFY_DEFER_HOSTS flag — defer=true with both hosts present certifies
    ///      everything and earns the unqualified banner.)
    /// @param anyHostDeferred  true iff fewer than the two spec-named hosts were
    ///                         actually C2-checked (a real deferral happened)
    function _reportPass(bool anyHostDeferred) internal view {
        if (anyHostDeferred) {
            console2.log(unicode"OK (QUALIFIED): activation step-7 gate PASSED for the CHECKED hosts.");
            console2.log(unicode"  guardian + delay floor + ownership + wiring for wired hosts.");
            console2.log(
                unicode"⚠ VERIFY_DEFER_HOSTS=true -- one or more surfaces are UNWIRED (see warnings above)."
            );
            console2.log(
                unicode"  Do NOT treat this as a full go-live: each deferred host has NO delay until wired + re-verified."
            );
        } else {
            console2.log(
                unicode"OK: activation step-7 gate PASSED for: guardian + delay floor + ownership + host wiring."
            );
            console2.log(
                unicode"NOTE (scope): this gate verifies the two STORAGE HOSTS are wired + allowed-source. It does"
            );
            console2.log(
                unicode"  NOT enumerate the actual record CALLERS (iToken proxies for lender burn/burnToBTC; ActivePool"
            );
            console2.log(
                unicode"  native pusher) — those are registered/verified by the step-2 source SIP (QUEUE_ALLOWED_SOURCES"
            );
            console2.log(
                unicode"  + setNativePusher). A missing one is fail-CLOSED (records revert UnregisteredSource, Owner-remediable)."
            );
            console2.log(
                unicode"Safe to run step 8 (setSecurityPerimeterEnabled(true)) ONCE the step-2 source set is confirmed."
            );
        }
    }

    /// @notice The step-7 COMPREHENSIVE go-live gate as a public read-only entry, so
    ///         a unit test — and an operator running a dry-run against live proxies —
    ///         can drive the EXACT assertions the `run` path runs. Reverts on any
    ///         unmet invariant with a DISTINCT message; returns silently when the
    ///         whole deploy is correctly configured. Read-only (`view`), never
    ///         mutates (setAdmin/setGlobalDelaySeconds are Owner steps 4–5, not this).
    ///
    ///         Revert taxonomy (distinct messages; "not yet configured" variants
    ///         first within each check so an early run points the operator back at
    ///         the missing step rather than at a false mis-config):
    ///           - admin unset            -> "...(unconfigured): controller.admin==0..."
    ///           - admin mismatch         -> "...: controller.admin() != queue.admin()..."
    ///           - globalDelaySeconds==0  -> "...(unconfigured): controller.globalDelaySeconds==0..."
    ///           - sub-floor delay        -> "...: controller.globalDelaySeconds() < ...floor..."
    ///           - owner still deployer   -> "...(C1): queue/controller.owner() == deployer..."
    ///           - owner != governance    -> "...(C1): queue/controller.owner() != governance owner..."
    ///           - host not wired         -> "...(C2): host <addr> not wired..."
    ///           - host not allowed-src   -> "...(C2): host <addr> not allowed-source..."
    ///
    /// @param controller       the deployed ExitFeeController proxy
    /// @param queue            the deployed ExitDelayQueue proxy
    /// @param governanceOwner  the intended governance Owner (must own BOTH; != deployer)
    /// @param deployer         the broadcast EOA that ran the deploy (must own NEITHER)
    /// @param hosts            the intended product hosts (each must be wired + allowed-source)
    /// @param deferHosts       the explicit VERIFY_DEFER_HOSTS opt-in. An EMPTY host
    ///                         list is a vacuous wiring PASS (fail-open: a surface
    ///                         could ship unwired at zero-delay while this gate
    ///                         certifies "safe to run step 8"). The dry-run entry
    ///                         REFUSES an empty list unless the caller EXPLICITLY
    ///                         asserts deferral via `deferHosts == true` (C1,
    ///                         "refuse vacuous PASS"). The
    ///                         legitimate defer-both `run()` path still passes.
    function verify(
        ExitFeeController controller,
        ExitDelayQueue queue,
        address governanceOwner,
        address deployer,
        address[] memory hosts,
        bool deferHosts
    ) public view {
        // (C1) Refuse a vacuous wiring PASS: an empty intended-host list means the
        // C2 wiring loop asserts NOTHING, so the gate would certify go-live while a
        // surface ships unwired (fail-open zero-delay). Only an EXPLICIT deferral
        // opt-in may legitimately produce an empty list.
        require(
            hosts.length != 0 || deferHosts,
            "SP2-CTRL-02 (C1): empty intended-host list without VERIFY_DEFER_HOSTS=true -- refusing vacuous wiring PASS"
        );
        _verifyGuardian(controller, queue); //
        _verifyFloor(controller, queue);
        //
        _verifyOwnership(controller, queue, governanceOwner, deployer);
        // C1
        _verifyWiring(queue, hosts); // C2
    }

    // ── single guardian. "not yet configured" (admin==0) is distinct from a
    //    genuine guardian mismatch. ──
    function _verifyGuardian(ExitFeeController controller, ExitDelayQueue queue) internal view {
        address ctrlAdmin = controller.admin();
        address queueAdmin = queue.admin();
        require(
            ctrlAdmin != address(0),
            "guardian unconfigured: controller.admin()==0 -- run step 5 (setAdmin) first"
        );
        require(
            ctrlAdmin == queueAdmin,
            "single guardian violated: controller.admin() != queue.admin() -- single guardian violated"
        );
    }

    // ── delay-floor liveness. globalDelaySeconds==0 (step 4 not run) is
    //    distinct from a configured-but-sub-floor delay. The queue's own per-request
    //    `require(d >= minimumDelaySeconds)` is the SAFETY enforcement; this is the
    //    LIVENESS check that a legit global delay does not sit below the floor and
    //    self-brick every non-bypassed exit.
    //
    //    C2: the `> 0` guard is on the ACTIVE globalDelaySeconds — a
    //    zero global delay = inert perimeter, rejected here at go-live. The queue's
    //    `minimumDelaySeconds` FLOOR itself MAY be 0 (the per-request DelayBelowFloor
    //    backstop is then inactive, Owner-remediable, NOT a go-live blocker) — so
    //    there is deliberately NO `minimumDelaySeconds != 0` assertion. ──
    function _verifyFloor(ExitFeeController controller, ExitDelayQueue queue) internal view {
        uint256 globalDelay = uint256(controller.globalDelaySeconds());
        uint256 floor = uint256(queue.minimumDelaySeconds());
        require(
            globalDelay != 0,
            "delay unconfigured: controller.globalDelaySeconds()==0 -- run step 4 (setGlobalDelaySeconds) first"
        );
        require(
            globalDelay >= floor,
            "sub-floor delay: controller.globalDelaySeconds() < queue.minimumDelaySeconds() -- sub-floor delay self-bricks exits"
        );
    }

    // ── C1: ownership. BOTH the queue and the controller must be owned by the
    //    intended governance Owner and NOT by the deployer EOA — a blank/zero owner
    //    that silently left the deployer in control (ExitDelayQueue.initialize
    //    resolves a zero owner_ to msg.sender) MUST NOT pass go-live. The
    //    "owner == deployer" check is reported BEFORE the "== governanceOwner"
    //    check so the still-deployer case gets the most actionable message. ──
    function _verifyOwnership(
        ExitFeeController controller,
        ExitDelayQueue queue,
        address governanceOwner,
        address deployer
    ) internal view {
        require(
            governanceOwner != address(0),
            "SP2-CTRL-02 (C1 unconfigured): governance owner arg == 0 -- set EXIT_DELAY_GOVERNANCE_OWNER"
        );
        require(
            deployer != address(0),
            "SP2-CTRL-02 (C1 unconfigured): deployer arg == 0 -- set EXIT_DELAY_DEPLOYER"
        );
        require(
            governanceOwner != deployer,
            "SP2-CTRL-02 (C1 unconfigured): governance owner == deployer -- they must differ"
        );

        address queueOwner = queue.owner();
        address ctrlOwner = controller.owner();

        // still-deployer first (the silent-blank-owner footgun this gate exists for)
        require(
            queueOwner != deployer,
            "SP2-CTRL-02 (C1): queue.owner() == deployer EOA -- ownership not handed to governance"
        );
        require(
            ctrlOwner != deployer,
            "SP2-CTRL-02 (C1): controller.owner() == deployer EOA -- ownership not handed to governance"
        );
        require(queueOwner == governanceOwner, "SP2-CTRL-02 (C1): queue.owner() != governance owner");
        require(ctrlOwner == governanceOwner, "SP2-CTRL-02 (C1): controller.owner() != governance owner");
    }

    // ── C2: wiring. Every intended host must (i) point its queue pointer at THIS
    //    queue (else that surface pays direct at zero-delay = fail-OPEN) AND (ii) be
    //    a registered allowed-source (else its records revert UnregisteredSource =
    //    bricked fail-CLOSED). Both mis-states must be caught before enabling. The
    //    revert names the specific host address for a fast fix. ──
    function _verifyWiring(ExitDelayQueue queue, address[] memory hosts) internal view {
        for (uint256 i; i < hosts.length; i++) {
            address host = hosts[i];
            // (defensive: a zero host is never an intended host — _resolveHosts
            //  filters/reverts them — but guard so a caller-supplied list cannot
            //  slip a 0.)
            require(host != address(0), "SP2-CTRL-02 (C2): intended host == 0");

            require(
                IExitDelayQueueHost(host).exitDelayQueue() == address(queue),
                string.concat(
                    "SP2-CTRL-02 (C2): host ",
                    vm.toString(host),
                    " not wired -- host.exitDelayQueue() != queue (fail-open zero-delay)"
                )
            );
            require(
                queue.isAllowedSource(host),
                string.concat(
                    "SP2-CTRL-02 (C2): host ",
                    vm.toString(host),
                    " not allowed-source -- queue.isAllowedSource(host)==false (bricked fail-closed)"
                )
            );
        }
    }
}
