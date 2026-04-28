#!/usr/bin/env bash
set -uo pipefail

# dedup_test.sh — fixture test for the deterministic glue around the
# Haiku dedup call in build-review.sh. The dedup itself is an LLM call
# and lives in the round-2 STILL_PRESENT drop logic in
# skills/review-dedup.md (which dedup_smoke.sh exercises against the
# live API). Here we only test:
#   1. Resolution-status splits (drives the round-2 body section).
#   2. Verdict-table input (still-present blocker count).
#   3. validate_dedup_output's shape contract.
# No LLM key required.

cd "$(dirname "$0")/.."

RES=tests/fixtures/resolution-status.json
STATE=tests/fixtures/prior-state.json

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

# 1. Resolution-status splits — these jq expressions live verbatim in
#    build-review.sh and feed the "Since previous review" body section.
RESOLVED_LIST=$(jq '[.[] | select(.status == "RESOLVED")]' "$RES")
STILL_PRESENT_LIST=$(jq '[.[] | select(.status == "STILL_PRESENT")]' "$RES")
assert_eq "RESOLVED count"        1 "$(echo "$RESOLVED_LIST" | jq 'length')"
assert_eq "STILL_PRESENT count"   2 "$(echo "$STILL_PRESENT_LIST" | jq 'length')"

# 2. Verdict-table input: STILL_PRESENT_BLOCKERS is derived by id-joining
#    STILL_PRESENT entries against prior-state.findings — NOT from the
#    resolution checker's `prior_severity` field. The verdict gate must
#    not ride on LLM compliance for blocker counts. This jq is the same
#    program as in scripts/build-review.sh.
#    In our fixture both STILL_PRESENT priors (c2, s1) are minor → 0.
STILL_PRESENT_BLOCKERS=$(jq -n \
  --slurpfile state "$STATE" \
  --argjson still "$STILL_PRESENT_LIST" \
  '($still | map(.id)) as $ids
   | ($state[0].findings // [])
   | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
   | length')
assert_eq "Still-present blocker count (both fixture STILL_PRESENT are minor)" 0 "$STILL_PRESENT_BLOCKERS"

# 2b. Same logic, but with a fixture mutation: bump c2 to critical in prior
#     state and confirm the id-join surfaces it as a blocker (regression
#     guard against a future refactor that drops the join).
PROMOTED_STATE=$(jq '.findings |= map(if .id == "c2" then .severity = "critical" else . end)' "$STATE")
STILL_PRESENT_BLOCKERS_PROMOTED=$(jq -n \
  --argjson state "$PROMOTED_STATE" \
  --argjson still "$STILL_PRESENT_LIST" \
  '($still | map(.id)) as $ids
   | ($state.findings // [])
   | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
   | length')
assert_eq "Still-present blocker count (c2 promoted to critical in state)" 1 "$STILL_PRESENT_BLOCKERS_PROMOTED"

# 3. Shape + size validator (mirrors validate_dedup_output in build-review.sh).
#    Drop-all is now ALLOWED — review-dedup.md authorizes it for two
#    cases (all bugbot-exempt, round-2 STILL_PRESENT-overlap). The
#    earlier "reject empty for non-empty" rule was wrong: it caused the
#    fallback to re-post raw findings, re-introducing the duplicates /
#    exempt entries the dedup is meant to filter.
GOOD='[{"id":"x","severity":"minor","path":"a","line_start":1}]'
BAD_NOT_ARRAY='{"id":"x"}'
BAD_MISSING_KEY='[{"id":"x","severity":"minor","path":"a"}]'
INVENTED_ID='[{"id":"never-seen","severity":"minor","path":"a","line_start":1}]'
EMPTY='[]'
NONEMPTY_INPUT='[{"id":"i1","severity":"critical","path":"a","line_start":1}]'

# Single function that mirrors the full build-review.sh validator chain.
validate_dedup() {
  local out="$1" inp="$2"
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -e 'all(type == "object" and has("severity") and has("path") and has("line_start") and has("id"))' >/dev/null 2>&1 || return 1
  local out_len in_len
  out_len=$(printf '%s' "$out" | jq 'length')
  in_len=$(printf '%s' "$inp" | jq 'length')
  [ "$out_len" -le "$in_len" ] || return 1
  printf '%s' "$out" | jq --argjson in "$inp" -e 'all(.id as $id | $in | any(.id == $id))' >/dev/null 2>&1 || return 1
  return 0
}

if validate_dedup "$GOOD" "$GOOD";                   then assert_eq "Valid dedup shape"           0 0; else assert_eq "Valid dedup shape"           0 1; fi
if validate_dedup "$BAD_NOT_ARRAY" "$GOOD";           then assert_eq "Reject non-array"            1 0; else assert_eq "Reject non-array"            1 1; fi
if validate_dedup "$BAD_MISSING_KEY" "$GOOD";         then assert_eq "Reject missing key"          1 0; else assert_eq "Reject missing key"          1 1; fi
if validate_dedup "$EMPTY" "$EMPTY";                  then assert_eq "Accept empty for empty"      0 0; else assert_eq "Accept empty for empty"      0 1; fi
if validate_dedup "$EMPTY" "$NONEMPTY_INPUT";         then assert_eq "Accept drop-all (legit)"     0 0; else assert_eq "Accept drop-all (legit)"     0 1; fi
if validate_dedup "$INVENTED_ID" "$NONEMPTY_INPUT";   then assert_eq "Reject invented id"          1 0; else assert_eq "Reject invented id"          1 1; fi

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "FAILED: $fail assertion(s)"
  exit 1
fi
echo ""
echo "PASSED: all assertions"
