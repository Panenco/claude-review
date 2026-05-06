#!/usr/bin/env bash
set -uo pipefail

# pick_oauth_token_test.sh — exercises scripts/pick-oauth-token.sh end-to-end.
# Uses CLAUDE_PROBE_CMD to stub out the real Haiku probe so the test runs
# offline and deterministically. The stub maps token CONTENT to a status
# (e.g. "allowed-1" → status=allowed, "blocked-1" → status=blocked) so each
# case can stage the desired pool shape.

cd "$(dirname "$0")/.."

PICKER="scripts/pick-oauth-token.sh"
[ -x "$PICKER" ] || { echo "FAIL: $PICKER not executable"; exit 1; }

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
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "OK:   $label"
  else
    echo "FAIL: $label — expected to find '$needle' in: $haystack"
    fail=$((fail + 1))
  fi
}

# Stub probe. Token content drives the simulated status:
#   prefix "allowed-" → status=allowed (with future resetsAt)
#   prefix "blocked-" → status=blocked
#   prefix "warning-" → status=warning
#   prefix "noevent-" → emit nothing → picker classifies as invalid
#   anything else     → status=invalid (no rate_limit_event line)
PROBE_STUB='
case "$CLAUDE_CODE_OAUTH_TOKEN" in
  allowed-*) printf "%s\n" "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\",\"resetsAt\":1778065800,\"rateLimitType\":\"five_hour\"}}" ;;
  blocked-*) printf "%s\n" "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"blocked\",\"resetsAt\":1778100000,\"rateLimitType\":\"five_hour\"}}" ;;
  warning-*) printf "%s\n" "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"warning\",\"resetsAt\":1778099999,\"rateLimitType\":\"five_hour\"}}" ;;
  noevent-*) printf "%s\n" "{\"type\":\"result\",\"is_error\":true}" ;;
  *) printf "" ;;
esac
'
export CLAUDE_PROBE_CMD="$PROBE_STUB"

# Per-case GITHUB_ENV / GITHUB_OUTPUT files so we can inspect what the
# picker tried to export. The picker also exits 0/1, which we capture.
run_picker() {
  local tmp env_file out_file
  tmp=$(mktemp -d)
  env_file="$tmp/env"
  out_file="$tmp/out"
  : > "$env_file"
  : > "$out_file"
  GITHUB_ENV="$env_file" GITHUB_OUTPUT="$out_file" \
    bash "$PICKER" > "$tmp/stdout" 2> "$tmp/stderr"
  local rc=$?
  printf 'rc=%s\n' "$rc"
  printf 'env=%s\n' "$(cat "$env_file")"
  printf 'out=%s\n' "$(cat "$out_file")"
  printf 'stdout=%s\n' "$(cat "$tmp/stdout")"
  printf 'stderr=%s\n' "$(cat "$tmp/stderr")"
  rm -rf "$tmp"
}

# --- 1. No tokens at all → exits 1 with a clear error -----------------------
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKENS; run_picker)
assert_eq "No tokens → exits 1" "rc=1" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "No tokens → error mentions setup-token" "claude setup-token" "$RESULT"

# --- 2. Single CLAUDE_CODE_OAUTH_TOKEN → fast-path, no probe, exit 0 --------
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKENS
  CLAUDE_CODE_OAUTH_TOKEN=anything-goes-here run_picker)
assert_eq "Single token → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Single token → writes chosen to GITHUB_ENV" \
  "CLAUDE_CODE_OAUTH_TOKEN=anything-goes-here" "$RESULT"
assert_contains "Single token → emits pool_size=1" "pool_size=1" "$RESULT"
assert_contains "Single token → log says 'skipping probe'" "skipping probe" "$RESULT"

# --- 3. Pool of 1 in CLAUDE_CODE_OAUTH_TOKENS → still single-token fast path ---
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKENS="allowed-solo" run_picker)
assert_eq "Pool of 1 → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Pool of 1 → writes the only token to GITHUB_ENV" \
  "CLAUDE_CODE_OAUTH_TOKEN=allowed-solo" "$RESULT"

# --- 4. Pool of 3, all allowed → picks one, healthy_count=3 -----------------
INPUT=$'allowed-1\nallowed-2\nallowed-3'
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKENS="$INPUT" run_picker)
assert_eq "Pool of 3 allowed → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Pool of 3 allowed → pool_size=3" "pool_size=3" "$RESULT"
assert_contains "Pool of 3 allowed → healthy_count=3" "healthy_count=3" "$RESULT"
PICKED=$(echo "$RESULT" | grep -oE 'CLAUDE_CODE_OAUTH_TOKEN=allowed-[123]' | head -1)
case "$PICKED" in
  CLAUDE_CODE_OAUTH_TOKEN=allowed-1|CLAUDE_CODE_OAUTH_TOKEN=allowed-2|CLAUDE_CODE_OAUTH_TOKEN=allowed-3)
    echo "OK:   Pool of 3 allowed → picked one of the three ($PICKED)"
    ;;
  *)
    echo "FAIL: Pool of 3 allowed → did not pick a valid candidate ($PICKED)"
    fail=$((fail + 1))
    ;;
