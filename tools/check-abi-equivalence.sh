#!/usr/bin/env bash
#
# Cross-pragma ABI guard for the ExitFeeController interface.
#
# Two files declare the ExitFeeController ABI surface:
#   src/interfaces/IExitFeeController.sol         (range pragma >=0.5.17 <0.9.0)
#   src/interfaces/v0_4/IExitFeeController.sol    (0.4.26 outlier, AMM)
#
# ── Fee surface vs delay extension ───────────────────────────
# The unified file carries TWO surfaces:
#   * the FEE surface (RatePolicy / ExitFeeQuote / quoteExitFee / policy
#     setters + views + events) — consumed under 0.5.17 (Sovryn-smart),
#     0.6.11 (zero), 0.8.20 (this repo) AND 0.4.26 (AMM); and
#   * the DELAY extension (securityPerimeterEnabled / globalDelaySeconds /
#     admin / bypass tiers / passthrough registry / quoteExitDelay*),
#     added by the Security-Perimeter delay feature.
# The AMM (0.4.26) is DEFERRED and "swaps are never delayed" (spec), so it
# never consumes the delay extension. The `v0_4/` outlier is therefore
# intentionally FEE-ONLY (26 members). The guard's job is to protect the
# fee surface the AMM actually calls — NOT to force ~20 dead delay members
# into a 0.4.26 interface. Check 1 below is accordingly a SUBSET relation:
# every v0_4 member MUST appear byte-for-byte in the unified ABI (fee surface
# matches exactly across pragmas); the unified file MAY carry additional
# (delay) members the outlier omits. A fee-side struct reorder or signature
# drift still fails (the reordered member no longer matches its v0_4 twin).
#
# This script enforces equivalence on three axes that a casual
# `forge inspect ... methodIdentifiers` diff would NOT catch:
#
#   1. Fee-surface ABI shape (SUBSET): every v0_4 member — function
#      inputs/outputs (including struct tuples), event `indexed` flags,
#      `stateMutability`, `anonymous`, and error signatures — must appear
#      identically in the unified ABI. A struct field reorder inside
#      `ExitFeeQuote` would keep function selectors identical (selectors
#      only hash inputs) but break callers decoding the returned tuple, and
#      it breaks the subset match here.
#
#   2. SkipReason enum ordinal order. The ABI encodes the enum as uint8,
#      so `forge inspect` cannot see a reorder. Synthesized skip-reason
#      values on the AMM side would silently become wrong if
#      `CONTROLLER_REVERT` and `VAULT_REVERT` swapped positions.
#
#   3. Per-target-compiler build of the unified file. `auto_detect_solc`
#      picks the highest compatible compiler (currently 0.8.29 for the
#      range pragma), so a 0.8-only syntax change would pass a normal
#      `forge build` while breaking the 0.5.17 / 0.6.11 downstream repos.
#      Each target compiler is invoked explicitly.
#
# Run locally:   tools/check-abi-equivalence.sh
# CI integration: wire as a required step in every PR build.
#
# Exits 0 on equivalence; non-zero with a diff/explanation on mismatch.
#
set -euo pipefail
cd "$(dirname "$0")/.."

UNIFIED="src/interfaces/IExitFeeController.sol"
V0_4="src/interfaces/v0_4/IExitFeeController.sol"
UNIFIED_FQ="$UNIFIED:IExitFeeController"
V0_4_FQ="$V0_4:IExitFeeController"

for cmd in jq forge; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: $cmd is required (foundryup / brew install jq)" >&2
        exit 2
    fi
done

forge build --silent

# ─── 1) Full ABI equivalence ──────────────────────────────────────────────
# Two normalizations are applied before diff:
#
#   - Strip the `internalType` field everywhere (including nested struct
#     components). It's a documentation annotation -- Solc 0.5+ records it
#     as e.g. "struct IExitFeeController.RatePolicy", Solc 0.4.26 omits it
#     entirely; neither version's value is part of the on-wire encoding.
#
#   - Strip top-level parameter `name` (e.g. "surfaceId", "actor"). Those
#     are documentation only, may legitimately differ between files, and
#     do not affect encoding. We do NOT strip struct-component names
#     (e.g. `RatePolicy.active`) -- those are surfaced to callers via
#     typed bindings and a rename can silently break downstream code.
#
# KEEP: type, components[] order, indexed flags, stateMutability, anonymous.
normalize_abi() {
    jq -S 'walk(if type == "object" then del(.internalType) else . end)
           | map(
                if (.type == "function" or .type == "event" or .type == "error" or .type == "constructor") then
                    (if has("inputs")  then .inputs  |= map(del(.name)) else . end)
                    | (if has("outputs") then .outputs |= map(del(.name)) else . end)
                else .
                end
           )'
}

echo "── 1) Fee-surface ABI subset (v0_4 ⊆ unified; exact match per member) ──"
# The v0_4 outlier is the fee-only reference surface. Every one of its
# normalized ABI members MUST appear byte-for-byte in the unified ABI. The
# unified ABI may carry extra (delay) members the outlier omits — those are
# NOT required in v0_4 (AMM never delays). jq computes `v0_4 − unified`
# (set difference on normalized members): a non-empty result is a fee-surface
# mismatch (drift or a struct reorder) and fails the gate.
UNIFIED_ABI=$(forge inspect "$UNIFIED_FQ" abi --json | normalize_abi)
V0_4_ABI=$(forge inspect "$V0_4_FQ" abi --json | normalize_abi)

