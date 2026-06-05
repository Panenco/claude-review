#!/usr/bin/env bash
set -uo pipefail

# verdict_gate_annotation_test.sh — regression guard for issue #61.
#
# A blocking verdict (REQUEST_CHANGES) used to exit 1 with zero console
# output, so the Actions "Verdict gate" step rendered as a bare red ✗ with an
# empty log and no annotation (Panenco/qit#6486). The gate must emit a visible
# `::error::` annotation so the failed step explains itself.
#
# This executes the REAL scripts/verdict-gate.sh against fixture
# review-result.json files for each verdict and asserts both the exit code and
# the emitted annotation. The REQUEST_CHANGES / APPROVE / COMMENT paths make no
# `gh` API calls (only the missing-file crash path does), so no network/stubs
# are needed.

cd "$(dirname "$0")/.."
REPO="$(pwd)"
GATE="$REPO/scripts/verdict-gate.sh"

fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "OK:   $label" ;;
    *) echo "FAIL: $label — expected to find '$needle' in:"; printf '%s\n' "$haystack" | sed 's/^/        /'; fail=$((fail + 1)) ;;
  esac
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "FAIL: $label — did NOT expect '$needle' in output"; fail=$((fail + 1)) ;;
    *) echo "OK:   $label" ;;
  esac
}
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "OK:   $label"; else echo "FAIL: $label — want '$want', got '$got'"; fail=$((fail + 1)); fi
}

# run_gate <review-result-json> → sets OUT (combined stdout+stderr) and RC.
run_gate() {
  local body="$1"
  local work; work="$(mktemp -d)"
  printf '%s' "$body" > "$work/review-result.json"
  set +e
  OUT=$(cd "$work" && ANALYZER_OUTCOME=success POSTER_OUTCOME=success \
        GITHUB_STEP_SUMMARY="$work/summary.md" PR_NUMBER=1 \
        GITHUB_REPOSITORY=o/r GH_TOKEN=x \
        bash "$GATE" 2>&1)
  RC=$?
  set -e
  rm -rf "$work"
}

echo "── REQUEST_CHANGES: must fail AND emit an error annotation ──"
run_gate '{"verdict":"REQUEST_CHANGES","summary":"s","findings":[{"severity":"major","type":"bug","path":"a.ts","line_start":1,"title":"boom"}]}'
assert_eq        "exit code 1"          "1" "$RC"
assert_contains  "emits ::error::"      "::error::" "$OUT"
assert_contains  "names the verdict"    "REQUEST_CHANGES" "$OUT"
assert_contains  "states finding count" "1 blocking finding" "$OUT"

echo ""
echo "── APPROVE: passes, no error annotation ──"
run_gate '{"verdict":"APPROVE","summary":"ok","findings":[]}'
assert_eq          "exit code 0"     "0" "$RC"
assert_not_contains "no ::error::"   "::error::" "$OUT"

echo ""
echo "── COMMENT: passes with a warning (non-blocking) ──"
run_gate '{"verdict":"COMMENT","summary":"note","findings":[{"severity":"minor","type":"design-smell","path":"a.ts","line_start":1,"title":"nit"}]}'
assert_eq          "exit code 0"     "0" "$RC"
assert_contains    "emits ::warning::" "::warning::" "$OUT"
assert_not_contains "no ::error::"   "::error::" "$OUT"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All verdict-gate annotation tests passed."
  exit 0
else
  echo "$fail verdict-gate annotation test(s) failed."
  exit 1
fi
