# Upgrade this repo's Claude PR review to v3

You are upgrading the Panenco Claude PR review pipeline in **this** repository to `@v3`. The pipeline itself is upstream (`panenco/claude-review`) and auto-propagates on the moving `v3` tag — your job is to bring **this repo's config** in line with what v3 expects, then prove it by opening a PR and asking the pipeline to review it clean (`APPROVE`, no findings).

**Do this even if the pin already says `@v3`.** v3 was re-cut as an **on-demand** pipeline: reviews come from a `/review` comment, never a push.

- Coming from `@v1`/`@v2`: do every step.
- Already on `@v3`: Step 2 is the whole job; skim the rest to confirm nothing regressed.

## Source of truth

The authoritative, always-current spec is **`prompts/setup-review.md` on `panenco/claude-review@v3`**. Read it first; everything below is a *delta summary* to focus your work. When this prompt and the canonical file disagree, **the canonical file wins.**

Fetch it (private repo — use `gh`, not a raw URL):

```bash
gh api repos/panenco/claude-review/contents/prompts/setup-review.md?ref=v3 \
  --jq '.content' | base64 -d > /tmp/setup-review-v3.md
```

Read `/tmp/setup-review-v3.md` in full before editing anything.

## Step 1 — Audit what this repo has today

Gather evidence; don't assume. Report each finding before you change it:

- **Current pin** — `grep -r 'pr-review.yml@' .github/workflows/`. Are you on `@v1`, `@v2`, or already `@v3`?
- **Runtime or not** — does this repo bind a port / serve requests (NestJS, Express, Next.js, Django, FastAPI, Spring, Go net/http, a compose service)? Read every `package.json` for `dev`/`start:dev`, check for `docker-compose.yml`, `Dockerfile`, `main.go`, `manage.py`, `*.csproj`. This decides whether `dev-start.sh` is mandatory.
- **dev-start.sh** — does `.github/claude-review/dev-start.sh` exist and is it `chmod +x`? Or is bring-up still living as legacy bash inside `.github/review-config.md`'s `## Functional validation`?
- **Build caching** — does bring-up cold-build anything beyond the pnpm/npm store (Gradle, Maven, Go modules, Rust `target`, pip)? Are the `dev_cache_*` inputs wired on the caller?
- **review-config heading levels** — are `### Auth` and `### Known service ports` at level 3 (`###`) and at the file root *after* `## Functional validation` closes?
- **bugbot.md** — is there an "Accepted supply-chain trade-offs" section, and does it name the `@v3` tag (not `@v1`/`@v2`)?

## Step 2 — Switch the caller to the on-demand trigger (the breaking change)

