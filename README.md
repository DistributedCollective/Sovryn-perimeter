# Sovryn Perimeter

**The Sovryn security perimeter** is a trust boundary drawn around the protocol's holdings.
Inside it, nothing changes: positions, operations, and protocol flows compose exactly as they
do today. The boundary acts only at the point where value leaves the protocol — because exits
are where DeFi losses actually happen: an exploit only profits in the minutes it takes to turn
a bug into a withdrawal.

The perimeter ships in phases. **Phase 1 — this repository — is the funding rail: the
Perimeter Fee**, fee machinery on every user-initiated exit surface, deployed switched off and
enabled at a minimal rate (0.10%) only after post-deployment verification. Later phases ship
the protection itself: continuous monitoring of every exit and the ability to intervene between
a suspicious withdrawal beginning and value leaving the perimeter. See **SIP-0094: Perimeter
Fee Activation** in the [SIPS repository](https://github.com/DistributedCollective/SIPS) for
the full programme.

This repo holds the **shared on-chain contracts** (`ExitFeeController`, `ExitFeeVault`) plus
the pragma-versioned `IExitFeeController` interface that downstream product repos copy into
their own trees. Product-side hooks live in the home repos:
[Sovryn-smart-contracts](https://github.com/DistributedCollective/Sovryn-smart-contracts)
(branch `sovryn-perimeter-fee`) and
[zero-contracts](https://github.com/DistributedCollective/zero-contracts)
(branch `sovryn-perimeter-fee`).

- **Interface API**: [`src/interfaces/IExitFeeController.sol`](src/interfaces/IExitFeeController.sol)

---

## Repo layout

```
src/
├── ExitFeeController.sol       # UUPS-upgradeable, governance-owned policy resolver
├── ExitFeeVault.sol            # UUPS-upgradeable, passive holder (sweep API)
└── interfaces/
    ├── IExitFeeController.sol  # range pragma >=0.5.17 <0.9.0 (unified across home repos)
    ├── IExitFeeVault.sol       # pragma 0.8.20 (repo-internal vault interface)
    └── v0_4/
        └── IExitFeeController.sol  # 0.4.26 outlier (AMM only, structural diff)

test/unit/                      # Foundry unit tests (forge test)
script/                         # Foundry deploy + upgrade scripts (forge script)
tools/                          # CI/preflight helpers (bash)
deployments/<chainId>/          # per-chain deployment artifacts (committed for mainnet/testnet)
lib/                            # OZ Upgradeable 4.9.6, OZ Contracts 4.9.6, forge-std (git submodules)
```

---

## Quickstart

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation), `jq`, `git`.

```bash
git clone --recurse-submodules https://github.com/DistributedCollective/Sovryn-perimeter.git
cd Sovryn-perimeter
forge build
forge test
tools/check-abi-equivalence.sh             # cross-pragma ABI guard (4 compilers)
```

Expected: **99/99 tests passing** (95 unit + 4 invariant), ABI-equivalence green across solc 0.5.17 / 0.6.11 / 0.8.20 / 0.4.26.

If you've cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

---

## Architecture (one-paragraph version)

`ExitFeeController` resolves a per-call fee from a three-tier `RatePolicy` lookup (actor → sub-product → surface) for a given `(surfaceId, subProduct, actor, grossAmount)`. The view-only `quoteExitFee(...)` never reverts on policy lookups — it returns an `ExitFeeQuote` with `(active, rateBps, feeAmount, netAmount, feeReceiver, reason)`. Product-side hooks call this from each home repo's existing user-payout call site via a local `_safeQuote` helper, and on a positive quote split the user payout via the family's existing transfer primitive (`_safeTransfer`, `vaultEtherWithdraw`, `activePool.sendETH`, etc.). The fee leg goes to `feeReceiver` (set to the deployed `ExitFeeVault` proxy); the user leg uses the family's existing fail-closed behavior. The controller never moves tokens.

`ExitFeeVault` is a passive holder. It accepts ERC20 transfers and native RBTC via `receive()`. The only way out is `sweepERC20` or `sweepRBTC`, callable by either the proxy owner or the configured operational `admin`; both authorities can use an explicit recipient, and both can rotate `defaultRecipient`. On the controller, the operational admin can toggle `exitFeeEnabled` and rotate `feeReceiver`, while policy writes, admin rotation, and UUPS upgrades remain owner-only. Production ownership is intended for the designated governance multisig — on RSK mainnet the Exchequer Multisig, which also holds the operational admin role at launch; `renounceOwnership` is overridden to revert on both contracts so an accidental call cannot brick owner-only administration and upgrades.

---

## Deploy flow

**One-time:** import the deployer key into Foundry's encrypted keystore. The key never lives in shell history, env vars, or on disk in plaintext:

```bash
cast wallet import deployer --interactive
# Pastes the private key (hidden), prompts for a password.
# Stored encrypted at ~/.foundry/keystores/deployer.
```

For each deploy, set env vars (no private key):

```bash
export RSK_RPC=<chain-rpc-url>                                      # required by the commands below
# On RSK mainnet all three below are the Exchequer Multisig
# (0x924f5ad34698Fd20c90Fe5D5A8A0abd3b42dc711): it is the final owner AND the
# operational admin of both contracts, and ownership is transferred to it
# immediately after each bootstrap (its only act is acceptOwnership()).
export EXIT_FEE_VAULT_ADMIN=<final-owner-address>
export EXIT_FEE_CONTROLLER_ADMIN=<final-owner-address>
export EXIT_FEE_OPERATIONAL_ADMIN=<operational-admin-address>
```

`tools/finalize-deployment.sh` also accepts `RPC_URL` or `ETH_RPC_URL`, and `tools/check-upgrade-safety.sh` accepts `RPC_URL`; the literal Forge commands below use `$RSK_RPC`, so set it as shown. The finalization tool records `git rev-parse --short HEAD` directly—there is no `GIT_SHA` input.

Deploy + finalize each contract (`--account deployer` prompts for the keystore password):

```bash
# 1) Vault deploy. Initial owner = the deployer wallet (NOT the governance Safe).
#    The deployer retains owner power for the vault bootstrap phase; ownership
#    is handed off to the Safe in step 2.
forge script script/01_DeployVault.s.sol --rpc-url $RSK_RPC --broadcast --account deployer
tools/finalize-deployment.sh ExitFeeVault 01_DeployVault <chainId>
# Publish the sources on the Rootstock Blockscout explorer (impl + proxy with
# constructor args). Idempotent; chain 30/31 resolve to the right instance,
# anything else needs BLOCKSCOUT_URL. A verification failure never blocks the
# deploy — fix and re-run.
tools/verify-deployment.sh ExitFeeVault 01_DeployVault <chainId>

# 2) Vault bootstrap: set defaultRecipient, appoint the operational admin,
#    then queue the Ownable2Step handoff to EXIT_FEE_VAULT_ADMIN (the
#    governance Safe). Every input is REQUIRED — the script reverts on a
#    missing one instead of inferring a default. "The Safe sweeps to itself"
#    is a common shape, but it is stated, not assumed.
export EXIT_FEE_VAULT_RECIPIENT=<recipient address>
forge script script/02_BootstrapVault.s.sol \
    --rpc-url $RSK_RPC --broadcast --account deployer \
    --sig "run(uint256)" <chainId>

# 3) Controller deploy. Same pattern as the vault -- deployer is initial owner.
forge script script/03_DeployController.s.sol --rpc-url $RSK_RPC --broadcast --account deployer
tools/finalize-deployment.sh ExitFeeController 03_DeployController <chainId>
tools/verify-deployment.sh ExitFeeController 03_DeployController <chainId>

# 4) Controller bootstrap: configure + (optionally) activate, appoint the
#    operational admin, then queue the Ownable2Step handoff to
#    EXIT_FEE_CONTROLLER_ADMIN (the governance Safe).
export EXIT_FEE_VAULT_PROXY=<vault proxy from step 1>
# Rates for the four surfaces that ship ON. All REQUIRED — a missing one reverts
# the script rather than shipping a rate nobody chose. 0 does NOT mean "skip":
# the surface is still written, active and free.
export PERIMETER_LENDING_LENDER_BPS=<bps>
export PERIMETER_LENDING_BORROWER_BPS=<bps>
export PERIMETER_ZERO_WITHDRAW_COLL_BPS=<bps>
export PERIMETER_ZERO_CLAIM_SURPLUS_BPS=<bps>
# PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY has no consumer in this release and takes no env
# var: the script writes it as (active=false, 0). Turning it on later is a single
# setSurfacePolicy call from the owner.
# MAINNET: keep this false. Enabling at deploy would turn the
# system on while the deployer EOA still owns the proxies — enable via the governance
# Safe only after the ownership handoff and the release gates in SIP-0094.
# =true is for local/test chains only.
export PERIMETER_ENABLE_AT_DEPLOY=false
forge script script/04_BootstrapController.s.sol \
    --rpc-url $RSK_RPC --broadcast --account deployer \
    --sig "run(uint256)" <chainId>

# 5) Final step (governance Safe): call acceptOwnership() on BOTH proxies in
#    follow-up Safe transactions to complete the Ownable2Step handoffs:
#      vault.acceptOwnership()
#      controller.acceptOwnership()
#    Until both accept, the deployer is still the active owner of each
#    proxy. Minimize this window.
```

For non-interactive runs (CI, automation), use `--password-file <path>` so the password — not the key — comes from a file. The keystore itself is still encrypted at rest.

**Skipping the bootstrap scripts.** The checked-in deploy scripts always call `initialize(deployer)`; they do not read `EXIT_FEE_VAULT_ADMIN` or `EXIT_FEE_CONTROLLER_ADMIN`. Therefore, merely skipping bootstrap leaves the deployer as owner, and the Safe cannot perform owner-only configuration. To make a Safe the owner from proxy creation, use a reviewed deployment variant that passes the Safe directly to `initialize(newOwner_)`. Otherwise, the deployer must perform the required configuration, call `transferOwnership(Safe)`, and the Safe must call `acceptOwnership()` before it can perform owner-only operations.

After finalize, `deployments/<chainId>/<Contract>.json` contains:

```jsonc
{
  "contractName": "ExitFeeVault",
  "chainId": 30,
  "proxyAddress": "0x...",        // ERC1967 proxy (constant across upgrades)
  "implAddress": "0x...",         // currently-active impl
  "implBytecodeHash": "0x...",    // keccak256(eth_getCode(implAddress))
  "deploymentBlock": 12345,
  "deploymentTx": "0x...",
  "timestamp": 1734567890,
  "gitSha": "f2722c4",
  "abi": [...],                   // copied verbatim from out/<Contract>.sol/<Contract>.json
  "storageLayout": {...}          // copied verbatim — basis for upgrade-safety checks
}
```

**Commit the deployment artifact** for mainnet / testnet chains. It's the on-chain source of truth for future upgrade-safety checks.

The controller deploys in safe defaults: `exitFeeEnabled = false`, no `feeReceiver`, no surface/sub-product/actor policies. Every product-side hook no-ops until the activation sequence runs (either via the bootstrap script above, or as individual Safe transactions post-handoff).


---

## Upgrade flow

The Perimeter Fee proxies are UUPS-upgradeable. Only the proxy owner (governance Safe / TimelockOwner) can authorize an upgrade. The flow:

1. **Build + audit the new impl** on `feat/<change>` or release branch.
2. **Deploy the new impl** on-chain (it becomes a candidate; the proxy still points at the active impl). Note its address — call it `$NEW_IMPL`.
3. **Run the pre-flight safety check** before queueing the owner transaction:

   ```bash
   RSK_RPC=$RSK_RPC tools/check-upgrade-safety.sh \
       ExitFeeController <chainId> $NEW_IMPL
   ```

   Three guards must pass:
   - Saved deployment artifact's impl hash still matches on-chain (artifact isn't stale).
   - Proxy's EIP-1967 implementation slot still points at the saved impl.
   - The current local build's `storageLayout` is upgrade-compatible with the saved layout: every existing `(label, slot, offset, type)` unchanged (with full struct/enum member equivalence); new vars only at slots previously inside `__gap`; `__gap` reduced by exactly the number of **storage slots** the new vars occupy (Solidity packs sub-32-byte fields, so two `uint128` fields share one slot and `__gap` shrinks by 1, not 2).

   This does not bind `$NEW_IMPL` to the local build. Before approval, independently verify the candidate source/bytecode so the owner knows the checked layout belongs to the deployed implementation.

4. **Execute through the current proxy owner.** For a production Safe, submit `proxy.upgradeTo($NEW_IMPL)` through the Safe using calldata such as:

   ```bash
   cast calldata "upgradeTo(address)" "$NEW_IMPL"
   ```

   `99_UpgradeProxy.s.sol` is only for local/test deployments or an EOA-owned proxy. Its broadcasting account must itself be the current proxy owner:

   ```bash
   export PROXY=<proxy-address>
   export NEW_IMPL=<candidate-impl-address>
   forge script script/99_UpgradeProxy.s.sol \
       --rpc-url $RSK_RPC --broadcast --account <owner-account>
   ```

5. **Refresh the deployment artifact** so future safety checks have the new baseline. For the Foundry-script path, run:

   ```bash
   RSK_RPC=$RSK_RPC tools/finalize-deployment.sh \
       ExitFeeController 99_UpgradeProxy <chainId>
   tools/verify-deployment.sh ExitFeeController 99_UpgradeProxy <chainId>
   ```

   The verify step publishes the new implementation's source on the Rootstock
   Blockscout explorer (the proxy stays verified from its initial deploy).

   The current finalizer reads the local `99_UpgradeProxy` Foundry broadcast log. It cannot ingest a Safe/Timelock execution receipt. For a contract-owned production proxy, the release process must capture the governance transaction and refresh the artifact through a reviewed Safe-aware process before treating it as the next upgrade baseline.

6. **Commit the updated `deployments/<chainId>/<Contract>.json`**.

The upgrade-safety check deliberately does **not** verify candidate-bytecode-vs-build via simple hash compare: UUPS impls embed `UUPSUpgradeable.__self` (the impl's own deploy address) as an `address immutable`, so two impls compiled from the same source but deployed at different addresses have different runtime bytecode. The auditor verifies source via `forge verify-bytecode --etherscan-api-key ...` or sourcify against the canonical bytecode (with immutable-masking).

---

## Tooling reference

| Tool                                                                                            | Purpose                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `forge test`                                                                                    | Run all Foundry tests (95 unit tests across controller + vault, plus 4 controller invariants).                                                                                                                                                                                                                                            |
| `tools/check-abi-equivalence.sh`                                                                | Cross-pragma ABI guard. Diffs the unified `IExitFeeController.sol` against the `v0_4/` outlier and compiles both under each target compiler (0.5.17, 0.6.11, 0.8.20, 0.4.26). Required CI gate.                                                                                                                                           |
| `tools/finalize-deployment.sh <Contract> <ScriptBase> <chainId>`                                | Post-deploy / post-upgrade for transactions broadcast by the checked-in Foundry scripts. Reads `broadcast/<ScriptBase>.s.sol/<chainId>/run-latest.json` and `out/<Contract>.sol/<Contract>.json`, writes `deployments/<chainId>/<Contract>.json`. Auto-detects initial-deploy vs upgrade mode; it does not ingest Safe/Timelock receipts. |
| `tools/check-upgrade-safety.sh <Contract> <chainId> <candidate>`                                | Pre-flight gate before queuing a UUPS upgrade. Three guards (saved-on-chain match, proxy-impl-slot match, storage-layout upgrade-compat).                                                                                                                                                                                                 |
| `forge script script/InspectController.s.sol --rpc-url $RSK_RPC --sig "run(uint256)" <chainId>` | Read-only inspector. Prints the live `ExitFeeController` state: ownership, `exitFeeEnabled` / `feeReceiver` / `MAX_BPS`, surface policies, and every configured sub-product / actor override (read from the on-chain enumeration index — no log scans). Verifies the on-chain EIP-1967 impl slot matches the saved deployment artifact.   |

---

## Home-repo integration

Perimeter Fee is consumed by three product repos. Each one copies the `IExitFeeController` interface file into its own tree on a `private/perimeter` branch — **no git submodule** (the file-copy approach avoids submodule-pointer churn during private-branch development and audit):

| Home repo                                  | Pragma | Interface copy                                                                                       | Hook location                                                                                       |
| ------------------------------------------ | ------ | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `Sovryn-smart-contracts`                   | 0.5.17 | `contracts/external/perimeter/IExitFeeController.sol` ← copy of `src/interfaces/IExitFeeController.sol` | lending: `LoanTokenLogicShared` · loan/margin: `ModuleCommonFunctionalities` + `LoanClosingsShared` |
| `zero-contracts`                           | 0.6.11 | same path ← copy of `src/interfaces/IExitFeeController.sol`                                          | `BorrowerOperations`                                                                                |
| `oracle-based-amm` _(deferred to Phase 6)_ | 0.4.26 | same path ← copy of `src/interfaces/v0_4/IExitFeeController.sol`                                     | `ConverterBase`                                                                                     |

The 0.5+/0.6+/0.8 range pragma on the unified interface means Sovryn-smart-contracts and zero-contracts copy the same file; only AMM needs the structurally-different `v0_4/` outlier.

When the interface changes here, each home repo re-copies its respective file (with a provenance header pinning the perimeter SHA) and runs `tools/check-abi-equivalence.sh` against the perimeter source to confirm the v0_4 outlier still matches.

---

## Project conventions

- **Pragmas**: pinned exact (`0.8.20`), not floating (`^0.8.20`). The unified interface is the one exception — it uses a range pragma intentionally for cross-compiler portability.
- **Storage layout**: every upgradeable contract reserves a 50-slot OZ-style namespace via `uint256[N] private __gap;` where `N = 50 − own_slots`. Documented in-line at the top of each contract's storage section.
- **Custom errors over revert strings**: gas-efficient and IDE-greppable.
- **`renounceOwnership` is disabled** on both contracts to prevent admin lockout.
- **`nonReentrant` ordered before the access modifier** (`onlyOwner` / `onlyAdminOrOwner`): engages first, blocks reentrancy through any subsequent modifier.
- **Aderyn**: static-analysis config in [`aderyn.toml`](aderyn.toml). Project-level exclusions cover by-design patterns (`centralization-risk` on governance setters, `costly-loop` / `require-revert-in-loop` on batch policy setters).

---

## Status

**Phase 1 complete**: shared Perimeter Fee contracts (controller + vault) + interfaces + deploy/upgrade tooling. 99/99 tests passing (95 unit + 4 invariant). ABI-equivalence guard green across four compilers. The local/EOA deploy → finalize → upgrade-safety flow is smoke-tested; production Safe execution requires the Safe-aware artifact-refresh step noted above.

**Next**: Phase 2 (lending hooks in `Sovryn-smart-contracts-perimeter`), Phase 3 (loan/margin hooks in same repo), Phase 4 (Zero hooks in `zero-contracts-perimeter`). Phase 6 (AMM) deferred until proof gates pass.


---

## License

MIT. See [LICENSE](LICENSE).