esac

# --- 5. Mixed pool: 1 allowed + 2 blocked → picks the allowed one -----------
INPUT=$'blocked-1\nallowed-only\nblocked-2'
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKENS="$INPUT" run_picker)
assert_eq "Mixed pool → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Mixed pool → picks the allowed candidate" \
  "CLAUDE_CODE_OAUTH_TOKEN=allowed-only" "$RESULT"
assert_contains "Mixed pool → healthy_count=1" "healthy_count=1" "$RESULT"
assert_contains "Mixed pool → pool_size=3" "pool_size=3" "$RESULT"

# --- 6. All exhausted (blocked + warning + invalid) → exits 1 with table ----
INPUT=$'blocked-1\nwarning-2\nnoevent-3'
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKENS="$INPUT" run_picker)
assert_eq "All exhausted → exits 1" "rc=1" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "All exhausted → error names blocked status" "status=blocked" "$RESULT"
assert_contains "All exhausted → error names warning status" "status=warning" "$RESULT"
assert_contains "All exhausted → error names invalid status" "status=invalid" "$RESULT"
assert_contains "All exhausted → suggests waiting or rotating" \
  "Wait for a token's 5-hour window" "$RESULT"
# When all probes fail, we MUST NOT write any token to GITHUB_ENV — a
# downstream step running with whatever was already in env would silently
# burn the (also exhausted) token without surfacing the diagnosis.
ENV_LINE=$(echo "$RESULT" | grep -oE 'env=CLAUDE_CODE_OAUTH_TOKEN=[^ ]+' || true)
assert_eq "All exhausted → does not export a token to GITHUB_ENV" "" "$ENV_LINE"

# --- 7. Pool with empty/whitespace lines → ignored, doesn't inflate count ---
INPUT=$'\n  \nallowed-1\n\n  allowed-2  \n'
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_TOKENS="$INPUT" run_picker)
assert_eq "Whitespace-only lines stripped → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Whitespace-only lines stripped → pool_size=2" "pool_size=2" "$RESULT"

# --- 8. CLAUDE_CODE_OAUTH_TOKENS wins over CLAUDE_CODE_OAUTH_TOKEN ----------
RESULT=$(CLAUDE_CODE_OAUTH_TOKEN=should-be-ignored \
  CLAUDE_CODE_OAUTH_TOKENS="allowed-from-pool" run_picker)
assert_eq "Pool wins over single → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Pool wins over single → uses pool token" \
  "CLAUDE_CODE_OAUTH_TOKEN=allowed-from-pool" "$RESULT"

# --- 9. CLAUDE_CODE_OAUTH_TOKENS empty/whitespace falls back to single -----
RESULT=$(CLAUDE_CODE_OAUTH_TOKEN=allowed-fallback \
  CLAUDE_CODE_OAUTH_TOKENS=$'\n  \n  \n' run_picker)
assert_eq "Empty pool → falls back to single → exits 0" \
  "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Empty pool → uses single token" \
  "CLAUDE_CODE_OAUTH_TOKEN=allowed-fallback" "$RESULT"
assert_contains "Empty pool → fast path (pool_size=1)" "pool_size=1" "$RESULT"

# --- 10. Single token with trailing newline still single (no spurious 2nd) --
# A common foot-gun: a user pastes a token followed by ENTER into the GitHub
# secret form, leaving a trailing \n. Without trimming, build_candidates would
# emit ["token", ""] and the picker would route to the multi-token branch
# with one guaranteed-failing probe. Trim ensures it stays single-token.
RESULT=$(unset CLAUDE_CODE_OAUTH_TOKENS
  CLAUDE_CODE_OAUTH_TOKEN=$'tok-with-trailing-newline\n' run_picker)
assert_eq "Trailing newline on single → exits 0" "rc=0" "$(echo "$RESULT" | grep '^rc=')"
assert_contains "Trailing newline on single → pool_size=1 (no probe)" \
  "pool_size=1" "$RESULT"
assert_contains "Trailing newline on single → token written without the newline" \
  "CLAUDE_CODE_OAUTH_TOKEN=tok-with-trailing-newline" "$RESULT"

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "FAILED: $fail assertion(s)"
  exit 1
fi
echo ""
echo "PASSED: all assertions"
