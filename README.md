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

Optional: for a custom review bot identity, also set `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, and `CLAUDE_REVIEW_APP_SLUG`.

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
[Setup] Node, deps, Playwright, dev environment (launched in background
        alongside Stage 1 to overlap bring-up with context gathering)
    |
[Stage 1: Context Builder] (Sonnet)
    Gathers PR metadata, diff, issue, conventions, build verification.
    On round-2 follow-up reviews also computes /tmp/since-last.diff
    against the prior review's HEAD.
    Writes context.md + test-plan.md
    |
[Stage 2: Parallel Reviewers]
    |-- Core (Opus): bugs, spec mismatches, security
    |-- Sweep (Sonnet): consistency, test quality, performance
    |-- Spec-compliance (Sonnet): PRD-vs-code (only when a PRD is detected)
    |-- Functional (Sonnet + Playwright): E2E testing, screenshots
    |
    Round 1 only (first review of the PR):
    |-- Core pass-2 (Opus): independent re-review, union-of-finding boost
    |-- Sweep pass-2 (Sonnet): independent re-review
    |-- Gap-finder critic (Opus, sequential after the parallel fan):
        net-new findings the prior pairs missed
    |
    Round 2 only (subsequent pushes):
    |-- Resolution checker (Sonnet): classifies every prior finding as
        RESOLVED / STILL_PRESENT / NEW_CONTEXT against /tmp/since-last.diff
    |
[Stage 3: Merge + Dedup + Post]
    Haiku-driven semantic dedup across every reviewer's output (groups
    by root cause, not just path+line; on round 2 also drops new findings
    whose root cause matches a STILL_PRESENT prior). Uploads screenshots,
    persists round-state for the next follow-up review, posts atomic review.
    |
Verdict: APPROVE / COMMENT / REQUEST_CHANGES
```

### Round 1 vs round 2

The pipeline persists a small state artifact (`/tmp/review-state.json`) on every successful run — the deduped findings, verdict, and head SHA reviewed. On the next push to the same PR, the next run downloads it, computes the diff since that SHA, and runs the round-2 fan above. The verdict ladder gains a round-2 layer:

