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

Setup instructions for the dev environment. The workflow extracts **bash code blocks** from this section and `eval`s them in sequence, then starts a dev server via your package manager. Reference files by the path they actually live at in your repo (e.g., `apps/api/.env.example`, not `.env.example`, if that's where your example lives). The "Validate review config" step warns at job-start when paths mentioned here don't exist.

Generic template — adapt to your stack:

```markdown
## Functional validation

### Step 1: Start database (if needed)

\`\`\`bash
# Use whatever your project uses to start services. Common examples:
docker compose up -d
# Then wait for readiness:
for i in $(seq 1 15); do docker compose exec -T <service> pg_isready -U <user> > /dev/null 2>&1 && break; sleep 2; done
\`\`\`

### Step 2: Environment

\`\`\`bash
# Adjust the source path to where YOUR .env.example actually lives
cp <path/to/>.env.example .env
\`\`\`

### Step 3: Migrations / ORM setup (if any)

\`\`\`bash
# e.g. Prisma: cd <api-dir> && npx prisma generate && npx prisma migrate deploy
# e.g. Drizzle: cd <api-dir> && npx drizzle-kit push
# e.g. TypeORM: cd <api-dir> && npx typeorm migration:run
# e.g. Django:  python manage.py migrate
\`\`\`

### Step 4: Dev servers

The workflow auto-starts `<pkg-manager> run dev` if no server is already listening after this section runs, so only add a `dev` command here if your project needs something non-standard.
```

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
