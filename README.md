# Claude PR Review Pipeline

Reusable, multi-stage PR review pipeline powered by Claude Code. Runs automated code review with correctness checking (Opus), consistency/performance analysis (Sonnet), and end-to-end functional testing (Sonnet + Playwright).

## Quick Start

### 1. Add the caller workflow

Create `.github/workflows/claude-review.yml` in your repo. Track the `@v1` tag so pipeline fixes propagate automatically across all consumer repos — the reusable workflow and its composite action both get pulled fresh at job start. Pair this with the `bugbot.md` policy line in Step 3 so the reviewer does not re-flag `@v1 + secrets: inherit` on every PR.

```yaml
name: Claude PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number to review'
        required: true
        type: string
jobs:
  review:
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v1
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

Why `@v1` and not a SHA pin: every consumer repo stays on the same moving target, so a fix landed on `panenco/claude-review` reaches everything on the next PR push without touching any downstream repo. The trade-off — a mutable tag + `secrets: inherit` is technically a supply-chain vector — is one we explicitly accept here because upstream is first-party (Panenco org) and the logistics of SHA-bumping every consumer after every pipeline fix were unworkable. If *your* repo has different trust needs, substitute a 40-char SHA for `@v1`.

**Tag-resolution caveat.** The reusable workflow file and the composite action resolve `@v1` at different moments of the job. Moving `v1` while a run is starting can cause a mismatch between the two — push the `v1` tag at idle times, not while runs are in flight.

### 2. Set secrets

Add `CLAUDE_CODE_OAUTH_TOKEN` as a repo or org secret. Generate it with:

```bash
claude setup-token
```

Optional: for a custom review bot identity, also set `CLAUDE_REVIEW_APP_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, and `CLAUDE_REVIEW_APP_SLUG`.

### 3. (Optional) Add project config

For best results, add two optional files:

- `bugbot.md` — project-specific review rules
- `.github/review-config.md` — build prep, conventions, dev env, auth

Without these, the pipeline still works — it auto-discovers what it can and runs core + sweep reviewers.

---

## How It Works

```
PR opened / updated
    |
[Setup] Node, deps, Playwright, dev environment
    |
[Stage 1: Context Builder] (Sonnet)
    Gathers PR metadata, diff, issue, conventions, build verification
    Writes context.md + test-plan.md
    |
[Stage 2: Parallel Reviewers]
    |-- Core (Opus): bugs, spec mismatches, security
    |-- Sweep (Sonnet): consistency, test quality, performance
    |-- Functional (Sonnet + Playwright): E2E testing, screenshots
    |
[Stage 3: Merge + Post]
    Deduplicates findings, uploads screenshots, posts atomic review
    |
Verdict: APPROVE / COMMENT / REQUEST_CHANGES
```

---

## Per-Project Configuration

### `bugbot.md` (optional)

A markdown list of project-specific review rules. Place at the repo root. Both the core and sweep reviewers read this.

```markdown
# Bugbot

- Controllers must be thin. Business logic goes through the Handler Pattern.
- No Server Components or Server Actions. Strict SPA.
- Tests use real database. Never mock the ORM.
- Secrets and URLs come from config/environment, never hardcoded.
```

#### False-positive prevention

Add a "Verify before flagging" section to prevent reviewers from citing libraries or components that don't exist in your repo:

```markdown
## Verify before flagging

Before reporting a finding that cites a library or component, confirm it exists:
- Check `context.md` -> "Repo capabilities" for available exports and dependencies.
- If the artifact is not listed, drop the finding or move to `uncertain_observations`.
```

### `.github/review-config.md` (optional)

Structured markdown with these sections (all optional):

#### `## Build preparation`

Commands to run after `install` and before typecheck/lint:

```markdown
## Build preparation

After install, run:

\`\`\`bash
pnpm --recursive exec prisma generate
\`\`\`
```

#### `## Convention files`

Map changed paths to convention/rule files:

