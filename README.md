# Claude PR Review Pipeline

Reusable PR review pipeline powered by Claude Code. A single orchestrator agent runs two independent judges in parallel (Opus for deep reasoning, Haiku for cheap broad coverage), reconciles them through a debate loop, and dispatches an end-to-end functional tester (Sonnet + Playwright) when the diff has user-observable surface.

## Quick Start

### 1. Add the caller workflow

Create `.github/workflows/claude-review.yml` in your repo. Track the `@v2` tag so pipeline fixes propagate automatically across all consumer repos — the reusable workflow and its composite action both get pulled fresh at job start. Pair this with the `bugbot.md` policy line in Step 3 so the reviewer does not re-flag `@v2 + secrets: inherit` on every PR. (If you're still on `@v1`, see [Migration: v1 → v2](#migration-v1--v2) — the bump requires one new permission and may change verdicts on refactor / auto-described PRs.)

```yaml
name: Claude PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  push:
    branches: [main]  # warms the Playwright cache
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number to review'
        required: true
        type: string
jobs:
  review:
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v2
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

The `permissions:` block is required: reusable workflow permissions are capped by the caller's, and GitHub's default `GITHUB_TOKEN` is read-only at most orgs. Omitting it produces `startup_failure` with no logs. See `prompts/setup-review.md` for the full troubleshooting flow.

Why `@v2` and not a SHA pin: every consumer repo stays on the same moving target, so a fix landed on `panenco/claude-review` reaches everything on the next PR push without touching any downstream repo. The trade-off — a mutable tag + `secrets: inherit` is technically a supply-chain vector — is one we explicitly accept here because upstream is first-party (Panenco org) and the logistics of SHA-bumping every consumer after every pipeline fix were unworkable. If *your* repo has different trust needs, substitute a 40-char SHA for `@v2`.

**Tag-resolution caveat.** The reusable workflow file and the install step resolve their refs at different moments of the job. Moving `v2` while a run is starting can cause a mismatch — push the `v2` tag at idle times, not while runs are in flight.

**Pinning to a non-default ref.** Pre-release dogfooding (testing pipeline changes against a real consumer repo before merging to `main`) needs both the workflow file and the install step at the same ref. Pass `pipeline_ref` so the install matches:

```yaml
uses: panenco/claude-review/.github/workflows/pr-review.yml@<branch-or-sha>
with:
  pr_number: ${{ inputs.pr_number || '' }}
  pipeline_ref: <branch-or-sha>
```

Without `pipeline_ref`, the install defaults to `@v2` and consumers get new orchestration on old skills, which fails at max-turns. The `@v2` default is correct for normal use; only override during testing.

### 2. Set secrets

Add `CLAUDE_CODE_OAUTH_TOKEN` as a repo or org secret. Generate it with:

```bash
claude setup-token
```

Optional — when one Claude.ai subscription's 5-hour rate-limit window keeps blocking reviews, run `claude setup-token` against multiple subscriptions and put all tokens (one per line) in a single secret named `CLAUDE_CODE_OAUTH_TOKENS` instead. The pipeline probes each at job start and randomly picks one with capacity available.

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
[Setup] Node, deps, dev environment, install
        .claude/agents/review-functional-tester.md (subagent definition
        with inline `mcpServers` for Playwright MCP — server starts when
        the orchestrator dispatches the subagent, NOT at orchestrator
        start; eliminates the lazy-spawn vs ToolSearch chicken-and-egg
        that left MCP "pending" silently). Dev-env launched in background —
        overlaps with the orchestrator's context-build phase so total wall
        time = max(CB, dev-env).
    |
[One agent: Review: orchestrate]  (anthropics/claude-code-action)
    A single Sonnet orchestrator runs end-to-end and dispatches
    everything via the Task tool:
      Phase 0   — Task: context builder (Sonnet) → context.md +
                  test-plan.md (with a 5-sentence diff summary at the top
                  of context.md).
      Phase 0.5 — Bash: poll /tmp/dev-env/rc, source the dev-env outputs
                  (API_URL, WEB_URL, …) for the functional subagent.
      Phase 1   — Early-exit on docs-only / trivial PRs (zero non-doc
                  chunks AND no spec source) without dispatching any
                  judges. Writes APPROVE-eligible meta and exits.
      Phase 2   — Parallel Task fan (single assistant response):
                    Judge-Opus  (model: claude-opus-4-7)   ─┐
                    Judge-Haiku (model: claude-haiku-4-5)  ├ all parallel
                    Thread classifier (round 2 only)       │
                    Functional tester (Playwright MCP)     ─┘
                  Pipeline-self-test runs as Bash directly when
                  STRATEGY=pipeline-self-test (deterministic, no LLM).
      Phase 3   — Up to 2 rebuttal rounds when judges disagree (each
                  round dispatches both judges in parallel via Task
                  with MODE=rebuttal; each sees the other's findings).
      Phase 4   — Consolidate + write /tmp/all-findings.json and
                  /tmp/review-meta.json. No separate dedup step — the
                  judge debate IS the dedup.
    |
[Stage 2: Build + Post]  (pure Bash)
    Reads /tmp/all-findings.json + /tmp/review-meta.json directly.
    Applies the round-2 verdict ladder using thread-classifier output,
    uploads screenshots, persists round-state, replies + closes
    RESOLVED threads (own bot, other bots, AND humans), posts atomic
    review.
    |
Verdict: APPROVE / COMMENT / REQUEST_CHANGES
```

### Why one top-level agent?

Two practical wins. (1) **Native rate-limit fast-fail.** `anthropics/claude-code-action` exits in <1 s when the OAuth token hits a quota wall; the bare `claude -p` CLI silently retries and *hangs* until the 45-minute job timeout — a real bug observed on PR #309. (2) **All parallelism through the `Task` tool.** No bash background processes, no `wait`/reap traps, no sibling stdout files. One nested transcript covers the whole review.

### Why two judges?

A single LLM judge can have a bad sample on any given run — miss something subtle, over-grade a defensive note, mis-route a finding to the wrong file. The orchestrator runs **two independent judges with different model strengths** (Opus for deep reasoning, Haiku for cheap broad-coverage finds) and reconciles them: if they agree, the review ships immediately; if they disagree, each judge sees the other's findings and either concedes the ones they missed or defends the ones the other dropped. This catches the long tail where one judge is wrong without paying for it on every PR — most reviews converge on the first round.

### Round 1 vs round 2

The pipeline persists a small state artifact (`/tmp/review-state.json`) on every successful run — the deduped findings, verdict, head SHA reviewed, and the posted review's GitHub id. On the next push to the same PR, the next run downloads it, computes the diff since that SHA, and the round-2 thread classifier runs alongside the orchestrator. The verdict ladder gains a round-2 layer that's strictly **anti-downgrade**:

- Prior `REQUEST_CHANGES`, no new criticals/majors, all prior blockers `RESOLVED` → per-PR verdict (APPROVE if no new findings, COMMENT otherwise).
- Prior `REQUEST_CHANGES`, some prior blockers `STILL_PRESENT` → keep `REQUEST_CHANGES`.
- Prior `COMMENT`, no new blockers → per-PR verdict (APPROVE when the per-PR judgement is APPROVE, COMMENT when minor findings remain). The ladder no longer pins prior=COMMENT to COMMENT — that ratchet was the source of "bot says Would APPROVE but verdict says COMMENT" contradictions.
- Any prior verdict + ≥1 new critical/major → `REQUEST_CHANGES` (handled by the per-PR ladder upstream).
- Prior review **dismissed by the author** → treat prior verdict as APPROVE for ladder purposes (the dismissal is the strongest signal a human gives the bot; we don't re-enforce findings the author has rejected). Surfaced as a banner in the review body.

When the round-2 ladder overrides the bot's per-PR judgement (e.g. STILL_PRESENT blockers force REQUEST_CHANGES on a clean re-review), the body prepends a one-line "Verdict pinned to X by the round-2 ladder" rationale so the body's narrative never contradicts the header.

**Thread resolution covers humans too.** When the thread classifier marks a thread RESOLVED, the poster replies with `✅ Resolved as of <sha>` and calls `resolveReviewThread` — for our own past bot comments, for other bots' threads (cursor, aikido, sonarcloud), and for human reviewers' inline comments. A "this should be X" from a teammate that gets fixed in a follow-up commit closes automatically, same as a bot's finding.

**Severity grading:** the bot uses four levels — `critical` and `major` block (REQUEST_CHANGES); `minor` and `note` post inline but never gate APPROVE. Doc nits / identifier typos / "you might consider …" observations land at `note` so a single one-word fix doesn't hold a PR at COMMENT. The judge skill enforces a "demonstrate the failure mode" rule for blocking severities — if a critical/major finding can't show the path that produces a real outcome, it's downgraded.

**Findings outside diff hunks:** comments whose `path:line:side` falls outside any diff hunk (deleted-line findings without `side: "LEFT"`, or near-but-imprecise line targets) are appended to the review body under "Findings outside diff hunks" rather than silently dropped. Setting `side: "LEFT"` for deleted-line findings keeps them inline.

**Crash-banner cleanup:** when a run crashes before posting a review (OAuth quota, max-turns, runner OOM), the workflow posts a single review carrying the `<!-- claude-review-crash -->` HTML marker. The next successful run finds that review and edits its body to a "_Superseded by …_" form so the misleading red banner doesn't survive every retry.

If the prior state artifact is missing (retention expired, prior run failed before upload), round 2 degrades to a clean full re-review with a `::notice::` explaining why.

On round 2 the test planner also rescopes the functional run: scenarios are planned against `/tmp/since-last.diff` rather than the full PR diff, and **zero scenarios is a valid outcome**. A small follow-up commit drops to `quick` (one scenario over the touched area) when since-last has user-observable surface, or `skip` (no scenarios) when since-last is comments / log strings / type-only / internal-helper / docs / config / dev-tooling — anything a user wouldn't notice. The smoke gate inherits the prior round's `functional_overall` for technical-change PRs, so a `skip` on round 2 doesn't drop APPROVE → COMMENT (inheritance kicks in only for prior PASS/WARN; a prior FAIL still blocks). Prior `critical`/`major` functional findings whose path is in since-last AND is plausibly the area being fixed get one targeted retest scenario; otherwise the resolution-checker + dedup re-evaluate them independently.

---

## Per-Project Configuration

### `bugbot.md` (optional)

A markdown list of project-specific review rules. Place at the repo root. Both judges read this (it's inlined into the orchestrator prompt and forwarded to each judge subagent).

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

# Install, codegen, migrate. The pipeline puts a default pnpm on PATH,
# but pin your project's real version via `packageManager` + corepack so
# lockfile semantics match local.
corepack enable
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
- Pin your package manager. The runner provides a default pnpm (`pnpm/action-setup` with `version: 10`) so scripts that call `pnpm` directly keep working, but it won't necessarily match your local version. For pnpm/yarn projects, set `"packageManager"` in the root `package.json` and call `corepack enable` near the top of `dev-start.sh` to activate the exact version you pinned.

If the project has nothing to start (pure-docs, lib-only), do **not** create this file. Its absence is the signal for degraded mode (core + sweep reviewers run; no functional tester). An empty-but-present `dev-start.sh` will fail the step.

##### Passing secrets to `dev-start.sh`

If bring-up needs credentials (private registry token, S3 keys for seeding, third-party API key), put them in a repo secret named `DEV_ENV_SECRETS` as `KEY=VALUE` lines. The pipeline exports each line as an env var before running the script. Blank lines and `# comments` are skipped; everything after the first `=` is preserved verbatim so tokens containing `=` survive.

```
NPM_TOKEN=npm_xxxxx
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
# values are exposed verbatim — do not wrap in quotes
```

Same wiring as `TRACKER_SECRETS` for `fetch-issue.sh`: the caller's `secrets: inherit` forwards it, and the env vars are visible to `dev-start.sh`, the legacy `## Functional validation` bash blocks, and the `### Auth` eval. Pick any names that make sense for your stack.

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

## Usage tracking

Every review run emits a tiny `claude-review-usage` workflow artifact (one `usage.json` per run with repo, PR, run id, verdict, findings count, smoke result, round, phase timings). The step is `if: always() + continue-on-error: true`, so a tracking failure can never block a review and there is no new secret or PAT to manage.

To see how reviews are being used across consumer repos, run the local aggregator from a clone of this repo:

```bash
bash scripts/usage-report.sh                        # markdown summary, last 30 days
bash scripts/usage-report.sh --since 7d             # short window
bash scripts/usage-report.sh --owner panenco        # scope code-search discovery
bash scripts/usage-report.sh --repos a/b,c/d        # explicit list, skip discovery
bash scripts/usage-report.sh --write docs/USAGE.md  # write the markdown to a file
bash scripts/usage-report.sh --json                 # raw JSONL on stdout for piping
```

The script uses your local `gh` auth (already cross-org), discovers repos via `gh search code 'panenco/claude-review path:.github/workflows'`, lists each repo's `claude-review-usage` artifacts via the GitHub Actions API, and prints per-repo run counts, verdict mix, round-1 vs round-2 split, total findings raised, and a recent-runs feed. Token totals are not included yet — the sub-agents currently log in plain text; switching them to `stream-json` is a follow-up. Requires `gh`, `jq`, `unzip`.

---

## Versioning

- `@v2` — current floating tag, always points to the latest v2.x release. Use this for auto-updates.
- `@v2.0.0` — pinned tag. Use for critical stability.
- `@v1` — frozen at the final v1 release (`b8223a98`, Apr 21 2026). No new fixes are backported here. Repos still on `@v1` continue to work; bump to `@v2` to receive new pipeline fixes (see [Migration: v1 → v2](#migration-v1--v2)).
- Breaking changes (input/output format changes, new required permissions, verdict-gate additions) bump the major version.

---

## Migration: v1 → v2

`@v1` was frozen at `b8223a98`; everything beyond that ships under `@v2`. The bump is small in code but consumer-visible — there is one **required** caller-workflow change and two new gates that can change verdicts on existing PRs without any wiring on your side.

### 1. Required: add `actions: read` to the caller workflow's `permissions:` block

Round-2 follow-up reviews download the prior run's `review-state` artifact via `actions/download-artifact` with `run-id`. Reusable-workflow permissions are capped by the caller's, so without `actions: read` on the caller, every push after the first silently degrades to a clean full re-review and the round-2 verdict ladder doesn't apply. Full block:

```yaml
permissions:
  contents: write       # screenshots → review-assets branch
  pull-requests: write  # post review + comments
  issues: write
  actions: read         # round-2 follow-up reviews look up the prior
                        # run's review-state artifact by run-id
```

If your existing caller has *no* `permissions:` block at all (the original v1 README's minimal example), this is also where you fix the `startup_failure`-on-orgs-with-default-read-only-`GITHUB_TOKEN` issue — the other three lines were always required, just under-documented.

### 2. New verdict gates (no wiring needed; verdicts on existing PRs may shift)

- **Smoke-test gate** — on technical PRs (refactor / library swap / framework or runtime upgrade / build-config / `chore: bump …`), `APPROVE` is withheld unless the functional smoke run returns `PASS` or `WARN`. The trigger is *intent*, not file types: a pure-refactor commit with no manifest touch counts; a major `Cargo.toml` / `Dockerfile` / `pyproject.toml` bump counts. Repos in degraded mode (no `.github/claude-review/dev-start.sh`) will see refactor PRs flip from APPROVE → COMMENT until they configure a working bring-up.
- **Manual-spec gate** — PRs whose body is purely auto-generated (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code summaries) with no linked issue or PRD get downgraded APPROVE → COMMENT. Findings still post normally; only the green-check approval is gated. To re-enable APPROVE: link an issue, paste acceptance criteria into the PR body, or wire up an external tracker (`fetch-issue.sh`).

Both gates compose with each other: `APPROVE` is granted only when *something* substantively validated the change — either a manual spec or a working app smoke-tested under the diff.

### 3. New optional knobs (defaults preserve v1 behaviour)

- `DEV_ENV_SECRETS` repo secret — newline-separated `KEY=VALUE` env exposed to `dev-start.sh` (and to the legacy `## Functional validation` bash blocks + `### Auth` eval). Mirrors `TRACKER_SECRETS`. Use it for registry tokens, cloud SDK keys, or third-party API creds your bring-up needs at boot.
- New workflow inputs, all optional with sensible defaults: `pipeline_ref` (default `v2`), `dev_env_timeout_seconds` (360), `functional_max_turns` (200, was 120), `model_high` (Opus — drives the high-recall judge), `model_fast` (Haiku — drives the cheap broad-coverage judge), `model_functional` (Sonnet — Haiku here regressed on severity calibration in dogfooding). The `core_max_turns` input from v1 is kept for caller compatibility but no longer has effect: the orchestrator's per-phase ceilings live inside the skill prompts and the workflow caps the orchestrator at `--max-turns 100`. The `*_max_turns` defaults were raised to give the prompt-side STOP-and-write anchors room to land output before the framework enforces a ceiling — generous headroom is recall insurance, especially on round 2 where there is no pass-2 redundancy.

### 4. Already in `@v1`, called out for sub-tag pinners

Anyone bumping straight from `@v1.4.0` (or earlier) to `@v2` also picks up the `CLAUDE_REVIEW_APP_ID` → `CLAUDE_REVIEW_APP_CLIENT_ID` secret rename and the `actions/create-github-app-token@v3` upgrade. Repos that tracked `@v1` (the moving tag) already received these in the final v1.x bumps; only sub-tag pinners are affected.

### 5. Round-based reviews (informational)

First reviews now run a recall-boosted round-1 fan (double-pass + gap-finder critic on core + sweep). Subsequent pushes run round-2 logic that classifies every prior finding against the diff since the last review. No consumer wiring is required beyond the `actions: read` permission in step 1; this is purely an internal mechanics change. If the prior state artifact is missing (retention expired or prior run failed), round-2 degrades to a clean full re-review with a `::notice::` explaining why.

---

## Example Configs

The `bugbot.md` and `review-config.md` examples above cover the common shapes. Adapt them to your stack rather than copying verbatim. The pipeline is framework-agnostic; the reviewer reads the files verbatim, so what you write is what it enforces.

If you have a polished config for a stack not covered here (e.g. Python/FastAPI, Rails, Go) and would like to share it as a reference, open a PR on this repo.

---

## Architecture

The pipeline consists of:

- **Reusable workflow** (`.github/workflows/pr-review.yml`) — dev-env setup, pinned Playwright + @playwright/mcp install (cached, decoupled from the consumer repo), functional-tester subagent installation (`.claude/agents/review-functional-tester.md`), the single `claude-code-action` invocation, post-processing, review posting
- **6 skill files** (`skills/`) — prompt templates defining review methodology:
  - `review-orchestrator` — the single top-level Claude Code agent; dispatches the context builder, judges, thread classifier, and functional tester via the `Task` tool, runs the debate, writes the final findings + meta
  - `review-context-builder` — Task subagent; gathers PR metadata, diff index, spec sources, and a 5-sentence diff summary into `context.md`
  - `review-judge` — Task subagent skill used by both the Opus and Haiku judges (correctness, security, spec, consistency, performance, tests)
  - `review-thread-classifier` — Task subagent (round-2 only); classifies prior findings + open inline threads (own bot, other bots, **humans**) as RESOLVED / STILL_PRESENT / NEW_CONTEXT
  - `review-functional-tester` — custom subagent type (auto-discovered from `.claude/agents/review-functional-tester.md`, written at workflow runtime); inline `mcpServers` block defines Playwright MCP scoped to this subagent, so the server starts when it spawns rather than relying on parent inheritance. First turn is an MCP smoke check that hard-fails the run as `overall: CRASH` if MCP is unavailable — silent fallback to curl is forbidden.
  - `review-test-planner` — embedded inside the context builder skill; picks the functional strategy (skip / quick / functional / pipeline-self-test) and writes scenarios into `test-plan.md`
- **Functional prompt template** (`scripts/functional-prompt.template.txt`) — bootstraps the functional tester with auth + env info

There is **one top-level Claude Code agent** for the entire review. All parallelism happens via the orchestrator's `Task` tool calls. There is no multi-source merge or separate dedup step — the orchestrator's debate loop produces the final, deduped findings array directly, then `build-review.sh` formats it into the GitHub PR review.

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
