# Claude PR Review Pipeline

Reusable, multi-stage PR review pipeline powered by Claude Code. Runs automated code review with correctness checking (Opus), consistency/performance analysis (Sonnet), and end-to-end functional testing (Sonnet + Playwright).

## Quick Start

### 1. Add the caller workflow

Create `.github/workflows/claude-review.yml` in your repo. **Pin to a full commit SHA** — `secrets: inherit` hands every repo/org secret (including `CLAUDE_CODE_OAUTH_TOKEN`) to this workflow, so a mutable tag is a supply-chain risk. Bump the SHA deliberately when you want a new version.

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
    # Pin to an immutable SHA. Look up the current v1 SHA at
    # https://github.com/Panenco/claude-review/commits/v1 and substitute below.
    uses: panenco/claude-review/.github/workflows/pr-review.yml@<40-char-sha>  # v1
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

If you prefer `@v1` over a SHA (accepting the risk), know that **both the reusable workflow file and the composite action download resolve against the tag at different moments of the job**. Moving `v1` while a run is starting can cause a version mismatch between the two — prefer SHA pinning for deterministic behavior.

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

Free-text guidance for reviewers:

```markdown
## Stack-specific review focus

**API (NestJS + Prisma)**
- Controllers must be thin — business logic in Handler services.
- Tests must use real database, not mock the ORM.

**Web (Next.js)**
- Data fetching via TanStack Query only. Query keys centralized.
```

#### `## Functional validation`

Setup instructions for the dev environment. Use fenced bash code blocks — the workflow extracts and executes them:

```markdown
## Functional validation

### Step 1: Start database

\`\`\`bash
docker compose up -d
for i in $(seq 1 15); do docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 && break; sleep 2; done
\`\`\`

### Step 2: Environment

\`\`\`bash
cp .env.example .env
\`\`\`

### Step 3: Migrations

\`\`\`bash
cd apps/api && npx prisma generate && npx prisma migrate deploy && cd ../..
\`\`\`

### Step 4: Dev servers

\`\`\`bash
pnpm run dev &
\`\`\`
```

#### `### Auth`

Authentication for functional testing:

```markdown
### Auth

- Sign up: `POST /api/auth/sign-up/email` with `{"name":"Test","email":"test@ci.local","password":"Password1!"}`
- Sign in: `POST /api/auth/sign-in/email` with `{"email":"test@ci.local","password":"Password1!"}`
- Method: cookie (use `-c cookies.txt` / `credentials: 'include'`)
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

The configuration examples above cover common stacks. For more examples, see this repo's issue tracker or the qec-app reference implementation:

- NestJS + Prisma monorepo — see [qec-app's review-config.md](https://github.com/Panenco/qec-app/blob/main/.github/review-config.md)
- Other stacks — contributions welcome
- Python FastAPI

---

## Architecture

The pipeline consists of:

- **Reusable workflow** (`.github/workflows/pr-review.yml`) — orchestration, dev env setup, agent launching, finding merge, review posting
- **5 skill files** (`skills/`) — prompt templates defining review methodology
- **Functional prompt template** (`scripts/functional-prompt.template.txt`) — bootstraps the functional tester with auth + env info

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
