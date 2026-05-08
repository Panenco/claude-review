#!/usr/bin/env bash
# pick-oauth-token.sh — Choose a Claude OAuth token from a pool of one or
# more candidates, preferring tokens whose 5-hour subscription rate-limit
# window still allows a call. Backwards-compat with single-token setups
# (just CLAUDE_CODE_OAUTH_TOKEN set).
#
# Why probe? Claude.ai subscription tokens hit a rolling 5-hour ceiling
# that the headless `/usage` slash command does NOT expose (it returns a
# static string with no API call). The only proactive signal available is
# the `rate_limit_event` line emitted by `--output-format stream-json`
# during a real call. Its `rate_limit_info.status` reports:
#   "allowed"          — under the soft threshold; fully usable
#   "allowed_warning"  — past the soft threshold but calls still go through
#   "blocked"          — over the cap; subsequent calls fail
#   anything else      — abnormal (network error, expired token, etc.)
# Both "allowed" and "allowed_warning" mean the token can serve a review.
# We issue a tiny Haiku probe per candidate, parse the event, and pick a
# token that's actually usable. Pool of one skips the probe entirely.
#
# Inputs (env):
#   CLAUDE_CODE_OAUTH_TOKENS — optional. Newline-separated pool of tokens.
#   CLAUDE_CODE_OAUTH_TOKEN  — optional. Single token; used when _TOKENS is
#                              unset or empty. Also the canonical name the
#                              CLI and claude-code-action read.
#   GITHUB_ENV               — set by GitHub Actions; path to write env exports
#   GITHUB_OUTPUT            — set by GitHub Actions; path to write step outputs
#   CLAUDE_BIN               — optional override for the claude CLI path
#                              (default: $HOME/.local/bin/claude)
#   CLAUDE_PROBE_CMD         — TEST-ONLY override. When set, replaces the real
#                              CLI probe. Receives the candidate token via
#                              CLAUDE_CODE_OAUTH_TOKEN in its env and must
#                              echo a JSON line shaped like the CLI's
#                              `rate_limit_event` (with rate_limit_info.status
#                              and rate_limit_info.resetsAt).
#
# Outputs:
#   $GITHUB_ENV    — appends `CLAUDE_CODE_OAUTH_TOKEN=<chosen>`
#   $GITHUB_OUTPUT — appends `fingerprint=<sha256:12>`, `pool_size=<N>`,
#                    `healthy_count=<M>`
#
# Exit:
#   0 — picked a token (single-token mode is always 0)
#   1 — no candidates supplied OR every candidate is exhausted/invalid

set -uo pipefail

# Stable, leak-free fingerprint of a token (first 12 hex of sha256).
fingerprint() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

# Format epoch seconds as UTC ISO-8601 "YYYY-MM-DDTHH:MMZ", or echo back
# the raw value if neither BSD nor GNU `date` accepts it. Used purely for
# operator-readable log lines — empty input returns "-".
format_resets() {
  local resets="$1"
  [ -z "$resets" ] && { printf -- '-'; return 0; }
  date -u -r "$resets" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || date -u -d "@$resets" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || printf '%s' "$resets"
}

# Probe one token. Echoes a single line: "<status>|<resetsAt>".
# `status` is "allowed" / "blocked" / "warning" (whatever the API returns),
# OR "invalid" when the probe failed to produce a rate_limit_event line at
# all (network error, expired token, malformed output). `resetsAt` is the
# unix epoch seconds, or empty when unavailable.
probe_token() {
  local token="$1"
  local out rle status resets
  if [ -n "${CLAUDE_PROBE_CMD:-}" ]; then
    out=$(CLAUDE_CODE_OAUTH_TOKEN="$token" bash -c "$CLAUDE_PROBE_CMD" 2>&1) || true
  else
    # Haiku is the cheapest model; the rate limit is account-wide so a
    # Haiku probe correctly reflects whether subsequent Opus/Sonnet calls
    # would also be allowed. timeout 30 prevents a hung TLS handshake from
    # stalling the whole job. --max-turns 1 + "ok" guarantees a single
    # tool-free assistant turn.
    out=$(CLAUDE_CODE_OAUTH_TOKEN="$token" timeout 30 \
      "${CLAUDE_BIN:-$HOME/.local/bin/claude}" -p "ok" \
        --model claude-haiku-4-5 \
        --max-turns 1 \
        --output-format stream-json \
        --verbose \
        --setting-sources user \
        --permission-mode dontAsk \
      2>&1) || true
  fi

  rle=$(printf '%s\n' "$out" | grep -m1 '"type":"rate_limit_event"' || true)
  if [ -z "$rle" ]; then
    printf 'invalid|\n'
    return 0
  fi
  status=$(printf '%s' "$rle" | jq -r '.rate_limit_info.status // "invalid"' 2>/dev/null || echo invalid)
  resets=$(printf '%s' "$rle" | jq -r '.rate_limit_info.resetsAt // ""' 2>/dev/null || echo "")
  printf '%s|%s\n' "$status" "$resets"
}