```markdown
## Convention files

| Changed path | Read |
|---|---|
| `apps/api/**` | `.cursor/rules/api.mdc`, `.cursor/rules/general.mdc` |
| `apps/web/**` | `.cursor/rules/web.mdc`, `.cursor/rules/general.mdc` |
```

#### `## Stack-specific review focus`

Free-text guidance for reviewers. Write rules in terms of **your** stack — the pipeline is framework-agnostic. Example framing:

```markdown
## Stack-specific review focus

**API (<your framework>)**
- <Architectural rule reviewers must enforce — e.g., "controllers thin, logic in services".>
- <Test expectation — e.g., "tests use real DB, never mock the ORM".>

**Web (<your framework>)**
- <Data-fetching rule — e.g., "data via <library>; query keys centralized".>
```

#### `## Functional validation`

**Prose only — no executable bash.** This section is read by the reviewer agents from `context.md` and describes what the functional tester should exercise. The *executable* side of dev-env bring-up lives in `.github/claude-review/dev-start.sh` (see below).

Describe (in prose) what the project needs at runtime: database flavour + credentials, where `.env` lives, migrations/codegen, dev-server ports, seed data / test users. Do not duplicate the commands — the script is the source of truth.

> Legacy: older configs embed bash blocks in this section. The pipeline still supports that path with a `::warning::` prompting migration to `dev-start.sh`.

### `.github/claude-review/dev-start.sh` (recommended)

First-class contract for bringing up the dev environment. The pipeline runs this script in a subshell, then probes URLs from `### Known service ports` and the auth block. Non-zero exit is tolerated: the review falls through to degraded mode (core + sweep still run).

```bash
#!/usr/bin/env bash
set -uo pipefail

# Bring up database (if any) — ALWAYS fail fast on timeout.
docker compose up -d postgres
READY=false
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U <user> -d <db> > /dev/null 2>&1; then
    READY=true; break
  fi
  sleep 2
done
[ "$READY" = "true" ] || { echo "::error::Postgres never became ready in 60s"; exit 1; }

# Install, codegen, migrate.
pnpm install --frozen-lockfile
# e.g. pnpm exec prisma generate && pnpm exec prisma migrate deploy

# Start services.
pnpm run dev > /tmp/dev.log 2>&1 &
DEV_PID=$!

# Block until healthy.
API_READY=false
for i in $(seq 1 60); do
  if curl -fsS http://localhost:<port>/<health-path> > /dev/null 2>&1; then
    API_READY=true; break
  fi
  sleep 2
done
[ "$API_READY" = "true" ] || { echo "::error::API never became ready"; tail -n 200 /tmp/dev.log; exit 1; }
```

Rules:
- `chmod +x` after creating it.
- No `set -e` — the subshell wrapper already tolerates exit N, and `set -e` surprises you in idioms like `curl || true`.
- Readiness loops must explicitly test the flag after the loop and `exit 1` on timeout. Silent-success loops are flagged by the reviewer.
- Paths in `cp`/`source`/`cat` are scanned at job start; the Validate step warns if any don't exist.

If the project has nothing to start (pure-docs, lib-only), skip this file. The pipeline warns once and runs core + sweep without functional testing.

#### `### Auth`

Authentication for functional testing:

```markdown
### Auth

- Sign up: `POST <endpoint>` with `<JSON body>`
- Sign in: `POST <endpoint>` with `<JSON body>`
- Method: cookie | bearer | header | none
```

**Phrasing matters for auto-extraction.** The functional tester scans for sign-in lines starting with `Sign in:`, `Sign-in:`, `Signin:`, `Log in:`, `Log-in:`, or `Login:` to pre-build an authentication snippet. If yours is phrased differently, it still works — the agent reads this whole section from `context.md` and follows it — but the pre-built snippet won't be generated.

**Header-based auth (e.g., custom `x-auth` token) — document the capture step:**

```markdown
### Auth

- Sign in: `POST /api/auth/login` with `{"email":"<email>","password":"<password>"}`
- On success the token is returned in the `x-auth` response header. Subsequent requests must include `x-auth: <token>`.
- Method: header
```

#### `### Known service ports`

```markdown
### Known service ports

| Service | URL | Notes |
|---------|-----|-------|
| API | http://localhost:3001/api | Health at GET /api |
| Web | http://localhost:3000 | |
```

---

## Degradation Matrix

| Missing file | Impact | Behavior |
|---|---|---|
| `review-config.md` | Reduced | No build prep, no conventions, no functional testing. Core + sweep still work. |
| `bugbot.md` | Minor | Reviewers use generic methodology only. |
| `CLAUDE.md` | Minor | No architecture context. Reviewers rely on diff + issue. |
| Both config files | Significant | Code-only review (core + sweep) with auto-detected capabilities. Still catches bugs, spec issues, security. |

---

## Versioning

- `@v1` — floating tag, always points to latest v1.x.x. Use this for auto-updates.
- `@v1.0.0` — pinned tag. Use for critical stability.
- Breaking changes (input/output format changes) bump to `@v2`.

---

## Example Configs

The `bugbot.md` and `review-config.md` examples above cover the common shapes. Adapt them to your stack rather than copying verbatim. The pipeline is framework-agnostic; the reviewer reads the files verbatim, so what you write is what it enforces.

If you have a polished config for a stack not covered here (e.g. Python/FastAPI, Rails, Go) and would like to share it as a reference, open a PR on this repo.

---

## Architecture

The pipeline consists of:

- **Reusable workflow** (`.github/workflows/pr-review.yml`) — orchestration, dev env setup, agent launching, finding merge, review posting
- **5 skill files** (`skills/`) — prompt templates defining review methodology
- **Functional prompt template** (`scripts/functional-prompt.template.txt`) — bootstraps the functional tester with auth + env info

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
