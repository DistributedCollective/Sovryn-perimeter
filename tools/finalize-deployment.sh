#!/usr/bin/env bash
#
# Build a deployment artifact for a freshly-deployed Perimeter Fee proxy.
#
# Usage:
#   tools/finalize-deployment.sh <ContractName> <ScriptBaseName> <chainId>
#
# Examples:
#   tools/finalize-deployment.sh ExitFeeVault       01_DeployVault      31337
#   tools/finalize-deployment.sh ExitFeeController  03_DeployController 30
#   tools/finalize-deployment.sh ExitFeeController  99_UpgradeProxy     30
#
# Reads the Foundry broadcast log + the build artifact, then writes
# deployments/<chainId>/<ContractName>.json with:
#
#   contractName        the Solidity contract name
#   chainId             chain the proxy lives on
#   proxyAddress        ERC1967Proxy address (stays constant across upgrades)
#   implAddress         currently-active implementation address
#   implBytecodeHash    keccak256 of the impl's deployed bytecode (fetched
#                       from the RPC if RSK_RPC is set; otherwise computed
#                       from the build artifact's deployedBytecode)
#   deploymentBlock     block number the most-recent deploy/upgrade landed in
#   deploymentTx        tx hash that deployed/upgraded the impl
#   timestamp           UNIX time the broadcast happened
#   gitSha              repo HEAD at deploy time
#   abi                 (object) full ABI -- copied verbatim from out/
#   storageLayout       (object) layout -- copied verbatim from out/
#
# On UPGRADE (script = 99_UpgradeProxy): proxyAddress is preserved from
# the existing deployment artifact; only implAddress / hash / block / tx
# update. ABI + storageLayout reflect the NEW impl (matching the new
# active code).
#
# All addresses are normalised to lowercase 0x-prefixed hex.
#
# Exit codes:
#   0 ok
#   1 input/parse error
#   2 missing prerequisite (forge/jq, broadcast log, etc.)
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 3 ]; then
    echo "usage: $0 <ContractName> <ScriptBaseName> <chainId>" >&2
    exit 1
fi

CONTRACT="$1"
SCRIPT_BASE="$2"   # e.g. "01_DeployVault" -- without .s.sol
CHAIN_ID="$3"

for cmd in jq forge cast; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: $cmd is required" >&2
        exit 2
    fi
done

BROADCAST="broadcast/${SCRIPT_BASE}.s.sol/${CHAIN_ID}/run-latest.json"
BUILD_ARTIFACT="out/${CONTRACT}.sol/${CONTRACT}.json"
OUT_DIR="deployments/${CHAIN_ID}"
OUT_FILE="${OUT_DIR}/${CONTRACT}.json"

if [ ! -f "$BROADCAST" ]; then
    echo "error: broadcast log not found at $BROADCAST" >&2
    echo "       (did you forge script ... --broadcast first?)" >&2
    exit 2
fi
if [ ! -f "$BUILD_ARTIFACT" ]; then
    echo "error: build artifact not found at $BUILD_ARTIFACT" >&2
    echo "       (try: forge build)" >&2
    exit 2
fi

# Validate the build artifact has a usable storageLayout. If extra_output
# isn't set in foundry.toml or the artifact is stale, .storageLayout will
# be null/missing -- writing that into the deployment artifact would
# create a poisoned baseline for future upgrade-safety checks.
if ! jq -e '.storageLayout.storage | type == "array"' "$BUILD_ARTIFACT" > /dev/null 2>&1; then
    echo "error: build artifact at $BUILD_ARTIFACT has no usable storageLayout." >&2
    echo "       Expected .storageLayout.storage to be an array. Check that" >&2
    echo "       foundry.toml has extra_output = [\"storageLayout\"] and re-run" >&2
    echo "       'forge clean && forge build'." >&2
    exit 2
fi
if ! jq -e '.abi | type == "array"' "$BUILD_ARTIFACT" > /dev/null 2>&1; then
    echo "error: build artifact at $BUILD_ARTIFACT has no usable abi array." >&2
    exit 2
fi

mkdir -p "$OUT_DIR"

# ─── Pull deploy info from broadcast log ─────────────────────────────────
# Initial deploy (01_/02_) has two CREATE transactions: impl, then proxy.
# Upgrade (99_) has one upgradeTo() call: extract its target arg as newImpl.
#
# We dispatch on whether the broadcast contains an upgradeTo call.

