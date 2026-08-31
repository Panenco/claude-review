# Claude PR Review Pipeline

Reusable PR review pipeline powered by Claude Code. **Two model calls:** a reviewer that reads the diff and scales its own depth, then an adversary whose only job is to refute what the first one found. An end-to-end functional tester (Sonnet driving a real browser) runs when you ask for one, and can never change the verdict. See [ADR 0003](docs/adr/0004-two-call-review.md).

**Reviews are on demand.** Nothing runs on push. You ask for a review by commenting on the PR, and the comment says which passes to run.

## The `/review` command

| Comment | What runs |
| --- | --- |
| `/review` | Nothing — posts the menu below. |
| `/review code` | The code review. It picks its own depth from the diff. |
| `/review functional` | The code review **+** the browser tester (dev-env bring-up, smoke, screenshots). |
| `/review all` | Both. |
| `/review … deep` | Adds the size-ceiling override — see below. Combines with any pass: `/review code deep`, `/review all deep`. |

**Combine passes in one comment.** `/review code functional` runs them in one session and posts **one** review. Separate comments queue up and post separate reviews.

**`deep` is the only depth control, and it is not about depth.** An oversized PR (over 3000 non-generated lines or 60 files) is normally blocked with a split request and never read. `deep` reviews it anyway. It applies to **the run it starts**; the `deep-review` **label** does exactly the same thing but persistently, so a big PR that genuinely cannot be split does not need the command re-typed on every push. Either input is enough. `full` is an alias for `deep`.

- Aliases: `judges` = `code`, `browser`/`e2e`/`smoke` = `functional`, `full` = `deep`.
- `native` runs a **second opinion**: Anthropic's official `code-review` plugin, in-session, from a marketplace vendored at a pinned commit SHA. Opt-in, advisory, and included in `all`.
- The trigger must **start** the comment — mentioning `/review all` mid-sentence does nothing.
- Only `OWNER`/`MEMBER`/`COLLABORATOR` can trigger a run. Everyone else is ignored silently.
- **Not opt-in:** the code review, and how hard it thinks. The command picks the passes; `deep` only decides whether an oversized PR is read at all.

## Quick Start

### 1. Add the caller workflow

Create `.github/workflows/claude-review.yml` in your repo. Track the `@v3` tag so pipeline fixes propagate automatically across all consumer repos — the reusable workflow and its composite action both get pulled fresh at job start. Pair this with the `bugbot.md` policy line in Step 4 so the reviewer does not re-flag `@v3 + secrets: inherit` on every PR.

```yaml
name: Claude PR Review
on:
  issue_comment:
    types: [created]
  workflow_dispatch:
    inputs:
      pr_number:
        description: "PR number to review"
        required: true
        type: string
      command:
        description: 'Passes to run, e.g. "/review code functional". Empty = code review only.'
        required: false
        type: string
jobs:
  review:
    # Filter only — without it every comment on every issue opens a run that
    # exists just to skip itself. Authorization lives in the called workflow.
    if: >-
      github.event_name != 'issue_comment' ||
      (github.event.issue.pull_request != null &&
       startsWith(github.event.comment.body, '/review'))
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v3
    permissions:
      contents: write
      pull-requests: write
      issues: write
      packages: read
      id-token: write # for the coming per-developer Claude seats; inert until then
    with:
      pr_number: ${{ inputs.pr_number || '' }}
      command: ${{ inputs.command || '' }}
    secrets: inherit
```

You do **not** forward the comment body. A reusable workflow sees the caller's `github` context, so it reads `github.event.comment.body` itself; `command` exists only for `workflow_dispatch`, which has no comment to read (an empty command there means a plain judge review — clicking *Run workflow* is the opt-in).

There is deliberately **no `pull_request_target`**. Earlier versions used it to run a cache-warm job here; that trigger has read-only access to the cache and the warm stored nothing. Warming now lives in its own workflow — see *Add the cache-warm workflow* below.

The `permissions:` block is required: reusable workflow permissions are capped by the caller's, and GitHub's default `GITHUB_TOKEN` is read-only at most orgs. Omitting it produces `startup_failure` with no logs. Add `id-token: write` now even though nothing uses it yet — the reviewer will soon mint an OIDC token to draw on the requester's own Claude seat, and a caller that lacks the line then fails at startup with no logs. `actions: read` is **no longer required** — round-2 state is derived from the PR's own review history, not from workflow artifacts; existing callers that still grant it are unaffected and can leave it in. See `prompts/setup-review.md` for the full troubleshooting flow.

Why `@v3` and not a SHA pin: every consumer repo stays on the same moving target, so a fix landed on `panenco/claude-review` reaches everything on the next PR push without touching any downstream repo. The trade-off — a mutable tag + `secrets: inherit` is technically a supply-chain vector — is one we explicitly accept here because upstream is first-party (Panenco org) and the logistics of SHA-bumping every consumer after every pipeline fix were unworkable. If _your_ repo has different trust needs, substitute a 40-char SHA for `@v3`.

**Tag-resolution caveat.** The reusable workflow file and the install step resolve their refs at different moments of the job. Moving `v3` while a run is starting can cause a mismatch — push the `v3` tag at idle times, not while runs are in flight.

**Pinning to a non-default ref.** Pre-release dogfooding (testing pipeline changes against a real consumer repo before merging to `main`) needs both the workflow file and the install step at the same ref. Pass `pipeline_ref` so the install matches:

```yaml
uses: panenco/claude-review/.github/workflows/pr-review.yml@<branch-or-sha>
with:
  pr_number: ${{ inputs.pr_number || '' }}
  pipeline_ref: <branch-or-sha>
```

Without `pipeline_ref`, the install defaults to `@v3` and consumers get new orchestration on old skills, which fails at max-turns. The `@v3` default is correct for normal use; only override during testing.

**Bot-opened PRs.** There is no `allowed_bots` input any more, and nothing to configure: a bot's comment never clears the `author_association` gate, and a bot's *PR* is reviewed like any other once a human comments `/review` on it. Renovate and dependabot PRs simply sit unreviewed until somebody asks — which is the point of an on-demand trigger.

**Changing the trigger word.** Pass `command_trigger` if `/review` collides with another bot in your repo. Change the caller's `startsWith(...)` filter to match, and note that the menu the bot posts back quotes whatever you set.

Empty (the default) skips all bot-initiated runs. Two notes for allowed bots: dependabot-triggered events receive *Dependabot secrets*, not Actions secrets — add `CLAUDE_CODE_OAUTH_TOKEN` there too or the token picker fails. And bot-authored PRs waive the manual-spec gate (a machine PR can never link a human spec), so they can reach APPROVE on review merit alone.

