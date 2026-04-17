#!/usr/bin/env bash
set -uo pipefail

# setup-dev-env.sh — Pre-start the consumer repo's dev environment for the
# Claude Code functional tester.
#
# Contract (first-class):
#   .github/claude-review/dev-start.sh — an executable script in the
#   consumer repo that installs deps, starts services, and blocks until
#   they respond. If the script exits non-zero, we downgrade to a warning
#   so the review still runs without functional testing.
#
# After bring-up, we probe URLs from review-config.md's `### Known service
# ports` table (for functional-tester context) and run any auth setup from
# `### Auth`. Neither of those needs shell in review-config.md anymore —
# all executable setup lives in dev-start.sh.
#
# If no dev-start.sh exists:
#   - With review-config.md present, fall back to extracting bash blocks
#     from `## Functional validation` (legacy contract, warned as
#     deprecated — consumers should migrate to dev-start.sh).
#   - Without either, emit a single warning and skip. No more stack
#     heuristics (Prisma autodetect, docker-compose probing, port
#     guessing, root `pnpm run dev` fallback) — those were the main
#     source of project-specific bleed-through.
#
# Required env vars:
#   GITHUB_OUTPUT   — path to GitHub Actions output file
#
# Outputs (written to $GITHUB_OUTPUT):
#   api_ready   — true/false
#   api_url     — URL of the running API (possibly adjusted via health-path fallback)
#   web_ready   — true/false
#   web_url     — URL of the running web app
#   auth_ready  — true/false

DEV_SCRIPT=".github/claude-review/dev-start.sh"
CONFIG=".github/review-config.md"
HAS_CONFIG=false
[ -f "$CONFIG" ] && HAS_CONFIG=true

# Extract bash blocks from a section of review-config.md, heading-level-aware.
# ## matches a level-2 section and includes its ### subsections; ### stops at
# the next ### or ##. Used for the legacy Functional validation path and for
# the Auth section (still supported in review-config.md).
extract_section_code() {
  local section="$1" file="$2"
  awk -v sec="$section" '
    /^(##|###) / {
      lvl = ($0 ~ /^### /) ? 3 : 2
      if (in_sec && lvl <= sec_level) in_sec = 0
      if (!in_sec && $0 ~ sec)        { in_sec = 1; sec_level = lvl }
      next
    }
    in_sec && /^```bash$/ { in_block=1; next }
    in_sec && /^```$/     { in_block=0; next }
    in_block              { print }
  ' "$file"
}

# First-match URL extraction from Known service ports table. Multi-match
# would produce multi-line output, which breaks $GITHUB_OUTPUT
# ("Invalid format '<url>'"). Exit awk after the first row matches.
extract_port_url() {
  local service="$1" file="$2"
  awk -v svc="$service" '
    /^\| / && tolower($0) ~ tolower(svc) {
      match($0, /https?:\/\/[^ |]+/)
      if (RSTART > 0) { print substr($0, RSTART, RLENGTH); exit }
    }
  ' "$file"
}

echo "::group::Pre-start dev environment"

# ── Phase 1: Bring up the environment ──
if [ -f "$DEV_SCRIPT" ]; then
  echo "Running $DEV_SCRIPT (first-class dev-start contract)..."
  # Subshell isolation: the script's readiness loops typically end with
  # `exit 1` on timeout, and under `set -e` that would kill this step
  # instead of letting the review fall through to degraded mode.
  ( bash "$DEV_SCRIPT" ) || echo "::warning::$DEV_SCRIPT exited non-zero — functional testing may be skipped"
elif [ "$HAS_CONFIG" = "true" ]; then
  # Legacy contract: bash blocks embedded in review-config.md's
  # ## Functional validation section. Keep this path for repos that
  # haven't migrated yet. Flag as deprecated.
  SETUP_CODE=$(extract_section_code "Functional validation" "$CONFIG")
  if [ -n "$SETUP_CODE" ]; then
    echo "::warning::Legacy: running bash blocks from $CONFIG's '## Functional validation'. Migrate to $DEV_SCRIPT (see claude-review README → 'dev-start.sh contract')."
    ( eval "$SETUP_CODE" ) || echo "::warning::Some review-config.md setup commands failed"
  else
    echo "::warning::No $DEV_SCRIPT and no bash blocks in $CONFIG's '## Functional validation' — skipping dev-env bring-up. Functional tester will run in degraded mode."
  fi
else
  echo "::warning::No $DEV_SCRIPT and no $CONFIG — skipping dev-env bring-up. Functional tester will run in degraded mode."
fi

# ── Phase 2: Probe URLs from review-config.md ──
# Regardless of how bring-up happened, URLs live in the Known service ports
# table so the functional tester + reviewer can consume them consistently.
API_READY=false
API_URL=""
WEB_READY=false
WEB_URL=""

if [ "$HAS_CONFIG" = "true" ]; then
  API_URL=$(extract_port_url "API" "$CONFIG")
  WEB_URL=$(extract_port_url "Web" "$CONFIG")
fi

# Probe API. Configs often list a base URL (http://localhost:4000) even
# though the framework mounts routes under a prefix — a plain base probe
# 404s and the whole step times out. Try the given URL first, then common
# health paths on the same origin before giving up.
if [ -n "$API_URL" ]; then
  API_ORIGIN=$(printf '%s' "$API_URL" | sed -E 's#^(https?://[^/]+).*#\1#')
  for i in $(seq 1 15); do
    if curl -sf "$API_URL" > /dev/null 2>&1; then
      API_READY=true; break
    fi
    for suffix in /api /api/health /api/ping /health /healthz /ping; do
      if curl -sf "${API_ORIGIN}${suffix}" > /dev/null 2>&1; then
        API_URL="${API_ORIGIN}${suffix}"
        API_READY=true
        echo "API responded at $API_URL (configured base did not)"
        break 2
      fi
    done
    sleep 2
  done
fi

# Probe Web
if [ -n "$WEB_URL" ]; then
  for i in $(seq 1 15); do
    if curl -sf "$WEB_URL" > /dev/null 2>&1; then
      WEB_READY=true; break
    fi
    sleep 2
  done
fi

echo "api_ready=$API_READY" >> "$GITHUB_OUTPUT"
echo "api_url=$API_URL" >> "$GITHUB_OUTPUT"
echo "web_ready=$WEB_READY" >> "$GITHUB_OUTPUT"
echo "web_url=$WEB_URL" >> "$GITHUB_OUTPUT"

# ── Phase 3: Auth setup from review-config.md ──
AUTH_READY=false
if [ "$HAS_CONFIG" = "true" ] && [ "$API_READY" = "true" ]; then
  AUTH_CODE=$(extract_section_code "Auth" "$CONFIG")
  if [ -n "$AUTH_CODE" ]; then
    echo "Running auth setup from review-config.md..."
    ( eval "$AUTH_CODE" ) && AUTH_READY=true || echo "::warning::Auth setup from config failed"
  fi
fi
echo "auth_ready=$AUTH_READY" >> "$GITHUB_OUTPUT"

if [ "$API_READY" = "true" ]; then
  echo "API ready at $API_URL"
else
  echo "::warning::API not ready"
fi
echo "Dev env: API=$API_READY ($API_URL), Web=$WEB_READY ($WEB_URL), Auth=$AUTH_READY"
echo "::endgroup::"
