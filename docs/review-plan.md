# Review plan — how much review a PR gets

Before any model runs, claude-review classifies each PR with a deterministic,
no-LLM resolver ([`scripts/review-plan.sh`](../scripts/review-plan.sh)) into a
**review plan**. This keeps routine PRs fast and cheap while reserving the deep,
two-judge review for substantial or risky changes.

> **The plan decides depth, not what runs.** Reviews are on demand: the `/review`
> comment that started the run chose which *passes* to run (judges, browser
> tester, native second opinion). This resolver only decides how hard the judges
> think about the diff. See [the command table](../README.md#the-review-command).

## The plan

Each PR resolves to a `review_level` and a `gate` (the reason). The resolver
checks these in order and stops at the first match:

| # | gate | when | review_level |
|---|------|------|--------------|
| 1 | `label` | `skip-review` label present | `skip` |
| 2 | `promotion` | release/promotion PR (e.g. `staging` → `main`) | `light` |
| 3 | `oversized` | over the size ceiling (default 3000 lines / 60 files) | `skip` → blocking `REQUEST_CHANGES` (split the PR) |
| 4 | `nonruntime` | only tests / docs / lockfiles / reviewer config changed | `light` |
| 4 | `nonruntime` | a supply-chain file is touched — `.github/` (CI/workflow), `.claude/`, `bugbot.md` (reviewer/agent config) | `full` |
| 4b | `tiny` | ≤ 10 non-generated lines, no sensitive paths | `light` |
| 5 | `small` | ≤ 300 non-generated lines, no sensitive paths | `light` |
| 6 | `normal` | substantial, **or** touches a sensitive path | `full` |

- **`full`** — the dual-judge debate (Opus + Haiku, with rebuttal).
- **`light`** — a single judge, no rebuttal. The fast path for the judge fan. At
  `small` and `tiny` the single judge runs on Opus (high recall on the path that
  gets the least scrutiny); at `nonruntime` / `promotion` it stays on Sonnet.
  A `light` plan does **not** suppress the add-on passes: `/review functional` and
  `/review native` are honoured at every tier, because a small diff is exactly
  where one screenshot or one second opinion beats more prose.
- **`tiny`** — a ≤ 10-line, non-sensitive runtime fix. One Opus judge reviews it.
  Sensitive paths and `deep` still get the full dual-judge review. On round 2, a
  trivial since-last delta is reviewed by a single judge too.
- **`skip`** — no judges. For most skip reasons the reason is posted as a note;
  for `oversized` the orchestrator instead emits a blocking `REQUEST_CHANGES`
  asking to split the PR (no judge debate). Nothing runs on push, so there is no
  duplicate-block problem to dedupe: ask again after splitting and the block
  re-evaluates against the new size. `/review deep` (or the `deep-review` label)
  overrides it and forces a full review.

### Runtime-evidence gate (applies across tiers)

This applies only to runs that asked for `functional`. When they did, and the
test planner judged the PR has runtime behaviour to exercise
(`## Strategy ∈ {quick, functional}`), the run must produce smoke evidence, and
the verdict depends on how the smoke run ended:

- **Ran and `FAIL`ed** — reproduced runtime evidence against the PR: the
  orchestrator raises the verdict to a blocking `REQUEST_CHANGES` (it carries
  no findings, so a later round un-pins it once the failure clears).
- **Never ran** — no `dev-start.sh`, the bring-up failed or timed out, or the
  tester crashed. That is a setup problem, not evidence against the PR: the
  verdict is never raised, but `APPROVE` is withheld (capped at `COMMENT`) and
  the review body's **⚙️ Review setup health** section states exactly what was
  broken (missing vs present-but-failed, with the script's actual error) and
  the one action that fixes it.
- **`PASS`/`WARN`** — satisfied.

A run that never asked for `functional` is exempt outright — the gate cannot
withhold `APPROVE` over evidence nobody requested. So are docs-only / non-runtime
PRs (`## Strategy: skip`, and the `nonruntime` / `promotion` / `label` gates):
there is nothing to test. On round 2,
a deliberate `## Strategy: skip` inherits the prior round's `PASS`/`WARN`; a
prior `FAIL` still blocks.

> Generated files (lockfiles, snapshots, `dist/`, `*.min.*`, `*.generated.*`, …)
> don't count toward the size — a big lockfile bump alone won't push a small PR
> into `full`.

`/review deep` — and the `deep-review` label (see below) — flips rungs 2, 3, and
5 to `full`.

## Round 2: same plan, scoped review

The plan resolves **fresh each round** from the PR's overall shape — the table
above, labels included, applies identically to every run. There is no separate
round-2 plan refinement. What makes follow-up rounds cheap is **context
scoping**, not a smaller plan: when a prior **judged** review exists (derived
from the PR's own review history), the context builder scopes the diff index to the
changes since the last reviewed commit, judges read only that, every open
thread is classified against it, and functional scenarios are planned against
the since-last diff (zero scenarios is a valid outcome for follow-ups with no
user-observable surface). The verdict ladder still pins unresolved prior
blockers regardless of how small the follow-up is.

A round the plan **skipped** (`skip-review` label, or the oversized
split-request) is not a round: no judge read the diff, so there is nothing to
scope against. Those reviews carry a hidden skip marker and are excluded from
the round count — the next run resumes from the last review that *did* judge,
whatever came after it. With no judged round yet, that means a fresh full-scope
round 1: this is what makes `/review deep` on an oversized PR work, since it
would otherwise "resume" from a block that reviewed nothing and judge only the
newest commit. With a judged round behind it, the skip is simply transparent —
the next request is the next round, scoped to that judged round's SHA, with its
verdict and its unresolved blockers still pinned. A skip never launders a
standing block: the skip review does not dismiss it either.

## Labels

| label | effect |
|-------|--------|
| `skip-review` | Skip the detailed review entirely (e.g. already reviewed elsewhere). Highest precedence — it outranks an explicit `/review` comment, so a PR the bot must not touch stays untouched. |
| `deep-review` | Force a **full** review on a PR that would otherwise be downgraded (promotion / oversized / small). The standing version of `/review deep`: use the label when every review of this PR should be deep, the command when just this one should. |

If both labels are on a PR, **`skip-review` wins**.

## Per-repo tuning

Every knob is a `workflow_call` **input** with a safe default. Pass it in the
`with:` block of the job that calls the reusable workflow to tune per repo:

| input | default | meaning |
|-------|---------|---------|
| `gate_small_ceiling` | `300` | non-generated lines at/under which a runtime PR is `small` (single judge) |
| `gate_tiny_ceiling` | `10` | non-generated lines at/under which a runtime PR is `tiny` (single judge) |
| `gate_size_ceiling` | `3000` | non-generated lines over which a PR is `oversized` |
| `gate_file_ceiling` | `60` | changed files over which a PR is `oversized` |
| `gate_sensitive_globs` | auth.* / oauth / authentication / authorization / security / payments / migrations | path globs that force `full` even when small |
| `gate_deep_label` | `deep-review` | label that forces a full review |
| `gate_skip_label` | `skip-review` | label that skips review |
| `gate_promotion_bases` | `main master production prod` | base branches treated as release targets |
| `gate_promotion_heads` | `staging develop dev release hotfix` | head branches treated as promotion sources |

### Sensitive paths and the `auth/` caveat

Sensitive paths force a full review no matter how small the diff — for code
where a single judge isn't enough (authentication logic, payments, DB
migrations, security).

A **bare `auth/` directory is deliberately not sensitive by default.** Many
frontends use `views/auth/` (or `pages/auth/`) as the *signed-in route group* —
the whole authenticated area of the app — so flagging it would force nearly
every frontend PR into a full review. The default matches auth *files*
(`auth.*`) and unambiguous directories (`authentication/`, `oauth/`, …) instead.

If your repo keeps real auth logic in an `auth/` directory, opt it back in.
Note that setting this input **replaces** the default list, so include
everything you want treated as sensitive:

```yaml
# in the with: block of your caller job
with:
  pr_number: ${{ inputs.pr_number || '' }}
  gate_sensitive_globs: "*/auth/* */oauth/* */security/* */payments/* */migrations/*"
```

## Examples

All of these assume `/review code`; add `functional` or `native` to layer a pass
on top of whatever the gate decided.

| PR | gate | how the judges review it |
|----|------|--------------------------|
| 40-line bug fix in `src/` | `small` | single Opus judge |
| 2500-line feature | `normal` | full debate (under the 3000 ceiling) |
| 3500-line feature | `oversized` | blocked: `REQUEST_CHANGES` asking to split — no judges (use `/review deep` to force a full review anyway) |
| 20-line change in `database/migrations/` | `normal` (sensitive) | full debate |
| `staging` → `main` release | `promotion` | single-judge `light` |
| docs-only PR | `nonruntime` | single judge |
| `.claude/` or `bugbot.md` config PR | `nonruntime` (supply-chain) | full dual-judge |
| small but tricky PR you want fully reviewed | `/review code deep` | full debate |