**Caching the dev-env build (`dev_cache_*`).** The functional tester runs `dev-start.sh` on a fresh runner every review, so any compiled/downloaded artefacts (a Gradle/Maven build, a Go module cache, a Rust `target`, …) are rebuilt cold each time — often the single biggest chunk of bring-up wall-time. The pnpm/npm store is already cached for you; everything else is opt-in and **stack-agnostic** via four inputs. It reuses the same producer/consumer split as the package store — the lightweight **warm-cache workflow** (below) populates the cache, and the functional job only restores it. Pass the same four values to both workflows:

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

> The warm-cache workflow is a vanilla runner (`ubuntu-latest` unless you set `runner`) with only Node set up, so the warm command owns its toolchain. Use the runner's preinstalled versions (`$JAVA_HOME_21_X64`, `$GOROOT_1_22_X64`, …) or install what it needs — no `setup-java`/`setup-go` runs for you there.

How it works and how far the warmth reaches:
- **`dev_cache_warm_command`** runs in the warm-cache workflow — the default branch's cache scope, against the default branch (never PR head). `pr-review.yml` accepts the input too but ignores it; only the warm workflow acts on it. Because it writes to the default branch's scope, **every** PR's functional job restores it, not just re-pushes of the same branch. It runs **only on a cache miss** (i.e. after the key rotates), so steady-state it's a no-op. Keep it cheap and PR-code-free — a dependency *resolve/prefetch*, not a full build.
- The functional job **restores** the cache after disk cleanup, before the bring-up, so `dev-start.sh` builds warm. It does **not** save (no extra weight on the long review job).
- Omit `dev_cache_warm_command` and only the restore runs — useful if your **own** main CI already writes a cache under the same key/prefix (Actions caches are repo-scoped, so it's reused here).
- Leave all of it unset to disable caching entirely — no cache step runs.

**Keep it short-lived.** Build caches are large and the repo shares a 10 GB Actions-cache budget (LRU-evicted, plus 7-day idle eviction). Two habits keep it bounded: cache the **dependency** dir, not whole build trees (`~/.gradle/caches/modules-2`, not `~/.gradle` — the latter drags in transient daemon/build state), and let the **key rotate via `hashFiles`** of your lockfiles so entries churn only when dependencies actually change. The warm-on-miss design means a new entry is written only when the key rotates, not on every PR.

**Self-hosted runners / ARC (`runner`).** Reviews run on the `panenco-claude-review` ARC scale set by default. Repos **outside** that fleet — every public repo, and any private repo not admitted to the `claude-review` org runner group — must opt back out explicitly:

```yaml
uses: panenco/claude-review/.github/workflows/pr-review.yml@v3
with:
  pr_number: ${{ inputs.pr_number || '' }}
  runner: ubuntu-latest    # or your own self-hosted scale-set label
```

**This default fails closed, not open.** ARC resolves the label through the runner group; a repo the group does not list gets no runner and no fallback — the job queues until GitHub's 24 h timeout and then fails. Two rules follow. A repo must be added to the `claude-review` group's selected-repositories list *before* it inherits this default. And the group is created with `allows_public_repositories: false`, so **every public repo must pass `runner: ubuntu-latest`** — including `panenco/claude-review` itself, which is why its own caller sets it explicitly.

Pass the **same `runner` to `pr-review.yml` and `warm-cache.yml`** — the two must land on the same fleet. The Actions cache is a repo-scoped remote service, so a self-hosted job *can* restore what a hosted job saved, but cache keys are scoped by `runner.os` **and** `runner.arch`: a warm on hosted x64 and a review job on an arm64 fleet would never match keys, and every review would run cold.

Two things your fleet needs. It must have **network egress to the GitHub Actions cache service** — without it, caching silently degrades to always-cold (reviews still work, just slower). And the image should carry **Chrome's shared libraries** (`libnss3`, `libatk1.0-0t64`, `libgbm1`, `libasound2t64`, … — what `playwright install --with-deps` or `agent-browser install --with-deps` apt-installs): the browser binary itself unpacks into `$HOME` and needs no root, but those libs do, and a non-root container cannot apt-install them at review time. The pipeline preflights the browser and warns rather than failing when they're missing; the functional tester then reports `CRASH` instead of testing.

The warm-cache workflow is PR-code-free by construction — it runs off the default branch, `pnpm fetch` reads only the lockfile, and `dev_cache_warm_command` is trusted caller config — so it is safe to run on your own fleet. It needs no secrets at all.

**The native `code-review` pass is back, and pinned.** `/review native` dispatches Anthropic's official `code-review` plugin in-session as a second opinion. It was deleted in the v4 rewrite (ADR 0004) largely because its marketplace could not be SHA-pinned; [ADR 0005](docs/adr/0005-native-pass-returns-pinned.md) reverses that. The workflow now checks out `anthropics/claude-plugins-public` at a **full commit SHA**, cuts the catalog down to that one plugin, and hands the action a **local directory path** instead of a live URL — so every third-party reference in `pr-review.yml` stays SHA-pinned.

It is **opt-in and advisory**: `/review native` or `/review all` turns it on, its findings are candidates that `review-verify` refutes at the same bar as everything else, and if the marketplace fails to resolve the review runs without it. You still get exactly one review comment.

`native_review_scope` and `model_standard` are **live inputs again** — they were deprecated no-ops only while the pass was deleted. `native_review_scope` is optional free text that narrows the second opinion to some paths (e.g. `only review changes under apps/api/`); `model_standard` names the model that runs it.

**The session is still sandboxed.** The review job holds `contents: write` / `pull-requests: write` / `issues: write`, and every agent in it reads attacker-controlled PR content — so the session denies **every GitHub write verb**: `gh pr comment/review/edit/close/merge/ready`, `gh issue comment/edit/close`, `gh release`, `git push`, the raw `gh` API subcommand, plus `Edit`/`WebFetch`/`WebSearch`. What stays reachable is reads — `gh pr view/diff/list`, `gh issue view`, `gh search`, `git log/blame/diff/show` — which is all a reviewer needs. That is possible because the pipeline's own privileged API calls live in a reviewed helper (`scripts/upload-screenshots.sh`) rather than inline in a prompt: `--disallowedTools` is session-wide and cannot be scoped to one subagent, so nothing may need what nothing should have.



### 2. Add the cache-warm workflow

Create `.github/workflows/claude-review-warm.yml`. This is the **producer** half of the review cache; the review job only ever restores.

```yaml
name: Claude Review Cache Warm
on:
  push:
    branches: [main]          # your default branch
    paths:
      - '**/pnpm-lock.yaml'
      - '**/package-lock.json'
  schedule:
    - cron: '0 5 * * 1'       # covers the 7-day idle eviction on a quiet week
  workflow_dispatch:

concurrency:
  group: claude-review-warm
  cancel-in-progress: false

jobs:
  warm:
    uses: panenco/claude-review/.github/workflows/warm-cache.yml@v3
    permissions:
      contents: read
    with:
      # Same value you pass to pr-review.yml. Public repos MUST set
      # ubuntu-latest — see "Self-hosted runners" below.
      runner: panenco-claude-review
      # Only if you use the dev_cache_* feature — same four values as the
      # review caller. Add the key-file globs to `paths:` above too.
      # dev_cache_paths: |
      #   ~/.gradle/caches/modules-2
      # dev_cache_key_files: |
      #   **/gradle/libs.versions.toml
      # dev_cache_key_prefix: gradle
      # dev_cache_warm_command: cd backend/java && ./gradlew :api:dependencies --no-daemon
```

**Why this is a separate workflow, and why the trigger list is not negotiable.** GitHub lets only `push`, `workflow_dispatch`, `repository_dispatch`, `schedule`, `delete`, `registry_package` and `page_build` create or overwrite caches in the default branch's scope. Every other event that resolves to the default branch gets **read-only** access — explicitly including `pull_request_target`, `issue_comment` and `workflow_run`, whose payload or initiating actor can be influenced from outside the repo. It is cache-poisoning protection and it cannot be granted away; `actions: write` makes no difference.

A reusable workflow inherits the **caller's** event, so a warm job living next to the review trigger inherits a read-only one and every save is refused. GitHub reports that refusal as a warning, not a failure — which is why the earlier design ran green while storing nothing for a month ([#101](https://github.com/panenco/claude-review/issues/101)). `warm-cache.yml` now asserts its caller's event up front and **fails** if it cannot write, so a misconfigured trigger is visible on the first run.

Skip this workflow entirely if your team does not use `/review functional`: without it reviews still work, they just install cold.

### 3. Set secrets

Add `CLAUDE_CODE_OAUTH_TOKEN` as a repo or org secret. Generate it with:

```bash
claude setup-token
```

Optional — when one Claude.ai subscription's 5-hour rate-limit window keeps blocking reviews, run `claude setup-token` against multiple subscriptions and put all tokens (one per line) in a single secret named `CLAUDE_CODE_OAUTH_TOKENS` instead. The pipeline probes each at job start and randomly picks one with capacity available.

Optional: for a custom review bot identity, also set `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, and `CLAUDE_REVIEW_APP_SLUG`.

### 4. (Optional) Add project config

For best results, add two optional files:

- `bugbot.md` — project-specific review rules
- `.github/review-config.md` — build prep, conventions, dev env, auth

Without these, the pipeline still works — it auto-discovers what it can and runs the judge review on the raw diff.

---

## How It Works

```
/review … comment on a PR
    |
[Cmd]   Which passes were asked for → code review (always) + functional?
        See scripts/review-command.sh.
    |
[State] prior-review-state.sh → round, prior_head_sha, prior_verdict,
        straight off the PR's own review list. No cross-run artifacts.
    |
[Guard] scripts/guard.sh — pure bash, no model call. Four exits:
          skip-review label            → skip, post nothing
          empty since-last delta       → skip, post nothing
          oversized (>3000 lines/60 f) → REQUEST_CHANGES split request
          no non-generated files       → skip, post nothing
        Anything else runs. NO DEPTH TIERS — review-scan self-scales.
    |
[Setup] Node/pnpm, pinned agent-browser + Chrome (cached), browser
        launch preflight, disk reclaim, full clone, dev-env launched in
        background, subagents installed to ~/.claude/agents/.
        Functional-only work is skipped unless a comment asked for it.
    |
[One agent: Review: orchestrate]  (anthropics/claude-code-action)
    A single sonnet-5 session at --effort low (`model_orchestrator`).
    It orchestrates and writes files; it never reviews the diff and
    never rewrites a subagent's prose, so it does not need the
    reviewing model — and it never lends its own to a subagent: each
    one pins its model in its installed frontmatter. Two Task calls:
      review-scan   (opus-5, effort: medium) — reads the diff itself,
                    picks light vs full and says why, emits candidate
                    findings that MUST each name a concrete failure
                    scenario. On round 2+ it reads only
                    git diff <prior_head_sha>..HEAD and carries the
                    prior review's still-unresolved findings.
                    → /tmp/scan.json
      (functional tester, sonnet-5 — same response, ADVISORY ONLY, and
       only when a linked issue supplies real acceptance criteria)
      review-verify (opus-5, effort: low) — ONE pass over all
                    candidates whose mandate is to REFUTE them against
                    the source at HEAD. Uncertain → refuted. Reads
                    /tmp/functional.json if the tester wrote one (it
                    is the only reader — scan runs in parallel with
                    the tester and would never see it). Decides the
                    verdict and renders the final body.
                    → /tmp/verify.json
    The orchestrator copies verify's output into /tmp/review.json
    VERBATIM.
    |
[Post]  post-review.sh (deterministic): validates /tmp/review.json,
        hunk-validates comments, expands {{LINK:path:line}} placeholders,
        dismisses stale reviews, supersedes old crash banners, posts the
        review atomically. Its exit code is the check: green = review
        posted (incl. REQUEST_CHANGES), red = pipeline failure.
    |
Verdict: APPROVE / COMMENT / REQUEST_CHANGES
```

**Check color ≠ verdict.** The workflow check is green whenever a review was successfully posted — including `REQUEST_CHANGES`. The blocking signal is the PR review itself; use branch protection's required-review settings if you want a blocking verdict to prevent merging. A red check always means the pipeline failed: no review was produced, or a computed verdict never reached the PR. (Earlier versions failed the check on `REQUEST_CHANGES`, which made real pipeline failures indistinguishable from working reviews and trained authors to re-run good runs.)

### Why one top-level agent?

Two practical wins. (1) **Native rate-limit fast-fail.** `anthropics/claude-code-action` exits in <1 s when the OAuth token hits a quota wall; the bare `claude -p` CLI silently retries and _hangs_ until the 45-minute job timeout — a real bug observed on PR #309. (2) **All parallelism through the `Task` tool.** No bash background processes, no `wait`/reap traps, no sibling stdout files. One nested transcript covers the whole review.

### Why a refuter instead of a second judge?

A single LLM reviewer can have a bad sample on any given run — miss something subtle, over-grade a defensive note, mis-anchor a finding. The old answer was two judges plus a debate loop; it cost two full diff reads and then a third call to reconcile them, and it still produced findings nobody could reproduce.

The v4 answer is cheaper and sharper: **one reviewer, then one adversary.** `review-verify` reads `review-scan`'s candidates and tries to kill each one against the source at HEAD — does that input actually reach that line, does the missing guard exist above it, does the caller already handle it. **Uncertain counts as refuted.** Dropping a real bug costs one missed comment; keeping a fake one costs the author's trust in every future review. That asymmetry is what a second judge could never enforce, because a second judge is incentivised to find things too.

Two rules do most of the work upstream of it. **Every finding must name a concrete failure scenario** — a real input or state producing a real wrong output — and a finding that cannot is deleted by the model that found it, not downgraded to `minor` to survive. And **zero findings is the correct output for a clean PR**; most PRs deserve one.

> **Depth is the model's call, not a table's.** There are no tiers. `scripts/guard.sh` answers exactly one question — does a model run at all — and `review-scan` picks light or full from the diff itself, recording which and why in `depth_used`. A small change to auth logic gets the full pass because the reviewer can see what it touches, not because a glob matched. Oversized PRs (over the size ceiling) are still blocked with a `REQUEST_CHANGES` asking to split, with no model call at all. Functional testing runs when, and only when, a comment asks for it. See [ADR 0003](docs/adr/0004-two-call-review.md); [ADR 0001](docs/adr/0001-risk-tiered-review-depth.md) records the tiered design it replaced.

### Round 1 vs round 2

Review state lives on the PR itself — there are no cross-run artifacts. On every run, `scripts/prior-review-state.sh` lists the pipeline's own prior reviews on the PR: the newest **judged** review's `commit_id` is the previously-reviewed SHA, its state is the prior verdict, and the count of judged reviews sets the round number. *Judged* is the load-bearing word — a guard short-circuit (the oversized split-request, the skip-label note) posts a review without any model reading the diff, so it carries a hidden marker (`<!-- claude-review-oversized -->` / `<!-- claude-review-skipped -->`) and is excluded from the count. Counting one would scope the next review to the since-last diff and approve a PR nobody ever read. Crash banners and their supersede notes are excluded the same way. A skip-marked post also never dismisses a standing review — adding `skip-review` must not clear a REQUEST_CHANGES nobody re-reviewed. The checkout is a full clone, so `git diff <prior>..HEAD` is always computable.

**What round 2 actually does.** Two things, and deliberately only two:

- **Scope.** `review-scan` reads only `git diff <prior_head_sha>..HEAD`. It reads the wider file for context, but it does not go hunting outside that delta — round 1 already read the rest.
- **Carry.** It re-checks each finding the prior review raised against the code at HEAD and decides *fixed* or *unresolved* **from the code**, not from any reply. Unresolved ones are carried into `prior_findings` and refuted by `review-verify` like any other candidate. Fixed ones are never mentioned again, and nothing already raised gets re-raised under a new title.

**Empty delta → nothing happens at all, unless a person asked.** If no non-generated file changed since the last judged review, `guard.sh` short-circuits before any model call and posts nothing — for *automatic* re-runs. A run a human started (`/review …`, or Run workflow) is never answered with silence: `/review code` followed by `/review functional` on the same commit used to give the second request a 👀 reaction and nothing else, no comment and no tester. An explicit request always gets a review.

**There is no ladder.** The verdict is recomputed from scratch every round, from surviving findings alone. A prior `REQUEST_CHANGES` does **not** force another one, and a prior `APPROVE` does not protect this round. The old anti-downgrade ladder pinned each round to its predecessor and produced twelve rounds of flip-flopping between "would approve" and a blocking verdict on a single PR; it is deleted, along with thread adjudication, `DISPUTED` states and "dropped after author rebuttal" bookkeeping. A prior finding survives because the code still shows it, or it does not survive.


**Severity grading:** three levels — `critical` (security, data loss, broken build) and `major` (a user-reachable logic bug) block; `minor` is real but non-blocking. The `note` level is gone: a finding that cannot name a concrete failure scenario is deleted rather than parked at the bottom of the scale, so there is nothing left for a fourth level to hold. `REQUEST_CHANGES` needs a surviving critical or major and **never** comes from a gate, a missing spec, a missing dev env or a smoke test that did not run — that class of verdict was 76% of the old pipeline's blocks and almost none of its real defects.

**Inline comments are reserved for what matters.** Max **5**, filled strictly critical → major → minor, each ≤700 **bytes**, and each carrying a committable ```suggestion``` block — comments with one resolve at 75.5% against 64.6% without. A suggestion fence the clamp cut through is dropped rather than re-closed: a truncated committable suggestion silently deletes the tail of the code it replaces. A finding appears exactly once: as an inline comment *or* as a body bullet, never both. The body itself is budgeted to ~600 bytes with a hard cap of 1200, measured **before** `{{LINK:…}}` placeholders are expanded (the model is told to count `{{LINK:path:line}}` as `path:line`, so that is what the poster enforces — measuring the expanded text charged ~130 bytes per link against the budget and truncated away findings the model had rendered within it). Any empty section is omitted, and a section header whose items were all cut is dropped with them.

**Nothing that cannot be posted inline is discarded.** A comment whose `path:line:side` falls outside any diff hunk (a deleted-line finding without `side: "LEFT"`, an imprecise line target, or *any* line of a file large enough that GitHub omits its `patch`), and every comment past the 5-comment cap, is rendered as a body bullet under `### Also flagged` with its own file link. Under the inline-XOR-body rule the body does not already list it, so dropping it would erase the finding from the review. Setting `side: "LEFT"` for deleted-line findings keeps them inline.

**Crash banners:** when a run can't post a real review, the poster posts a single review carrying the `<!-- claude-review-crash -->` HTML marker, in one of three forms matched to what actually happened: **quota exhausted** (OAuth rate-limit — re-run after reset or rotate the token), **result unreadable** (the agent ran and produced output that couldn't be parsed — a transient serialization slip that a plain re-run almost always clears, no human action implied), or **incomplete** (no output at all — max-turns, network, or OOM). Each links to the run logs. The orchestrator validates its own `/tmp/review.json` with `jq` before exiting and repairs malformed escaping in place, so the "result unreadable" form is rare; it exists as a safety net rather than the common path. The next successful run finds any prior crash banner and edits its body to a "_Superseded by …_" form so a stale red banner doesn't survive every retry.

