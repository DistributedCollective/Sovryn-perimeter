#!/usr/bin/env bash
#
# Pre-flight check before upgrading a Perimeter Fee proxy to a new impl.
#
# Usage:
#   tools/check-upgrade-safety.sh <ContractName> <chainId> <candidateImplAddress>
#
# Example:
#   tools/check-upgrade-safety.sh ExitFeeController 30 0xabc...def
#
# Verifies the invariants this script CAN check reliably:
#
# Sanity 1: SAVED IMPL STILL MATCHES ON-CHAIN
#   keccak256(eth_getCode(deployments/<chainId>/<Contract>.json::implAddress))
#   == deployments/<chainId>/<Contract>.json::implBytecodeHash
#
#   AND the proxy's EIP-1967 implementation slot points at that impl.
#
#   Catches: the deployment artifact is stale (someone redeployed without
#   updating it, or upgraded the proxy outside the script flow).
#
# Sanity 2: CANDIDATE IS DEPLOYED AND NON-EMPTY
#   eth_getCode(candidateImplAddress) is non-empty.
#
#   We deliberately do NOT do a bytecode-vs-build hash compare here. UUPS
#   impls have a UUPSUpgradeable.__self immutable that is the impl's own
#   deploy address inlined into the runtime bytecode -- so two impls
#   compiled from the same source but deployed at different addresses
#   have DIFFERENT bytecode. Robustly verifying "candidate matches current
#   source" requires immutable-masking, which is brittle in shell. That
#   verification is the auditor's responsibility (typically via
#   `forge verify-bytecode --etherscan-api-key ...` or sourcify), not this
#   pre-flight gate. This script focuses on the things it CAN guarantee.
#
# Safety: STORAGE LAYOUT UPGRADE-COMPAT
#   Diffs deployments/<chainId>/<Contract>.json::storageLayout against
#   out/<Contract>.sol/<Contract>.json::storageLayout.
#
#   What "safe" means here:
#   - Every (label, slot, offset, type) in the SAVED layout must appear
#     unchanged in the candidate layout (no slot moves, no type changes,
#     no removed variables). Type equivalence includes full struct/enum
#     member definitions, not just the type name.
#   - The candidate may consume STORAGE SLOTS previously inside __gap by
#     adding new variables. Solidity packs sub-32-byte fields together,
#     so accounting is by OCCUPIED STORAGE SLOTS, not by entry count.
#     E.g. two new uint128 fields share one slot; __gap shrinks by 1.
#   - The candidate's __gap length must equal the saved __gap length
#     minus the number of STORAGE SLOTS occupied by new variables in
#     the reclaimed range (see tools/diff-storage-layouts.py).
#
# Exit codes:
#   0 all checks passed -- safe to queue the upgrade
#   1 a check failed -- DO NOT upgrade
#   2 missing prerequisite (forge/jq/cast, deployment artifact, etc.)
#
# Requires: jq, cast, forge, and an RPC URL in env (e.g. RSK_RPC, set
#           per the canonical-design memo's mainnet endpoint).
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 3 ]; then
    echo "usage: $0 <ContractName> <chainId> <candidateImplAddress>" >&2
    exit 1
fi

CONTRACT="$1"
CHAIN_ID="$2"
CANDIDATE="$(echo "$3" | tr 'A-Z' 'a-z')"

DEPLOY_ARTIFACT="deployments/${CHAIN_ID}/${CONTRACT}.json"
BUILD_ARTIFACT="out/${CONTRACT}.sol/${CONTRACT}.json"
RPC="${RSK_RPC:-${RPC_URL:-}}"

for cmd in jq cast forge; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: $cmd is required" >&2
        exit 2
    fi
done

if [ -z "$RPC" ]; then
    echo "error: set RSK_RPC or RPC_URL env var to the chain's RPC endpoint" >&2
    exit 2
fi

if [ ! -f "$DEPLOY_ARTIFACT" ]; then
    echo "error: no deployment artifact at $DEPLOY_ARTIFACT" >&2
    echo "       run finalize-deployment.sh after the initial deploy first" >&2
    exit 2
fi
if [ ! -f "$BUILD_ARTIFACT" ]; then
    echo "error: no build artifact at $BUILD_ARTIFACT (try: forge build)" >&2
    exit 2
fi

# Validate both layouts BEFORE doing any diffing. If either is null/missing,
# the diff would silently pass on degenerate inputs and we'd have no real
# upgrade-safety guarantee.
if ! jq -e '.storageLayout.storage | type == "array"' "$DEPLOY_ARTIFACT" > /dev/null 2>&1; then
    echo "error: deployment artifact at $DEPLOY_ARTIFACT has no usable storageLayout." >&2
    echo "       The saved baseline is corrupted. Re-run finalize-deployment.sh against" >&2
    echo "       the live impl to repopulate the artifact." >&2
    exit 2