**v3 does not review on push.** A reviewer comments `/review …` on the PR and the
comment names the passes: `code` (judges), `functional` (browser tester),
`native` (Anthropic's plugin), `all`, plus `deep` to force the dual-judge path.
Depth is still sized automatically — the command picks the passes, not how hard
they think.

A caller left on `pull_request` reds the check on every push (no PR number on
that event), so the repo has **no working reviews** until this step is done.

In `.github/workflows/claude-review.yml`:

- Replace the `pull_request:` trigger with `issue_comment: { types: [created] }`.
- **Delete the draft guard** (`if: … github.event.pull_request.draft == false`)
  and replace the job `if:` with the comment filter from the canonical Step 2:
  `github.event_name != 'issue_comment' || (github.event.issue.pull_request != null && startsWith(github.event.comment.body, '/review'))`.
- Re-key `concurrency.group` from `github.event.pull_request.number` to
  `github.event.issue.number`, and set `cancel-in-progress: false` — cancelling
  would throw away a review a human explicitly asked for.
- Add a `command` input to `workflow_dispatch` and pass it through as
  `command: ${{ inputs.command || '' }}`. Do **not** try to forward the comment
  body: the reusable workflow reads it off your event context itself.
- Keep `pull_request_target` only if the team will use `/review functional`
  regularly — it warms the browser/dependency cache and never reviews.
- **Delete `allowed_bots`, `native_review`, `native_review_runner` and
  `core_max_turns` if present.** All four are gone; passing any of them now fails
  the run with `startup_failure`. `native_review_scope` stays.
- Keep the reusable-workflow pin at **`panenco/claude-review/.github/workflows/pr-review.yml@v3`** and the full `permissions:` block (`contents: write`, `pull-requests: write`, `issues: write`, `packages: read`, `id-token: write`). Missing `permissions:` is the #1 startup failure. `id-token: write` is inert today; add it now so the caller is ready when the reviewer starts minting an OIDC token to draw on the requester's own Claude seat.
- `actions: read` is **no longer needed** in v3 (round-2 state comes from the PR's own review history). Drop it; keeping it is harmless.

Only people with write access (`OWNER`, `MEMBER`, `COLLABORATOR`) can trigger a
run. That gate lives in the reusable workflow, so there is nothing to copy and
nothing a caller can get wrong.

In `bugbot.md`, update (or add) the **Accepted supply-chain trade-offs** section so it names `panenco/claude-review/.github/workflows/pr-review.yml@v3 + secrets: inherit` as accepted. This is what keeps the reviewer from re-flagging the mutable tag on every PR.

## Step 3 — The big one: a mandatory, working `dev-start.sh` (runtime repos)

v3 removes the judges-only mode. **If this repo runs an app, `.github/claude-review/dev-start.sh` is mandatory** — a runtime PR with no smoke evidence can never be `APPROVE`d (capped at `COMMENT`), and every affected review carries a "⚙️ Review setup health" nag until the bring-up works.

- If you were relying on legacy `## Functional validation` bash blocks in `review-config.md`, **migrate those commands into `dev-start.sh`** and leave `## Functional validation` as **prose only** (the script is the single source of truth for commands).
- Build it per canonical **Step 4.5**: fail-fast readiness loops (every wait ends in `[ "$X" = true ] || { echo ::error::…; exit 1; }`), codegen/migrations **before** the server, **no `set -e`**, package manager pinned, `chmod +x`.
- Only genuinely non-runtime repos (pure-docs, lib-only) omit the file — document that determination explicitly.

## Step 4 — Wire build caching (`dev_cache_*`) if the stack needs it

New in v3: a generic, stack-agnostic build cache. The functional tester runs `dev-start.sh` on a fresh runner every review; anything beyond the pnpm/npm store (already cached for you) rebuilds cold. If your `dev-start.sh` compiles or downloads Gradle/Maven/Go/Rust/pip artefacts, add the four `dev_cache_*` inputs on the caller's `with:` block, derived from the per-stack table in canonical Step 2. Cache the **dependency dir, not whole build trees**; key on lockfile globs (not a pre-hashed key). Leave all four unset to disable.

## Step 5 — review-config heading hygiene

The pipeline greps for these literally. In `.github/review-config.md`, ensure `### Auth` and `### Known service ports` are **level-3 headings at the file root, placed after `## Functional validation` has closed** — not promoted to `##`, not nested inside Functional validation. Wrong placement surfaces a setup-health bullet in every review.

## Step 6 — Validate, then open the upgrade PR

1. **Local boot loop** — from a clean checkout, `bash .github/claude-review/dev-start.sh` must exit 0 and answer on every `### Known service ports` URL. Time it; if the slow part is a cold dependency build, confirm the `dev_cache_*` inputs cover it. (Exception: app boots only with creds you lack locally → verify by inspection + council, emit a `DEV_ENV_SECRETS` to-do, per canonical Step 4.5.2.)
2. **Council** — dispatch 3 parallel `general-purpose` reviewers (correctness / efficiency / project-fit lenses) over the `dev-start.sh` + `dev_cache_*` block per canonical Step 4.5.2. Iterate until a round raises no blocking flaw (cap 3 rounds).
3. **Self-check** — run the canonical **Step 5** checklist against your `review-config.md` and `dev-start.sh`.
4. **Open the PR** titled `chore: upgrade Claude review to v3`, then **comment `/review all` on it**. It will not review itself — that is the point of the upgrade. Confirm the bot reacts 👀 within a few seconds; if nothing happens, the trigger is still wrong (check Step 2, then check that you have write access on the repo). Target **no findings, `APPROVE`**. If findings appear, they're almost always real; read and fix them before merge.
5. **Tell the team.** Reviews no longer appear on their own. A one-line message with the command table from the README is the whole handover.

## What changed under the hood (context, no action needed)

Knowing these avoids surprise on your first v3 PRs:

- **Nothing runs on push.** No review appears until somebody asks for one. Budget-wise this is the whole point: the browser stack and the dev-env bring-up — the expensive half of a review — now cost nothing unless a comment said `functional`.
- **Oversized PRs block** — > 3000 non-generated lines or > 60 files → canned "split this PR" `REQUEST_CHANGES`, no judges. Override per-PR with `/review deep`; bypass a known-bundled PR with the `skip-review` label, which outranks an explicit command.
- **No spec withholds APPROVE** — no linked issue / PRD / tracker spec / substantive PR body → capped at `COMMENT`. Bot-authored PRs waive it.
- **No runtime evidence withholds APPROVE** — but only on runs that asked for `functional`. `/review code` on a runtime PR is not capped at `COMMENT` for lacking a smoke it was never asked to perform. (Step 3 still matters: the moment someone types `functional`, a broken `dev-start.sh` caps the verdict.)
- **Failed smoke blocks** — a reproduced runtime failure → `REQUEST_CHANGES` with the failing scenario.
- Leaner tiers and model bumps (Sonnet 5 on the standard/functional tier, Opus on small-PR single-judge) are internal — no config change.
