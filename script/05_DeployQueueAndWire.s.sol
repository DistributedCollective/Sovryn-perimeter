// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExitFeeController} from "../src/ExitFeeController.sol";
import {ExitDelayQueue} from "../src/ExitDelayQueue.sol";
import {IExitDelayQueueHost} from "../src/interfaces/IExitDelayQueueHost.sol";

/// @title  Deploy ExitDelayQueue + wire the product hosts (activation step 1)
/// @notice activation ordering STEP 1: deploy the `ExitDelayQueue` impl +
///         ERC1967Proxy alongside the already-deployed `ExitFeeController` (from
///         `03_DeployController`), then WIRE the queue pointer into each product
///         host via `setExitDelayQueue`: the `sovrynProtocol`
///         singleton (lending + loan/margin) and the Zero `BorrowerOperations`
///         proxy.
///
///         IMPORTANT — this script performs ONLY the deploy + host-wire (step 1).
///         It DELIBERATELY does NOT configure the security-critical controller
///         state (`setAdmin`, `setGlobalDelaySeconds`) — those are activation steps 4–5
///         OWNER actions, executed as a SIP / Safe tx, NOT by this deployer script
///         (roles-not-actors: the deployer must not silently hold guardian/delay
///         authority). It also does NOT enable the perimeter (step 8).
///
///         The go-live GATES — (`controller.admin == queue.admin`)
///         and (`controller.globalDelaySeconds >= queue.minimumDelaySeconds`)
///         — are NOT asserted here. They CANNOT be: this script runs at step 1,
///         BEFORE the Owner has configured the controller's admin + global delay
///         (steps 4–5), so `controller.admin() == 0` and `globalDelaySeconds() == 0`
///         at this point. A correctly-ordered first deploy would therefore ALWAYS
///         revert if the assertions lived here (the ordering constraint below).
///         Instead they live in the dedicated READ-ONLY `06_VerifyActivation.s.sol`
///         verify script, run LAST as the step-7 go-live gate — AFTER the Owner
///         has configured admin + globalDelaySeconds.
///
///         The controller never reads or calls the queue at RUNTIME (kill-switch
///         queue-independence). The host wiring here is the ONLY
///         on-chain coupling and it is one-directional (host → queue pointer).
///
/// @dev Usage:
///
///   export EXIT_DELAY_QUEUE_OWNER=0x...        # queue Owner (governance Safe / timelock)
///   export EXIT_DELAY_QUEUE_ADMIN=0x...        # queue Admin (must != Owner; == controller.admin, set later)
///   export WRBTC_ADDRESS=0x...                 # canonical wrapped-RBTC ERC20
///   export QUEUE_MIN_DELAY_SECONDS=3600        # per-request delay floor
///   export QUEUE_ALLOWED_SOURCES=0xA,0xB       # comma-separated hooked sources (optional; activation step 2)
///   # Product hosts to wire (activation step 1). BOTH are REQUIRED non-zero UNLESS you
///   # set DEFER_HOSTS=true. A missing/misspelled host env var must ABORT the deploy
///   # (C2, no silent address(0) no-op wire) — deferral must be EXPLICIT, never
///   # implicit-via-blank. When DEFER_HOSTS=true, an unset/zero host is skipped so
///   # its wiring can be moved to a later per-host Owner SIP/Safe tx.
///   export SOVRYN_PROTOCOL_HOST=0x...          # sovrynProtocol singleton (lending + loan/margin)
///   export ZERO_BORROWER_OPERATIONS_HOST=0x... # Zero BorrowerOperations proxy
///   export DEFER_HOSTS=true                    # OPTIONAL explicit opt-in to defer a zero host
///
///   forge script script/05_DeployQueueAndWire.s.sol \
///       --rpc-url $RSK_RPC --broadcast --account deployer \
///       --sig "run(uint256)" <chainId>
///
///   Reads `deployments/<chainId>/ExitFeeController.json` for the controller proxy.
///   After this script:
///     1. tools/finalize-deployment.sh ExitDelayQueue 05_DeployQueueAndWire <chainId>
///     2. activation steps 2–6 (allowed sources, routes, setGlobalDelaySeconds,
///        setAdmin×2, bypass) — Owner SIP / Safe txs.
///     3. `06_VerifyActivation.s.sol` — the step-7 read-only go-live gate.
///     4. controller.setSecurityPerimeterEnabled(true) — step 8.
contract DeployQueueAndWire is Script {
    using stdJson for string;

    /// @dev Validated deploy configuration, parsed from env by `_readConfig`. Held
    ///      in a struct so `run()` keeps only ONE live local across the broadcast
    ///      (avoids a stack-too-deep on the non-viaIR Paris build).
    struct DeployConfig {
        address queueOwner;
        address queueAdmin;
        address wrbtc;
        uint32 minDelay;
        address[] allowedSources;
        address sovrynHost;
        address zeroHost;
    }

    /// @param chainId          the target chain (selects the deployments artifact dir)
    /// @return queueProxy       the deployed ExitDelayQueue proxy
    /// @return queueImpl        the deployed ExitDelayQueue implementation
    function run(uint256 chainId) external returns (address queueProxy, address queueImpl) {
        ExitFeeController controller = _controller(chainId);
        DeployConfig memory cfg = _readConfig();

        console2.log("ExitFeeController @", address(controller));
        console2.log("  controller.admin (pre-config, expect 0):", controller.admin());
        console2.log(
            "  controller.globalDelaySeconds (pre-config, expect 0):",
            uint256(controller.globalDelaySeconds())
        );
        console2.log("  queue owner:                  ", cfg.queueOwner);
        console2.log("  queue admin:                  ", cfg.queueAdmin);
        console2.log("  queue minimumDelaySeconds:    ", uint256(cfg.minDelay));
        console2.log("  sovrynProtocol host:          ", cfg.sovrynHost);
        console2.log("  Zero BorrowerOperations host: ", cfg.zeroHost);
        console2.log("");

        uint256 wiredCount;
        vm.startBroadcast();

        // ── Deploy the queue behind its proxy (initialize sets owner/admin/floor). ──
        queueImpl = address(new ExitDelayQueue());
        queueProxy = address(
            new ERC1967Proxy(
                queueImpl,
                abi.encodeCall(
                    ExitDelayQueue.initialize,
                    (cfg.queueOwner, cfg.queueAdmin, cfg.wrbtc, cfg.minDelay, cfg.allowedSources)
                )
            )
        );

        // ── WIRE the queue pointer into each supplied product host. ──
        //    setExitDelayQueue is host-Owner/Timelock-gated; the broadcast wallet
        //    must hold that authority for the wire to land (else the host reverts).
        //    A zero host is skipped (only reachable under DEFER_HOSTS=true — the
        //    require()s in _readConfig already aborted a blank host otherwise).
        wiredCount = wireHosts(queueProxy, cfg.sovrynHost, cfg.zeroHost);

        vm.stopBroadcast();

        console2.log("ExitDelayQueue impl deployed at:  ", queueImpl);
        console2.log("ExitDelayQueue proxy deployed at: ", queueProxy);
        console2.log("");
        // (C2) The "hosts wired" success line prints ONLY when a host was actually
        //      wired — a deferred-all deploy says so explicitly instead of claiming
        //      a wire that never happened.
        if (wiredCount > 0) {
            console2.log(
                unicode"OK: queue deployed + hosts wired (activation step 1). hosts wired:", wiredCount
            );
        } else {
            console2.log(
                unicode"OK: queue deployed, NO hosts wired (DEFER_HOSTS) — wire each host via a later Owner SIP (activation step 1)."
            );
        }
        console2.log(unicode"NOTE: admin + globalDelaySeconds are Owner steps 4-5 (NOT set here).");
        console2.log(unicode"Verify with 06_VerifyActivation.s.sol (step-7 gate) AFTER steps 4-5,");
        console2.log(unicode"then controller.setSecurityPerimeterEnabled(true) (step 8).");
        console2.log("Next: tools/finalize-deployment.sh ExitDelayQueue 05_DeployQueueAndWire <chainId>");
    }

    /// @dev Locate the already-deployed controller from its deployment artifact.
    function _controller(uint256 chainId) internal view returns (ExitFeeController) {
        string memory ctrlArtifact =
            vm.readFile(string.concat("deployments/", vm.toString(chainId), "/ExitFeeController.json"));
        return ExitFeeController(ctrlArtifact.readAddress(".proxyAddress"));
    }

    /// @dev Parse + VALIDATE the deploy config from env (C1/C2: no silent
    ///      address(0) defaults). A missing/misspelled critical env var ABORTS the
    ///      deploy here rather than defaulting to address(0) on-chain. In particular
    ///      EXIT_DELAY_QUEUE_OWNER is required (C1): ExitDelayQueue.initialize
    ///      resolves a zero `owner_` to msg.sender, which would silently leave the
    ///      deployer EOA holding UUPS/upgrade/source-registry/recovery/sweep
    ///      authority. Product hosts are REQUIRED non-zero unless DEFER_HOSTS=true
    ///      (C2: a blank host must ABORT, never no-op-wire a fail-open surface;
    ///      deferral must be EXPLICIT).
    function _readConfig() internal view returns (DeployConfig memory cfg) {
        cfg.queueOwner = vm.envAddress("EXIT_DELAY_QUEUE_OWNER");
        cfg.queueAdmin = vm.envAddress("EXIT_DELAY_QUEUE_ADMIN");
        cfg.wrbtc = vm.envAddress("WRBTC_ADDRESS");
        uint256 minDelay = vm.envUint("QUEUE_MIN_DELAY_SECONDS");
        require(minDelay <= type(uint32).max, "05: QUEUE_MIN_DELAY_SECONDS overflows uint32");
        cfg.minDelay = uint32(minDelay);

        cfg.allowedSources = vm.envOr("QUEUE_ALLOWED_SOURCES", ",", new address[](0));

        cfg.sovrynHost = vm.envOr("SOVRYN_PROTOCOL_HOST", address(0));
        cfg.zeroHost = vm.envOr("ZERO_BORROWER_OPERATIONS_HOST", address(0));

        // The address/host safety checks are factored into a PURE validator so a
        // unit test can drive every abort branch on an in-memory struct — NO
        // vm.setEnv (which mutates process-global env forge does not isolate
        // between parallel test functions, a genuine race across env-driven tests).
        validateConfig(cfg, vm.envOr("DEFER_HOSTS", false));
    }

    /// @notice Validate the deploy config (C1/C2 no-silent-blanks safety). Reverts
    ///         with a DISTINCT message per missing/misspelled critical input;
    ///         returns silently when the config is deployable. Pure so it is
    ///         driveable in a unit test with an in-memory struct, race-free.
    /// @param cfg          the parsed config
    /// @param deferHosts   the explicit DEFER_HOSTS opt-in (true ⇒ a zero host is
    ///                     an intentional deferral, not an error)
    function validateConfig(DeployConfig memory cfg, bool deferHosts) public pure {
        // C1 — no silent address(0) for the security-critical queue inputs. A zero
        // owner would let ExitDelayQueue.initialize resolve owner_ to msg.sender,
        // silently leaving the deployer EOA with queue authority — so abort loud.
        require(
            cfg.queueOwner != address(0),
            "05: EXIT_DELAY_QUEUE_OWNER must be set (C1: zero owner => deployer EOA holds queue authority)"
        );
        require(cfg.queueAdmin != address(0), "05: EXIT_DELAY_QUEUE_ADMIN must be set");
        // No admin-vs-owner separation is enforced: the launch shape has the
        // governance Safe holding both roles, and the authority split becomes
        // meaningful only once ownership later moves while the admin stays put.
        require(cfg.wrbtc != address(0), "05: WRBTC_ADDRESS must be set");

        // C2 — a blank host must ABORT (never no-op-wire a fail-open zero-delay
        // surface) UNLESS deferral is EXPLICIT via DEFER_HOSTS=true.
        if (!deferHosts) {
            require(
                cfg.sovrynHost != address(0),
                "05: SOVRYN_PROTOCOL_HOST must be set (or set DEFER_HOSTS=true to defer)"
            );
            require(
                cfg.zeroHost != address(0),
                "05: ZERO_BORROWER_OPERATIONS_HOST must be set (or set DEFER_HOSTS=true to defer)"
            );
        }

        // (C2 duplicate-host guard) A non-zero duplicate pair (both spec-named host
        // vars pointing at the SAME address — a copy-paste footgun) would wire one
        // surface twice and leave the OTHER silently unwired at zero-delay. Reject
        // it. The `== address(0)` clause preserves the both-zero DEFER_HOSTS path.
        require(
            cfg.sovrynHost != cfg.zeroHost || cfg.sovrynHost == address(0),
            "05: SOVRYN_PROTOCOL_HOST == ZERO_BORROWER_OPERATIONS_HOST (duplicate host)"
        );
    }

    /// @notice Wire the queue pointer into the two product hosts,
    ///         skipping any zero host (wiring deferred to a per-host SIP/Safe tx).
    ///         Public so a unit test can drive the wire step directly WITHOUT the
    ///         env-parsing broadcast path (whose `vm.setEnv` mutates process-global
    ///         env that forge does not isolate between parallel test functions).
    ///         Must be called from a context authorized to set each host pointer.
    /// @return wiredCount how many hosts were actually wired (a zero host is not
    ///         counted) — drives the conditional "hosts wired" success line (C2).
    function wireHosts(address queue, address sovrynHost, address zeroHost)
        public
        returns (uint256 wiredCount)
    {
        if (_wireHost(sovrynHost, queue, "sovrynProtocol")) wiredCount++;
        if (_wireHost(zeroHost, queue, "Zero BorrowerOperations")) wiredCount++;
    }

    /// @dev Wire one product host's queue pointer, verifying the write took.
    ///      A zero host is a no-op (wiring deferred to a later per-host SIP/Safe tx).
    /// @return wired true iff the host was non-zero and its pointer was written.
    function _wireHost(address host, address queue, string memory label) internal returns (bool wired) {
        if (host == address(0)) {
            console2.log(string.concat("  wire SKIPPED (host unset): "), label);
            return false;
        }
        IExitDelayQueueHost(host).setExitDelayQueue(queue);
        require(
            IExitDelayQueueHost(host).exitDelayQueue() == queue, "05: setExitDelayQueue did not take on host"
        );
        console2.log(string.concat("  wired queue -> host: "), label);
        return true;
    }
}
