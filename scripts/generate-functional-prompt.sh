#!/usr/bin/env bash
# `-x` makes every command visible in the job log. The caller runs us from a
# step that already has `set -x` on, but that trace stops at the script
# boundary — if we die silently under `set -e`, the reviewer processes we were
# launched alongside get orphan-killed and the whole review looks like
# "analyzer crashed" with no evidence. Tracing here points future debugging
# at the exact failing line.
set -Eeuxo pipefail

# generate-functional-prompt.sh — Build the functional tester prompt from the template.
#
# Reads review-config.md for auth info, builds AUTH_INSTRUCTIONS and ENV_HINT
# from the current environment state, and renders the template to /tmp/functional-prompt.txt.
#
# Required env vars:
#   API_READY   — true/false
#   API_URL     — URL of the running API (may be empty)
#   WEB_READY   — true/false
#   WEB_URL     — URL of the running web app (may be empty)
#   AUTH_READY  — true/false
#
# Output:
#   /tmp/functional-prompt.txt — rendered prompt for the functional tester agent

API_URL_VAL="${API_URL:-not discovered}"
WEB_URL_VAL="${WEB_URL:-not discovered}"
# Wall-clock budget the tester self-enforces (records a start ts, hard-stops +
# writes when elapsed exceeds this). Primary runtime bound, well under the job's
# timeout-minutes — see functional_budget_seconds in pr-review.yml.
FUNCTIONAL_BUDGET_SECONDS_VAL="${FUNCTIONAL_BUDGET_SECONDS:-480}"

# ── Build ENV_HINT ──
ENV_HINT="ENVIRONMENT STATUS: "
if [ "$API_READY" = "true" ]; then
  ENV_HINT+="API is ALREADY RUNNING at $API_URL_VAL. "
else
  ENV_HINT+="API is NOT running — you may need to start it (check review-config.md or CLAUDE.md). "
fi
if [ "$WEB_READY" = "true" ]; then
  ENV_HINT+="Web is ALREADY RUNNING at $WEB_URL_VAL. "
else
  ENV_HINT+="Web is NOT running — start it if browser tests are needed. "
fi
if [ "$AUTH_READY" = "true" ]; then
  ENV_HINT+="Auth cookies are pre-created at /tmp/test-cookies.txt. Use -b /tmp/test-cookies.txt for authenticated curl requests. "
else
  ENV_HINT+="Auth is NOT pre-configured. Check review-config.md (in context.md) for sign-in endpoint and credentials. If none available, test public endpoints only. "
fi
# Add dynamic info about what was set up
COMPOSE_FILE=""
for cf in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  [ -f "$cf" ] && COMPOSE_FILE="$cf" && break
done
[ -n "$COMPOSE_FILE" ] && ENV_HINT+="Docker services are running via docker compose. "
[ -f .env ] && ENV_HINT+=".env exists. "
# `head -1` closes the pipe as soon as it reads a match, which gives `find`
# SIGPIPE → under `pipefail` the whole command substitution exits 141 and
# errexit aborts the script. `|| true` keeps the detection best-effort.
PRISMA_FOUND=$(find . -maxdepth 5 -path '*/prisma/schema.prisma' -not -path '*/node_modules/*' 2>/dev/null | head -1 || true)
[ -n "$PRISMA_FOUND" ] && ENV_HINT+="Prisma is generated and migrated. "
ENV_HINT+="Skip setup steps that are already done."

# ── Build AUTH_INSTRUCTIONS ──
# Default when auth extraction fails or is absent: tell the agent to consult
# review-config.md (which is embedded in context.md) instead of silently
# treating the app as unauthenticated. That's better than "test only public
# endpoints" because most functional tests need auth.
AUTH_INSTRUCTIONS="Auth was not auto-extracted. Read the '### Auth' section of review-config.md (included in context.md) and follow the documented method (cookie/bearer/header/custom). If the app has no auth, test public endpoints only and note auth status in uncertain_observations."
if [ -f .github/review-config.md ] && grep -q '^### Auth' .github/review-config.md; then
  # Extract sign-in URL and credentials from review-config.md.
  # Match "Sign in", "Sign-in", "Signin", "Log in", "Log-in", "Login" — these
  # are the common user-visible phrasings. `|| true` guards against grep
  # returning non-zero when no line matches, which would abort the whole
  # analyze step under `set -euo pipefail`.
  AUTH_LINES=$(grep -iE 'sign.?in|log.?in' .github/review-config.md || true)
  SIGNIN_LINE=$(printf '%s\n' "$AUTH_LINES" | grep -oE 'POST [^ ]+' | head -1 | sed 's/^POST //' | sed 's/`//g' || true)
  SIGNIN_BODY=$(printf '%s\n' "$AUTH_LINES" | grep -oE '\{[^}]+\}' | head -1 || true)
  if [ -n "$SIGNIN_LINE" ] && [ -n "$SIGNIN_BODY" ]; then
    # Build the browser_evaluate auth code. This assumes cookie-based auth
    # (credentials:'include'). Bearer- and header-based auth need the agent
    # to capture the response token and re-send it, which the agent does
    # from review-config.md directly — we don't try to templatize it here.
    FULL_SIGNIN_URL="${API_URL_VAL%/api*}${SIGNIN_LINE}"
    AUTH_INSTRUCTIONS="browser_evaluate with: async () => { const r = await fetch('${FULL_SIGNIN_URL}', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(${SIGNIN_BODY}), credentials:'include'}); return r.status; } — if review-config.md documents a non-cookie method (bearer/header/x-auth), ignore this snippet and follow the documented method instead."
  fi