MISSING=$(jq -n \
    --argjson u "$UNIFIED_ABI" \
    --argjson v "$V0_4_ABI" \
    '$v | map(select( . as $x | ($u | any(. == $x)) | not ))')

if [ "$(echo "$MISSING" | jq 'length')" != "0" ]; then
    echo "    error: v0_4 fee-surface members absent from (or divergent in) the unified ABI:" >&2
    echo "$MISSING" | jq -r '.[] | "        \(.type) \(.name // "(anonymous)")"' >&2
    echo "           Catches: fee function/event/error signature drift, struct tuple" >&2
    echo "           component order, indexed flags, stateMutability, anonymous —" >&2
    echo "           on the surface the 0.4.26 AMM actually consumes." >&2
    echo "           (Delay-extension members legitimately live ONLY in the unified" >&2
    echo "            file; they are NOT required in the v0_4 outlier )" >&2
    exit 1
fi
V0_4_COUNT=$(echo "$V0_4_ABI" | jq 'length')
UNIFIED_COUNT=$(echo "$UNIFIED_ABI" | jq 'length')
echo "    ok ($V0_4_COUNT/$V0_4_COUNT v0_4 fee members matched; unified carries $UNIFIED_COUNT total)"

# ─── 2) SkipReason enum ordinal equivalence ───────────────────────────────
# The ABI shows uint8 only; `forge inspect` cannot see the enum variant order.
# Extract the body between `enum SkipReason {` and `}` from each file, strip
# whitespace/commas/comments, compare line-by-line so a reorder shows up.
extract_skip_reason() {
    awk '
        /^[[:space:]]*enum[[:space:]]+SkipReason[[:space:]]*\{/ { inside = 1; next }
        inside && /\}/ { exit }
        inside {
            line = $0
            sub(/\/\/.*/, "", line)            # strip line comments
            gsub(/[[:space:],]/, "", line)     # strip whitespace + commas
            if (length(line) > 0) print line
        }
    ' "$1"
}

echo "── 2) SkipReason enum ordinal equivalence ────────────────────────────"
UNIFIED_ENUM=$(extract_skip_reason "$UNIFIED")
V0_4_ENUM=$(extract_skip_reason "$V0_4")
if [ "$UNIFIED_ENUM" != "$V0_4_ENUM" ]; then
    echo "    error: SkipReason variant order diverges." >&2
    echo "           ABI cannot detect this (uint8 only); ordinals MUST match." >&2
    echo "    unified:" >&2
    echo "$UNIFIED_ENUM" | sed 's/^/        /' >&2
    echo "    v0_4:" >&2
    echo "$V0_4_ENUM"    | sed 's/^/        /' >&2
    exit 1
fi
COUNT=$(echo "$UNIFIED_ENUM" | wc -l | tr -d ' ')
echo "    ok ($COUNT variants):"
echo "$UNIFIED_ENUM" | nl -ba -s '. ' -w 1 | sed 's/^/        /'

# ─── 3) Per-target-compiler build of the unified interface ────────────────
# auto_detect_solc picks the highest compatible compiler (currently 0.8.x),
# so a 0.8-only syntax change would pass a normal build while breaking the
# 0.5.17 / 0.6.11 downstream consumers. Force each target compiler explicitly.
# Forge's `--skip <FILTER>` is substring-matched, so `--skip ExitFeeController.sol`
# would also catch `IExitFeeController.sol` and `v0_4/IExitFeeController.sol`
# -- exactly the interface files we want to compile here. (Earlier versions of
# this script used --skip and silently NO-OP'd, reporting false positives.)
#
# Pass each target interface as a positional path to forge build: that is
# unambiguous -- forge compiles exactly that file plus its imports, and a
# bad path or compile error produces a non-zero exit code. Drop --silent so
# a future regression that compiles 0 files (e.g. file moved without script
# update) surfaces visibly instead of silently passing.
attempt_build() {
    local solc="$1" file="$2" log
    log=$(mktemp)
    if ! forge build --use "solc:$solc" "$file" > "$log" 2>&1; then
        echo "    error: $file does not compile under solc $solc" >&2
        cat "$log" >&2
        rm -f "$log"
        return 1
    fi
    # Confirm forge actually saw the file. With a positional path it is
    # nearly impossible to silently compile zero files, but emit a clear
    # error if it ever does. Each target compiler logs the language version
    # it used; a successful compile of a real file always produces it.
    if ! grep -qE "Compiling|No files changed, compilation skipped" "$log"; then
        echo "    error: forge produced no compile log under solc $solc -- file may have been skipped" >&2
        cat "$log" >&2
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
}

echo "── 3) Per-target-compiler build of unified interface ─────────────────"
for SOLC in 0.5.17 0.6.11 0.8.20; do
    attempt_build "$SOLC" "$UNIFIED"
    echo "    ok @ solc $SOLC"
done

attempt_build "0.4.26" "$V0_4"
echo "    ok @ solc 0.4.26 (v0_4 outlier)"

echo
echo "ABI equivalence: OK"
