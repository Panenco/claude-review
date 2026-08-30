---
status: accepted
date: 2026-08-27
supersedes: 0001
amended-by: 0005
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
  **REVERSED by ADR 0005** — the marketplace turned out to be pinnable after
  all, as a local-path source vendored by a SHA-pinned `actions/checkout`, so
  the pass, both inputs and both deprecated inputs are live again. The
  reasoning below about the URL form was correct; it was simply never the only
  form available. Everything else in this ADR stands.
- `skills/review-context-builder.md`, `skills/review-judge.md`,
  `skills/review-native.md` and `scripts/fetch-pr-threads.sh` are deleted. The
  scan reads the PR itself with `gh pr view/diff`; there is no separate context
  artifact. **Its spec retrieval was not deleted with it — see the amendment.**
- No thread adjudication, no `DISPUTED` state, no "dropped after author
  rebuttal" bookkeeping. A prior finding survives or it does not, decided by
  reading the code at HEAD.
- Targets: **$0.60-0.90/run**, 4-6 minutes, body ~600 chars (hard cap 1200),
  inline comments ≤700 chars, max 5.

## Amendment, 2026-08-28 — spec assembly is one file, not four sources

Deleting the context builder took its **spec retrieval** with it, and that was
not a decision anyone made. Two of the three sources came back in stages, badly:
first only the linked GitHub issue, leaving a repo that tracks work in Linear or
Jira with a reviewer that had no requirements at all, and `TRACKER_SECRETS`
forwarded to nothing. The sandbox was never the obstacle — the hook ran as a
plain `Bash` invocation, not through the denied raw `gh` API verb.

**`scripts/build-spec.sh` now assembles one `/tmp/spec.md`** in the
orchestrator's turn 1, from every source that resolves, each under a header
naming its origin: linked GitHub issue → external tracker via
`.github/claude-review/fetch-issue.sh` (60s timeout, soft-fail) → in-repo spec
documents → the PR body. `review-scan` reads that one file and knows nothing
about the sources, so its spec section got *shorter* while gaining two of them.
No source resolving is a normal outcome: the file is empty and the review runs
without a spec, exactly as before.

Two deliberate narrowings from v3: the in-repo lookup is no longer bound to
`docs/prds/` — it resolves **any** repo-relative markdown path referenced from
the issue or PR body, repo-wide, so no directory convention and no configuration
is needed — and the PR-title-word-match against that directory is gone with it.
The functional tester's test plan stays issue-ACs-only; the assembled file is
wider than a test plan on purpose.

**One new use of the `human_review` channel:** with a spec loaded, substantive
work no criterion asks for is raised as at most **one** item per review. It is
the inverse of AC compliance, it has no failure scenario so it can never be a
finding, and with no spec loaded it is not raised at all.

## Amendment 2, 2026-08-28 — the in-repo document is the spec; the issue is a summary

The first amendment ordered the sources linked issue → tracker → in-repo
document. That was backwards for how the fleet actually writes specs: **the
GitHub issue carries a summary, and the extensive planning document lives in the
repo** ("docs in code"). Ordering the summary first told the reviewer the thin
source outranked the real one, and made document discovery — which decides
whether the real spec is read at all — the least important step in the chain.

**Precedence is now document → issue → tracker → PR body**, and `/tmp/spec.md`
says so in its own structure: every header carries its source's authority
(`AUTHORITATIVE — this governs` / `SUMMARY — does not override the spec
document`), and the file opens with a `GOVERNING SOURCE` line naming what is in
force for that run. When no document resolved it says that outright, so a review
against a summary is visible rather than assumed complete.

**Discovery became load-bearing, so it got three more routes**, strongest first:
markdown **added or modified by the PR's own diff** (a planning doc committed
alongside the work it plans, needing no reference from anywhere); a location the
repo **declares** in `.github/review-config.md` as a one-line `Spec documents:`
path, directory or glob (the convention varies per repo — a repo needs a way to
say where its specs live, and one line is the whole feature); then the existing
explicit path/URL reference and the `<name>-prd` / `-spec` / `-rfc` last resort.
The denylist grew with it: `CLAUDE.md`, `AGENTS.md` and `bugbot.md` are prompts,
not requirements, and inlining them would feed the reviewer instructions dressed
as a spec.

**The 3×400-line cap became a truncation risk** the moment the document, not the
issue, was the spec — a real planning doc runs past 400 lines and the criteria
the PR implements are as likely to be at line 700 as line 40. The budget is now
1500 lines per document, 3000 across at most 4, whole-document inclusion by
default. When a cut is unavoidable it is **announced in the file**: a `TRUNCATED`
marker on the document, `SPEC IS PARTIAL` in the header block, an Actions
warning, and any document that did not fit at all listed by path. Silent
truncation and silent degradation are the same bug.

