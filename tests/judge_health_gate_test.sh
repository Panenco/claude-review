#!/usr/bin/env bash
set -uo pipefail

# judge_health_gate_test.sh — fixture test for the JUDGES_BOTH_FAILED safety gate
# in build-review.sh (~line 511). Mirrors the embedded jq and asserts which
# judge_health shapes force the degraded COMMENT (so an empty-findings run can't
# reach APPROVE while the body renders a "review failed" banner).
#
# Key case (the fix): at REVIEW_LEVEL=light there is ONE judge; if it (sonnet)
# failed there is no surviving output → it MUST trip the gate. A full run with
# one of two judges failed must NOT trip (the surviving judge is legitimate).
# No LLM key required.

cd "$(dirname "$0")/.."
fail=0

# Mirrors scripts/build-review.sh's JUDGES_BOTH_FAILED jq. Keep in sync.
judges_failed() {
  jq -r '
    def is_failed_str(field): if has(field) then (.[field] == "failed") else false end;
    def is_true_bool(field): if has(field) then (.[field] == true) else false end;
    if (type == "object" and (.judge_health // null | type == "object")) then
      (.judge_health |
        is_true_bool("both_failed")
        or is_true_bool("cb_failed")
        or (is_failed_str("opus") and is_failed_str("haiku"))
        or (is_true_bool("single_judge") and is_failed_str("sonnet"))
      )
    else false end' <<< "$1"
}

assert() {
  local label="$1" want="$2" meta="$3" got
  got=$(judges_failed "$meta")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

# ── trips the gate → degrade to COMMENT ──
assert "both_failed:true (full)" true '{"judge_health":{"both_failed":true}}'
assert "cb_failed:true" true '{"judge_health":{"cb_failed":true}}'
assert "opus+haiku both failed (full)" true '{"judge_health":{"opus":"failed","haiku":"failed"}}'
assert "light sole judge failed (single_judge+sonnet failed)" true \
  '{"judge_health":{"sonnet":"failed","single_judge":true}}'

# ── does NOT trip → legitimate review ──
assert "light sole judge OK" false \
  '{"judge_health":{"sonnet":"ok","single_judge":true,"agreed_at":"single"}}'
assert "full: one of two failed (survivor stands)" false '{"judge_health":{"opus":"failed","haiku":"ok"}}'
assert "full: both judges ok" false '{"judge_health":{"opus":"ok","haiku":"ok"}}'
assert "string \"false\" is not truthy" false '{"judge_health":{"both_failed":"false"}}'
assert "no judge_health" false '{"verdict":"COMMENT"}'

if [ "$fail" -eq 0 ]; then
  echo
  echo "All judge-health gate tests passed."
  exit 0
else
  echo
  echo "$fail judge-health gate assertion(s) failed."
  exit 1
fi
