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
  pull_request_target: # warms Playwright cache in main scope
  workflow_dispatch:
    inputs:
      pr_number:
        description: "PR number to review"
        required: true
        type: string
jobs:
  review:
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v2
    permissions:
      contents: write
      pull-requests: write
      issues: write
      packages: read
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

The `permissions:` block is required: reusable workflow permissions are capped by the caller's, and GitHub's default `GITHUB_TOKEN` is read-only at most orgs. Omitting it produces `startup_failure` with no logs. `actions: read` is **no longer required** — round-2 state is derived from the PR's own review history, not from workflow artifacts; existing callers that still grant it are unaffected and can leave it in. See `prompts/setup-review.md` for the full troubleshooting flow.

Why `@v2` and not a SHA pin: every consumer repo stays on the same moving target, so a fix landed on `panenco/claude-review` reaches everything on the next PR push without touching any downstream repo. The trade-off — a mutable tag + `secrets: inherit` is technically a supply-chain vector — is one we explicitly accept here because upstream is first-party (Panenco org) and the logistics of SHA-bumping every consumer after every pipeline fix were unworkable. If _your_ repo has different trust needs, substitute a 40-char SHA for `@v2`.

**Tag-resolution caveat.** The reusable workflow file and the install step resolve their refs at different moments of the job. Moving `v2` while a run is starting can cause a mismatch — push the `v2` tag at idle times, not while runs are in flight.

**Pinning to a non-default ref.** Pre-release dogfooding (testing pipeline changes against a real consumer repo before merging to `main`) needs both the workflow file and the install step at the same ref. Pass `pipeline_ref` so the install matches:

```yaml
uses: panenco/claude-review/.github/workflows/pr-review.yml@<branch-or-sha>
with:
  pr_number: ${{ inputs.pr_number || '' }}
  pipeline_ref: <branch-or-sha>
```

Without `pipeline_ref`, the install defaults to `@v2` and consumers get new orchestration on old skills, which fails at max-turns. The `@v2` default is correct for normal use; only override during testing.

**Allowing bot-opened PRs.** By default, runs triggered by a non-human actor (renovate, dependabot, automation bots) are skipped cleanly — a green check with a `::notice::`, no review, no crash banner. Opt in per-repo by passing `allowed_bots` (comma-separated bot logins, or `*` for all bots) on the caller's `with:` block. Use the login **without** the `[bot]` suffix — it matches `github.actor`:

```yaml
with:
  pr_number: ${{ inputs.pr_number || '' }}
  allowed_bots: panenco-automation   # not "panenco-automation[bot]"
```

Empty (the default) skips all bot-initiated runs. Two notes for allowed bots: dependabot-triggered events receive *Dependabot secrets*, not Actions secrets — add `CLAUDE_CODE_OAUTH_TOKEN` there too or the token picker fails. And bot-authored PRs waive the manual-spec gate (a machine PR can never link a human spec), so they can reach APPROVE on review merit alone.

**Caching the dev-env build (`dev_cache_*`).** The functional tester runs `dev-start.sh` on a fresh runner every review, so any compiled/downloaded artefacts (a Gradle/Maven build, a Go module cache, a Rust `target`, …) are rebuilt cold each time — often the single biggest chunk of bring-up wall-time. The pnpm/npm store is already cached for you; everything else is opt-in and **stack-agnostic** via four inputs. It reuses the same producer/consumer split as the package store — the lightweight **warm-cache job** (which runs in `main` scope on `pull_request_target`) populates the cache, and the functional job only restores it:

```yaml
with:
  pr_number: ${{ inputs.pr_number || '' }}
  dev_cache_paths: |          # what to cache (newline-separated). Keep it tight.
    ~/.gradle/caches/modules-2
    ~/.gradle/wrapper
  dev_cache_key_files: |      # files whose contents key the cache (globs, ** ok)
    **/gradle/libs.versions.toml
    **/*.gradle*
    **/gradle-wrapper.properties
  dev_cache_key_prefix: gradle
  dev_cache_warm_command: cd backend/java && JAVA_HOME=$JAVA_HOME_21_X64 ./gradlew :api:dependencies --no-daemon
```

