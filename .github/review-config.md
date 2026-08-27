# Review config — panenco/claude-review

This repo runs the review pipeline against itself in **degraded mode**. There
is no application to install, build, or boot — the deliverables are bash
scripts, GitHub Actions YAML, and markdown prompt skills. `dev-start.sh` is
deliberately absent (its absence is the documented signal for degraded mode in
the README's Degradation Matrix), so the functional tester is skipped and
only the two model calls run: `review-scan`, then `review-verify`.

## Stack-specific review focus

**Bash scripts (`scripts/*.sh`)**
- Use `set -uo pipefail`; do not introduce `set -e`. Rationale documented in `prompts/setup-review.md` Step 4.5 — `set -e` surprises idioms like `curl || true` and `grep` pipes that legitimately exit 1.
- Every readiness/wait loop must explicitly check the success flag after the loop and `exit 1` (or `::error::`) on timeout. Bare `for ... break ...; done` that silently falls through on timeout is the #1 bug we flag in consumer configs — don't ship it here either.
- Heredocs and `jq` filters that touch model-written JSON (`/tmp/scan.json`, `/tmp/verify.json`, `/tmp/functional.json`, `/tmp/review.json`) should type-guard with `type == "object" and ...` before `has(...)`. A non-object reviewer output once crashed `set -uo pipefail` and lost every finding.

**GitHub Actions YAML (`.github/workflows/*.yml`, `action.yml`)**
- Pinned third-party actions use full 40-char SHAs (see existing `actions/checkout`, `actions/setup-node`, `pnpm/action-setup`, `actions/create-github-app-token`, `anthropics/claude-code-action`). New entries should follow the same pattern.
- The `panenco/claude-review@v3` self-reference in `pr-review.yml`'s downstream install step (`ref: ${{ inputs.pipeline_ref }}`, default `v3`) is an intentional moving-tag reference, and the caller workflow's local-path `uses: ./.github/workflows/pr-review.yml` with no `pipeline_ref` is the intentional dogfood path. Both are listed under `bugbot.md` → "Accepted supply-chain trade-offs". Do not flag either.
- Reusable workflows cannot elevate permissions beyond the caller. The caller workflow's `permissions:` block (`contents: write`, `pull-requests: write`, `issues: write`) is required, not optional. Removing it produces `startup_failure` with zero jobs.

**Skill prompts (`skills/review-*.md`) and the setup recipe (`prompts/setup-review.md`)**
- Treat as code: small wording changes shift verdicts in CI. Specifically, `### Auth` and `### Known service ports` are grepped literally by `scripts/setup-dev-env.sh` during dev-env bring-up — it evals the bash under `### Auth` and pulls URLs from the ports table. Renaming or rewording either silently breaks consumer bring-up. (The `Sign in:` / `Method: cookie|bearer|header|none` phrasing is no longer grepped; it is handed to the functional tester as prose, so keep the canonical shape but nothing greps it.)
- Heading-level changes inside these files are similarly load-bearing. Promoting `### Auth` to `## Auth` makes the section swallow every `###` below it, so the probe evals whatever it finds there.

**README + setup recipe drift**
- `README.md` and `prompts/setup-review.md` describe overlapping ground (degradation matrix, dev-start contract, auth phrasing). When changing one, scan the other for stale claims. The README is for humans onboarding; the setup recipe is for Claude executing `/setup-review`. Both must agree on file paths, secret names, and phrasing rules — divergence shows up as confusing setup failures weeks later.

## Functional validation

This repo has no application services. There is nothing to install, no
database, no dev server, no auth flow. The pipeline runs in degraded mode by
design (no `.github/claude-review/dev-start.sh` is committed; per the README's
Degradation Matrix, that is the signal to skip the functional tester).
`review-scan` and `review-verify` run on the diff against the prompts,
scripts, and workflows checked into the repo.

If a future change introduces something runnable (e.g. a CLI to lint review
configs locally), this section and a `dev-start.sh` should be added together.

### Auth

- Method: none

### Known service ports

| Service | URL | Notes |
|---------|-----|-------|
| (none)  | —   | This repo ships only shell scripts, prompts, and workflows. No application services to probe. |
