#!/usr/bin/env bash
set -uo pipefail

# linked_issue_render_test.sh — regression guard for issue #59.
#
# `spec_sources.linked_issue` is the GitHub-native issue NUMBER; the renderer
# prints it as `#<value>`. A regression (judge copying the `/tmp/issue.json`
# path into the field) made the Spec-sources line render `#/tmp/issue.json`
# on a real review (PR #58). build-review.sh must accept the value only when
# it's a bare issue number and fall back to "none found" otherwise.
#
# Three checks:
#   1. Behaviour: the guard yields the number for digits, "none found" for a
#      path / null / missing.
#   2. Invariant (drift-proof): build-review.sh's linked_issue read carries the
#      digit guard — reads the real script, so removing it re-breaks this test.
#   3. Contract: the judge skill states linked_issue is the integer number,
#      never the file path.

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

# Mirrors the guard in scripts/build-review.sh.
guard() {
  jq -r '(.spec_sources.linked_issue // "") | tostring | if test("^[0-9]+$") then . else "none found" end'
}

echo "── Behaviour: linked_issue guard ──"
assert_eq "path     → none found" "none found" "$(echo '{"spec_sources":{"linked_issue":"/tmp/issue.json"}}' | guard)"
assert_eq "string # → number"     "57"         "$(echo '{"spec_sources":{"linked_issue":"57"}}' | guard)"
assert_eq "numeric  → number"     "57"         "$(echo '{"spec_sources":{"linked_issue":57}}' | guard)"
assert_eq "null     → none found" "none found" "$(echo '{"spec_sources":{"linked_issue":null}}' | guard)"
assert_eq "missing  → none found" "none found" "$(echo '{"spec_sources":{}}' | guard)"
# A path must never survive into the rendered `#<value>` token.
RENDERED="#$(echo '{"spec_sources":{"linked_issue":"/tmp/issue.json"}}' | guard)"
if printf '%s' "$RENDERED" | grep -q '/tmp'; then
  echo "FAIL: rendered token still contains a path: '$RENDERED'"
  fail=$((fail + 1))
else
  echo "OK:   path never reaches the '#<value>' token (got '$RENDERED')"
fi

echo ""
echo "── Invariant: build-review.sh guards the linked_issue read ──"
# The read of .spec_sources.linked_issue must constrain it to digits.
if grep -qE '\.spec_sources\.linked_issue.*test\("\^\[0-9\]\+\$"\)' scripts/build-review.sh; then
  echo "OK:   build-review.sh constrains linked_issue to a bare number"
else
  echo "FAIL: build-review.sh reads linked_issue without a digit guard (would render '#/tmp/...')"
  fail=$((fail + 1))
fi

echo ""
echo "── Contract: judge skill defines linked_issue as the integer number ──"
if grep -qiE 'linked_issue.*integer.*issue number|integer.*GitHub issue number' skills/review-judge.md; then
  echo "OK:   review-judge.md states linked_issue is the integer issue number"
else
  echo "FAIL: review-judge.md does not define linked_issue as the integer issue number"
  fail=$((fail + 1))
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All linked-issue render tests passed."
  exit 0
else
  echo "$fail linked-issue render test(s) failed."
  exit 1
fi
