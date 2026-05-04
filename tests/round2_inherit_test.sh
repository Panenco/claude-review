#!/usr/bin/env bash
set -uo pipefail

# round2_inherit_test.sh — fixture test for round-2 smoke-gate inheritance
# in build-review.sh. Mirrors the inline SMOKE_OK + persistence logic with
# the same shape, then asserts behavior across the cases Cursor + Aikido
# flagged on PR #26:
#
#   - planner deliberately chose skip + prior PASS  → inherit + persist
#   - degraded mode (planner wanted functional, tester didn't run) + prior PASS  → DO NOT inherit
#   - tester crashed (FUNCTIONAL_OK=0) + synthetic placeholder + prior PASS  → DO NOT inherit, DO NOT persist PASS
#   - tester ran successfully  → no inherit needed, persist real result
#   - fresh round 1 + tester ran  → persist real result, no inheritance possible
#   - prior FAIL + planner chose skip  → DO NOT inherit
#
# No LLM key required.

cd "$(dirname "$0")/.."

fail=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — want '$want', got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# decide_smoke <FUNCTIONAL_OK> <FUNCTIONAL_STRATEGY> <FUNCTIONAL_OVERALL> \
#              <PLANNED_STRATEGY> <PRIOR_FUNCTIONAL_OVERALL>
# Echoes "<SMOKE_OK> <SMOKE_INHERITED>". Mirrors build-review.sh:534-563.
decide_smoke() {
  local FUNCTIONAL_OK="$1"
  local FUNCTIONAL_STRATEGY="$2"
  local FUNCTIONAL_OVERALL="$3"
  local PLANNED_STRATEGY="$4"
  local PRIOR_FUNCTIONAL_OVERALL="$5"
  local SMOKE_OK=false
  local SMOKE_INHERITED=false
  if [ "${FUNCTIONAL_OK:-1}" -ne 1 ]; then
    :
  elif [ "$FUNCTIONAL_STRATEGY" = "skip" ]; then
    if [ "$PLANNED_STRATEGY" = "skip" ] && { [ "$PRIOR_FUNCTIONAL_OVERALL" = "PASS" ] || [ "$PRIOR_FUNCTIONAL_OVERALL" = "WARN" ]; }; then
      SMOKE_OK=true
      SMOKE_INHERITED=true
    fi
  elif [ "$FUNCTIONAL_OVERALL" = "PASS" ] || [ "$FUNCTIONAL_OVERALL" = "WARN" ]; then
    SMOKE_OK=true
  fi
  echo "$SMOKE_OK $SMOKE_INHERITED"
}

# decide_persist <SMOKE_INHERITED> <FUNCTIONAL_OK> <FUNCTIONAL_STRATEGY> \
#                <FUNCTIONAL_OVERALL> <PRIOR_FUNCTIONAL_STRATEGY> <PRIOR_FUNCTIONAL_OVERALL>
# Echoes "<PERSISTED_OVERALL>|<PERSISTED_STRATEGY>". Mirrors build-review.sh:1041-1063.
decide_persist() {
  local SMOKE_INHERITED="$1"
  local FUNCTIONAL_OK="$2"
  local FUNCTIONAL_STRATEGY="$3"
  local FUNCTIONAL_OVERALL="$4"
  local PRIOR_FUNCTIONAL_STRATEGY="$5"
  local PRIOR_FUNCTIONAL_OVERALL="$6"
  local PERSISTED_OVERALL=""
  local PERSISTED_STRATEGY=""
  if [ "$SMOKE_INHERITED" = "true" ]; then
    PERSISTED_OVERALL="$PRIOR_FUNCTIONAL_OVERALL"
    PERSISTED_STRATEGY="$PRIOR_FUNCTIONAL_STRATEGY"
  elif [ "${FUNCTIONAL_OK:-1}" -eq 1 ] && [ "$FUNCTIONAL_STRATEGY" != "skip" ]; then
    PERSISTED_OVERALL="$FUNCTIONAL_OVERALL"
    PERSISTED_STRATEGY="$FUNCTIONAL_STRATEGY"
  fi
  echo "${PERSISTED_OVERALL}|${PERSISTED_STRATEGY}"
}

echo "── Smoke gate decision ──"