fi

# ── Locate template ──
FUNC_TEMPLATE=""
for candidate in .review-pipeline/scripts/functional-prompt.template.txt .review-scripts/functional-prompt.template.txt .github/scripts/functional-prompt.template.txt; do
  if [ -f "$candidate" ]; then
    FUNC_TEMPLATE="$candidate"
    break
  fi
done

PIPELINE_DIR_VAL="${CLAUDE_REVIEW_PIPELINE_DIR:-}"

if [ -n "$FUNC_TEMPLATE" ] && [ -f "$FUNC_TEMPLATE" ]; then
  TEMPLATE_CONTENT=$(cat "$FUNC_TEMPLATE")
  TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{WEB_URL\}\}/$WEB_URL_VAL}"
  TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{AUTH_INSTRUCTIONS\}\}/$AUTH_INSTRUCTIONS}"
  TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{ENV_HINT\}\}/$ENV_HINT}"
  TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{PIPELINE_DIR\}\}/$PIPELINE_DIR_VAL}"
  TEMPLATE_CONTENT="${TEMPLATE_CONTENT//\{\{FUNCTIONAL_BUDGET_SECONDS\}\}/$FUNCTIONAL_BUDGET_SECONDS_VAL}"
  # `printf '%s\n'` over `echo` — if the template ever starts with `-n`/`-e`,
  # echo would swallow it as a flag and silently drop the first line.
  printf '%s\n' "$TEMPLATE_CONTENT" > /tmp/functional-prompt.txt
  printf '\n%s\n' "$ENV_HINT" >> /tmp/functional-prompt.txt
else
  echo "::warning::No functional-prompt template found -- using minimal fallback"
  cat > /tmp/functional-prompt.txt <<FALLBACK_EOF
You are a QA engineer validating PR functionality end-to-end. Read ${PIPELINE_DIR_VAL}/skills/review-functional-tester.md for the full spec — your subagent type is review-functional-tester so Playwright MCP is wired in directly via the subagent's mcpServers definition. Test through the user's flow whenever possible: Playwright MCP for UI, browser_evaluate (fetch with cookies) for API checks from within the browser context, curl via Bash only when nothing else works.

TURN 1 -- MCP smoke check (UNBATCHED, isolated, with bounded retry):
  Call mcp__playwright__browser_navigate with url="about:blank". If it errors with "tool not found" / "No such tool available" / "MCP server unavailable" / similar: this is usually a transient stdio startup race — run \`sleep 5\` via Bash and re-issue the same call, up to 3 attempts total. If any succeeds, proceed. Only if ALL 3 fail: STOP, write the loud-fail outputs in skills/review-functional-tester.md "MCP smoke-check failure" section, and exit. Do NOT silently fall back to curl.

TURN 2 -- Read test-plan.md + context.md in parallel (acceptance criteria live there). Also record your start time: \`echo \$(date +%s) > /tmp/functional-start\`. Your wall-clock budget is ${FUNCTIONAL_BUDGET_SECONDS_VAL}s — before EACH new scenario run \`echo \$(( \$(date +%s) - \$(cat /tmp/functional-start) ))\`; once it exceeds ${FUNCTIONAL_BUDGET_SECONDS_VAL}, STOP starting scenarios and write your outputs immediately.

TURN 3 -- $AUTH_INSTRUCTIONS

TURNS 4+ -- execute each scenario from the test plan (respecting the wall-clock budget above).
Web URL: $WEB_URL_VAL

LAST 2 TURNS -- write output:
  - /tmp/functional-findings.json
  - /tmp/functional-meta.json

$ENV_HINT
FALLBACK_EOF
fi

echo "Functional prompt generated: $(wc -l < /tmp/functional-prompt.txt) lines"
