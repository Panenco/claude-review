#!/usr/bin/env bash
set -uo pipefail

# round2_resolution_test.sh — fixture test for the round-2
# thread-resolution jq expressions in build-review.sh. The legacy
# dedup_test.sh covered an earlier shape; this PR replaced that file
# but the jq expressions changed:
#
#   - RESOLVED_LIST / STILL_PRESENT_LIST gained a `source == "prior_finding"`
#     filter so inline-thread entries (own_bot / other_bot / human) don't
#     leak into the verdict body's "Since previous review" section.
#   - The RESOLUTION_VALID shape check gained `has("source")` so a
#     resolution file missing the new field is treated as invalid.
#   - A new cross-check requires the prior_finding-subset length to be
#     >= prior-state.findings length (catches a classifier crashing
#     mid-write to `[]`).
#
# This test exercises all three changes against a synthetic
# /tmp/thread-resolution.json + prior-state/review-state.json. No LLM
# key required; pure jq.

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Realistic mixed-source thread-resolution.json ──
# Three prior_finding entries (c1, c2, c3 — two RESOLVED, one STILL_PRESENT
# of severity major), plus one entry per inline-comment source so the
# filters can prove they reject non-prior_finding rows.
cat > "$TMP/thread-resolution.json" <<'EOF'
[
  {"id":"c1","source":"prior_finding","status":"RESOLVED","evidence":"line 42 wraps in try/catch","prior_severity":"major","bot_user":null},
  {"id":"c2","source":"prior_finding","status":"STILL_PRESENT","evidence":"path unchanged in since-last.diff","prior_severity":"major","bot_user":null},
  {"id":"c3","source":"prior_finding","status":"RESOLVED","evidence":"function deleted","prior_severity":"minor","bot_user":null},
  {"id":1234567890,"source":"own_bot","status":"STILL_PRESENT","evidence":"path unchanged","prior_severity":null,"bot_user":"panenco-claude-reviewer[bot]"},
  {"id":1234567891,"source":"other_bot","status":"RESOLVED","evidence":"cursor flagged this; fixed in since-last","prior_severity":null,"bot_user":"cursor[bot]"},
  {"id":1234567892,"source":"human","status":"RESOLVED","evidence":"reviewer asked for await; added","prior_severity":null,"bot_user":null}
]
EOF

cat > "$TMP/review-state.json" <<'EOF'
{
  "schema_version": 1,
  "prior_head_sha": "abc123",
  "round": 1,
  "verdict": "REQUEST_CHANGES",
  "findings": [
    {"id":"c1","severity":"major","path":"src/auth.ts","line_start":42,"title":"Missing try/catch","evidence":"...","reasoning":"...","expected":"..."},
    {"id":"c2","severity":"major","path":"src/users.ts","line_start":17,"title":"SQL injection","evidence":"...","reasoning":"...","expected":"..."},
    {"id":"c3","severity":"minor","path":"src/utils.ts","line_start":5,"title":"Dead code","evidence":"...","reasoning":"...","expected":"..."}
  ]
}
EOF

# ── Block 1: RESOLVED_LIST / STILL_PRESENT_LIST filters drop non-prior_finding rows ──
RESOLVED_LIST=$(jq '[.[] | select(.source == "prior_finding" and .status == "RESOLVED")]' "$TMP/thread-resolution.json")
STILL_PRESENT_LIST=$(jq '[.[] | select(.source == "prior_finding" and .status == "STILL_PRESENT")]' "$TMP/thread-resolution.json")

assert_eq "RESOLVED_LIST length"     "2" "$(echo "$RESOLVED_LIST" | jq 'length')"
assert_eq "RESOLVED_LIST has c1"     "true" "$(echo "$RESOLVED_LIST" | jq 'any(.id == "c1")')"
assert_eq "RESOLVED_LIST has c3"     "true" "$(echo "$RESOLVED_LIST" | jq 'any(.id == "c3")')"
assert_eq "RESOLVED_LIST drops other_bot RESOLVED" \
                                     "false" "$(echo "$RESOLVED_LIST" | jq 'any(.id == 1234567891)')"
assert_eq "RESOLVED_LIST drops human RESOLVED" \
                                     "false" "$(echo "$RESOLVED_LIST" | jq 'any(.id == 1234567892)')"
assert_eq "STILL_PRESENT_LIST length" "1" "$(echo "$STILL_PRESENT_LIST" | jq 'length')"
assert_eq "STILL_PRESENT_LIST has c2" "true" "$(echo "$STILL_PRESENT_LIST" | jq 'any(.id == "c2")')"
assert_eq "STILL_PRESENT_LIST drops own_bot STILL_PRESENT" \
                                      "false" "$(echo "$STILL_PRESENT_LIST" | jq 'any(.id == 1234567890)')"

