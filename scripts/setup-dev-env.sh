#!/usr/bin/env bash
set -uo pipefail

# setup-dev-env.sh — Pre-start dev environment for functional testing.
#
# Reads setup from .github/review-config.md if present, falls back to auto-discovery.
#
# Required env vars:
#   PKG_MANAGER     — detected package manager (pnpm|yarn|npm|none)
#   GITHUB_OUTPUT   — path to GitHub Actions output file
#
# Outputs (written to $GITHUB_OUTPUT):
#   api_ready   — true/false
#   api_url     — URL of the running API
#   web_ready   — true/false
#   web_url     — URL of the running web app
#   auth_ready  — true/false
#   dev_pid     — PID of the dev server process (if started)

echo "::group::Pre-start dev environment"

CONFIG=".github/review-config.md"
HAS_CONFIG=false
[ -f "$CONFIG" ] && HAS_CONFIG=true

# Helper: extract bash code blocks from a section of review-config.md.
#
# The section boundary respects heading level. If `sec` matches a `##`
# heading, extraction continues through any `###` subsections and stops at
# the next `##`. If it matches a `###` heading, extraction stops at the
# next `###` or `##`. This was previously broken — the old logic reset
# `in_sec` on every `##` OR `###`, which caused `### Step 1` subsections
# under `## Functional validation` to silently terminate extraction and
# skip every bash block in the section.
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

# Helper: extract service URLs from Known service ports table.
# Returns only the FIRST matching row's URL: multiple matches (e.g. "API" vs
# "API docs") would otherwise produce multi-line output, which when written to
# $GITHUB_OUTPUT below breaks the file-command format ("Invalid format '<url>'").
extract_port_url() {
  local service="$1" file="$2"
  awk -v svc="$service" '
    /^\| / && tolower($0) ~ tolower(svc) {
      match($0, /https?:\/\/[^ |]+/)
      if (RSTART > 0) { print substr($0, RSTART, RLENGTH); exit }
    }
  ' "$file"
}

# ── Phase 1: Setup (Docker, .env, ORM, etc.) ──
if [ "$HAS_CONFIG" = "true" ] && [ -f "$CONFIG" ]; then
  # Execute code blocks from ## Functional validation section
  SETUP_CODE=$(extract_section_code "Functional validation" "$CONFIG")
  if [ -n "$SETUP_CODE" ]; then
    echo "Running setup from review-config.md..."
    # Run the eval'd setup in a subshell. Configs routinely end readiness
    # loops with `exit 1` when a service never responds, and because `eval`
    # runs in the current shell that would terminate setup-dev-env.sh
    # outright and fail the whole step. Isolating it in `( ... )` means
    # such a failure only aborts the config's own setup — the rest of the
    # pipeline (core + sweep reviewers) can still run, and the health
    # probes below will re-attempt discovery.
    ( eval "$SETUP_CODE" ) || echo "::warning::Some review-config.md setup commands failed"
  else
    echo "No setup code blocks in review-config.md"
  fi
else
  echo "No review-config.md -- using auto-discovery for dev env"
  # Auto-discovery fallbacks
  if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f compose.yml ] || [ -f compose.yaml ]; then
    echo "Auto: starting Docker services..."
    docker compose up -d 2>&1 || echo "::warning::docker compose failed"
    # Wait for database containers to be ready. The loop emits a distinct
    # "DB_READY" / "DB_TIMEOUT" marker so downstream steps know whether to
    # continue; we still return success (so functional testing can attempt
    # auto-discovery), but the marker + warning makes the timeout visible
    # instead of silently succeeding.
    DB_READY=false
    for i in $(seq 1 15); do
      if docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 || \
         docker compose exec -T db pg_isready -U postgres > /dev/null 2>&1 || \
         docker compose exec -T database pg_isready -U postgres > /dev/null 2>&1 || \
         docker compose exec -T mysql mysqladmin ping -h localhost > /dev/null 2>&1 || \
         docker compose exec -T db mysqladmin ping -h localhost > /dev/null 2>&1; then
        DB_READY=true
        echo "Database ready (attempt $i)."
        break
      fi
      sleep 2
    done
    if [ "$DB_READY" = "false" ]; then
      echo "::warning::Database never became ready in 30s — downstream migrations/seeds may fail."
    fi
  fi
  if [ ! -f .env ]; then
    for example_env in .env.example .env.sample .env.template .env.dev; do
      if [ -f "$example_env" ]; then
        cp "$example_env" .env
        echo "Auto: created .env from $example_env"
        break
      fi
    done
  fi
  # Copy .env to common app directories that may need it
  if [ -f .env ]; then
    for app_dir in apps/api apps/server apps/backend src/api src/server; do
      if [ -d "$app_dir" ] && [ ! -f "$app_dir/.env" ]; then
        cp .env "$app_dir/.env"
        echo "Auto: copied .env to $app_dir/"
      fi
    done
  fi
  # Auto-discover Prisma schemas
  for schema in $(find . -name 'schema.prisma' -path '*/prisma/*' -not -path '*/node_modules/*' 2>/dev/null); do
    SCHEMA_DIR=$(dirname "$(dirname "$schema")")
    echo "Auto: found Prisma schema at $schema"
    set -a; [ -f .env ] && source .env; set +a
    (cd "$SCHEMA_DIR" && npx prisma generate 2>&1 && npx prisma migrate deploy 2>&1) || echo "::warning::Prisma setup failed for $schema"
  done