You pass **globs, not a pre-hashed key**: a reusable-workflow caller's `with:` has no runner or checkout, so `${{ runner.os }}` / `${{ hashFiles() }}` aren't available there (they'd fail at startup). The workflow computes the key — `<RUNNER_OS>-<prefix>-<hash of dev_cache_key_files>` — and the restore-keys (`<RUNNER_OS>-<prefix>-`) inside the jobs, where a checkout exists.

Other stacks are the same shape — Go: `~/go/pkg/mod`, key files `**/go.sum`, warm `go mod download`; Maven: `~/.m2/repository`, key files `**/pom.xml`, warm `mvn -q dependency:go-offline`; Rust: `~/.cargo`, key files `**/Cargo.lock`, warm `cargo fetch`.

> The warm-cache job is a vanilla `ubuntu-latest` with only Node set up, so the warm command owns its toolchain. Use the runner's preinstalled versions (`$JAVA_HOME_21_X64`, `$GOROOT_1_22_X64`, …) or install what it needs — no `setup-java`/`setup-go` runs for you there.

How it works and how far the warmth reaches:
- **`dev_cache_warm_command`** runs in the warm-cache job — `main` scope, against the trusted **base ref** (never PR head). Because it writes to `main` scope, **every** PR's functional job restores it, not just re-pushes of the same branch. It runs **only on a cache miss** (i.e. after the key rotates), so steady-state it's a no-op. Keep it cheap and PR-code-free — a dependency *resolve/prefetch*, not a full build.
- The functional job **restores** the cache after disk cleanup, before the bring-up, so `dev-start.sh` builds warm. It does **not** save (no extra weight on the long review job).
- Omit `dev_cache_warm_command` and only the restore runs — useful if your **own** main CI already writes a cache under the same key/prefix (Actions caches are repo-scoped, so it's reused here).
- Leave all of it unset to disable caching entirely — no cache step runs.

**Keep it short-lived.** Build caches are large and the repo shares a 10 GB Actions-cache budget (LRU-evicted, plus 7-day idle eviction). Two habits keep it bounded: cache the **dependency** dir, not whole build trees (`~/.gradle/caches/modules-2`, not `~/.gradle` — the latter drags in transient daemon/build state), and let the **key rotate via `hashFiles`** of your lockfiles so entries churn only when dependencies actually change. The warm-on-miss design means a new entry is written only when the key rotates, not on every PR.

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

Without these, the pipeline still works — it auto-discovers what it can and runs the judge review on the raw diff.

---

## How It Works

```
PR opened / updated
    |
[Plan]  Deterministic resolver → review_level (full | light | skip)
        + run_functional. See docs/review-plan.md.
    |
[Setup] Node/pnpm, pinned Playwright + MCP (cached), disk reclaim,
        full clone, dev-env launched in background (overlaps with the
        context-build phase), prior review state derived from the PR's
        own review history, functional-tester subagent installed to
        ~/.claude/agents/ (inline `mcpServers` — Playwright starts when
        the subagent spawns, not at orchestrator start).
    |
[One agent: Review: orchestrate]  (anthropics/claude-code-action)
    A single Sonnet orchestrator runs end-to-end and dispatches
    everything via the Task tool:
      Phase A — Task: context builder (Sonnet) → context.md +
                test-plan.md: diff index, spec retrieval (linked
                issue / PRD / external tracker), test plan + auth
                recipe, and — on round 2 — classification of every
                open thread (own bot, other bots, humans) against
                the diff since the last review.
      Phase B — Parallel Task fan (single assistant response):
                  Judge-Opus  (model_high)              ─┐
                  Judge-Haiku (model_fast)              ├ all parallel
                  Functional tester (Playwright MCP,    ─┘
                    wall-clock budget)
                Light tier: ONE Sonnet judge instead of the pair.
                Trivial PRs early-exit before any judge dispatch.
      Phase C — Up to 2 rebuttal rounds when judges disagree (each
                sees the other's findings; concede or defend).
      Phase D — Consolidate + dedup, verdict ladder + gates, assemble
                review body + inline comments → /tmp/review.json,
                the single output artifact.
    |
[Post]  post-review.sh (deterministic): validates /tmp/review.json,
        hunk-validates comments, dismisses stale reviews, supersedes
        old crash banners, posts the review atomically, replies +
        resolves RESOLVED threads (own bot, other bots, AND humans).
        Its exit code is the check: green = review posted (incl.
        REQUEST_CHANGES), red = pipeline failure.
    |
Verdict: APPROVE / COMMENT / REQUEST_CHANGES
```

**Check color ≠ verdict.** The workflow check is green whenever a review was successfully posted — including `REQUEST_CHANGES`. The blocking signal is the PR review itself; use branch protection's required-review settings if you want a blocking verdict to prevent merging. A red check always means the pipeline failed: no review was produced, or a computed verdict never reached the PR. (Earlier versions failed the check on `REQUEST_CHANGES`, which made real pipeline failures indistinguishable from working reviews and trained authors to re-run good runs.)

### Why one top-level agent?

Two practical wins. (1) **Native rate-limit fast-fail.** `anthropics/claude-code-action` exits in <1 s when the OAuth token hits a quota wall; the bare `claude -p` CLI silently retries and _hangs_ until the 45-minute job timeout — a real bug observed on PR #309. (2) **All parallelism through the `Task` tool.** No bash background processes, no `wait`/reap traps, no sibling stdout files. One nested transcript covers the whole review.

### Why two judges?

A single LLM judge can have a bad sample on any given run — miss something subtle, over-grade a defensive note, mis-route a finding to the wrong file. The orchestrator runs **two independent judges with different model strengths** (Opus for deep reasoning, Haiku for cheap broad-coverage finds) and reconciles them: if they agree, the review ships immediately; if they disagree, each judge sees the other's findings and either concedes the ones they missed or defends the ones the other dropped. This catches the long tail where one judge is wrong without paying for it on every PR — most reviews converge on the first round.

> **Not every PR needs that depth.** A deterministic resolver classifies each PR up front and reserves the two-judge debate for substantial or sensitive changes; small PRs take a lighter single-judge pass (on Opus), and tiny (≤ 10-line) or docs-only PRs get that single judge with no functional run. Oversized PRs (over the size ceiling) aren't lightly reviewed — they're blocked with a `REQUEST_CHANGES` asking to split, unless you add the `deep-review` label. Functional testing is gated separately and stays on for every runtime diff above the tiny ceiling — screenshots of the running app are the review's centerpiece, so a small UI fix still gets its quick smoke + screenshot pass. See **[Review plan](docs/review-plan.md)** for the tiers, the `skip-review` / `deep-review` labels, and per-repo tuning — and [ADR 0001](docs/adr/0001-risk-tiered-review-depth.md) for why.

### Round 1 vs round 2

Review state lives on the PR itself — there are no cross-run artifacts. On every push, the pipeline lists its own prior reviews on the PR: the newest non-crash review's `commit_id` is the previously-reviewed SHA, its state is the prior verdict, and the review count sets the round number. The checkout is a full clone, so `git diff <prior>...HEAD` is always computable and since-last scoping never silently degrades into a full-price re-review. The context builder scopes round 2 to that since-last diff and classifies every open thread — re-verifying each "still present" claim against the file at HEAD before it counts. The verdict ladder gains a round-2 layer that's strictly **anti-downgrade**:

- Prior `REQUEST_CHANGES`, no new criticals/majors, all prior blockers `RESOLVED` → per-PR verdict (APPROVE if no new findings, COMMENT otherwise).
- Prior `REQUEST_CHANGES`, some prior blockers `STILL_PRESENT` → keep `REQUEST_CHANGES`.
- Prior `COMMENT`, no new blockers → per-PR verdict (APPROVE when the per-PR judgement is APPROVE, COMMENT when minor findings remain). The ladder no longer pins prior=COMMENT to COMMENT — that ratchet was the source of "bot says Would APPROVE but verdict says COMMENT" contradictions.
- Any prior verdict + ≥1 new critical/major → `REQUEST_CHANGES` (handled by the per-PR ladder upstream).
- Prior review **dismissed by the author** → the dismissal is the author's call on **low-severity** findings (minor/note stop counting), but it does **not** wave off a critical/major: those re-block if they still hold at HEAD unless the bot agreed they were wrong. Surfaced as a banner in the review body.
- Prior finding **disputed by a human** (a substantive reply/comment disputing it, code unchanged — author or maintainer, on any channel: thread reply, general PR comment, or review body) → the high-tier judge **evaluates the dispute on its merits against the code at HEAD**, it is not rubber-stamped. For **critical/major** the finding is dropped only if the judge affirmatively agrees it is wrong (a plausible-but-unverified assertion, an "in another PR" claim, or a bare dismissal keeps it blocking); **minor/note** are dropped on any reasonable explanation. Dropped findings are listed under "Dropped after author rebuttal"; ones the judge keeps are listed under "Still present after your reply" with the bot's reasoning, and the bot replies in-thread either way — so a blocker is never silently dropped or silently re-nagged.

When the round-2 ladder overrides the bot's per-PR judgement (e.g. STILL_PRESENT blockers force REQUEST_CHANGES on a clean re-review), the body prepends a one-line "Verdict pinned to X by the round-2 ladder" rationale so the body's narrative never contradicts the header.

**Thread resolution covers humans too.** When round-2 classification marks a thread RESOLVED, the poster replies with `✅ Resolved as of <sha>` and calls `resolveReviewThread` — for our own past bot comments, for other bots' threads (cursor, aikido, sonarcloud), and for human reviewers' inline comments. A "this should be X" from a teammate that gets fixed in a follow-up commit closes automatically, same as a bot's finding.

**Severity grading:** the bot uses four levels — `critical` and `major` block (REQUEST_CHANGES); `minor` and `note` never gate APPROVE. Doc nits / identifier typos / "you might consider …" observations land at `note` so a single one-word fix doesn't hold a PR at COMMENT. The judge skill enforces a "demonstrate the failure mode" rule for blocking severities — if a critical/major finding can't show the path that produces a real outcome, it's downgraded.

**Inline comments are reserved for what matters.** Only `critical`/`major` findings and functional failures post as inline comments, capped at 12 (overflow moves to the body, critical first); `minor` and `note` findings appear as bullets in the review body instead. When another reviewer bot already flagged the same defect, the review does not re-post it — the overlap is noted in the body, and a reply lands on the other bot's thread only when it adds genuinely new information. "+1"/"confirmed"-only replies are never posted.

**Findings outside diff hunks:** comments whose `path:line:side` falls outside any diff hunk (deleted-line findings without `side: "LEFT"`, or near-but-imprecise line targets) are appended to the review body under "Findings outside diff hunks" rather than silently dropped. Setting `side: "LEFT"` for deleted-line findings keeps them inline.

**Crash banners:** when a run can't post a real review, the poster posts a single review carrying the `<!-- claude-review-crash -->` HTML marker, in one of three forms matched to what actually happened: **quota exhausted** (OAuth rate-limit — re-run after reset or rotate the token), **result unreadable** (the agent ran and produced output that couldn't be parsed — a transient serialization slip that a plain re-run almost always clears, no human action implied), or **incomplete** (no output at all — max-turns, network, or OOM). Each links to the run logs. The orchestrator validates its own `/tmp/review.json` with `jq` before exiting and repairs malformed escaping in place, so the "result unreadable" form is rare; it exists as a safety net rather than the common path. The next successful run finds any prior crash banner and edits its body to a "_Superseded by …_" form so a stale red banner doesn't survive every retry.

**Round-2 cost comes from scoping, not a smaller plan.** The review plan resolves fresh each round from the same rules (labels included); what makes follow-up rounds cheap is that everything downstream is scoped to the since-last diff: the context builder indexes only the files changed since the prior review, judges read just that, and functional scenarios are planned against the since-last diff — **zero scenarios is a valid outcome** when the follow-up has no user-observable surface. The runtime-evidence gate inherits the prior round's functional result, so a deliberate round-2 `skip` doesn't re-block a runtime PR (inheritance applies only to a prior PASS/WARN; a prior FAIL still blocks).

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

| Changed path  | Read                                                 |
| ------------- | ---------------------------------------------------- |
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

**Prose only — no executable bash.** This section is read by the reviewer agents from `context.md` and describes what the functional tester should exercise. The _executable_ side of dev-env bring-up lives in `.github/claude-review/dev-start.sh` (see below).

Describe (in prose) what the project needs at runtime: database flavour + credentials, where `.env` lives, migrations/codegen, dev-server ports, seed data / test users. Do not duplicate the commands — the script is the source of truth.

> Legacy: older configs embed bash blocks in this section. The pipeline still supports that path with a `::warning::` prompting migration to `dev-start.sh`.

### `.github/claude-review/dev-start.sh` (recommended)

First-class contract for bringing up the dev environment. The pipeline runs this script in a subshell, then probes URLs from `### Known service ports` and the auth block. **Non-zero exit fails the Pre-start step and stops the whole review** — don't commit a `dev-start.sh` you haven't run successfully from a clean checkout. Repos that genuinely have nothing to start should not create the file at all — non-runtime PRs review cleanly without it, but a runtime PR with no bring-up is blocked by the runtime-evidence gate (`REQUEST_CHANGES`).

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
- Verify every path in `cp`/`source`/`cat` exists from a clean checkout — a broken path fails the bring-up hard.
- Pin your package manager. The runner provides a default pnpm (`pnpm/action-setup` with `version: 10`) so scripts that call `pnpm` directly keep working, but it won't necessarily match your local version. For pnpm/yarn projects, set `"packageManager"` in the root `package.json` and call `corepack enable` near the top of `dev-start.sh` to activate the exact version you pinned.
- Installs are store-cached for you. The pipeline caches the pnpm/npm store across runs (keyed on your lockfiles, warmed in main scope so new PRs hit it too), so `pnpm install --frozen-lockfile` in `dev-start.sh` mostly links from cache instead of downloading. No consumer wiring needed.

If the project has nothing to start (pure-docs, lib-only), do **not** create this file — non-runtime PRs review cleanly without it. The judges still run, but a runtime PR with no smoke evidence is blocked by the runtime-evidence gate (`REQUEST_CHANGES`), so any repo that ships a running app should commit a real one. An empty-but-present `dev-start.sh` will fail the step.

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

The context builder turns this section (plus the dev-env outputs) into a ready-made auth recipe for the functional tester, so the tester spends zero budget rediscovering auth. Be explicit and literal: exact endpoints, exact seeded credentials, exact method.

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

| Service | URL                       | Notes              |
| ------- | ------------------------- | ------------------ |
| API     | http://localhost:3001/api | Health at GET /api |
| Web     | http://localhost:3000     |                    |
```

#### `### Known dev-env quirks` (optional)

Known dev-environment failure modes no PR causes — seed-data gaps, SPA route 404s, flaky auth paths. The context builder copies the section verbatim into the functional tester's test plan, so a failure matching a listed quirk is treated as expected: mentioned in the functional summary, never reported as a finding.

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
#    Prefer URLs that match your tracker's host, then bare IDs. Exit 0 with
#    no output if nothing matches — that's a normal case, handled cleanly.
TICKET=$(jq -r '
    [.urls[] | select(test("<your-tracker-host>"))][0]
    // .ids[0]
    // empty
  ' /tmp/external-issue-candidates.json)
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
Run by:  the context-builder agent, from the repo root, with a 60s timeout
Env in:
  PR_NUMBER, PR, REPO                        (always set)
  <anything you put in TRACKER_SECRETS>      (your chosen names)
Stdout:  markdown. Inlined verbatim under "## Linked external issue" in context.md.
         For best results, make the first line a heading that surfaces the
         tracker identifier, e.g. "## Linked Linear issue: LIN-123" — it's
         extracted into the review's "Spec sources" line alongside any
         GitHub #N link. The body is read for acceptance-criteria extraction
         either way.
Exit:    0 with output     = success.
         0 with no output  = no external issue for this PR (normal).
         non-zero          = soft-fail: logged, review continues.
```

`GH_TOKEN` is deliberately **not** forwarded. If your script needs authenticated GitHub calls, add your own PAT via `TRACKER_SECRETS`.

#### Candidates file schema

Before your script runs, the context builder scans the PR title, PR body, and branch name for ticket-reference patterns and writes `/tmp/external-issue-candidates.json`. The file is always present and always valid JSON (empty arrays when nothing matches):

```json
{
  "ids": ["LIN-123"],
  "urls": ["https://linear.app/team/issue/LIN-123/..."]
}
```

`ids` are JIRA-style tokens (`[A-Z]+-\d+`) from title + body + branch name; `urls` are tracker-host URLs (jira / linear.app / notion / monday / clickup / asana / …) from the PR body. Prefer a URL match over a bare ID — URLs carry the most confidence.

---

## Degradation Matrix

| Missing file                           | Impact                            | Behavior                                                                                               |
| -------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `.github/claude-review/dev-start.sh`   | Blocks runtime PRs                | Functional tester skipped and the judges still run, but a runtime PR with no smoke evidence is blocked with `REQUEST_CHANGES` by the runtime-evidence gate. Docs-only / non-runtime PRs are exempt and review cleanly. |
| `.github/claude-review/fetch-issue.sh` | Expected when only GitHub is used | Skipped silently. GitHub-issue lookup remains the default spec source.                                 |
| `review-config.md`                     | Reduced                           | No build prep doc, no convention-rule routing, no Known-service-ports URLs to probe, no auth setup.    |
| `bugbot.md`                            | Minor                             | Reviewers use generic methodology only (no project-specific rules, no accepted-trade-offs exemptions). |
| `CLAUDE.md`                            | Minor                             | No architecture context. Reviewers rely on diff + issue.                                               |
| All config files                       | Significant                       | Code-only judge review on raw diff + build output. Still catches bugs, spec issues, security.          |

Note: a _present but broken_ `dev-start.sh` is **not** a soft-degrade case — the pipeline fails the Pre-start step and stops. Removing the file doesn't give you a clean "judges-only" review either: a runtime PR with no bring-up produces no smoke evidence and is blocked with `REQUEST_CHANGES` (only docs-only / non-runtime PRs review cleanly without it).

---

## Spec-presence gate

The pipeline withholds `APPROVE` whenever the PR has no human-authored spec. The judges decide this from the spec sources gathered in `context.md` — a linked GitHub issue with a non-trivial body, a PRD, an external-tracker spec, or a substantive manually-written PR-body section all qualify. Auto-generated PR descriptions (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code) describe what the diff _does_, not what it _should do_, and don't qualify on their own — they're a code summary, not a contract. When the judges set `manual_spec_present: false`, the verdict is downgraded from `APPROVE` to `COMMENT` and the review body explains how to fix it (link an issue, paste acceptance criteria, or wire up an external tracker). Findings still post normally; only the green-check approval is gated. Bot-authored PRs (renovate, dependabot) are exempt — a machine PR can never carry a human spec, so the gate would be permanent noise there.

## Runtime-evidence gate

The pipeline blocks with `REQUEST_CHANGES` whenever a PR the planner judged has runtime behaviour to exercise (`## Strategy ∈ {quick, functional}` in `test-plan.md`) produces no smoke evidence — no `.github/claude-review/dev-start.sh`, a bring-up that failed or timed out, or a functional tester that crashed. The functional tester walks through one representative user flow (the test plan picks it based on which code paths the change affects) with screenshots. If the smoke run does not return `PASS` or `WARN`, the verdict is set to `REQUEST_CHANGES` and the review body explains how to fix it (configure `dev-start.sh`, or fix the smoke failure). Docs-only / non-runtime PRs are exempt — there is nothing to test, so they review cleanly. (On round 2, a deliberate `## Strategy: skip` inherits the prior round's `PASS`/`WARN` rather than re-blocking; a prior `FAIL` still blocks.) Composes naturally with the spec-presence gate: together they ensure `APPROVE` is only granted when _something_ substantively validated the change, either an acceptance criterion or a working app.

---

## Usage tracking

Every review run emits a tiny `claude-review-usage` workflow artifact (one `usage.json` per run with repo, PR, run id, verdict, findings count, functional result, round, Claude cost, models, wall-clock). The step is `if: always() + continue-on-error: true`, so a tracking failure can never block a review and there is no new secret or PAT to manage.

To see how reviews are being used across consumer repos, run the local aggregator from a clone of this repo:

```bash
bash scripts/usage-report.sh                        # markdown summary, last 30 days
bash scripts/usage-report.sh --since 7d             # short window
bash scripts/usage-report.sh --owner panenco        # scope code-search discovery
bash scripts/usage-report.sh --repos a/b,c/d        # explicit list, skip discovery
bash scripts/usage-report.sh --write docs/USAGE.md  # write the markdown to a file
bash scripts/usage-report.sh --json                 # raw JSONL on stdout for piping
```

The script uses your local `gh` auth (already cross-org), discovers repos via `gh search code 'panenco/claude-review path:.github/workflows'`, lists each repo's `claude-review-usage` artifacts via the GitHub Actions API, and prints per-repo run counts, verdict mix, round-1 vs round-2 split, total findings raised, and a recent-runs feed. Requires `gh`, `jq`, `unzip`.

---

## Versioning

- `@v2` — current floating tag, always points to the latest v2.x release. Use this for auto-updates.
- `@v2.0.0` — pinned tag. Use for critical stability.
- `@v1` — frozen at the final v1 release (`b8223a98`, Apr 21 2026). No new fixes are backported here. Repos still on `@v1` continue to work; bump to `@v2` to receive new pipeline fixes (see [Migration: v1 → v2](#migration-v1--v2)).
- Breaking changes (input/output format changes, new required permissions, new verdict gates) bump the major version.

### Releasing a new version (maintainers)

There is **no release automation** — merging to `main` does not publish anything. Consumers pin the floating major tag (`@v2`), so a release is two steps: cut an immutable `vX.Y.Z` rollback anchor at the current `origin/main` tip, then move the floating major tag onto the same commit. Use the script:

```bash
scripts/release.sh v2.2.0            # publish (or: make release VERSION=v2.2.0)
scripts/release.sh v2.2.0 --dry-run  # preview the four git commands without pushing
```

It runs, in this order (immutable tag **first**, so the new tip keeps a stable name even if `v2` is later reverted):

```bash
git tag v2.2.0 origin/main      # immutable rollback anchor
git tag -f v2 origin/main       # point floating major at the same tip
git push origin v2.2.0
git push origin v2 --force
```

**Choosing the number:** bump the **minor** for a new capability or config-affecting change, the **patch** for a pure fix. A breaking change bumps the **major** (`v3`) — never force-move the existing major onto a breaking change, since every consumer floats it.

**Before you publish:**

- **Push at idle.** Don't move the major tag while reviews are running — see the **Tag-resolution caveat** near the top of this README (the workflow file and the install step resolve their refs at different moments; moving mid-run can split versions). The script tags `origin/main`, not your local checkout, so a stale local `main` is harmless.
- **For model changes, confirm the dogfood gate.** This repo self-reviews its own PRs, so the PR's own "In-Depth Review" run exercises the change. Confirm that run reported `judge_health.opus == "ok"` (no silent failover to Haiku) before publishing.

---

## Migration: v1 → v2

`@v1` was frozen at `b8223a98`; everything beyond that ships under `@v2`. The bump is small in code but consumer-visible — there is one **required** caller-workflow change and two new gates that can change verdicts on existing PRs without any wiring on your side.

### 1. Required: a complete `permissions:` block on the caller workflow

Reusable-workflow permissions are capped by the caller's, and an absent block at orgs with a default read-only `GITHUB_TOKEN` produces `startup_failure` with no logs. Full block:

```yaml
permissions:
  contents: write # screenshots → review-assets branch
  pull-requests: write # post review + comments
  issues: write
  packages: read
```

`actions: read` is **not** required: round-2 state is derived from the PR's own review history (the prior review's `commit_id`), not from workflow artifacts. Earlier v2 docs asked for it — callers that still grant it are unaffected; it can be removed at leisure.

### 2. New verdict gates (no wiring needed; verdicts on existing PRs may shift)

- **Runtime-evidence gate** — a PR the planner judged has runtime behaviour to exercise (`## Strategy ∈ {quick, functional}`) is blocked with `REQUEST_CHANGES` unless the functional smoke run returns `PASS` or `WARN`. Repos with no `.github/claude-review/dev-start.sh` (or a bring-up that fails/times out) will see runtime PRs blocked with `REQUEST_CHANGES` until they configure a working bring-up. Docs-only / non-runtime PRs are exempt.
- **Oversized PRs** — PRs over the size ceiling (default 3000 non-generated lines or 60 files) are blocked with a `REQUEST_CHANGES` asking to split, with no judge debate. Add the `deep-review` label to force a full review instead.
- **Manual-spec gate** — PRs whose body is purely auto-generated (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code summaries) with no linked issue or PRD get downgraded APPROVE → COMMENT. Findings still post normally; only the green-check approval is gated. To re-enable APPROVE: link an issue, paste acceptance criteria into the PR body, or wire up an external tracker (`fetch-issue.sh`).

These gates compose: `APPROVE` is granted only when _something_ substantively validated the change — either a manual spec or a working app smoke-tested under the diff. Note the runtime-evidence gate now _blocks_ (`REQUEST_CHANGES`) rather than merely downgrading to `COMMENT`, while the manual-spec gate still downgrades `APPROVE` → `COMMENT`.

### 3. New optional knobs (defaults preserve v1 behaviour)

- `DEV_ENV_SECRETS` repo secret — newline-separated `KEY=VALUE` env exposed to `dev-start.sh` (and to the legacy `## Functional validation` bash blocks + `### Auth` eval). Mirrors `TRACKER_SECRETS`. Use it for registry tokens, cloud SDK keys, or third-party API creds your bring-up needs at boot.
- New workflow inputs, all optional with sensible defaults: `pipeline_ref` (default `v2`), `dev_env_timeout_seconds` (360), `functional_budget_seconds` (480 — the functional tester's wall-clock bound; it records a start timestamp and hard-stops + writes its findings once elapsed exceeds this, so a thorough tester against a live backend can't run into the job's `timeout-minutes` ceiling and get cancelled with nothing posted), `free_disk_space` (`safe` — reclaims runner disk before a heavy `dev-start.sh` bring-up so it can't ENOSPC the post-orchestrate steps and lose a finished review; `safe` removes only tooling no Linux app bring-up needs (CodeQL/Haskell/Swift, ~12 GB), `aggressive` also drops Android + .NET, `off` disables), `model_high` (Opus — drives the high-recall judge), `model_fast` (Haiku — drives the cheap broad-coverage judge), `model_functional` (Sonnet — Haiku here regressed on severity calibration in dogfooding). The `core_max_turns` input from v1 is kept as a deprecated no-op alias for caller compatibility: the workflow caps the orchestrator at `--max-turns 100` and per-phase discipline lives inside the skill prompts. The functional tester is bounded by wall-clock (`functional_budget_seconds`), not turn count — turns are a poor proxy for runtime against a real backend. A `functional_max_turns` input existed briefly under `@v2`; it has been removed (passing it from the caller is a workflow-call error — drop it).

### 4. Already in `@v1`, called out for sub-tag pinners

Anyone bumping straight from `@v1.4.0` (or earlier) to `@v2` also picks up the `CLAUDE_REVIEW_APP_ID` → `CLAUDE_REVIEW_APP_CLIENT_ID` secret rename and the `actions/create-github-app-token@v3` upgrade. Repos that tracked `@v1` (the moving tag) already received these in the final v1.x bumps; only sub-tag pinners are affected.

### 5. Round-based reviews (informational)

Subsequent pushes to a reviewed PR run round-2 logic that classifies every prior finding against the diff since the last review. State comes from the PR's own review history — no artifacts, no extra permissions, no consumer wiring; this is purely an internal mechanics change.

---

## Example Configs

The `bugbot.md` and `review-config.md` examples above cover the common shapes. Adapt them to your stack rather than copying verbatim. The pipeline is framework-agnostic; the reviewer reads the files verbatim, so what you write is what it enforces.

If you have a polished config for a stack not covered here (e.g. Python/FastAPI, Rails, Go) and would like to share it as a reference, open a PR on this repo.

---

## Architecture

The pipeline consists of:

- **Reusable workflow** (`.github/workflows/pr-review.yml`) — review-plan resolution, dev-env setup, pinned Playwright + @playwright/mcp install (cached, decoupled from the consumer repo), prior-state derivation from the PR's review history, functional-tester subagent installation, the single `claude-code-action` invocation, the deterministic poster
- **4 skill files** (`skills/`) — prompt templates defining review methodology:
  - `review-orchestrator` — the single top-level Claude Code agent; dispatches the context builder, judges, and functional tester via the `Task` tool, runs the debate, consolidates + dedups, applies the verdict ladder and gates, assembles the review, and writes the single output artifact `/tmp/review.json`
  - `review-context-builder` — Task subagent; gathers PR metadata, diff index, spec sources (linked issue / PRD / external tracker), the functional test plan + auth recipe, and — on round 2 — the classification of every open thread (own bot, other bots, **humans**) as RESOLVED / STILL_PRESENT / DISPUTED / NEW_CONTEXT (a `DISPUTED` finding is then adjudicated on its merits by the high-tier judge), into `context.md` + `test-plan.md`
  - `review-judge` — Task subagent skill used by both the Opus and Haiku judges (correctness, security, spec, design, consistency, performance, tests)
  - `review-functional-tester` — drives the live app via Playwright MCP under a wall-clock budget; first turn is an MCP smoke check that hard-fails the run as `overall: CRASH` if MCP is unavailable — silent fallback to curl is forbidden
- **Static subagent definition** (`agents/review-functional-tester.md`) — installed to `~/.claude/agents/` at job start; its inline `mcpServers` block scopes Playwright MCP to this subagent, so the server starts when it spawns rather than relying on parent inheritance
- **Deterministic poster** (`scripts/post-review.sh`) — validates `/tmp/review.json`, hunk-validates inline comments against the PR diff, dismisses stale reviews, supersedes crash banners, posts the review atomically, resolves threads; its exit code is the check

There is **one top-level Claude Code agent** for the entire review, and one handoff: the orchestrator owns all judgment AND assembly and writes `/tmp/review.json`; the poster only validates and POSTs it. See [ADR 0002](docs/adr/0002-github-as-state-single-assembler.md) for why.

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
