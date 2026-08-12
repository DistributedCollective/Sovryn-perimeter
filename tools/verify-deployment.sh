#!/usr/bin/env bash
#
# Submit the sources of a freshly-deployed (or freshly-upgraded) Perimeter Fee
# contract to the Rootstock Blockscout explorer for verification.
#
# Usage:
#   tools/verify-deployment.sh <ContractName> <ScriptBaseName> <chainId>
#
# Examples (same argument triple as tools/finalize-deployment.sh -- run
# finalize first; this script reads the deployment artifact it writes):
#   tools/verify-deployment.sh ExitFeeVault       01_DeployVault      30
#   tools/verify-deployment.sh ExitFeeController  03_DeployController 30
#   tools/verify-deployment.sh ExitFeeController  99_UpgradeProxy     30
#
# What it verifies:
#   - the implementation, always (address from deployments/<chainId>/<Contract>.json)
#   - the ERC1967Proxy, only when its CREATE is in this script's broadcast log
#     (initial deploys; an upgrade broadcast has no proxy CREATE). Constructor
#     args (impl address + init calldata) are read from the broadcast log and
#     ABI-encoded with cast.
#
# Verifier endpoint by chainId: 30 -> rootstock.blockscout.com,
# 31 -> rootstock-testnet.blockscout.com. Any other chain (or a private
# fork) needs an explicit BLOCKSCOUT_URL, which also overrides the default
# on 30/31. Verification is idempotent: an "already verified" response
# counts as success, so re-running after a partial failure is safe.
#
# Verification failure must never roll back or block a deploy -- the chain
# state is already final. Fix the cause and re-run this script.
#
# Exit codes:
#   0 ok (verified, or already verified)
#   1 input/parse error
#   2 missing prerequisite (forge/jq/cast, artifact, broadcast log, etc.)
#   3 verification rejected by the explorer
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

case "$CHAIN_ID" in
    30) VERIFIER_URL="${BLOCKSCOUT_URL:-https://rootstock.blockscout.com/api}" ;;
    31) VERIFIER_URL="${BLOCKSCOUT_URL:-https://rootstock-testnet.blockscout.com/api}" ;;
    *)
        if [ -z "${BLOCKSCOUT_URL:-}" ]; then
            echo "error: no default explorer for chainId $CHAIN_ID -- set BLOCKSCOUT_URL" >&2
            echo "       (a local fork has no explorer; verification only applies to public chains)" >&2
            exit 2
        fi
        VERIFIER_URL="$BLOCKSCOUT_URL"
        ;;
esac

DEPLOYMENT="deployments/${CHAIN_ID}/${CONTRACT}.json"
BROADCAST="broadcast/${SCRIPT_BASE}.s.sol/${CHAIN_ID}/run-latest.json"
SRC_PATH="src/${CONTRACT}.sol:${CONTRACT}"
PROXY_SRC_PATH="lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

if [ ! -f "$DEPLOYMENT" ]; then
    echo "error: deployment artifact not found at $DEPLOYMENT" >&2
    echo "       (run tools/finalize-deployment.sh first)" >&2
    exit 2
fi
if [ ! -f "$BROADCAST" ]; then
    echo "error: broadcast log not found at $BROADCAST" >&2
    echo "       (did you forge script ... --broadcast first?)" >&2
    exit 2
fi

IMPL_ADDR=$(jq -r '.implAddress' "$DEPLOYMENT")
PROXY_ADDR=$(jq -r '.proxyAddress' "$DEPLOYMENT")
if [ -z "$IMPL_ADDR" ] || [ "$IMPL_ADDR" = "null" ]; then
    echo "error: no implAddress in $DEPLOYMENT" >&2
    exit 1
fi

# verify_one <address> <path:Name> [--constructor-args 0x...]
# Tolerates "already verified" (idempotent re-runs); any other failure is fatal.
verify_one() {
    local addr="$1"; shift
    local target="$1"; shift
    local out
    echo "verifying ${target##*:} at $addr against $VERIFIER_URL ..."
    if out=$(forge verify-contract "$addr" "$target" \
                --verifier blockscout \
                --verifier-url "$VERIFIER_URL" \
                --chain-id "$CHAIN_ID" \
                --watch "$@" 2>&1); then
        echo "$out" | tail -3
    else
        echo "$out" | tail -10
        if echo "$out" | grep -qi "already verified"; then
            echo "=> already verified; treating as success"
        else
            echo "error: explorer rejected verification of ${target##*:} at $addr" >&2
            exit 3
        fi
    fi
}

verify_one "$IMPL_ADDR" "$SRC_PATH"

# The proxy CREATE only exists in initial-deploy broadcasts (01_/03_).
# Match by contractAddress instead of ordinal position so a reordered or
# partially-replayed broadcast cannot pair the wrong constructor args.
PROXY_TX=$(jq -c --arg proxy "$PROXY_ADDR" '
    [.transactions[]
     | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
     | select((.contractAddress | ascii_downcase) == ($proxy | ascii_downcase))]
    | .[0] // empty
' "$BROADCAST")

if [ -n "$PROXY_TX" ]; then
    PROXY_IMPL_ARG=$(echo "$PROXY_TX" | jq -r '.arguments[0]')
    PROXY_INIT_DATA=$(echo "$PROXY_TX" | jq -r '.arguments[1]')
    if [ -z "$PROXY_IMPL_ARG" ] || [ "$PROXY_IMPL_ARG" = "null" ] \
       || [ -z "$PROXY_INIT_DATA" ] || [ "$PROXY_INIT_DATA" = "null" ]; then
        echo "error: proxy CREATE in $BROADCAST has no parsable constructor arguments" >&2
        exit 1
    fi
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,bytes)" "$PROXY_IMPL_ARG" "$PROXY_INIT_DATA")
    verify_one "$PROXY_ADDR" "$PROXY_SRC_PATH" --constructor-args "$CONSTRUCTOR_ARGS"
else
    echo "no proxy CREATE in $BROADCAST (upgrade run) -- proxy already verified from its initial deploy"
fi

echo "done: sources for $CONTRACT (chain $CHAIN_ID) submitted to $VERIFIER_URL"