- Prior `REQUEST_CHANGES`, no new criticals/majors, all prior blockers `RESOLVED` → `APPROVE`.
- Prior `REQUEST_CHANGES`, no new blockers, some prior blockers `STILL_PRESENT` → keep `REQUEST_CHANGES`.
- Prior `COMMENT`, no new blockers → keep `COMMENT` (don't auto-promote on a pure follow-up).
- Any prior verdict + ≥1 new critical/major → `REQUEST_CHANGES`.

Round-1 is otherwise identical to the legacy single-pass review with the recall boost (double-pass + critic) layered on. If the prior state artifact is missing (retention expired, prior run failed before upload), round 2 degrades to a clean full re-review with a `::notice::` explaining why.

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

First-class contract for bringing up the dev environment. The pipeline runs this script in a subshell, then probes URLs from `### Known service ports` and the auth block. **Non-zero exit fails the Pre-start step and stops the whole review** — don't commit a `dev-start.sh` you haven't run successfully from a clean checkout. Repos that genuinely have nothing to start should not create the file at all (its absence is the signal for degraded mode).

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

If the project has nothing to start (pure-docs, lib-only), do **not** create this file. Its absence is the signal for degraded mode (core + sweep reviewers run; no functional tester). An empty-but-present `dev-start.sh` will fail the step.

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

### `.github/claude-review/fetch-issue.sh` (optional — external issue trackers)

The default spec sources are the linked GitHub issue and any `docs/prds/*.md` referenced from the PR/issue body. Repos that track specs in Linear, Jira, Monday, Notion, etc. can opt into a hook that fetches the external spec and includes it in `context.md` alongside the GitHub one. **No provider is built in here** — the consumer owns the script and picks whatever API call makes sense for their tracker.

Three steps to opt in:

**1. Create a repo secret `TRACKER_SECRETS`** with your credentials in `KEY=VALUE` lines (blank lines and `# comments` are skipped). Pick any names that make sense for your tracker — the workflow exports each line as an env var to your script:

```
LINEAR_API_KEY=lin_api_xxxxx
LINEAR_WORKSPACE=panenco
```

**2. Drop `.github/claude-review/fetch-issue.sh`**. Adapt the `jq` filters and the `curl` call to your tracker:

```bash
#!/usr/bin/env bash
set -uo pipefail

# 1. Pick the best ticket reference from the pre-extracted candidates.
#    Prefer explicit markers, then URLs whose host matches your tracker, then
#    keyword-qualified targets, then bare IDs. Exit 0 with no output if nothing
#    matches — that's a normal case, the workflow handles it cleanly.
TICKET=$(jq -r '
    [.explicit_markers[] | select(.key | ascii_downcase == "<your-tracker>") | .value][0]
    // [.urls[] | select(.host == "<your-tracker-host>") | .url][0]
    // [.closing_keywords[] | .target][0]
    // [.ids[] | .id][0]
    // empty
  ' "$ISSUE_CANDIDATES_FILE")
[ -z "${TICKET:-}" ] && exit 0

# 2. Fetch from your tracker using env vars you set via TRACKER_SECRETS.
curl -sS --fail-with-body "<your-tracker-api-url>" \
  -H "Authorization: $YOUR_API_KEY" \
  -H "Accept: application/json" \
| jq -r '"# " + .title + "\n\n" + .description'
```

**3. (Optional, recommended) Add a `Ticket:` line to your PR template** so authors paste the tracker URL — this lands in the highest-confidence bucket:

```
Ticket: https://linear.app/team/issue/LIN-123/...
```

#### Contract

```
Script:  .github/claude-review/fetch-issue.sh  (presence = opt-in)
Env in:
  PR_NUMBER, PR_TITLE, PR_BODY, HEAD_REF, BASE_REF, REPO    (always set)
  ISSUE_CANDIDATES_FILE=/tmp/external-issue-candidates.json  (always set)
  <anything you put in TRACKER_SECRETS>                      (your chosen names)
Stdout:  markdown. Inlined verbatim under "## Linked external issue" in context.md.
         For best results, make the first line a heading that surfaces the
         tracker identifier, e.g. "## Linked Linear issue: LIN-123" — the
         core reviewer extracts this into spec_sources.external_issue so
         the final review summary can show the tracker ID alongside any
         GitHub #N link. Omit the identifier and external_issue stays null;
         the section body is still read for acceptance-criteria extraction.
Exit:    0 with output     = success.
         0 with no output  = no external issue for this PR (normal).
         non-zero          = soft-fail: ::warning:: logged, review continues.
```

`GH_TOKEN` is deliberately **not** forwarded. If your script needs authenticated GitHub calls, add your own PAT via `TRACKER_SECRETS`.

#### `$ISSUE_CANDIDATES_FILE` schema

A workflow step scans the branch name, PR title, and PR body for every recognized ticket-reference pattern and writes the result here before your script runs. The file is always present and always valid JSON (empty arrays when nothing matches). Your script picks the signal that matches your tracker.

```json
{
  "explicit_markers": [{"key": "Linear", "value": "LIN-123", "source": "pr_body_line"}],
  "closing_keywords": [{"keyword": "Fixes", "target": "LIN-123", "source": "pr_body"}],
  "urls":             [{"url": "https://linear.app/...", "host": "linear.app", "source": "pr_body"}],
  "ids":              [{"id": "LIN-123", "source": "branch_name"}]
}
```

Confidence tiers (in extraction priority order): (1) `explicit_markers` — `Ticket: …` / `<Provider>: …` lines in the PR body; (2) `closing_keywords` — `Fixes LIN-123` / `Closes https://…`; (3) `urls` in the PR body (host exposed so you can filter); (4) `ids` from the branch name; (5) `ids` from the PR body without a keyword; (6) `ids` from the PR title (often a `[LIN-123]` prefix). Source field on each `ids` entry is one of `branch_name`, `pr_body`, `pr_title`.

---

## Degradation Matrix

| Missing file | Impact | Behavior |
|---|---|---|
| `.github/claude-review/dev-start.sh` | Expected for degraded mode | Functional tester skipped. Core + sweep reviewers still run. |
| `.github/claude-review/fetch-issue.sh` | Expected when only GitHub is used | Skipped silently. GitHub-issue lookup remains the default spec source. |
| `review-config.md` | Reduced | No build prep doc, no convention-rule routing, no Known-service-ports URLs to probe, no auth setup. |
| `bugbot.md` | Minor | Reviewers use generic methodology only (no project-specific rules, no accepted-trade-offs exemptions). |
| `CLAUDE.md` | Minor | No architecture context. Reviewers rely on diff + issue. |
| All config files | Significant | Code-only review (core + sweep) on raw diff + build output. Still catches bugs, spec issues, security. |

Note: a *present but broken* `dev-start.sh` is **not** a soft-degrade case — the pipeline fails the Pre-start step and stops. Remove the file to enter degraded mode explicitly.

---

## Spec-presence gate

The pipeline withholds `APPROVE` whenever the PR has no human-authored spec. The core reviewer judges this from the spec sources gathered in `context.md` — a linked GitHub issue with a non-trivial body, a PRD, an external-tracker spec, or a substantive manually-written PR-body section all qualify. Auto-generated PR descriptions (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code) describe what the diff *does*, not what it *should do*, and don't qualify on their own — they're a code summary, not a contract. When the core reviewer sets `manual_spec_present: false`, the verdict is downgraded from `APPROVE` to `COMMENT` and the review body explains how to fix it (link an issue, paste acceptance criteria, or wire up an external tracker). Findings still post normally; only the green-check approval is gated.

## Smoke-test gate for technical PRs

The pipeline withholds `APPROVE` whenever the PR's stated intent is "no user-visible behavior change" (refactor, library swap, framework/runtime upgrade, build-config change, restructure, perf rewrite — across any ecosystem) but the smoke run did not pass. The trigger is intent, not file types: a `refactor: split foo into bar/baz` with no manifest touch counts; a major `Cargo.toml`/`Dockerfile`/`pyproject.toml` bump counts. The test planner detects this from PR title/body keywords (`refactor`, `chore`, `bump`, `upgrade`, `migrate`, "no behavior change"), diff shape (high move/rename ratio, low net new logic), and dependency-manifest deltas, then emits `## Technical change: true` in `test-plan.md`. The functional tester copies the flag into `functional-meta.json` and walks through one representative user flow (the planner picks it autonomously based on which code paths the change affects) with screenshots. If the smoke run does not return `PASS` or `WARN` — including the degraded-mode case where `.github/claude-review/dev-start.sh` is missing and the app can't be brought up — the verdict is downgraded from `APPROVE` to `COMMENT` and the review body explains how to enable it (configure `dev-start.sh`, or fix the smoke failures). Composes naturally with the spec-presence gate: together they ensure `APPROVE` is only granted when *something* substantively validated the change, either an acceptance criterion or a working app.

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
- **9 skill files** (`skills/`) — prompt templates defining review methodology: `review-context-builder`, `review-core`, `review-sweep`, `review-spec-compliance`, `review-functional-tester`, `review-test-planner`, `review-gap-finder` (round-1 critic), `review-dedup` (Haiku semantic dedup), `review-resolution-checker` (round-2 prior-finding classifier)
- **Functional prompt template** (`scripts/functional-prompt.template.txt`) — bootstraps the functional tester with auth + env info

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