**The out-of-scope `human_review` item moved with the precedence.** It was gated
on "`/tmp/spec.md` is non-empty", which included the PR-body fallback — asserting
that a PR does more than asked, against a bot summary of that same PR, is
circular. It is now gated on a governing source that is a document, an issue or a
ticket, and suppressed entirely when the spec is marked partial (the pages we cut
may be exactly what asked for the work). Against a spec document it may be put as
fact; against a summary it must say it is reading a summary. Still capped at one
item, still never a finding.

**The functional tester no longer plans against the thinnest source.** Amendment
1 fixed its input at the linked issue's ACs. Once the issue is known to be a
summary, that is the same silent degradation in a second place: a tester that
verifies three of twelve criteria and reads as if it verified the feature. The
orchestrator now quotes the criteria from the **governing** source — the spec
document when one resolved, else the linked issue — diff-touched criteria first,
with everything unreached listed in `untested`. What stayed excluded, and why:
the external-tracker section is third-party hook output and the PR body
summarises the diff under test; neither is a test plan, and neither should be
steering a browser. The tester still reads no spec artifact itself — the
orchestrator pastes the criteria into its prompt, exactly as before.

## Amendment 3, 2026-08-30 — review depth scales with the diff

The evidence behind the finding bar was that humans write **2–5 judgement
comments per defect**. That got flattened into three global constants: `0–5
items` in review-scan, `up to 5` carried in review-verify, and
`REVIEW_COMMENT_LIMIT:-10` in post-review.sh. A 20-line typo fix and a 2500-line
refactor were allowed exactly the same depth.

`scripts/guard.sh` already counts non-generated lines and files and is a pure,
unit-tested function of its env, so it is where the scale is computed — once,
deterministically, before any model runs:

```
weight        = ng_lines + 25 * ng_files
depth_scale   = min(3 + weight/250, 8)     # 3..8   human_review / check ceiling
comment_limit = 2 * depth_scale            # 6..16  post-review.sh inline cap
```

**Every 250 units of diff weight buys one more judgement slot, starting at 3 and
stopping at 8; the inline cap is twice that.** No tiers — ADR 0004 killed the
seven-tier classifier and this does not bring it back by another name. It is one
continuous step function with two clamps.

Why those numbers:

| | weight | `depth_scale` / `comment_limit` |
|---|---|---|
| 25-line one-file fix | 50 | 3 / 6 — **tighter than the old flat 5** |
| 400-line, 4-file PR (the team's stated limit) | 500 | 5 / 10 — **exactly today's caps** |
| 1000-line, 20-file change | 1500 | 8 / 16 |
| at the guard's own 3000-line ceiling | 3000+ | 8 / 16 |

- **25 per file** — opening an unfamiliar file costs about what reading 25 lines
  of an open one costs. It also keeps the 60-file ceiling worth 1500: enough to
  reach the top band on files alone, not enough to dwarf the line count.
- **250 per step** — chosen so the common case does not move. The team's 400-line
  PR limit lands on 5, which is what shipped before this amendment.
- **floor 3** — most small PRs never had five honest questions in them; the flat
  ceiling was inviting padding at the bottom of the range.
- **cap 8** — past ~1000 lines of real change, the constraint is the reader's
  attention, not the diff. A review nobody finishes is not deeper.
- **2× for the inline cap** — that is today's 10-comments-for-5-checks ratio,
  held constant rather than re-derived.

`review_effort` (1–5) is only known after scan has run, so the guard cannot use
it. **review-verify** applies it, once, as the single modulation: −1 at
`review_effort` ≤ 2, +1 at 5, unchanged at 3–4, clamped to 2..8. The guard sizes
the diff; scan rates the judgement it needed; verify is the one place they meet.

**A wider ceiling is not a weaker bar,** and the prompts say so explicitly.
`### Never an item` is unchanged and now carries a lead-in stating that nothing
in it relaxes as the scale rises, and `Do not pad` was strengthened: a list of
eight where two were honest gets skimmed harder than a list of five, so filling
a wide ceiling costs more, not less. Emitting fewer items than the scale allows
is never a failure. The failure mode this amendment must not create is a model
filling new slots with "double check this logic"; that shape is still banned
outright.

Wiring, end to end: `guard.sh` emits `depth_scale` and `comment_limit` on the
proceed path only → the workflow's guard step already appends its stdout to
`GITHUB_OUTPUT`, so both become step outputs for free →
`REVIEW_DEPTH_SCALE` goes to the orchestrator env (scan and verify read it) and
`REVIEW_COMMENT_LIMIT` to the poster step. **post-review.sh is untouched** apart
from a comment: it still reads `REVIEW_COMMENT_LIMIT` with its `:-10` default,
which is exactly what a short-circuited run (empty outputs) falls back to.
`scripts/review-local.sh` threads both off the same guard run so an eval
measures the caps production would have applied.