fi
if ! jq -e '.storageLayout.storage | type == "array"' "$BUILD_ARTIFACT" > /dev/null 2>&1; then
    echo "error: build artifact at $BUILD_ARTIFACT has no usable storageLayout." >&2
    echo "       Check foundry.toml has extra_output = [\"storageLayout\"] and re-run" >&2
    echo "       'forge clean && forge build'." >&2
    exit 2
fi

SAVED_IMPL=$(jq -r '.implAddress' "$DEPLOY_ARTIFACT")
SAVED_HASH=$(jq -r '.implBytecodeHash' "$DEPLOY_ARTIFACT")
PROXY_ADDR=$(jq -r '.proxyAddress' "$DEPLOY_ARTIFACT")

echo "Contract: $CONTRACT (chainId $CHAIN_ID)"
echo "Proxy:    $PROXY_ADDR"
echo

# ─── Sanity 1: saved impl still matches on-chain ─────────────────────────
echo "── 1) Saved impl still matches on-chain bytecode ─────────────────────"
ONCHAIN_SAVED_CODE=$(cast code "$SAVED_IMPL" --rpc-url "$RPC")
ONCHAIN_SAVED_HASH=$(cast keccak "$ONCHAIN_SAVED_CODE")
if [ "$ONCHAIN_SAVED_HASH" != "$SAVED_HASH" ]; then
    echo "    error: saved impl bytecode hash diverges from on-chain." >&2
    echo "      saved:    $SAVED_HASH" >&2
    echo "      on-chain: $ONCHAIN_SAVED_HASH" >&2
    echo "      Either the deployment artifact is stale, or the chain state moved." >&2
    exit 1
fi
echo "    ok"

# Also verify the proxy's EIP-1967 impl slot points at the saved impl, in
# case the proxy was upgraded outside the script flow.
EIP1967_IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ONCHAIN_PROXY_IMPL=$(cast storage "$PROXY_ADDR" "$EIP1967_IMPL_SLOT" --rpc-url "$RPC" | tr 'A-Z' 'a-z')
# Storage slot returns 32-byte left-padded; address is the last 40 hex chars.
ONCHAIN_PROXY_IMPL="0x${ONCHAIN_PROXY_IMPL: -40}"
if [ "$ONCHAIN_PROXY_IMPL" != "$SAVED_IMPL" ]; then
    echo "    error: proxy's EIP-1967 implementation slot points at a different impl than saved." >&2
    echo "      saved impl:   $SAVED_IMPL" >&2
    echo "      proxy points: $ONCHAIN_PROXY_IMPL" >&2
    echo "      The proxy was upgraded outside the deploy-script flow. Run finalize-deployment.sh." >&2
    exit 1
fi
echo "    proxy's EIP-1967 impl slot = $SAVED_IMPL  ok"

# ─── Sanity 2: candidate is deployed and non-empty ───────────────────────
echo "── 2) Candidate deployed at $CANDIDATE (non-empty bytecode) ──────────"
CANDIDATE_CODE=$(cast code "$CANDIDATE" --rpc-url "$RPC")
if [ -z "$CANDIDATE_CODE" ] || [ "$CANDIDATE_CODE" = "0x" ]; then
    echo "    error: no code at candidate address $CANDIDATE" >&2
    exit 1
fi
CANDIDATE_HASH=$(cast keccak "$CANDIDATE_CODE")
echo "    ok (hash: $CANDIDATE_HASH)"
echo
echo "    Note: this script does NOT verify that the candidate's bytecode"
echo "    matches the current source. UUPS impls embed their own deploy"
echo "    address as an immutable, so a simple hash compare doesn't work."
echo "    Auditor verifies source via 'forge verify-bytecode' against"
echo "    Etherscan/Sourcify, or by reproducing the deploy locally and"
echo "    comparing immutable-masked bytecode."

# ─── Safety: storage layout upgrade-compat ────────────────────────────────
echo "── 3) Storage layout upgrade-compat ──────────────────────────────────"

# Delegate to the Python tool. It handles full type expansion (catching
# struct member reorders / type widenings / enum variant reorders),
# proper slot-span accounting (numberOfBytes / 32, ceiling), and the
# out-of-namespace check. Bash + jq's recursion model is too limited
# to do this cleanly; Python 3 is on every macOS/Linux dev box.
if ! command -v python3 >/dev/null 2>&1; then
    echo "    error: python3 is required for the storage-layout diff" >&2
    exit 2
fi
DIFF_TOOL="$(dirname "$0")/diff-storage-layouts.py"
if [ ! -x "$DIFF_TOOL" ]; then
    echo "    error: missing or non-executable $DIFF_TOOL" >&2
    exit 2
fi

python3 "$DIFF_TOOL" "$DEPLOY_ARTIFACT" "$BUILD_ARTIFACT"
DIFF_EXIT=$?
if [ $DIFF_EXIT -ne 0 ]; then
    exit $DIFF_EXIT
fi
echo


echo
echo "Upgrade-safety: OK"
echo "  proxy:        $PROXY_ADDR"
echo "  active impl:  $SAVED_IMPL"
echo "  candidate:    $CANDIDATE"
echo "  ready to queue: upgradeTo($CANDIDATE)"