# Trim each line, drop empties, and dedupe (preserving first-occurrence
# order). Used by both the pool and single-token paths so a trailing
# newline on a single-token secret (a common foot-gun when pasting into
# the GitHub UI) doesn't get split into a valid candidate plus an empty
# one, AND a token pasted twice into the pool doesn't probe twice
# (wasted Haiku call + inflated pool_size in the operator log).
trim_lines() {
  printf '%s\n' "$1" | awk '
    {
      gsub(/^[ \t\r]+|[ \t\r]+$/, "", $0)
      if (length && !seen[$0]++) print
    }
  '
}

# Build candidate list. CLAUDE_CODE_OAUTH_TOKENS wins when it has any
# non-whitespace content; otherwise we fall back to single-token compat.
# Plain `${X:-Y}` is wrong here — it only falls through when X is unset or
# the empty string, not when X is "\n   \n" (a real shape when a user
# saves an empty-looking secret).
build_candidates() {
  local out
  out=$(trim_lines "${CLAUDE_CODE_OAUTH_TOKENS:-}")
  [ -n "$out" ] || out=$(trim_lines "${CLAUDE_CODE_OAUTH_TOKEN:-}")
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

main() {
  local CANDIDATES=()
  while IFS= read -r line; do
    CANDIDATES+=("$line")
  done < <(build_candidates)
  local pool_size=${#CANDIDATES[@]}

  if [ "$pool_size" -eq 0 ]; then
    echo "::error::No Claude OAuth token configured. Set either CLAUDE_CODE_OAUTH_TOKEN (single) or CLAUDE_CODE_OAUTH_TOKENS (newline-separated pool) as a repo secret."
    echo "::error::Run 'claude setup-token' locally against a Claude subscription to generate one."
    exit 1
  fi

  # Single-token fast path: no decision to make, so skip the probe.
  if [ "$pool_size" -eq 1 ]; then
    local fp
    fp=$(fingerprint "${CANDIDATES[0]}")
    echo "::notice title=Claude OAuth token::Single token configured (fingerprint $fp). No pool — skipping probe."
    [ -n "${GITHUB_ENV:-}" ] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "${CANDIDATES[0]}" >> "$GITHUB_ENV"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      printf 'fingerprint=%s\npool_size=1\nhealthy_count=1\n' "$fp" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi

  # Multi-token: probe each, build a status table, pick a healthy one.
  echo "::group::Probing $pool_size OAuth tokens"
  local i fp result status resets human_resets
  local STATUSES=() RESETS=() FPS=() ALLOWED_IDX=()
  for i in "${!CANDIDATES[@]}"; do
    fp=$(fingerprint "${CANDIDATES[i]}")
    FPS[i]="$fp"
    result=$(probe_token "${CANDIDATES[i]}")
    status="${result%%|*}"
    resets="${result#*|}"
    STATUSES[i]="$status"
    RESETS[i]="$resets"
    human_resets=$(format_resets "$resets")
    printf 'token #%d %s — status=%s resetsAt=%s\n' "$i" "$fp" "$status" "$human_resets"
    # Accept any "allowed*" status — the API uses "allowed_warning" once
    # the soft threshold is crossed but calls still go through. Strict
    # equality ("allowed") was rejecting accounts the operator could
    # plainly see still had capacity on claude.ai/usage.
    case "$status" in allowed|allowed_*) ALLOWED_IDX+=("$i") ;; esac
  done
  echo "::endgroup::"

  if [ "${#ALLOWED_IDX[@]}" -eq 0 ]; then
    echo "::error::All $pool_size OAuth tokens are exhausted or invalid — review cannot run."
    for i in "${!CANDIDATES[@]}"; do
      echo "::error::  ${FPS[i]} — status=${STATUSES[i]} resetsAt=$(format_resets "${RESETS[i]}")"
    done
    echo "::error::Wait for a token's 5-hour window to reset, or rotate one of the secrets."
    exit 1
  fi

  # Random pick spreads load across healthy tokens. Not crypto, just balancing.
  local pick="${ALLOWED_IDX[$((RANDOM % ${#ALLOWED_IDX[@]}))]}"
  local chosen="${CANDIDATES[pick]}"
  local chosen_fp="${FPS[pick]}"
  echo "::notice title=Claude OAuth token::Picked token #$pick (fingerprint $chosen_fp) from pool of $pool_size — ${#ALLOWED_IDX[@]} healthy."

  [ -n "${GITHUB_ENV:-}" ] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$chosen" >> "$GITHUB_ENV"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'fingerprint=%s\npool_size=%s\nhealthy_count=%s\n' \
      "$chosen_fp" "$pool_size" "${#ALLOWED_IDX[@]}" >> "$GITHUB_OUTPUT"
  fi
}

main "$@"
