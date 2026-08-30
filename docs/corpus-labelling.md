# What the labelled probe corpus measures, and what it says

`scripts/probe-score.sh` scores the reviewer against a corpus of real merged PRs
labelled `simple` / `needs-eyes` / `docs-slice` / `docs-baseline`. The corpus
itself is git-ignored (`tests/fixtures/probe-corpus.json`) because this repo is
public and it names private client repos. This file records what the labelling
found, so the rubric and the reviewer skills can be tuned against evidence
rather than intuition.

## The question that was open

A first pass labelled 39 PRs drawn from a single recent window in two client
repos and measured **14% of code PRs `simple`**, against an owner estimate of
30-50%. The window was noted as bugfix-heavy, so the number might have been a
sampling artifact.

## The wider draw

122 additional merged code PRs and 24 docs-only PRs, stratified across two
repos and six periods spanning ~5 months (the full merged history of both
repos: 1,266 code PRs, 130 docs-only). One stratum, `orig-window`, deliberately
replicates the first pass's draw (`gh pr list` default order, most recent
merged) so the two are comparable.

## Answer: the recent window was not atypical

| period        | simple / n | rate |
|---------------|-----------:|-----:|
| `orig-window` |       5/20 |  25% |
| 2026-08       |       6/20 |  30% |
| 2026-07       |       4/20 |  20% |
| 2026-06       |       6/20 |  30% |
| 2026-05       |       6/20 |  30% |
| 2026-04       |       8/22 |  36% |

Chi-square across the six periods is 1.6 on 5 df (p ~ 0.9) — indistinguishable
from flat. Per-bucket 95% CIs are roughly +/-20pp, so the visible spread is
noise. Dropping the three repo-genesis scaffold PRs that inflate 2026-04 flattens
it further (36% -> 26%).

**Type mix does not rescue the estimate either.** The `fix:`-heavy window was
the suspected cause, but in these repos `fix:` PRs are *more* often simple
(31%) than `feat:` PRs (18%). Reweighting the observed per-type rates to the
repos' true long-run type mix (37% `fix`, 25% `feat`, 20% untyped, 6% `chore`)
gives 28.2%, versus 29.6% under the window's own mix — a 1.4pp move, in the
direction that would have made the window read *higher*.

Repo split is also flat: 29% in one repo vs 28% in the other.

## So the rate is a function of strictness, not of sampling

- loose (as labelled, borderlines counted as `simple`): **28.7%**, 95% CI 21-37%
- strict (borderlines counted as `needs-eyes`): **17.2%**, 95% CI 11-24%

The first pass's 14% sits just under the strict end. Nothing in the wider draw
supports 30-50% except the very top of the loose CI. Treat the honest number as
a **range, 17-29%**, and state which reading is in use.

Caveat worth keeping: per-labeller rates in this round ranged 6%-43% across
eight raters on shuffled batches. Rater spread exceeds period spread. The label
is genuinely subjective at the margin, which is why `borderline` exists and why
the range above is reported instead of a point estimate.

Docs-only, same caveat: 10/24 `docs-slice` (42%) against 18% in the first pass.

## Disqualifier rules, re-measured at n=122

Precision = share of PRs the rule fires on that really are `needs-eyes`.

| rule | fires | of which `simple` | precision | recall |
|------|------:|------------------:|----------:|-------:|
| migration file present            | 22 | 0 | 100% | 25% |
| auth/tenancy/visibility vocabulary| 13 | 0 | 100% | 14% |
| touches workflow / deploy / dev-env script | 20 | 1 | 95% | 21% |
| changed files > 20                | 40 | 3 |  92% | 42% |
| added lines > 100                 | 84 | 17|  79% | 77% |

**Held:** migration, auth/tenancy vocabulary, workflow/deploy scripts. All three
survived a 4x larger sample with at most one exception each. The single
workflow exception was a two-file split of a CI job that touches no product or
deploy code.

**Broke: `added lines <= 100`.** It was clean at n=28 (0 of 14 over-100 PRs were
simple); at n=122, 17 of 84 are. The failure mode is that raw `additions` counts
lockfiles, vendored docs and generated files. Recomputing over **production
lines only** — excluding lockfiles, `*.md`/`docs/**`, snapshots, `dist/`,
generated files and test files — lifts precision from 79% to 87% and is the
version worth keeping. Even then it is a soft signal, not a gate: 8 PRs over
100 production lines were still `simple` (a scaffold-only package, a
single-file visual reflow, a preview-render branch, a local-dev tooling swap).

Combining the three surviving rules with the production-lines refinement gates
43 of 122 PRs through, of which 60% are `simple` — the best cheap prefilter
found, and it wrongly excludes 9 genuinely simple PRs.

## Practical read for tuning the reviewer

- The three vocabulary/path rules are safe to treat as hard "do not auto-approve"
  signals: zero or near-zero false exclusions across 122 PRs.
- Size is not. Gate on production lines if a size gate is wanted at all, and
  expect it to cost real approvals.
- The share of PRs that *should* get a silent clean approval is 17-29%, not
  30-50%. Tuning the reviewer toward a 40% approve rate would be tuning it past
  what the work actually looks like.