fi

# ── Phase 2: Start dev server ──
# review-config.md setup code may have already started servers;
# auto-discovery always needs to start them.
if [ "$HAS_CONFIG" != "true" ] || ! curl -sf http://localhost:3000 > /dev/null 2>&1; then
  echo "Starting dev servers..."
  case "${PKG_MANAGER:-npm}" in
    pnpm) pnpm run dev > /tmp/dev-server.log 2>&1 & ;;
    yarn) yarn dev > /tmp/dev-server.log 2>&1 & ;;
    npm)  npm run dev > /tmp/dev-server.log 2>&1 & ;;
    *)    echo "::warning::Unknown package manager -- cannot start dev server" ;;
  esac
  echo "dev_pid=$!" >> "$GITHUB_OUTPUT"
fi

# ── Phase 3: Health checks ──
API_READY=false
API_URL=""
WEB_READY=false
WEB_URL=""

if [ "$HAS_CONFIG" = "true" ]; then
  # Read URLs from Known service ports table
  API_URL=$(extract_port_url "API" "$CONFIG")
  WEB_URL=$(extract_port_url "Web" "$CONFIG")
fi

# Probe API URL (from config or auto-discover).
#
# Configs often list the API base as e.g. `http://localhost:4000` even when the
# framework mounts routes under a prefix (`/api`, `/health`, etc.), so a plain
# probe against the base URL 404s and the whole step times out. Try the given
# URL first, then fall back to common health paths on the same origin before
# giving up.
if [ -n "$API_URL" ]; then
  API_ORIGIN=$(printf '%s' "$API_URL" | sed -E 's#^(https?://[^/]+).*#\1#')
  for i in $(seq 1 30); do
    if curl -sf "$API_URL" > /dev/null 2>&1; then
      API_READY=true; break
    fi
    for suffix in /api /api/health /api/ping /health /healthz; do
      if curl -sf "${API_ORIGIN}${suffix}" > /dev/null 2>&1; then
        API_URL="${API_ORIGIN}${suffix}"
        API_READY=true
        echo "Auto: API responded at $API_URL (configured base did not)"
        break 2
      fi
    done
    sleep 2
  done
else
  # Auto-probe common API ports
  for port in 3001 4000 8080 8000; do
    for path in /api /health /; do
      if curl -sf "http://localhost:$port$path" > /dev/null 2>&1; then
        API_URL="http://localhost:$port$path"
        API_READY=true
        echo "Auto-discovered API at $API_URL"
        break 2
      fi
    done
  done
  if [ "$API_READY" = "false" ]; then
    # Wait and retry
    sleep 15
    for port in 3001 4000 8080 8000; do
      for path in /api /health /; do
        if curl -sf "http://localhost:$port$path" > /dev/null 2>&1; then
          API_URL="http://localhost:$port$path"
          API_READY=true
          echo "Auto-discovered API at $API_URL (after wait)"
          break 2
        fi
      done
    done
  fi
fi

# Probe Web URL (from config or auto-discover)
if [ -n "$WEB_URL" ]; then
  for i in $(seq 1 15); do
    curl -sf "$WEB_URL" > /dev/null 2>&1 && WEB_READY=true && break
    sleep 2
  done
else
  for port in 3000 5173 4200 8080; do
    if curl -sf "http://localhost:$port" > /dev/null 2>&1; then
      WEB_URL="http://localhost:$port"
      WEB_READY=true
      echo "Auto-discovered Web at $WEB_URL"
      break
    fi
  done
fi

echo "api_ready=$API_READY" >> "$GITHUB_OUTPUT"
echo "api_url=$API_URL" >> "$GITHUB_OUTPUT"
echo "web_ready=$WEB_READY" >> "$GITHUB_OUTPUT"
echo "web_url=$WEB_URL" >> "$GITHUB_OUTPUT"

# ── Phase 4: Auth (from review-config.md) ──
AUTH_READY=false
if [ "$HAS_CONFIG" = "true" ] && [ "$API_READY" = "true" ]; then
  AUTH_CODE=$(extract_section_code "Auth" "$CONFIG")
  if [ -n "$AUTH_CODE" ]; then
    echo "Running auth setup from review-config.md..."
    # Same subshell-isolation pattern as the Functional validation eval:
    # an `exit N` or unbound var in the config must not kill the step.
    ( eval "$AUTH_CODE" ) && AUTH_READY=true || echo "::warning::Auth setup from config failed"
  fi
fi
echo "auth_ready=$AUTH_READY" >> "$GITHUB_OUTPUT"

if [ "$API_READY" = "true" ]; then
  echo "API ready at $API_URL"
else
  echo "::warning::API not ready"
  tail -30 /tmp/dev-server.log 2>/dev/null || true
fi
echo "Dev env: API=$API_READY ($API_URL), Web=$WEB_READY ($WEB_URL), Auth=$AUTH_READY"
echo "::endgroup::"