---

## Per-Project Configuration

### `bugbot.md` (optional)

A markdown list of project-specific review rules. Place at the repo root. `review-scan` reads it before it flags anything.

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

#### `Spec documents:` (optional, one line)

Where this repo keeps its planning/spec documents, so the reviewer finds the real specification instead of falling back to the issue summary. One line anywhere in the file — a path, a directory, or a glob; comma-separate several:

```markdown
Spec documents: docs/specs/, docs/prds/
```

Only needed when your specs are not already found some other way (the PR's own diff, an explicit path referenced from the issue or PR body, a `-prd` / `-spec` / `-rfc` name). It also **confers** spec authority: a declared path is treated as a specification even when its location and name match none of the conventions the assembler otherwise requires. It is a declaration, not configuration — there is nothing else to set.

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

First-class contract for bringing up the dev environment. The pipeline runs this script in a subshell, then probes URLs from `### Known service ports` and the auth block. **Non-zero exit means no functional testing that run**: the review still completes statically and the verdict is unaffected (no gate, no nag — ADR 0003), with the script's actual error in the `dev-env/log` run artifact. Don't commit a `dev-start.sh` you haven't run successfully from a clean checkout. Repos that genuinely have nothing to start should not create the file at all.

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

If the project has nothing to start (pure-docs, lib-only), do **not** create this file — the review runs the same either way. No verdict depends on it; what it decides is whether the functional tester has a running app to drive, so any repo that ships a running app should commit a real one.

##### Passing secrets to `dev-start.sh`

If bring-up needs credentials (private registry token, S3 keys for seeding, third-party API key), put them in a repo secret named `DEV_ENV_SECRETS` as `KEY=VALUE` lines. The pipeline exports each line as an env var before running the script. Blank lines and `# comments` are skipped; everything after the first `=` is preserved verbatim so tokens containing `=` survive.

```
NPM_TOKEN=npm_xxxxx
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
# values are exposed verbatim — do not wrap in quotes
```

Same wiring and the same parser as `TRACKER_SECRETS` for `fetch-issue.sh`: the caller's `secrets: inherit` forwards it, and the env vars are visible to `dev-start.sh`, the legacy `## Functional validation` bash blocks, and the `### Auth` eval. Pick any names that make sense for your stack.

#### `### Auth`

Authentication for functional testing:

```markdown
### Auth

- Sign up: `POST <endpoint>` with `<JSON body>`
- Sign in: `POST <endpoint>` with `<JSON body>`
- Method: cookie | bearer | header | none
```

The orchestrator hands this section (plus the dev-env outputs) to the functional tester as a ready-made auth recipe, so the tester spends zero budget rediscovering auth. Be explicit and literal: exact endpoints, exact seeded credentials, exact method.

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

Known dev-environment failure modes no PR causes — seed-data gaps, SPA route 404s, flaky auth paths. The section is passed verbatim to the functional tester, so a failure matching a listed quirk is treated as expected rather than reported as a finding.

### How the reviewer gets a spec

`review-scan` judges the diff against **one file**, `/tmp/spec.md`, assembled by `scripts/build-spec.sh` in the orchestrator's first turn from every source that resolves, each under a header naming its origin **and its authority**.

**The in-repo spec document is the specification; everything else is a summary of it.** Teams keep a short summary in the GitHub issue or the tracker and the extensive planning document in the repo, so where the two disagree the document wins. `spec.md` opens with a `GOVERNING SOURCE` line saying which one is in force for that run, and says outright when only a summary resolved.

**Not every markdown file is a specification.** Only a document of *intent* is: a path with a `planned` / `plans` / `specs` / `prd(s)` / `rfc(s)` / `design-docs` segment, or a `*-prd.md` / `*-spec.md` / `*-rfc.md` / `*-architecture.md` / `*-design.md` / `*-plan.md` basename. Runbooks and reference tables are excluded — they are instructions and data, they ask for nothing, and as "the spec" they produced findings about work no PR ever promised. Any path with a `_`-prefixed segment is excluded too (`docs/planned/_templates/` is a stale copy that used to beat the real document on sort order). A document **added or changed by this PR** is included and labelled `WRITTEN BY THIS PR`: judge the code against it, but it can never settle a question this PR itself leaves open, and it is never proof the code is right.

**The PR body is not a spec source.** It is written by the author — often by a bot summarising the diff — so judging the diff against it is circular. `review-scan` still reads it; it just cannot produce a spec finding from it.

| # | Source | Authority | Resolved from |
| - | ------ | --------- | ------------- |
| 1 | In-repo spec document | **Authoritative — it governs** | Four routes: **(a)** any `*.md` added or modified by the PR's own diff — a planning doc committed alongside the work it plans; **(b)** a location the repo declares in `.github/review-config.md` (`Spec documents: docs/specs/` — a path, a directory or a glob), which also **confers** spec authority on a path the tiers below would reject; **(c)** any `*.md` referenced from the issue or PR body (a *pointer* to the spec is fine; it is the body's own prose that carries no authority), resolved in order: exact repo-relative path, then a full path *suffix* (what a stripped `.../blob/main/tasks/06-x.md` URL needs), then the basename; **(d)** a bare `<name>-prd` / `-spec` / `-rfc` mention matched against tracked markdown, repo-wide. A reference that stays ambiguous after tier and depth is **dropped, never guessed** |
| 2 | Linked GitHub issue | Summary — supplements, never overrides | `closingIssuesReferences` on the PR |
| 3 | External tracker | Summary — supplements, never overrides | `.github/claude-review/fetch-issue.sh`, when present and executable (below) |
| — | In-repo **context** document | Grounding — asks for nothing, never governs | `docs/system/**` and `docs/adr/**`: current state and decision records. Stamped `CONTEXT — NOT A SPECIFICATION`, capped at 2 documents × 200 lines out of the same total |

