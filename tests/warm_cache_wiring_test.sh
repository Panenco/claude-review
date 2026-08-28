#!/usr/bin/env bash
set -uo pipefail

# warm_cache_wiring_test.sh — the cache warm can only work from a trigger that
# has WRITE access to the default branch's cache scope. GitHub grants that to
# push / workflow_dispatch / repository_dispatch / schedule / delete /
# registry_package / page_build only; pull_request_target, issue_comment and
# workflow_run get read-only and their saves are refused with a warning, not an
# error. That is why the warm is its own workflow: a reusable workflow inherits
# the CALLER's event and cannot choose its own.
#
# The bug this guards against ran green for a month. Every assertion here is a
# way it comes back.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WARM="$ROOT/.github/workflows/warm-cache.yml"
REVIEW="$ROOT/.github/workflows/pr-review.yml"
WARM_CALLER="$ROOT/.github/workflows/claude-review-warm.yml"
REVIEW_CALLER="$ROOT/.github/workflows/claude-review.yml"
fail=0

assert() {
  local label="$1" cond="$2"
  if [ "$cond" = "yes" ]; then
    echo "OK:   $label"
  else
    echo "FAIL: $label"
    fail=$((fail + 1))
  fi
}

# `on:` block of a workflow file — up to the first top-level key that follows.
on_block() { awk '/^on:/{p=1;next} p&&/^[a-zA-Z#]/{exit} p' "$1"; }

echo "── the warm lives in its own workflow, not in pr-review.yml ──"

assert "warm-cache.yml exists" \
  "$([ -f "$WARM" ] && echo yes || echo no)"
assert "warm-cache.yml is reusable (workflow_call)" \
  "$(grep -qE '^  workflow_call:' "$WARM" && echo yes || echo no)"
assert "pr-review.yml no longer declares a warm-cache job" \
  "$(grep -qE '^  warm-cache:' "$REVIEW" && echo no || echo yes)"

# The saves are the whole point. If they migrate back into pr-review.yml they
# inherit a read-only event again.
assert "pr-review.yml never saves a cache (restore-only)" \
  "$(grep -qE 'uses: actions/cache/save@|uses: actions/cache@' "$REVIEW" && echo no || echo yes)"
assert "warm-cache.yml is the one that saves" \
  "$(grep -qE 'uses: actions/cache/save@|uses: actions/cache@' "$WARM" && echo yes || echo no)"

echo
echo "── the warm asserts its trigger can write, and says so loudly ──"

assert "warm-cache.yml guards on the caller event" \
  "$(grep -Fq "CALLER_EVENT: \${{ github.event_name }}" "$WARM" && echo yes || echo no)"
for ev in push workflow_dispatch repository_dispatch schedule; do
  assert "guard admits $ev (write access)" \
    "$(grep -E '^ +push\|workflow_dispatch\|' "$WARM" | grep -Fq "$ev" && echo yes || echo no)"
done
for ev in pull_request_target issue_comment workflow_run; do
  assert "guard does not admit $ev (read-only)" \
    "$(grep -E '^ +push\|workflow_dispatch\|' "$WARM" | grep -Fq "$ev" && echo no || echo yes)"
done
# A warning would reproduce the original failure mode: green, and nothing stored.
assert "a read-only trigger fails the job rather than warning" \
  "$(grep -Fq '::error::' "$WARM" && grep -Fq 'exit 1' "$WARM" && echo yes || echo no)"

echo
echo "── the callers ──"

assert "warm caller exists" \
  "$([ -f "$WARM_CALLER" ] && echo yes || echo no)"
WARM_ON=$(on_block "$WARM_CALLER")
assert "warm caller triggers on push" \
  "$(printf '%s\n' "$WARM_ON" | grep -qE '^  push:' && echo yes || echo no)"
assert "warm caller triggers on schedule" \
  "$(printf '%s\n' "$WARM_ON" | grep -qE '^  schedule:' && echo yes || echo no)"
assert "warm caller does not trigger on a read-only event" \
  "$(printf '%s\n' "$WARM_ON" | grep -qE '^  (pull_request_target|issue_comment|workflow_run):' && echo no || echo yes)"

# It was here for the warm job, which has moved. Leaving it would claim a runner
# on every PR to run a review gate that now refuses the event anyway.
REVIEW_ON=$(on_block "$REVIEW_CALLER")
assert "review caller no longer triggers on pull_request_target" \
  "$(printf '%s\n' "$REVIEW_ON" | grep -qE '^  pull_request_target:' && echo no || echo yes)"

# Callers must be free to add write-capable triggers for the warm without those
# events also starting a review. A denylist gate cannot give them that.
GATE=$(awk '/^  review:/{p=1} p&&/^    if: >-/{g=1;next} g&&/^    [a-z]/{exit} g' "$REVIEW")
assert "review gate is an allowlist of events, not an exclusion" \
  "$(printf '%s\n' "$GATE" | grep -Fq "github.event_name == 'issue_comment'" \
     && printf '%s\n' "$GATE" | grep -Fq "github.event_name == 'workflow_dispatch'" \
     && echo yes || echo no)"
for ev in push schedule repository_dispatch; do
  assert "review gate does not admit $ev" \
    "$(printf '%s\n' "$GATE" | grep -Fq "$ev" && echo no || echo yes)"
done
# Unchanged security boundary — restated here because the gate was rewritten.
assert "review gate still requires OWNER/MEMBER/COLLABORATOR" \
  "$(printf '%s\n' "$GATE" | grep -Fq '["OWNER","MEMBER","COLLABORATOR"]' && echo yes || echo no)"

echo
echo "── the two halves must agree on the fleet and the keys ──"

# Keys are scoped by runner.os AND runner.arch. A hosted warm plus an arm64
# review fleet would never match, and every review would run cold.
assert "warm-cache.yml takes a runner input" \
  "$(grep -qE '^      runner:' "$WARM" && echo yes || echo no)"
assert "warm caller passes runner explicitly (this repo is public)" \
  "$(grep -qE '^      runner: ubuntu-latest' "$WARM_CALLER" && echo yes || echo no)"
assert "review caller passes the same runner" \
  "$(grep -qE '^      runner: ubuntu-latest' "$REVIEW_CALLER" && echo yes || echo no)"

# The browser pin keys a cache both workflows touch; drift is silent.
WARM_AB=$(sed -n 's/^  AGENT_BROWSER_VERSION: "\(.*\)"$/\1/p' "$WARM")
REVIEW_AB=$(sed -n 's/^  AGENT_BROWSER_VERSION: "\(.*\)"$/\1/p' "$REVIEW")
assert "AGENT_BROWSER_VERSION is in lockstep ($WARM_AB vs $REVIEW_AB)" \
  "$([ -n "$WARM_AB" ] && [ "$WARM_AB" = "$REVIEW_AB" ] && echo yes || echo no)"

# The dev cache is keyed identically on both sides or the restore never hits.
# shellcheck disable=SC2016  # asserting on the literal line, not expanding it
KEYLINE='echo "key=${RUNNER_OS}-${RUNNER_ARCH}-${KEY_PREFIX}-${hash}" >> "$GITHUB_OUTPUT"'
assert "both workflows compute the dev cache key the same way" \
  "$(grep -Fq "$KEYLINE" "$WARM" && grep -Fq "$KEYLINE" "$REVIEW" && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then
  echo "All warm-cache wiring tests passed."
else
  echo "$fail warm-cache wiring test(s) failed."
  exit 1
fi
