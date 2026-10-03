#!/usr/bin/env bash
# Deep fuzz / invariant / Echidna campaign at release-gate counts. Not CI: the
# unit suite gates every push; this gates a release. Expect hours, not minutes.
#
#   tools/release-gates.sh [output-dir] [phase]
#     output-dir  default /tmp/perimeter-release-gates
#     phase       all (default) | foundry | echidna | reach
#
# Everything the run produces is written under the output directory, which is
# outside the repo by default, so a campaign can never leave the tree dirty.
#
# A phase that produces no verdict is a FAILED gate, not a quiet one: each phase
# reports its exit code, and the script exits non-zero if any phase did not
# print a result. A gate that skips half its work in silence is worse than no
# gate at all. Two ways an Echidna phase can look green without being green are
# checked explicitly: a campaign truncated by its wall clock reports every
# un-falsified property as "passing" and exits 0, so the phase fails unless the
# log's `Total calls` reached the requested test limit; and a shrunk property
# set would satisfy a "some property passed" check, so the phase asserts the
# exact number of passing properties the harness source declares.
#
# The `reach` phase is the non-vacuity gate. Every operator-lever property is a
# "this never happened" assertion, which a campaign that never enters the
# guarded path satisfies for free. EchidnaExitDelayQueueReach inherits them all
# and adds one property that holds until every lever has been driven, so a
# healthy run must report THAT property falsified while every inherited property
# passes. A run in which it stays passing means the campaign never reached the
# guarded paths, and the gate fails.
#
# The reach phase certifies the property phase only if both campaigns have the
# same shape, so both read ECHIDNA_SEQ_LEN and ECHIDNA_LIMIT below. Echidna's
# property mode resets state between sequences, so the sequence length decides
# what a single run can reach; a reachability run at a different length would
# say nothing about the campaign that ships.
set -euo pipefail
cd "$(dirname "$0")/.."
export TZ=UTC
# Discovery and execution must cover the same complete default-profile suite,
# regardless of test filters left in the operator's shell.
unset FOUNDRY_MATCH_TEST FOUNDRY_NO_MATCH_TEST FOUNDRY_MATCH_CONTRACT FOUNDRY_NO_MATCH_CONTRACT
unset FOUNDRY_MATCH_PATH FOUNDRY_NO_MATCH_PATH FOUNDRY_SRC FOUNDRY_TEST FOUNDRY_SCRIPT FOUNDRY_LIBS
unset FOUNDRY_SKIP
export FOUNDRY_PROFILE=default FOUNDRY_CONFIG=foundry.toml

OUT="${1:-/tmp/perimeter-release-gates}"
PHASE="${2:-all}"
mkdir -p "$OUT"

ECHIDNA_LIMIT=500000
ECHIDNA_SEQ_LEN=1000
REACH_PROPERTY=echidna_levers_not_reached

HARNESS=test/echidna/EchidnaExitDelayQueue.sol
REACH_HARNESS=test/echidna/EchidnaExitDelayQueueReach.sol

# Run from an isolated checkout. Include harnesses, configuration and pinned
# dependencies in provenance; a git error or change during a run fails closed.
VERIFIER=tools/verify-release-campaign.py
source_pin=$(python3 "$VERIFIER" snapshot --report "$OUT/source.before.json")
require_clean_src() {
  local current
  current=$(python3 "$VERIFIER" snapshot --report "$OUT/source.after.json")
  if [ "$current" != "$source_pin" ]; then
    echo "release-gates: source/dependency snapshot changed during the run" >&2
    return 1
  fi
}

case "$PHASE" in
  all | foundry | echidna | reach) ;;
  *)
    echo "release-gates: unknown phase '$PHASE' (expected all, foundry, echidna or reach)" >&2
    exit 2
    ;;
esac

foundry_rc="skipped"
echidna_rc="skipped"
reach_rc="skipped"

if [ "$PHASE" = "all" ] || [ "$PHASE" = "foundry" ]; then
  require_clean_src
  forge test --list --json --match-test "(testFuzz_|invariant_)" \
    > "$OUT/foundry-inventory.json" 2> "$OUT/foundry-inventory.log"
  set +e
  FORGE_ALLOW_FAILURE=false FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 FOUNDRY_FUZZ_RUNS=20000 \
    forge test --match-test "(testFuzz_|invariant_)" -vv > "$OUT/foundry.log" 2>&1
  foundry_rc=$?
  set -e
fi