# Case A: round-2 planner chose skip + prior PASS → inherit
assert_eq "A: planner-skip + prior PASS" \
  "true true" \
  "$(decide_smoke 1 skip PASS skip PASS)"

# Case B: round-2 planner chose skip + prior WARN → inherit
assert_eq "B: planner-skip + prior WARN" \
  "true true" \
  "$(decide_smoke 1 skip PASS skip WARN)"

# Case C: degraded mode (planner wanted functional, tester didn't launch)
#         + prior PASS → DO NOT inherit (Aikido finding)
assert_eq "C: degraded-mode + prior PASS — must NOT inherit" \
  "false false" \
  "$(decide_smoke 1 skip PASS functional PASS)"

# Case D: tester crashed (FUNCTIONAL_OK=0) + synthetic placeholder
#         + prior PASS → first branch catches crash, no inherit
assert_eq "D: tester-crashed + prior PASS — must NOT inherit" \
  "false false" \
  "$(decide_smoke 0 skip PASS functional PASS)"

# Case E: planner-chose-skip + prior FAIL → no inherit (FAIL not in PASS/WARN)
assert_eq "E: planner-skip + prior FAIL — must NOT inherit" \
  "false false" \
  "$(decide_smoke 1 skip PASS skip FAIL)"

# Case F: planner-chose-skip + no prior (round 1 docs PR) → no inherit
assert_eq "F: planner-skip + no prior — must NOT inherit" \
  "false false" \
  "$(decide_smoke 1 skip PASS skip "")"

# Case G: tester ran successfully + functional PASS → SMOKE_OK without inherit
assert_eq "G: functional PASS — pass without inheritance" \
  "true false" \
  "$(decide_smoke 1 functional PASS functional "")"

# Case H: tester ran with WARN → also passes the gate
assert_eq "H: functional WARN — pass without inheritance" \
  "true false" \
  "$(decide_smoke 1 functional WARN functional "")"

# Case I: tester ran with FAIL → fail
assert_eq "I: functional FAIL — gate fails" \
  "false false" \
  "$(decide_smoke 1 functional FAIL functional "")"

# Case J: pipeline-self-test PASS → pass without inheritance
assert_eq "J: pipeline-self-test PASS" \
  "true false" \
  "$(decide_smoke 1 pipeline-self-test PASS pipeline-self-test "")"

echo
echo "── Persistence decision ──"

# Case K: real functional PASS → persist actual values
assert_eq "K: real run — persist actual" \
  "PASS|functional" \
  "$(decide_persist false 1 functional PASS "" "")"

# Case L: real functional FAIL → persist FAIL (next round won't inherit, but verdict gate uses it)
assert_eq "L: real FAIL — persist FAIL" \
  "FAIL|functional" \
  "$(decide_persist false 1 functional FAIL "" "")"

# Case M: tester crashed + synthetic placeholder → persist EMPTY (Cursor finding)
assert_eq "M: crashed — must NOT persist synthetic PASS" \
  "|" \
  "$(decide_persist false 0 skip PASS "" "")"

# Case N: degraded mode + synthetic placeholder → persist EMPTY (Cursor finding)
assert_eq "N: degraded mode — must NOT persist synthetic PASS" \
  "|" \
  "$(decide_persist false 1 skip PASS "" "")"

# Case O: planner deliberately chose skip + no inheritance → persist EMPTY
#         (so the next round can't claim inherited evidence from a skip placeholder)
assert_eq "O: planner-skip without inherit — persist EMPTY" \
  "|" \
  "$(decide_persist false 1 skip PASS "" "")"

# Case P: SMOKE_INHERITED=true → carry inherited values forward (chain)
assert_eq "P: inherited — carry prior forward" \
  "PASS|functional" \
  "$(decide_persist true 1 skip PASS functional PASS)"

# Case Q: SMOKE_INHERITED=true with prior WARN → carry WARN forward
assert_eq "Q: inherited WARN — carry WARN forward" \
  "WARN|quick" \
  "$(decide_persist true 1 skip PASS quick WARN)"

# Case R: pipeline-self-test PASS → persist actual
assert_eq "R: pipeline-self-test — persist actual" \
  "PASS|pipeline-self-test" \
  "$(decide_persist false 1 pipeline-self-test PASS "" "")"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASSED: all assertions"
  exit 0
else
  echo "FAILED: $fail assertion(s)"
  exit 1
fi
