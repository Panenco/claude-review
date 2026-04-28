# Bugbot

Project-specific review rules for `panenco/claude-review` itself. This repo IS
the upstream review pipeline, so most findings concern the pipeline's own code,
prompts, and config — not an application.

## What this repo ships

- Bash scripts under `scripts/` (review build, verdict gate, post, dev-env setup, prompt generation).
- Skill prompts under `skills/review-*.md` — read verbatim by Claude in CI.
- Reusable workflow `.github/workflows/pr-review.yml` (`workflow_call`).
- Composite action `action.yml` that installs skills/scripts into the consumer workspace.
- Setup recipe `prompts/setup-review.md` — read verbatim by Claude when a user runs `/setup-review`.

## Rules

- **Skill prompts and the setup recipe are executable assets, not prose.** Files in `skills/` and `prompts/setup-review.md` are read verbatim by Claude at runtime. Wording, heading levels, and exact strings (e.g. `### Auth`, `### Known service ports`, `Sign in:`, `Method: cookie|bearer|header|none`) are load-bearing — `pr-review.yml`'s validate step greps for them literally. Edit like code: any change risks shifting verdicts or breaking auto-extraction.
- **Shell scripts use `set -uo pipefail` only — never add `set -e`.** Documented rationale lives in `prompts/setup-review.md` (Step 4.5): `set -e` produces surprising failures in idioms like `curl || true` and `grep` pipes that legitimately return 1. Explicit `exit N` on every error path is the contract.
- **Readiness loops must fail fast.** Any `for i in $(seq …); do …; break; done` that probes a service must be followed by an explicit `if [ "$READY" != "true" ]; then echo ::error:: …; exit 1; fi`. Silent-success-on-timeout is the #1 bug we flag in consumer review-configs — don't ship it in our own examples or scripts.
- **Tag-resolution caveat is real.** `@v1` is resolved at different moments for the reusable workflow file vs the composite action invoked inside it (`pr-review.yml` line ~112: `uses: panenco/claude-review@v1`). The README documents this; preserve that note when editing tag/release guidance.
- **`anthropics/claude-code-action` restores `.claude/` from `origin/main` for untrusted PR heads.** Anything we write under `.claude/skills/` in the workspace is wiped at agent-launch time. The current install pattern (export `CLAUDE_REVIEW_PIPELINE_DIR` to the action's own download path, copy scripts to `.review-scripts/` which is *not* on the restore list) exists for this reason. Don't "simplify" by moving skills into the workspace.
- **Pipeline changes need an end-to-end thought, not just a code review.** A change to `build-review.sh`, any `skills/review-*.md`, `verdict-gate.sh`, or `pr-review.yml` can break every consumer repo on the next PR push (we ship `@v1` as a moving tag). Verdict-affecting changes especially: trace what flows into `core-meta.json` and `verdict-gate.sh` before approving.

## Verify before flagging

Before reporting a finding that cites a file, capability, or string, confirm it exists:

- Repo capabilities live at `scripts/`, `skills/`, `prompts/`, `.github/workflows/pr-review.yml`, and `action.yml`. Anything outside that surface is unlikely to be present.
- The runtime-generated `context.md` is not committed; references to "context.md" inside skills are deliberate (they describe the file the Context Builder writes during a review run, not a checked-in file).
- If unsure whether an artifact exists, drop the finding or move it to `uncertain_observations`.

## Accepted supply-chain trade-offs

- The caller workflow `.github/workflows/claude-review.yml` references `panenco/claude-review/.github/workflows/pr-review.yml@v1` with `secrets: inherit`. This is intentional self-dogfooding: the same path every consumer uses, applied to the upstream repo itself. Do **not** flag the moving-tag + `secrets: inherit` combination as a security finding here — the trade-off is explicitly accepted, identical to the consumer-side guidance.
- The reusable workflow itself (`.github/workflows/pr-review.yml`) calls `uses: panenco/claude-review@v1` on the install action. Same trade-off, same acceptance, same reason.
