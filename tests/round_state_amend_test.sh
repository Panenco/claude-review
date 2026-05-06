#!/usr/bin/env bash
set -uo pipefail

# round_state_amend_test.sh — regression for the round-state amend in
# post-review.sh after the POST. Cursor Bugbot caught a high-severity bug
# on PR #28: `select(length > 0)` on an empty review_node_id returns an
# empty stream, the surrounding object literal produces zero outputs,
# and the redirect writes an EMPTY file — wiping the whole round-state
# artifact. The fix uses `if ($rnid | length) > 0 then $rnid else null end`
# so empty input maps to literal null without breaking the object.

cd "$(dirname "$0")/.."

fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label"
    echo "      want: $want"
    echo "      got:  $got"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# The same jq the production script uses (see post-review.sh round-state
# amend block). Kept in lockstep with the production version — if you
# change one, change the other.
amend_state() {
  local input_file="$1" output_file="$2" rid="$3" rnid="$4"
  jq --arg rid "$rid" --arg rnid "$rnid" \
    '. + {
       review_id: ($rid | tonumber? // null),
       review_node_id: (if ($rnid | length) > 0 then $rnid else null end)
     }' \
    "$input_file" > "$output_file"
}

echo "── Round-state amend ──"

# Baseline state file looks like the v2.0 schema.
cat > "$TMP/state-baseline.json" <<'EOF'
{
  "schema_version": 1,
  "prior_head_sha": "abc123",
  "round": 1,
  "findings": [],
  "verdict": "APPROVE",
  "reviewed_at": "2026-05-06T00:00:00Z"
}
EOF

# Case 1: both ids present — should produce a populated object.
amend_state "$TMP/state-baseline.json" "$TMP/state-1.json" "12345" "PRR_xyz"
got_id=$(jq -r '.review_id' "$TMP/state-1.json")
got_node=$(jq -r '.review_node_id' "$TMP/state-1.json")
got_verdict=$(jq -r '.verdict' "$TMP/state-1.json")
assert_eq "both ids: review_id captured"      "12345"   "$got_id"
assert_eq "both ids: review_node_id captured" "PRR_xyz" "$got_node"
assert_eq "both ids: prior fields preserved"  "APPROVE" "$got_verdict"

# Case 2: empty REVIEW_NODE_ID — the regression. Pre-fix, this wrote an
# empty file. Post-fix, review_node_id should land as JSON null and the
# rest of the state must survive intact.
amend_state "$TMP/state-baseline.json" "$TMP/state-2.json" "67890" ""
if [ ! -s "$TMP/state-2.json" ]; then
  echo "FAIL: empty rnid: amend wrote an EMPTY file (regression — review state would be destroyed)"
  fail=$((fail + 1))
else
  echo "OK:   empty rnid: amend produced a non-empty file"
  got_id=$(jq -r '.review_id' "$TMP/state-2.json")
  got_node=$(jq -r '.review_node_id' "$TMP/state-2.json")
  got_verdict=$(jq -r '.verdict' "$TMP/state-2.json")
  got_findings=$(jq -r '.findings | length' "$TMP/state-2.json")
  assert_eq "empty rnid: review_id still captured"        "67890"   "$got_id"
  assert_eq "empty rnid: review_node_id is JSON null"     "null"    "$got_node"
  assert_eq "empty rnid: prior fields preserved"          "APPROVE" "$got_verdict"
  assert_eq "empty rnid: findings array preserved"        "0"       "$got_findings"
fi

# Case 3: non-numeric REVIEW_ID (defensive — gh response shape oddity).
# tonumber? should silently fall back to null without aborting the whole
# expression.
amend_state "$TMP/state-baseline.json" "$TMP/state-3.json" "not-a-number" "PRR_abc"
got_id=$(jq -r '.review_id' "$TMP/state-3.json")
got_node=$(jq -r '.review_node_id' "$TMP/state-3.json")
assert_eq "non-numeric rid: review_id falls back to null" "null"    "$got_id"
assert_eq "non-numeric rid: review_node_id still captured" "PRR_abc" "$got_node"

# Case 4: both empty — degraded but must not destroy state. (post-review.sh
# guards this case at the call site with `if [ -n "$REVIEW_ID" ]`, but the
# jq itself should still behave sanely.)
amend_state "$TMP/state-baseline.json" "$TMP/state-4.json" "" ""
if [ ! -s "$TMP/state-4.json" ]; then
  echo "FAIL: both empty: amend wrote an EMPTY file"
  fail=$((fail + 1))
else
  echo "OK:   both empty: amend produced a non-empty file"
  got_id=$(jq -r '.review_id' "$TMP/state-4.json")
  got_node=$(jq -r '.review_node_id' "$TMP/state-4.json")
  assert_eq "both empty: review_id is null"      "null" "$got_id"
  assert_eq "both empty: review_node_id is null" "null" "$got_node"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All round-state-amend tests passed."
  exit 0
else
  echo "$fail round-state-amend test(s) failed."
  exit 1
fi
