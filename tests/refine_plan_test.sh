#!/usr/bin/env bash
set -uo pipefail

# refine_plan_test.sh — fixture test for scripts/refine-review-plan.sh.
#
# Round-2 plan refinement is a pure function of (full-PR plan, prior state
# fields, since-last file shape, labels) — no git, no network. The workflow
# computes those inputs; this test feeds them via env and asserts the
# emitted plan, same harness style as review_plan_test.sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/refine-review-plan.sh"
fail=0

summary_of() {
  env "$@" bash "$SCRIPT" | awk -F= '
    /^review_level=/ {lvl=$2}
    /^run_functional=/{fn=$2}
    /^gate=/         {g=$2}
    END {print lvl, fn, g}'
}

assert_plan() {
  local label="$1" want="$2"; shift 2
  local got; got=$(summary_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

reason_of() {
  env "$@" bash "$SCRIPT" | grep '^reason=' | cut -d= -f2-
}

# Full-PR plan for a big normal PR, reused below.
BIG_ORIG=(ORIG_LEVEL=full ORIG_FUNCTIONAL=true ORIG_GATE=normal ORIG_REASON="Eligible for full review")

# ── round 1 / prior unavailable → passthrough ──
assert_plan "round 1 passes the full-PR plan through" "full true normal" \
  ROUND2_AVAILABLE=false "${BIG_ORIG[@]}" \
  SINCE_FILES_TSV=$'src/a.ts\t10\t2'

# ── full-PR plan already at the floor → passthrough ──
assert_plan "orig light (small PR) stays light" "light true small" \
  ROUND2_AVAILABLE=true ORIG_LEVEL=light ORIG_FUNCTIONAL=true ORIG_GATE=small ORIG_REASON=r \
  SINCE_FILES_TSV=$'src/a.ts\t10\t2'
assert_plan "orig skip (label) stays skip" "skip false label" \
  ROUND2_AVAILABLE=true ORIG_LEVEL=skip ORIG_FUNCTIONAL=false ORIG_GATE=label ORIG_REASON=r \
  SINCE_FILES_TSV=$'src/a.ts\t10\t2'

# ── deep-review label → keep the full-PR plan every round ──
assert_plan "deep-review label keeps full" "full true normal" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" GATE_LABELS=$'deep-review' \
  SINCE_FILES_TSV=$'src/a.ts\t3\t1'

# ── empty since-last (same-SHA re-run) → light, no functional ──
assert_plan "empty since-last → light re-check" "light false small" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" SINCE_FILES_TSV=

# ── small follow-up on a big PR → light + quick functional ──
assert_plan "small since-last on big PR → light" "light true small" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL=full \
  SINCE_FILES_TSV=$'src/fix.ts\t40\t5'

# ── big or sensitive since-last keeps the full fan ──
assert_plan "large since-last stays full" "full true normal" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL=full \
  SINCE_FILES_TSV=$'src/big.ts\t300\t101'
assert_plan "sensitive since-last forces full" "full true normal" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL=full \
  SINCE_FILES_TSV=$'src/payments/charge.ts\t8\t1'

# ── skip label re-applies via the resolver on round 2 ──
assert_plan "skip-review label on round 2 → skip" "skip false label" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" GATE_LABELS=$'skip-review' \
  SINCE_FILES_TSV=$'src/a.ts\t10\t2'

# ── escalation: PR warrants full but no prior round ran one ──
assert_plan "prior round was light → escalate to full-PR plan" "full true normal" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL=light \
  SINCE_FILES_TSV=$'src/fix.ts\t40\t5'
# Pre-tiering state files have no review_level — treat as full (no escalation).
assert_plan "missing PRIOR_LEVEL treated as full" "light true small" \
  ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL= \
  SINCE_FILES_TSV=$'src/fix.ts\t40\t5'

# ── reason strings name the round-2 scoping ──
R=$(reason_of ROUND2_AVAILABLE=true "${BIG_ORIG[@]}" PRIOR_LEVEL=full SINCE_FILES_TSV=$'src/fix.ts\t40\t5')
case "$R" in
  "Round 2, planned on the diff since the last review:"*) echo "OK:   refined reason carries the round-2 prefix" ;;
  *) echo "FAIL: refined reason missing round-2 prefix — got '$R'"; fail=$((fail + 1)) ;;
esac

if [ "$fail" -eq 0 ]; then
  echo
  echo "All refine-plan tests passed."
  exit 0
else
  echo
  echo "$fail refine-plan test assertion(s) failed."
  exit 1
fi