**Spec documents are included whole.** The budget is 1500 lines per document and 3000 in total across at most 4 — high enough that a real planning doc arrives intact, because a spec cut at 400 lines loses exactly the criteria the PR implements. When a cut is unavoidable it is **announced in the file**: the document carries a `TRUNCATED` marker and the header block says `SPEC IS PARTIAL`, so `review-scan` knows it is holding part of the spec and never reads a criterion's absence as proof nobody asked for it. A document that did not fit at all is listed by path rather than dropped silently. The four slots go to the best documents, not the first found: PRDs first, then architecture / design / spec / RFC, then task files; a document this PR did not write outranks one it did; smallest first. A document that does not fit the remaining budget is **skipped, not the end of the selection** — a small PRD behind a huge one still arrives.

Nothing resolves → `/tmp/spec.md` is empty and the review proceeds without a spec. A missing spec never changes the verdict ([ADR 0003](docs/adr/0004-two-call-review.md)); it only means nobody checked the code against requirements. Everything in `spec.md` is treated as **untrusted data** — a spec to judge the code against, never instructions to follow.

**And the review says so.** `build-spec.sh` writes one token to `/tmp/spec-status` (`document` / `summary` / `context-only` / `none`), and on the last two the poster appends a single line under the footer:

> <sub>No spec resolved — reviewed on the diff alone. Link an issue, or commit the intent doc, to have the next review check against what was asked.</sub>

