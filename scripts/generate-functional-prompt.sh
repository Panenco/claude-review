#!/usr/bin/env bash
set -euo pipefail

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
PRISMA_FOUND=$(find . -maxdepth 5 -path '*/prisma/schema.prisma' -not -path '*/node_modules/*' 2>/dev/null | head -1)
[ -n "$PRISMA_FOUND" ] && ENV_HINT+="Prisma is generated and migrated. "
ENV_HINT+="Skip setup steps that are already done."

# ── Build AUTH_INSTRUCTIONS ──
AUTH_INSTRUCTIONS="No auth configured. Test only public endpoints. Note auth gaps in uncertain_observations."
if [ -f .github/review-config.md ] && grep -q '^### Auth' .github/review-config.md; then
  # Extract sign-in URL and credentials from review-config.md
  SIGNIN_LINE=$(grep -i 'sign.in' .github/review-config.md | grep -oE 'POST [^ ]+' | head -1 | sed 's/^POST //' | sed 's/`//g')
  SIGNIN_BODY=$(grep -i 'sign.in' .github/review-config.md | grep -oE '\{[^}]+\}' | head -1)
  if [ -n "$SIGNIN_LINE" ] && [ -n "$SIGNIN_BODY" ]; then
    # Build the browser_evaluate auth code
    FULL_SIGNIN_URL="${API_URL_VAL%/api*}${SIGNIN_LINE}"
    AUTH_INSTRUCTIONS="browser_evaluate with: async () => { const r = await fetch('${FULL_SIGNIN_URL}', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(${SIGNIN_BODY}), credentials:'include'}); return r.status; }"
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
  echo "$TEMPLATE_CONTENT" > /tmp/functional-prompt.txt
  printf '\n%s\n' "$ENV_HINT" >> /tmp/functional-prompt.txt
else
  echo "::warning::No functional-prompt template found -- using minimal fallback"
  cat > /tmp/functional-prompt.txt <<FALLBACK_EOF
You are a QA engineer validating PR functionality end-to-end. Read ${PIPELINE_DIR_VAL}/skills/review-functional-tester.md for the full spec. Test through the user's flow whenever possible: Playwright MCP for UI, browser_evaluate (fetch with cookies) for API checks from within the browser context, curl via Bash only when nothing else works.

TURN 1 -- do ALL of these in parallel (one message, multiple tool calls):
  a) ToolSearch query: select:mcp__playwright__browser_navigate,mcp__playwright__browser_take_screenshot,mcp__playwright__browser_snapshot,mcp__playwright__browser_console_messages,mcp__playwright__browser_click,mcp__playwright__browser_fill_form,mcp__playwright__browser_wait_for,mcp__playwright__browser_select_option,mcp__playwright__browser_press_key,mcp__playwright__browser_evaluate
  b) Read test-plan.md (repo root)
  c) Read context.md (repo root) -- contains the acceptance criteria

TURN 2 -- $AUTH_INSTRUCTIONS

TURNS 3+ -- execute each scenario from the test plan.
Web URL: $WEB_URL_VAL

LAST 2 TURNS -- write output:
  - /tmp/functional-findings.json
  - /tmp/functional-meta.json

$ENV_HINT
FALLBACK_EOF
fi

echo "Functional prompt generated: $(wc -l < /tmp/functional-prompt.txt) lines"
