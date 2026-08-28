---
status: accepted
date: 2026-08-27
supersedes: 0001
---

# 0003 — A two-call review: guard, scan, verify

## Context

The v3 pipeline made **seven model calls** per review: a context builder, two
debating judges plus up to two rebuttal rounds, an optional native
(`code-review` plugin) pass, a functional tester, and the orchestrator's own
consolidation. Measured on this repo's own runs it cost **$3.02/run mean**
($7.22 worst) over 11-12 minutes, and read **504k cached tokens for a 3-line
diff**. Fleet-wide, only ~20% of its `REQUEST_CHANGES` verdicts were a real
defect; 76% were gate-driven — a missing spec, a missing dev env, a smoke test
that never ran.

Three separate mechanisms were producing that noise:

- **Depth tiers** (ADR 0001). A deterministic resolver classified every PR into
  one of six tiers before any model ran. It is structural, not semantic: it
  cannot tell that a 40-line change is risky unless its path says so, and the
  model that reads the diff can.
- **The verdict ladder.** Round 2+ pinned the verdict against the prior round —
  a prior `REQUEST_CHANGES` forced another one. On one PR that produced twelve
  rounds of flip-flopping between "would approve" and a blocking verdict.
- **Gates as blockers.** Missing spec, missing `dev-start.sh`, and a smoke run
  that never happened all reached `REQUEST_CHANGES`, which is where most of the
  76% came from.

## Decision

**Two model calls, and the model decides depth.**

```
guard.sh  ->  review-scan (1 call)  ->  review-verify (1 call)  ->  post-review.sh
                                         \- functional tester (advisory, optional)
```

- **`scripts/guard.sh`** — pure bash, no network, ~90 lines. Four
  short-circuits, and only the four a model must never be paid to make: a
  `skip-review` label, an empty since-last delta, an oversized PR (blocked with
  a split request and no model call), and a diff with no non-generated files.
  **No tiers.**
- **`skills/review-scan.md`** — reads the diff itself and **self-scales its own
  depth**, recording which it chose and why. Every finding must carry a
  concrete `failure_scenario`; a finding that cannot name one is dropped by the
  model that found it. Zero findings is the expected output for a clean PR.
- **`skills/review-verify.md`** — one pass over all candidates whose mandate is
  to **refute**. It re-reads the source at HEAD and defaults to refuted when
  uncertain. It also decides the verdict and renders the final body; nothing
  downstream rewrites its prose.

Verdict rules move entirely into review-verify: `REQUEST_CHANGES` needs a
surviving critical/major finding and **never** comes from a gate, a missing
spec, a failed smoke test or a missing dev env. `APPROVE` requires zero
findings plus an argued case that a human pass changes nothing. `COMMENT` is
the default and a good outcome.

**Incremental review, without the ladder.** When a prior judged review exists,
review-scan reads only `git diff <prior_head_sha>..HEAD` and re-checks the
prior review's findings against HEAD, carrying the still-unresolved ones. An
empty delta skips the run entirely and posts nothing. But the verdict is
computed **fresh** each round from surviving findings alone — the prior verdict
is not an input. Scoping is what makes round 2 cheap; pinning is what made it
wrong.

## Considered options

- **Keep the judge panel, cut the rebuttal rounds.** Cheaper, but the panel's
  cost is mostly the two full diff reads, and the disagreement it produced was
  the thing the debate then had to resolve.
- **Keep tiers, drop the debate.** Keeps a structural classifier making a
  semantic call, which is the part ADR 0001 already flagged as its own weakness.
- **Guard + scan + verify (chosen).** One reviewer that scales itself, one
  adversary that tries to kill its findings. The refutation pass is what
  replaces the second judge, at a fraction of the tokens.

## Consequences

- ADR 0001 is **superseded**. `scripts/review-plan.sh`, `docs/review-plan.md`,
  the six tiers are gone. What survives is a single override for the size ceiling, reachable two ways: `/review deep` in the comment (one run) or the `deep-review` label (every push). Neither selects a depth — they only decide whether an oversized PR is read at all. The comment is the primary interface; the label stays because it is persistent state, which a comment cannot be, and a large PR that legitimately cannot be split should not need the command re-typed each round. `skip-review` stays label-only for the same reason, in reverse. `gate_deep_label` is therefore live again — it names that label, and the workflow now passes it to the guard as `GATE_FORCE_LABEL` alongside the comment's `GATE_FORCE_DEEP`.
  `gate_small_ceiling`, `gate_tiny_ceiling`, `gate_sensitive_globs`,
  `gate_promotion_*` and `model_fast` remain as **deprecated, ignored** inputs:
  a reusable workflow errors on an undefined input, so removing one breaks every
  consumer's caller workflow.
- The native (`code-review` plugin) pass is **deleted** with the orchestrator
  that dispatched it, and with it the `plugin_marketplaces` / `plugins` inputs
  and the unpinnable marketplace ref they installed. `native_review_scope` and
  `model_standard` survive as deprecated inputs for the same reason;
  `/review native` still parses and runs a normal code review, saying so.
- `skills/review-context-builder.md`, `skills/review-judge.md`,
  `skills/review-native.md` and `scripts/fetch-pr-threads.sh` are deleted. The
  scan reads the PR itself with `gh pr view/diff`; there is no separate context
  artifact.
- No thread adjudication, no `DISPUTED` state, no "dropped after author
  rebuttal" bookkeeping. A prior finding survives or it does not, decided by
  reading the code at HEAD.
- Targets: **$0.60-0.90/run**, 4-6 minutes, body ~600 chars (hard cap 1200),
  inline comments ≤700 chars, max 5.
