#!/usr/bin/env bash
# Deep fuzz / invariant / Echidna campaign at release-gate counts. Not CI: the
# unit suite gates every push; this gates a release. Expect hours, not minutes.
#
#   tools/release-gates.sh [output-dir] [phase]
#     output-dir  default /tmp/perimeter-release-gates
#     phase       all (default) | foundry | echidna
#
# Everything the run produces is written under the output directory, which is
# outside the repo by default, so a campaign can never leave the tree dirty.
#
# A phase that produces no verdict is a FAILED gate, not a quiet one: each phase
# reports its exit code, and the script exits non-zero if either phase did not
# print a result. A gate that skips half its work in silence is worse than no
# gate at all.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/perimeter-release-gates}"
PHASE="${2:-all}"
mkdir -p "$OUT"

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

foundry_rc="skipped"
echidna_rc="skipped"

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
  echidna . --contract EchidnaExitDelayQueue --config test/echidna/echidna.yaml \
    --test-limit 500000 --timeout 7200 --corpus-dir "$OUT/corpus" \
    --crytic-args --foundry-compile-all > "$OUT/echidna.log" 2>&1
  echidna_rc=$?
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
  if [ "$echidna_rc" -ne 0 ] || ! grep -qE "^echidna_[A-Za-z0-9_]+: (passing|failed)" "$OUT/echidna.log"; then
    echo "release-gates: the Echidna phase produced no verdict (exit $echidna_rc)" >&2
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
