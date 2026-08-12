#!/usr/bin/env bash
#
# Regression test for tools/check-upgrade-safety.sh.
#
# Runs the safety check in two scenarios:
#
#   1. Identity case (candidate == saved impl, source unchanged):
#      Must exit 0. Proves the check doesn't reject benign no-op upgrades.
#
#   2. Negative case (test/fixtures/BadV2.sol):
#      BadV2 adds a state variable AFTER the saved namespace's __gap. The
#      check must reject this with non-zero exit. Proves the gap-rule
#      enforcement actually catches an upgrade that adds storage outside
#      the reclaimed __gap region.
#
# Requires: a running RPC at $RSK_RPC with vault + controller already
# deployed and finalized (run via the steps in the README's Deploy flow,
# OR via the snippets below).
#
# Exit codes:
#   0 both scenarios match expectations
#   1 either scenario failed expectations
#   2 missing prerequisite
#
set -euo pipefail
cd "$(dirname "$0")/.."

for cmd in jq cast forge anvil; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: $cmd is required" >&2
        exit 2
    fi
done

# Spin up an isolated anvil so this test is hermetic.
ANVIL_PORT="${ANVIL_PORT:-8548}"
RPC="http://localhost:$ANVIL_PORT"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

cleanup() {
    if [ -n "${ANVIL_PID:-}" ]; then
        kill "$ANVIL_PID" 2>/dev/null || true
    fi
    if [ -f /tmp/test-upgrade-safety-orig-ctrl.json ]; then
        cp /tmp/test-upgrade-safety-orig-ctrl.json out/ExitFeeController.sol/ExitFeeController.json
        rm -f /tmp/test-upgrade-safety-orig-ctrl.json
    fi
}
trap cleanup EXIT

anvil --port "$ANVIL_PORT" --silent > /tmp/test-upgrade-safety-anvil.log 2>&1 &
ANVIL_PID=$!
sleep 2

# Make sure forge build has run (so out/ artifacts exist) and BadV2 is built.
forge build > /dev/null

echo "── deploying vault + controller to localhost:$ANVIL_PORT ─────────────"
EXIT_FEE_VAULT_ADMIN=$ADMIN \
    forge script script/01_DeployVault.s.sol --rpc-url "$RPC" --broadcast --private-key $PK > /dev/null 2>&1
RSK_RPC=$RPC tools/finalize-deployment.sh ExitFeeVault 01_DeployVault 31337 > /dev/null
EXIT_FEE_CONTROLLER_ADMIN=$ADMIN \
    forge script script/03_DeployController.s.sol --rpc-url "$RPC" --broadcast --private-key $PK > /dev/null 2>&1
RSK_RPC=$RPC tools/finalize-deployment.sh ExitFeeController 03_DeployController 31337 > /dev/null

# ─── Scenario 1: identity case ───────────────────────────────────────────
echo "── 1) identity case (candidate == saved impl) ─────────────────────"
SAVED_CTRL=$(jq -r '.implAddress' deployments/31337/ExitFeeController.json)
set +e
RSK_RPC=$RPC tools/check-upgrade-safety.sh ExitFeeController 31337 "$SAVED_CTRL" > /tmp/test-upgrade-safety-1.log 2>&1
EXIT_1=$?
set -e
if [ "$EXIT_1" -ne 0 ]; then
    echo "    FAIL: identity case exited $EXIT_1 (expected 0)" >&2
    tail -20 /tmp/test-upgrade-safety-1.log >&2
    exit 1
fi
echo "    ok (exit 0)"

# Helper: run the safety check with a bad layout swapped in, assert it fails
# with a specific error message.
run_negative_test() {
    local scenario_name="$1"
    local bad_artifact="$2"
    local expected_error_substring="$3"
    local logfile
    logfile=$(mktemp)

    if ! jq -e '.storageLayout' "$bad_artifact" > /dev/null 2>&1; then
        echo "    SKIP: $bad_artifact missing or has no storageLayout (forge build didn't pick up the fixture?)" >&2
        return 1
    fi

    # Substitute the bad layout into the controller's build artifact.
    jq --slurpfile bad "$bad_artifact" \
        '.storageLayout = $bad[0].storageLayout' \
        /tmp/test-upgrade-safety-orig-ctrl.json \
        > out/ExitFeeController.sol/ExitFeeController.json

    set +e
    RSK_RPC=$RPC tools/check-upgrade-safety.sh ExitFeeController 31337 "$SAVED_CTRL" > "$logfile" 2>&1
    local exit_code=$?
    set -e

    if [ "$exit_code" -eq 0 ]; then
        echo "    FAIL: $scenario_name exited 0 (expected non-zero)." >&2
        echo "          Script accepted an unsafe upgrade." >&2
        tail -25 "$logfile" >&2
        rm -f "$logfile"
        return 1
    fi
    if ! grep -q "$expected_error_substring" "$logfile"; then
        echo "    FAIL: $scenario_name rejected but for the wrong reason." >&2
        echo "          Expected error to contain: $expected_error_substring" >&2
        tail -25 "$logfile" >&2
        rm -f "$logfile"
        return 1
    fi

    echo "    ok (exit $exit_code, rejected with expected error)"
    rm -f "$logfile"
}

# Helper: run safety check with a SAFE candidate layout swapped in, assert
# it exits 0.
run_positive_test() {
    local scenario_name="$1"
    local good_artifact="$2"
    local logfile
    logfile=$(mktemp)

    if ! jq -e '.storageLayout' "$good_artifact" > /dev/null 2>&1; then
        echo "    SKIP: $good_artifact missing or has no storageLayout" >&2
        return 1
    fi

    jq --slurpfile good "$good_artifact" \
        '.storageLayout = $good[0].storageLayout' \
        /tmp/test-upgrade-safety-orig-ctrl.json \
        > out/ExitFeeController.sol/ExitFeeController.json

    set +e
    RSK_RPC=$RPC tools/check-upgrade-safety.sh ExitFeeController 31337 "$SAVED_CTRL" > "$logfile" 2>&1
    local exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        echo "    FAIL: $scenario_name exited $exit_code (expected 0)." >&2
        echo "          Script rejected a SAFE upgrade." >&2
        tail -25 "$logfile" >&2
        rm -f "$logfile"
        return 1
    fi
    echo "    ok (exit 0)"
    rm -f "$logfile"
}

# Save original controller artifact ONCE; scenarios swap layouts into
# out/ExitFeeController.sol/ExitFeeController.json and the trap restores.
cp out/ExitFeeController.sol/ExitFeeController.json /tmp/test-upgrade-safety-orig-ctrl.json

echo "── 2) positive: GoodPackedV2 adds two packed uint128 fields ─────────"
run_positive_test "GoodPackedV2" out/GoodPackedV2.sol/GoodPackedV2.json

echo "── 3) negative: BadV2 adds storage outside saved namespace ──────────"
run_negative_test "BadV2" out/BadV2.sol/BadV2.json "outside any saved __gap range"

echo "── 4) negative: BadV3 reorders RatePolicy struct members ────────────"
run_negative_test "BadV3" out/BadV3.sol/BadV3.json "shifted or changed shape"

echo
echo "All upgrade-safety scenarios passed."
