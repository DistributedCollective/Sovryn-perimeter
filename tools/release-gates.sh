#!/usr/bin/env bash
# Deep fuzz / invariant / Echidna campaign at release-gate counts. Not CI: the
# unit suite gates every push; this gates a release. Expect hours, not minutes.
#
#   tools/release-gates.sh [output-dir]        # default /tmp/perimeter-release-gates
#
# Everything the run produces is written under the output directory, which is
# outside the repo by default, so a campaign can never leave the tree dirty.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/perimeter-release-gates}"
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

require_clean_src
FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 FOUNDRY_FUZZ_RUNS=20000 \
  forge test --match-test "(testFuzz_|invariant_)" -vv > "$OUT/foundry.log" 2>&1 || true

require_clean_src
echidna . --contract EchidnaExitDelayQueue --config test/echidna/echidna.yaml \
  --test-limit 500000 --corpus-dir "$OUT/corpus" \
  --crytic-args --foundry-compile-all > "$OUT/echidna.log" 2>&1 || true

echo "── foundry ──"
grep -E "Suite result|passed|failed|FAIL" "$OUT/foundry.log" | tail -5
echo "── echidna ──"
grep -E "passing|failed!|falsified" "$OUT/echidna.log" | tail -10

# The campaign writes only under "$OUT" and into git-ignored build directories.
# Say so out loud, so a dirty tree after a release gate is never a mystery.
if [ -n "$(git status --porcelain)" ]; then
  echo "── working tree is NOT clean after the run ──"
  git status --porcelain
fi
