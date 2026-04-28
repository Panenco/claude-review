# Review config — panenco/claude-review

This repo runs the review pipeline against itself in **degraded mode**. There
is no application to install, build, or boot — the deliverables are bash
scripts, GitHub Actions YAML, and markdown prompt skills. `dev-start.sh` is
deliberately absent (its absence is the documented signal for degraded mode in
the README's Degradation Matrix), so the functional tester is skipped and
only the core (Opus) and sweep (Sonnet) reviewers run.

## Stack-specific review focus

**Bash scripts (`scripts/*.sh`)**
- Use `set -uo pipefail`; do not introduce `set -e`. Rationale documented in `prompts/setup-review.md` Step 4.5 — `set -e` surprises idioms like `curl || true` and `grep` pipes that legitimately exit 1.
- Every readiness/wait loop must explicitly check the success flag after the loop and `exit 1` (or `::error::`) on timeout. Bare `for ... break ...; done` that silently falls through on timeout is the #1 bug we flag in consumer configs — don't ship it here either.
- Heredocs and `jq` filters that touch `core-meta.json` or any reviewer output JSON should type-guard with `type == "object" and ...` before `has(...)`. Recent fix in `build-review.sh` exists because a non-object reviewer output crashed `set -uo pipefail` and lost every finding.

**GitHub Actions YAML (`.github/workflows/*.yml`, `action.yml`)**
- Pinned third-party actions use full 40-char SHAs (see existing `actions/checkout`, `actions/setup-node`, `pnpm/action-setup`, `actions/create-github-app-token`, `anthropics/claude-code-action`). New entries should follow the same pattern.
- The `panenco/claude-review@v1` self-references (one in the caller workflow, one inside `pr-review.yml`'s install step) are intentional moving-tag references and are listed under `bugbot.md` → "Accepted supply-chain trade-offs". Do not flag.
- Reusable workflows cannot elevate permissions beyond the caller. The caller workflow's `permissions:` block (`contents: write`, `pull-requests: write`, `issues: write`) is required, not optional. Removing it produces `startup_failure` with zero jobs.

**Skill prompts (`skills/review-*.md`) and the setup recipe (`prompts/setup-review.md`)**
- Treat as code: small wording changes shift verdicts in CI. Specifically, the literal strings `### Auth`, `### Known service ports`, `Sign in:`, `Sign-in:`, `Signin:`, `Log in:`, `Log-in:`, `Login:`, and `Method: cookie|bearer|header|none` are grep targets in `pr-review.yml`'s "Validate review config" step and the functional tester's auth auto-extraction. Renaming or rewording any of these silently breaks consumer auto-detection.
- Heading-level changes inside these files are similarly load-bearing. Promoting `### Auth` to `## Auth` skips the validator's grep and emits warnings on every consumer PR.

**README + setup recipe drift**
- `README.md` and `prompts/setup-review.md` describe overlapping ground (degradation matrix, dev-start contract, auth phrasing). When changing one, scan the other for stale claims. The README is for humans onboarding; the setup recipe is for Claude executing `/setup-review`. Both must agree on file paths, secret names, and phrasing rules — divergence shows up as confusing setup failures weeks later.

## Functional validation

This repo has no application services. There is nothing to install, no
database, no dev server, no auth flow. The pipeline runs in degraded mode by
design (no `.github/claude-review/dev-start.sh` is committed; per the README's
Degradation Matrix, that is the signal to skip the functional tester). Core
and sweep reviewers run on the diff against the prompts, scripts, and
workflows checked into the repo.

If a future change introduces something runnable (e.g. a CLI to lint review
configs locally), this section and a `dev-start.sh` should be added together.

### Auth

- Method: none

### Known service ports

| Service | URL | Notes |
|---------|-----|-------|
| (none)  | —   | This repo ships only shell scripts, prompts, and workflows. No application services to probe. |