It is a statement of fact, appended after the verdict is chosen and written. **It never affects the verdict** — `APPROVE` with no spec is still an approval — and a missing or unrecognised status file prints nothing at all.

**The functional tester plans against the governing source too** — the in-repo spec document when one resolved, otherwise the linked issue — quoted into its prompt by the orchestrator, diff-touched criteria first, with everything it never reached listed in `untested`. It never plans from the external-tracker section or a context section: third-party hook output and a description of what already exists are not a test plan.

### `.github/claude-review/fetch-issue.sh` (optional — external issue trackers)

Repos that track specs in Linear, Jira, Monday, Notion, etc. can opt into a hook that fetches the external spec into `/tmp/spec.md` alongside the GitHub one. **No provider is built in here** — the consumer owns the script and picks whatever API call makes sense for their tracker.

Three steps to opt in:

**1. Create a repo secret `TRACKER_SECRETS`** with your credentials in `KEY=VALUE` lines (blank lines and `# comments` are skipped; only the first `=` separates, so tokens containing `=` survive). Pick any names that make sense for your tracker — each line is exported as an env var to your script:

```
LINEAR_API_KEY=lin_api_xxxxx
LINEAR_WORKSPACE=panenco
```

**2. Drop `.github/claude-review/fetch-issue.sh`** and `chmod +x` it. Adapt the `jq` filters and the `curl` call to your tracker:

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