IS_UPGRADE=$(jq -r '
    [.transactions[] | select(.function == "upgradeTo(address)")] | length > 0
' "$BROADCAST")

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [ "$IS_UPGRADE" = "true" ]; then
    # ── Upgrade path ─────────────────────────────────────────────────────
    if [ ! -f "$OUT_FILE" ]; then
        echo "error: cannot finalize upgrade -- no existing $OUT_FILE to update" >&2
        echo "       (initial deploy must run first via 01_/02_)" >&2
        exit 1
    fi

    PROXY_ADDR=$(jq -r '
        .transactions[] | select(.function == "upgradeTo(address)") | .contractAddress // .transaction.to
    ' "$BROADCAST" | head -1)
    NEW_IMPL=$(jq -r '
        .transactions[] | select(.function == "upgradeTo(address)") | .arguments[0]
    ' "$BROADCAST" | head -1)
    DEPLOY_BLOCK_HEX=$(jq -r '
        .receipts[] | .blockNumber
    ' "$BROADCAST" | tail -1)
    DEPLOY_BLOCK=$(printf '%d' "$DEPLOY_BLOCK_HEX")
    DEPLOY_TX=$(jq -r '
        .receipts[] | .transactionHash
    ' "$BROADCAST" | tail -1)
    TIMESTAMP=$(jq -r '.timestamp' "$BROADCAST")

    # Normalize to lowercase 0x-prefixed.
    PROXY_ADDR="$(echo "$PROXY_ADDR" | tr 'A-Z' 'a-z')"
    NEW_IMPL="$(echo "$NEW_IMPL"     | tr 'A-Z' 'a-z')"

    # Preserve the existing proxyAddress sanity-check.
    SAVED_PROXY=$(jq -r '.proxyAddress' "$OUT_FILE")
    if [ "$SAVED_PROXY" != "$PROXY_ADDR" ]; then
        echo "error: upgrade tx targets $PROXY_ADDR but saved artifact has proxyAddress=$SAVED_PROXY" >&2
        echo "       refusing to overwrite -- inspect manually" >&2
        exit 1
    fi

    IMPL_ADDR="$NEW_IMPL"
    PROXY="$PROXY_ADDR"
else
    # ── Initial deploy path ──────────────────────────────────────────────
    # Two CREATE txs in order: impl, then proxy.
    IMPL_ADDR=$(jq -r '
        [.transactions[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
                          | .contractAddress] | .[0]
    ' "$BROADCAST" | tr 'A-Z' 'a-z')
    PROXY=$(jq -r '
        [.transactions[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
                          | .contractAddress] | .[1]
    ' "$BROADCAST" | tr 'A-Z' 'a-z')
    DEPLOY_BLOCK_HEX=$(jq -r '.receipts[1].blockNumber' "$BROADCAST")
    DEPLOY_BLOCK=$(printf '%d' "$DEPLOY_BLOCK_HEX")
    DEPLOY_TX=$(jq -r '.receipts[1].transactionHash' "$BROADCAST")
    TIMESTAMP=$(jq -r '.timestamp' "$BROADCAST")

    if [ -z "$IMPL_ADDR" ] || [ "$IMPL_ADDR" = "null" ]; then
        echo "error: could not parse impl address from $BROADCAST" >&2
        exit 1
    fi
    if [ -z "$PROXY" ] || [ "$PROXY" = "null" ]; then
        echo "error: could not parse proxy address from $BROADCAST" >&2
        exit 1
    fi
fi

# ─── Compute implBytecodeHash ────────────────────────────────────────────
# ALWAYS hash the on-chain bytecode (via cast code), not the build artifact's
# deployedBytecode. Reason: UUPS impls have at least one `address immutable`
# field (UUPSUpgradeable.__self) whose value is the impl's own deploy address,
# inlined into the bytecode at constructor time. So two impls compiled from
# the SAME source but deployed at DIFFERENT addresses have DIFFERENT runtime
# bytecode. Hashing on-chain code captures the actually-deployed reality at
# this address; the upgrade-safety check at check-upgrade-safety.sh then
# verifies that the same on-chain bytes are still there at upgrade time.
#
# The RPC URL must be reachable. For mainnet use RSK_RPC; the script also
# accepts RPC_URL or, as a last resort, falls back to the foundry default.

RPC="${RSK_RPC:-${RPC_URL:-${ETH_RPC_URL:-http://localhost:8545}}}"

IMPL_CODE=$(cast code "$IMPL_ADDR" --rpc-url "$RPC" 2>&1 || true)
if [ -z "$IMPL_CODE" ] || [ "$IMPL_CODE" = "0x" ] || [[ "$IMPL_CODE" == *"error"* ]]; then
    echo "error: failed to fetch impl bytecode at $IMPL_ADDR via $RPC" >&2
    echo "       output: $IMPL_CODE" >&2
    exit 1
fi
IMPL_HASH=$(cast keccak "$IMPL_CODE")

# ─── Compose the deployment artifact JSON ────────────────────────────────
# Use jq to construct the object so abi + storageLayout get embedded as
# nested JSON (not stringified) and the field order stays stable for diff.

jq -n \
    --arg contractName     "$CONTRACT" \
    --argjson chainId      "$CHAIN_ID" \
    --arg proxyAddress     "$PROXY" \
    --arg implAddress      "$IMPL_ADDR" \
    --arg implBytecodeHash "$IMPL_HASH" \
    --argjson deploymentBlock "$DEPLOY_BLOCK" \
    --arg deploymentTx     "$DEPLOY_TX" \
    --argjson timestamp    "$TIMESTAMP" \
    --arg gitSha           "$GIT_SHA" \
    --slurpfile abi "$BUILD_ARTIFACT" \
    '{
        contractName:     $contractName,
        chainId:          $chainId,
        proxyAddress:     $proxyAddress,
        implAddress:      $implAddress,
        implBytecodeHash: $implBytecodeHash,
        deploymentBlock:  $deploymentBlock,
        deploymentTx:     $deploymentTx,
        timestamp:        $timestamp,
        gitSha:           $gitSha,
        abi:              $abi[0].abi,
        storageLayout:    $abi[0].storageLayout
    }' > "$OUT_FILE"

echo "Wrote $OUT_FILE"
echo "  proxy:    $PROXY"
echo "  impl:     $IMPL_ADDR"
echo "  bytecode: $IMPL_HASH"
echo "  block:    $DEPLOY_BLOCK"
echo "  tx:       $DEPLOY_TX"
echo "  gitSha:   $GIT_SHA"
