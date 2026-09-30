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

OUT="${1:-/tmp/perimeter-release-gates}"
PHASE="${2:-all}"
mkdir -p "$OUT"

ECHIDNA_LIMIT=500000
ECHIDNA_SEQ_LEN=1000
REACH_PROPERTY=echidna_levers_not_reached

HARNESS=test/echidna/EchidnaExitDelayQueue.sol
REACH_HARNESS=test/echidna/EchidnaExitDelayQueueReach.sol

# A release gate is only meaningful against the sources being released. If a
# mutant or a local edit is sitting in src/, wait briefly for it to be restored
# and otherwise refuse to run rather than certify the wrong bytecode.
require_clean_src() {
  local waited=0
  while [ -n "$(git status --porcelain src/)" ]; do
    if [ "$waited" -ge 300 ]; then
      echo "release-gates: src/ still modified after 5 minutes; refusing to run" >&2
      exit 1
    fi
    echo "release-gates: src/ is modified, waiting for a clean tree…" >&2
    sleep 30
    waited=$((waited + 30))
  done
}

# How many `echidna_` properties a harness source declares. Read from the source
# rather than hard-coded, so deleting a property cannot silently lower the bar
# the gate holds the campaign to.
declared_properties() {
  grep -cE '^[[:space:]]*function echidna_[A-Za-z0-9_]+\(' "$1"
}

# Verdict check shared by both Echidna phases: the campaign ran to its test
# limit, the expected number of properties passed, and exactly the expected
# number failed. `$5`, when set, names the property that MUST be among the
# failures.
check_echidna_log() {
  local log="$1" limit="$2" want_pass="$3" want_fail="$4" must_fail="${5:-}"
  local ok=0

  local calls
  calls=$(sed -n 's/^Total calls: \([0-9][0-9]*\).*/\1/p' "$log" | tail -1)
  if [ -z "$calls" ]; then
    echo "release-gates: no 'Total calls' line in $log — the campaign did not finish" >&2
    ok=1
  elif [ "$calls" -lt "$limit" ]; then
    echo "release-gates: campaign stopped at $calls calls, short of the $limit requested" >&2
    echo "release-gates: a truncated Echidna run reports every un-falsified property as" >&2
    echo "release-gates: passing, so this is a failed gate, not a green one" >&2
    ok=1
  else
    echo "  Total calls: $calls (requested $limit)"
  fi

  local passed failed
  passed=$(grep -cE '^echidna_[A-Za-z0-9_]+: passing' "$log" || true)
  failed=$(grep -cE '^echidna_[A-Za-z0-9_]+: (failed|FAILED)' "$log" || true)
  echo "  properties: $passed passing (expected $want_pass), $failed failed (expected $want_fail)"
  if [ "$passed" -ne "$want_pass" ] || [ "$failed" -ne "$want_fail" ]; then
    echo "release-gates: property verdict count does not match the harness source" >&2
    ok=1
  fi

  if [ -n "$must_fail" ] && ! grep -qE "^${must_fail}: (failed|FAILED)" "$log"; then
    echo "release-gates: $must_fail was not falsified — the campaign never reached the" >&2
    echo "release-gates: guarded paths the other properties are about, so they passed" >&2
    echo "release-gates: vacuously and certify nothing" >&2
    ok=1
  fi

  return "$ok"
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
  set +e
  FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 FOUNDRY_FUZZ_RUNS=20000 \
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
  if [ "$foundry_rc" -ne 0 ] || ! grep -q "test suites" "$OUT/foundry.log"; then
    echo "release-gates: the Foundry phase produced no verdict (exit $foundry_rc)" >&2
    gate_failed=1
  fi
fi

if [ "$echidna_rc" != "skipped" ]; then
  echo "── echidna (exit $echidna_rc) ──"
  grep -E "passing|failed!|falsified" "$OUT/echidna.log" | tail -12 \
    || echo "  no summary lines in $OUT/echidna.log"
  # Every declared property must pass and none may fail: this is the campaign
  # the release is certified on.
  if [ "$echidna_rc" -ne 0 ] \
    || ! check_echidna_log "$OUT/echidna.log" "$ECHIDNA_LIMIT" "$(declared_properties "$HARNESS")" 0; then
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
  if [ "$reach_rc" -eq 0 ] \
    || ! check_echidna_log "$OUT/reach.log" "$ECHIDNA_LIMIT" \
      "$(declared_properties "$HARNESS")" "$(declared_properties "$REACH_HARNESS")" "$REACH_PROPERTY"; then
    echo "release-gates: the reach phase did not prove the campaign is non-vacuous (exit $reach_rc)" >&2
    gate_failed=1
  fi
fi

# The campaign writes only under "$OUT" and into git-ignored build directories.
# Say so out loud, so a dirty tree after a release gate is never a mystery.
if [ -n "$(git status --porcelain)" ]; then
  echo "── working tree is NOT clean after the run ──"
  git status --porcelain
fi

exit "$gate_failed"
