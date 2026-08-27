# v4 — lean reviewer: deterministic rim, thin model core

## Evidence (this repo's own runs, n=28 PRs / 26 review runs)
- mean **$3.02/run**, worst $7.22; PR 94 cost ~$35-40 across 7 re-reviews of a 505-line diff
- median wall clock **11-12 min** (range 3m55s - 21m40s)
- **504k cache-read tokens** to review a 3-line diff (PR 95)
- median summary body **1560 chars**, uncorrelated with diff size (2-char diff -> 2329-char review)
- inline comments **1958-2656 chars** (published: resolved comments avg 617, unresolved 807)
- APPROVE only ever on 1-3 line diffs; fleet-wide APPROVE 60% but **only ~20% of REQUEST_CHANGES is a real defect**, 76% gate-driven
- zero GitHub file links generated anywhere

## Root causes
1. An LLM assembles the output. Sonnet orchestrator + ~49KB prompt reads every artifact and writes prose -> the 504k cache reads, the uncapped bodies, the round-to-round verdict flip-flop.
2. Fixed 2-judge panel over the whole diff, + up to 2 rebuttal rounds. Cost scales with diff size, twice, then doubles again on disagreement.
3. 11 verdict-affecting layers, mostly in prompts, untestable.
4. No length budget exists anywhere in the pipeline.
5. Functional tester derives severity from the PR title; a single FAIL raises to REQUEST_CHANGES with zero findings attached.
6. APPROVE is a side effect of "found nothing", not a decision.

## Architecture

plan(bash) -> pack(bash) -> spec(haiku) -> scan(opus/low) -> verify(opus/medium xN) -> decide(bash) -> render(bash) -> post(bash)

| # | Stage | Model | Note |
|---|---|---|---|
| 1 | Plan | - | keep review-plan.sh; add delta gating + `nochange` skip |
| 2 | Pack | - | NEW. PR-Agent compression: strip generated/lock/minified, drop deletion-only hunks, +/-3 ctx, token budget, overflow -> filename list |
| 3 | Spec | haiku-4.5 | AC/spec + convention extraction only. Replaces the 370-line LLM context builder at light tiers |
| 4 | Scan | **opus-5 --effort low** | one pass over packed diff -> candidates + reviewer briefing |
| 5 | Verify | **opus-5 --effort medium** | one agent per candidate, mandate = refute. Cost proportional to candidates (0-3), not diff size |
| 6 | Functional | sonnet-5 | unchanged mechanics; demoted - can never raise a verdict |
| 7 | Decide | - | NEW scripts/decide-verdict.sh - the whole ladder, unit-tested |
| 8 | Render | - | NEW scripts/render-review.sh - hard char budgets + GitHub links |
| 9 | Post | - | existing post-review.sh, slimmed |

Deleted: judge panel, rebuttal rounds, LLM body assembly, LLM ladder, LLM gate logic.

## Finding contract
Every candidate must carry, or it is dropped mechanically:
- `rule_id` from a pre-registered index (rules.yml) - model cannot invent categories
- `failure_scenario` - concrete input/state -> wrong output. Cannot name one => must not emit.
- `evidence` - quoted lines from the file
- `path:line` - validated against `git ls-files` and the diff hunk set
- `fix` - committable diff (+11pp resolution rate, arXiv 2607.21997)
Severity is DERIVED from rule_id + category caps. The model never picks severity.

## Verify pass
One opus-5/medium agent per candidate, mandate "refute this", defaults to refuted when uncertain.
Published deltas: 76% -> 6.3% FP (arXiv 2601.22952), 75% production precision (BitsAI-CR), 79-83% of candidates killed (Refute-or-Promote).

## Approval bar
APPROVE only when ALL hold:
- zero confirmed findings
- scan set `human_review_adds_nothing: true` AND argued why a human pass changes nothing
- no sensitive path (auth / payments / migrations / security / .github / .claude / infra)
- review-effort score <= 2/5
- functional PASS or genuinely not applicable (never SKIP-with-unknowns)
Otherwise -> COMMENT + `### What a human should review`.
REQUEST_CHANGES only for a confirmed critical/major finding. Never for a gate.

## Human-review briefing
1-3 items, model-chosen (no hardcoded categories). Each = GitHub link + what to check + why the bot could not settle it.

## Output budgets (enforced in bash, not prompts)
- body <= 1200 chars hard
- verdict <= 240 chars
- finding line <= 160 chars
- human-review items <= 3
- inline comment <= 700 chars
- links: https://github.com/O/R/pull/N/files#diff-<sha256(path)>R<line>  (verified working)
Deleted from body: "Spec sources", the 6-banner block, 7 canned setup-health bullets, "(consolidated from N judges, R rebuttal rounds)", always-on functional <details>.

## Round 2
Gate on `git diff PRIOR_HEAD..HEAD` only (today it uses whole-PR shape). Empty delta -> skip entirely, no post.
Feed prior findings + resolution status into the scan.

## Targets
$0.60-0.90/run (from $3.02) | 4-6 min (from 11-12) | body ~600 chars (from ~1560)