**3. (Optional, recommended) Add a `Ticket:` line to your PR template** so authors paste the tracker URL — it lands in the highest-confidence bucket:

```
Ticket: https://linear.app/team/issue/LIN-123/...
```

#### Contract

```
Script:  .github/claude-review/fetch-issue.sh   (executable = opt-in)
Run by:  scripts/build-spec.sh, from the repo root, 60s timeout
Env in:
  PR_NUMBER, PR, REPO                        (always set)
  <anything you put in TRACKER_SECRETS>      (your chosen names)
Stdout:  markdown. Inlined verbatim into /tmp/spec.md under a header naming
         the hook, and flagged there as untrusted tool output.
Exit:    0 with output     = success.
         0 with no output  = no external issue for this PR (normal).
         non-zero          = soft-fail: an Actions ::warning::, the output is
                             discarded, and the review continues on whatever
                             other sources resolved. A hang is killed at 60s.
```

`GH_TOKEN` is deliberately **not** forwarded. If your script needs authenticated GitHub calls, add your own PAT via `TRACKER_SECRETS`.

#### Candidates file schema

Before your script runs, `build-spec.sh` scans the PR title, PR body, and branch name for ticket-reference patterns and writes `/tmp/external-issue-candidates.json`. The file is always present and always valid JSON (empty arrays when nothing matches):

```json
{
  "ids": ["LIN-123"],
  "urls": ["https://linear.app/team/issue/LIN-123/..."]
}
```

`ids` are JIRA-style tokens (`[A-Z][A-Z0-9]+-\d+`) from title + body + branch name; `urls` are tracker-host URLs (jira / linear.app / gitlab / youtrack / notion / atlassian / trello / asana / clickup / monday) from the PR body. Prefer a URL match over a bare ID — URLs carry the most confidence.

---

## Degradation Matrix

| Missing file                           | Impact                            | Behavior                                                                                               |
| -------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `.github/claude-review/dev-start.sh`   | Functional tester skipped         | No verdict effect at all — a missing or broken bring-up never blocks a PR and never withholds `APPROVE` (ADR 0003 deleted that gate, and with it the `⚙️ Review setup health` section). `/review functional` degrades to a plain code review. |
| `.github/claude-review/fetch-issue.sh` | Expected when only GitHub is used | Absent: skipped silently — the linked GitHub issue and any referenced in-repo spec document remain the spec sources. Present but failing or hanging: killed at 60s, logged as an Actions warning, review continues. |
| `review-config.md`                     | Reduced                           | No build prep doc, no suppression rules, no declared `Spec documents:` location (the other three discovery routes still run), no Known-service-ports URLs to probe, and no `### Auth` recipe for the functional tester (it treats authenticated surfaces as `untested`). |
| `bugbot.md`                            | Minor                             | Reviewers use generic methodology only (no project-specific rules, no accepted-trade-offs exemptions). |
| `CLAUDE.md`                            | Minor                             | No architecture context. Reviewers rely on diff + issue.                                               |
| All config files                       | Significant                       | Code-only judge review on raw diff + build output. Still catches bugs, spec issues, security.          |

Note: a _present but broken_ `dev-start.sh` is not a verdict input either — the review runs statically and the script's actual error (exit code + failing line) goes to the `dev-env/log` run artifact, not into the review body.

---

## Spec-presence gate

> **Superseded by the APPROVE bar in [ADR 0003](docs/adr/0004-two-call-review.md).** There is no separate spec gate and no `manual_spec_present` flag. `APPROVE` now requires `review-verify` to accept an argued case that a human pass over the diff changes nothing — an unargued approval is rejected, so an unspecified PR fails that bar without a gate of its own. The description below is kept for the record.

The pipeline withheld `APPROVE` whenever the PR had no human-authored spec. The judges decided this from the spec sources gathered in `context.md` — a linked GitHub issue with a non-trivial body, a PRD, an external-tracker spec, or a substantive manually-written PR-body section all qualify. Auto-generated PR descriptions (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code) describe what the diff _does_, not what it _should do_, and don't qualify on their own — they're a code summary, not a contract. When the judges set `manual_spec_present: false`, the verdict is downgraded from `APPROVE` to `COMMENT` and the review body explains how to fix it (link an issue, paste acceptance criteria, or wire up an external tracker). Findings still post normally; only the green-check approval is gated. Bot-authored PRs (renovate, dependabot) are exempt — a machine PR can never carry a human spec, so the gate would be permanent noise there.

## Runtime-evidence gate

> **Deleted by [ADR 0003](docs/adr/0004-two-call-review.md).** There is no runtime-evidence gate and no `⚙️ Review setup health` section. The functional tester is advisory: it can neither raise nor lower a verdict, and a missing or broken dev env costs nothing. The description below is kept for the record.

Whenever the planner judged a PR has runtime behaviour to exercise (`## Strategy ∈ {quick, functional}` in `test-plan.md`), the functional tester walks through one representative user flow (picked from which code paths the change affects) with screenshots, and the verdict depends on how that smoke run ended:

- **Smoke ran and `FAIL`ed** — reproduced runtime evidence against the PR: the verdict is raised to `REQUEST_CHANGES` (the block carries no findings, so a later round un-pins it once the failure clears).
- **Smoke never ran** (`dev-start.sh` missing, bring-up failed or timed out, tester crashed) — a setup problem, not evidence against the PR: the verdict is **never raised**, but `APPROVE` is withheld (capped at `COMMENT`) and the review body's **⚙️ Review setup health** section states exactly what was broken — distinguishing *missing* (`dev-start.sh` doesn't exist → add one) from *present-but-failed* (it ran and exited non-zero → the actual error is quoted, with the full log in the `dev-env/log` run artifact) from *timeout* and *started-but-unreachable*.
- **Smoke `PASS`/`WARN`** — the gate is satisfied. (On round 2, a deliberate `## Strategy: skip` inherits the prior round's `PASS`/`WARN`; a prior `FAIL` still blocks.)

Docs-only / non-runtime PRs are exempt — there is nothing to test, so they review cleanly. Composes naturally with the spec-presence gate: together they ensure `APPROVE` is only granted when _something_ substantively validated the change, either an acceptance criterion or a working app.

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

### Where one run's money and minutes went (`scripts/run-breakdown.sh`)

`usage.json` records one cost for the whole session. To see **which stage** spent it,
break down a single run against the session transcript in the `claude-review-<pr>`
artifact — every subagent message carries a `parent_tool_use_id` pointing back at the
`Agent` call that dispatched it:

```bash
bash scripts/run-breakdown.sh 33300467953 Panenco/seaters   # downloads the artifacts
bash scripts/run-breakdown.sh --transcript orchestrator-output.txt --jobs jobs.json
bash scripts/run-breakdown.sh 33300467953 Panenco/seaters --json
```

It prints per-stage tokens (input / cache-read / cache-write / output), dollars and
share, a timeline of when each stage ran, and — from the runs API — the workflow's
step timings, so model time and runner bring-up are separable. This is the
before/after ruler for a pipeline optimisation: capture a baseline run id, land the
change, run it again, diff the tables.

Three counting traps it handles, each of which otherwise produces a plausible but
wrong table: the stream repeats the same `message.usage` once per content block (so
usage is deduped by `message.id`); an assistant entry's `output_tokens` is a
`message_start` placeholder, not the final count (so output comes from the result
entry's `modelUsage`, and is the one estimated column, marked `~`); and the native
pass's plugin fans out to subagents some runs never record (so a per-model shortfall
is credited to the stage that owns them, never smeared across stages that merely
share the model). The attributed total is printed beside the session's own
`total_cost_usd` — they should agree within ~1%, and a wider gap means the script's
price table has drifted from the models actually in use.

---

## Local review runs (`scripts/review-local.sh`)

Run the real pipeline against a real PR, on your machine, and **post nothing**.

```bash
cp .eval.env.example .eval.env      # set EVAL_REPO, and EVAL_PRS for a sweep
bash scripts/review-local.sh 1234              # full review
bash scripts/review-local.sh 1234 --spec-only  # spec assembly only — no model, free
make eval          # sweep EVAL_PRS
make eval-spec     # sweep, spec assembly only
```

It composes the same steps `pr-review.yml` composes, in the same order — `prior-review-state.sh`, `prior-findings.sh`, `guard.sh`, `build-spec.sh`, one `claude -p` orchestrator session with the real `--agents` and the real `--disallowedTools` sandbox, then `post-review.sh`. It works against a detached worktree of a local clone, with `origin/<base>` pinned to the PR's true fork point (`gh api compare`) so `build-spec.sh` sees what CI would see even on a merged PR. Each run gets its own directory in place of `/tmp`, so concurrent runs cannot clobber each other.

Everything the review would have sent to GitHub lands in `<EVAL_ROOT>/results/<pr>/posted/`: `verdict`, `body.md` (the final expanded body), `comments.json` (the inline comments as they would be posted), `meta.json`, `summary.md`, and `actions.log` — one line per suppressed GitHub call (`POST review APPROVE 2 comments`, `DISMISS 12345`, …), which is what makes a dry run auditable rather than merely quiet.

### The `REVIEW_OUT_DIR` seam

`scripts/post-review.sh` is the **only** writer to GitHub on the review path, so one seam in one file covers the whole pipeline. Set `REVIEW_OUT_DIR=<dir>` and every GitHub *write* becomes an artifact in that directory instead of a call. Reads still happen — hunk validation is what decides which comments go inline, and a dry run that skipped it would report a different review than the real one.

**It is a path, not a flag,** deliberately. `DRY_RUN=1` / `true` / `yes` / `0` / `false` all have a truthiness surface somebody eventually gets wrong. A path is set and meaningful, or unset and inert.

Three independent barriers keep it out of production:

1. `workflow_call` cannot inject arbitrary env into a called workflow, so a consumer cannot set it on the production path even deliberately.
2. `tests/pipeline_contract_test.sh` asserts the name appears in neither `.github/workflows/pr-review.yml` nor `action.yml`.
3. `post-review.sh` **refuses outright** when `REVIEW_OUT_DIR` is set and `GITHUB_ACTIONS=true` — `::error::` and `exit 1`. Loud, never silent.

### What a sweep costs

Banked from a v4 corpus run: **$1.94 mean per PR, ~250s wall clock**. A 10-PR sweep is roughly **$19 and ~42 minutes**. `--spec-only` sweeps run no model and are free.

---

## Versioning

- `@v3` — current floating tag, always points to the latest v3.x release. Use this for auto-updates.
- `@v3.0.0` — pinned tag. Use for critical stability.
- `@v2` — previous major, frozen at the final v2 release. Repos still on `@v2` continue to work; bump to `@v3` to receive new pipeline fixes (the v3 tier requires a `dev-start.sh` for runtime PRs).
- `@v1` — frozen at the final v1 release (`b8223a98`, Apr 21 2026). No new fixes are backported here. Repos still on `@v1` continue to work; bump to `@v3` to receive new pipeline fixes (see [Migration: v1 → v2](#migration-v1--v2) for the older bump).
- Breaking changes (input/output format changes, new required permissions, new verdict gates) bump the major version.

### Releasing a new version (maintainers)

There is **no release automation** — merging to `main` does not publish anything. Consumers pin the floating major tag (`@v3`), so a release is two steps: cut an immutable `vX.Y.Z` rollback anchor at the current `origin/main` tip, then move the floating major tag onto the same commit. Use the script:

```bash
scripts/release.sh v3.1.0            # publish (or: make release VERSION=v3.1.0)
scripts/release.sh v3.1.0 --dry-run  # preview the four git commands without pushing
```

It runs, in this order (immutable tag **first**, so the new tip keeps a stable name even if `v3` is later reverted):

```bash
git tag v3.1.0 origin/main      # immutable rollback anchor
git tag -f v3 origin/main       # point floating major at the same tip
git push origin v3.1.0
git push origin v3 --force
```

**Choosing the number:** bump the **minor** for a new capability or config-affecting change, the **patch** for a pure fix. A breaking change bumps the **major** (`v4`) — never force-move the existing major onto a breaking change, since every consumer floats it.

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
  id-token: write # for the upcoming per-developer Claude seats; see the Quick Start
```

`actions: read` is **not** required: round-2 state is derived from the PR's own review history (the prior review's `commit_id`), not from workflow artifacts. Earlier v2 docs asked for it — callers that still grant it are unaffected; it can be removed at leisure.

### 2. New verdict gates (no wiring needed; verdicts on existing PRs may shift)

- **Runtime-evidence gate** — **deleted by [ADR 0003](docs/adr/0004-two-call-review.md).** A missing `dev-start.sh`, a failed bring-up or a tester crash no longer affects the verdict at all. Fleet data showed this gate produced 31% of all `REQUEST_CHANGES` while naming zero defects. Functional results are advisory: a reproduced failure becomes an ordinary finding or a human-review item.
- **Oversized PRs** — PRs over the size ceiling (default 3000 non-generated lines or 60 files) are blocked with a `REQUEST_CHANGES` asking to split, with **no model call at all** — `guard.sh` renders that body itself. Ask again after splitting and the block re-evaluates against the new size. If the PR genuinely cannot be split, comment `/review deep` (or `/review code deep`, `/review all deep` — it composes with any pass) to review it anyway; the `deep-review` label is the persistent equivalent, applying to every push instead of one run. Either input alone lifts the ceiling. `skip-review` parks a PR the bot must not touch and wins over both — it stays label-only, because "never review this PR" is state, not a one-shot request.

  **Committed build output does not count towards that ceiling.** Lockfiles, `dist/`, `build/`, minified bundles, `openapi*`/`swagger*` specs, `schema.graphql` and `*.gen.*` are excluded from the size, so a regenerated artifact cannot get a small PR refused — seaters#2103 was blocked at "45478 non-generated lines" when 45335 of them were one committed `openapi.combined.json` and the reviewable diff was 143 lines. If your repo commits build output the built-in list does not name, declare it with `gate_generated_globs: "*.pot proto/**"` in the caller. Exclusion only changes the size arithmetic; the reviewer still gets the whole diff.
- **Manual-spec gate** — **deleted by [ADR 0003](docs/adr/0004-two-call-review.md).** A missing spec no longer downgrades the verdict on its own. `APPROVE` now requires `review-scan` to argue why a human pass would change nothing, plus no sensitive path touched and a low review-effort score — so an unspecified PR usually lands on `COMMENT` anyway, but because nothing could be vouched for, not because a gate fired.
Only two things now decide a verdict: surviving findings, and the oversized guard. `REQUEST_CHANGES` means a confirmed critical or major finding, or a diff too large to read. Everything else — no spec, no dev env, a crashed tester — is reported, never blocked on.

### 3. New optional knobs (defaults preserve v1 behaviour)

- `DEV_ENV_SECRETS` repo secret — newline-separated `KEY=VALUE` env exposed to `dev-start.sh` (and to the legacy `## Functional validation` bash blocks + `### Auth` eval). Use it for registry tokens, cloud SDK keys, or third-party API creds your bring-up needs at boot.
- New workflow inputs, all optional with sensible defaults: `pipeline_ref` (default `v2`), `dev_env_timeout_seconds` (360), `functional_budget_seconds` (480 — the functional tester's wall-clock bound; it records a start timestamp and hard-stops + writes its findings once elapsed exceeds this, so a thorough tester against a live backend can't run into the job's `timeout-minutes` ceiling and get cancelled with nothing posted), `free_disk_space` (`safe` — reclaims runner disk before a heavy `dev-start.sh` bring-up so it can't ENOSPC the post-orchestrate steps and lose a finished review; `safe` removes only tooling no Linux app bring-up needs (CodeQL/Haskell/Swift, ~12 GB), `aggressive` also drops Android + .NET, `off` disables), `model_high` (Opus — drives the high-recall judge), `model_fast` (Haiku — drives the cheap broad-coverage judge), `model_functional` (Sonnet — Haiku here regressed on severity calibration in dogfooding). The `core_max_turns` input from v1 has been removed (passing it is now a workflow-call error — drop it): the workflow caps the orchestrator at `--max-turns 100` and per-phase discipline lives inside the skill prompts. The functional tester is bounded by wall-clock (`functional_budget_seconds`), not turn count — turns are a poor proxy for runtime against a real backend. A `functional_max_turns` input existed briefly under `@v2`; it has been removed (passing it from the caller is a workflow-call error — drop it).

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

- **Reusable workflow** (`.github/workflows/pr-review.yml`) — prior-state derivation from the PR's review history, the deterministic guard, dev-env setup, pinned agent-browser + Chrome install and launch preflight (cached, decoupled from the consumer repo), subagent installation, the single `claude-code-action` invocation, the deterministic poster
- **Deterministic guard** (`scripts/guard.sh`) — ~90 lines of pure bash, no network, unit-tested. The only thing that decides whether a model runs at all: skip-review label, empty since-last delta, oversized PR (blocked with a split request it renders itself), no non-generated files. There are no depth tiers
- **4 skill files** (`skills/`) — prompt templates defining review methodology:
  - `review-orchestrator` — the single top-level Claude Code agent (sonnet-5 via `model_orchestrator`, `--effort low` — it is plumbing, not judgment, and its model never reaches a subagent); dispatches `review-scan` and the optional functional tester in one response, then `review-verify`, then copies verify's output into `/tmp/review.json` **verbatim**. It never reviews the diff and never rewrites a subagent's prose
  - `review-scan` — Task subagent (opus-5, `effort: medium`); reads the diff itself with `gh`/`Read`/`Grep`, self-scales light vs full and records why, and emits candidate findings that must each name a concrete failure scenario. On round 2+ it scopes to `git diff <prior_head_sha>..HEAD` and carries the prior review's still-unresolved findings → `/tmp/scan.json`
  - `review-verify` — Task subagent (opus-5, `effort: low`); ONE pass over all candidates whose mandate is to **refute** them against the source at HEAD, defaulting to refuted when uncertain. Decides the verdict and renders the posted body and inline comments → `/tmp/verify.json`. Its prose is final. It is also the **only** consumer of `/tmp/functional.json`, which is the one narrow exception to its never-invent-a-finding rule: the tester is dispatched in the same response as `review-scan` and finishes long after it, so scan can never read it
  - `review-functional-tester` — drives the live app with the `agent-browser` CLI under a wall-clock budget; first turn is a browser smoke check that hard-fails the run as `overall: CRASH` if Chrome can't launch — silent fallback to curl is forbidden. **Advisory only:** it can never raise or lower the verdict, and its test plan comes only from a linked issue's acceptance criteria (no issue, no test)
- **Static subagent definitions** (`agents/review-scan.md`, `agents/review-verify.md`, `agents/review-functional-tester.md`) — installed to `~/.claude/agents/` at job start; each pins its model and effort and points at its skill. The tester has no MCP server: the browser is a CLI the subagent drives through Bash, which the workflow installs and preflights before the agent starts
- **Privileged-API helper** (`scripts/upload-screenshots.sh`) — every raw GitHub REST/GraphQL call the review session makes, which is now only the screenshot upload to the `review-assets` branch. It exists so the session can deny the raw `gh` API subcommand outright
- **Session-end hook** (`scripts/require-review-json.sh`) — registered as a Claude Code `Stop` hook; it refuses to let the orchestrator end a session without `/tmp/review.json`. Bounded (3 nudges) and fails open to a visible crash banner rather than spinning

- **Deterministic poster** (`scripts/post-review.sh`) — validates `/tmp/review.json`, hunk-validates inline comments against the PR diff, dismisses stale reviews, supersedes crash banners, posts the review atomically, resolves threads; its exit code is the check

There is **one top-level Claude Code agent** for the entire review, and one handoff: the orchestrator owns all judgment AND assembly and writes `/tmp/review.json`; the poster only validates and POSTs it. See [ADR 0002](docs/adr/0002-github-as-state-single-assembler.md) for why.

All project-specific configuration is read from the consuming repo's `bugbot.md` and `.github/review-config.md` by convention.