if [ "$PHASE" = "all" ] || [ "$PHASE" = "echidna" ]; then
  require_clean_src
  # --timeout overrides the yaml's 300s wall clock, which the quick run wants and
  # a 500k-call campaign would hit long before its test limit. A timed-out
  # Echidna prints every un-falsified property as "passing", so leaving the
  # short timeout in place would turn a truncated run into a green gate.
  set +e
  # --corpus-dir: clear it whenever the harness changes. A corpus recorded
  # against older bytecode replays call sequences chosen for a different
  # contract and biases where the next campaign spends its calls.
  echidna . --contract EchidnaExitDelayQueue --config test/echidna/echidna.yaml \
    --test-limit "$ECHIDNA_LIMIT" --seq-len "$ECHIDNA_SEQ_LEN" --timeout 7200 \
    --corpus-dir "$OUT/corpus" \
    --crytic-args --foundry-compile-all > "$OUT/echidna.log" 2>&1
  echidna_rc=$?
  set -e
fi

if [ "$PHASE" = "all" ] || [ "$PHASE" = "reach" ]; then
  require_clean_src
  # The reach harness gets its own corpus directory: it is a different contract,
  # and replaying the main harness's sequences against it would be replaying
  # sequences chosen for other bytecode.
  # Same test limit and sequence length as the property phase: the reach run is
  # that campaign's own shape, carrying one extra property. --shrink-limit is
  # held down because the falsification IS the result here; a minimal
  # counterexample sequence adds nothing and shrinking a long one is slow.
  set +e
  echidna . --contract EchidnaExitDelayQueueReach --config test/echidna/echidna.yaml \
    --test-limit "$ECHIDNA_LIMIT" --seq-len "$ECHIDNA_SEQ_LEN" --timeout 7200 \
    --shrink-limit 100 --corpus-dir "$OUT/corpus-reach" \
    --crytic-args --foundry-compile-all > "$OUT/reach.log" 2>&1
  reach_rc=$?
  set -e
fi

gate_failed=0

if [ "$foundry_rc" != "skipped" ]; then
  echo "── foundry (exit $foundry_rc) ──"
  grep -E "Suite result|FAIL" "$OUT/foundry.log" | tail -6 || echo "  no summary lines in $OUT/foundry.log"
  if ! python3 "$VERIFIER" foundry --exit-code "$foundry_rc" --log "$OUT/foundry.log" \
      --inventory "$OUT/foundry-inventory.json" --report "$OUT/foundry.verdict.json"; then
    echo "release-gates: Foundry inventory/counts/status did not meet the requested campaign" >&2
    gate_failed=1
  fi
fi

if [ "$echidna_rc" != "skipped" ]; then
  echo "── echidna (exit $echidna_rc) ──"
  grep -E "passing|failed!|falsified" "$OUT/echidna.log" | tail -12 \
    || echo "  no summary lines in $OUT/echidna.log"
  # Every declared property must pass and none may fail: this is the campaign
  # the release is certified on.
  if ! python3 "$VERIFIER" echidna --exit-code "$echidna_rc" --log "$OUT/echidna.log" \
      --harness "$HARNESS" --limit "$ECHIDNA_LIMIT" --report "$OUT/echidna.verdict.json"; then
    echo "release-gates: the Echidna phase did not produce a clean verdict (exit $echidna_rc)" >&2
    gate_failed=1
  fi
fi

if [ "$reach_rc" != "skipped" ]; then
  echo "── reach (exit $reach_rc) ──"
  grep -E "passing|failed!|falsified" "$OUT/reach.log" | tail -12 \
    || echo "  no summary lines in $OUT/reach.log"
  # Inverted expectation: the inherited properties pass, and the one reach
  # property MUST be falsified. Echidna exits non-zero on a falsified property,
  # so here a zero exit code is itself the failure mode.
  if ! python3 "$VERIFIER" echidna --exit-code "$reach_rc" --log "$OUT/reach.log" \
      --harness "$HARNESS" --harness "$REACH_HARNESS" --failure "$REACH_PROPERTY" \
      --limit "$ECHIDNA_LIMIT" --report "$OUT/reach.verdict.json"; then
    echo "release-gates: the reach phase did not prove the campaign is non-vacuous (exit $reach_rc)" >&2
    gate_failed=1
  fi
fi

# The campaign writes only under "$OUT" and into git-ignored build directories.
# Say so out loud, so a dirty tree after a release gate is never a mystery.
if ! require_clean_src; then gate_failed=1; fi

exit "$gate_failed"