# ── Block 2: RESOLUTION_VALID shape check ──
# Mirrors build-review.sh:471-473: type==array and all entries have id+source+status.
shape_ok() {
  jq -e 'type == "array" and all(type == "object" and has("id") and has("source") and has("status"))' "$1" >/dev/null 2>&1
  echo $?
}

assert_eq "shape: full mixed file passes"      "0" "$(shape_ok "$TMP/thread-resolution.json")"

# Drop the `source` field from one entry → must fail the guard.
jq 'map(if .id == "c1" then del(.source) else . end)' "$TMP/thread-resolution.json" > "$TMP/no-source.json"
assert_eq "shape: missing source on one row fails" "1" "$(shape_ok "$TMP/no-source.json")"

# Drop the `status` field → must fail.
jq 'map(if .id == "c1" then del(.status) else . end)' "$TMP/thread-resolution.json" > "$TMP/no-status.json"
assert_eq "shape: missing status on one row fails" "1" "$(shape_ok "$TMP/no-status.json")"

# Empty array still passes (no entries to check; vacuously true).
echo '[]' > "$TMP/empty.json"
assert_eq "shape: empty array passes (vacuous)"    "0" "$(shape_ok "$TMP/empty.json")"

# Object instead of array → fails.
echo '{"foo":"bar"}' > "$TMP/object.json"
assert_eq "shape: object fails"                    "1" "$(shape_ok "$TMP/object.json")"

# ── Block 3: prior_finding subset cross-check ──
# Mirrors build-review.sh:474-480. RESOLUTION_VALID requires
#   length([entries where source=="prior_finding"]) >= length(prior.findings).
prior_findings_len() { jq '.findings | length' "$1"; }
resolution_prior_len() { jq '[.[] | select(.source == "prior_finding")] | length' "$1"; }

assert_eq "cross-check: full file (3) >= prior (3)" "true" \
  "$([ "$(resolution_prior_len "$TMP/thread-resolution.json")" -ge "$(prior_findings_len "$TMP/review-state.json")" ] && echo true || echo false)"

# Truncate the resolution to 1 prior_finding (c1) — must fail the cross-check.
jq '[.[] | select(.id == "c1" or .source != "prior_finding")]' "$TMP/thread-resolution.json" > "$TMP/short.json"
SHORT_LEN=$(resolution_prior_len "$TMP/short.json")
assert_eq "cross-check: short prior_finding (1) NOT >= prior (3)" "false" \
  "$([ "$SHORT_LEN" -ge "$(prior_findings_len "$TMP/review-state.json")" ] && echo true || echo false)"

# When prior has 0 findings, even an empty resolution counts as valid (0 >= 0).
echo '{"findings":[]}' > "$TMP/empty-prior.json"
echo '[]' > "$TMP/empty-resolution.json"
assert_eq "cross-check: empty prior + empty resolution → valid" "true" \
  "$([ "$(resolution_prior_len "$TMP/empty-resolution.json")" -ge "$(prior_findings_len "$TMP/empty-prior.json")" ] && echo true || echo false)"

# ── Block 4: STILL_PRESENT_BLOCKERS id-join derives blocker count from
#    the prior-state severities, not the resolver's prior_severity field
#    (build-review.sh:493-499). c2 is STILL_PRESENT and severity=major in
#    prior-state → count must be 1.
STILL_PRESENT_BLOCKERS=$(jq -n \
  --slurpfile state "$TMP/review-state.json" \
  --argjson still "$STILL_PRESENT_LIST" \
  '($still | map(.id)) as $ids
   | ($state[0].findings // [])
   | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
   | length')
assert_eq "id-join: 1 still-present blocker (c2)" "1" "$STILL_PRESENT_BLOCKERS"

# When all prior findings are RESOLVED, the join returns 0 — the round-2
# ladder's "all blockers resolved" branch fires.
ALL_RESOLVED='[
  {"id":"c1","source":"prior_finding","status":"RESOLVED","evidence":"x","prior_severity":"major","bot_user":null},
  {"id":"c2","source":"prior_finding","status":"RESOLVED","evidence":"y","prior_severity":"major","bot_user":null},
  {"id":"c3","source":"prior_finding","status":"RESOLVED","evidence":"z","prior_severity":"minor","bot_user":null}
]'
ALL_STILL_LIST=$(echo "$ALL_RESOLVED" | jq '[.[] | select(.source == "prior_finding" and .status == "STILL_PRESENT")]')
ALL_RESOLVED_BLOCKERS=$(jq -n \
  --slurpfile state "$TMP/review-state.json" \
  --argjson still "$ALL_STILL_LIST" \
  '($still | map(.id)) as $ids
   | ($state[0].findings // [])
   | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
   | length')
assert_eq "id-join: 0 still-present blockers when all RESOLVED" "0" "$ALL_RESOLVED_BLOCKERS"

if [ "$fail" -eq 0 ]; then
  echo
  echo "All round-2 resolution tests passed."
  exit 0
else
  echo
  echo "$fail round-2 resolution test assertion(s) failed."
  exit 1
fi
