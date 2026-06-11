# Review plan — how much review a PR gets

Before any model runs, claude-review classifies each PR with a deterministic,
no-LLM resolver ([`scripts/review-plan.sh`](../scripts/review-plan.sh)) into a
**review plan**. This keeps routine PRs fast and cheap while reserving the deep,
two-judge review for substantial or risky changes.

## The plan

Each PR resolves to a `review_level`, whether functional app-testing runs, and a
`gate` (the reason). The resolver checks these in order and stops at the first
match:

| # | gate | when | review_level | functional |
|---|------|------|--------------|------------|
| 1 | `label` | `skip-review` label present | `skip` | no |
| 2 | `promotion` | release/promotion PR (e.g. `staging` → `main`) | `light` | no |
| 3 | `oversized` | over the size ceiling (default 1500 lines / 40 files) | `light` | yes |
| 4 | `nonruntime` | only tests / docs / CI / lockfiles changed | `full` | no |
| 5 | `small` | ≤ 300 non-generated lines, no sensitive paths | `light` | yes |
| 6 | `normal` | substantial, **or** touches a sensitive path | `full` | yes |

- **`full`** — the dual-judge debate (Opus + Haiku, with rebuttal).
- **`light`** — a single judge, no rebuttal. The fast path for the judge fan only:
  functional testing still runs per the table, because runtime evidence is the
  review's centerpiece — small UI fixes are exactly where one screenshot beats
  prose, and oversized feature PRs are exactly where an APPROVE without runtime
  evidence is riskiest. The test planner still scopes the run (a small diff with
  no user-observable surface plans `skip`; a trivial one plans a 1-scenario
  `quick`), so the cost scales with the surface, not the gate.
- **`skip`** — no judges; the reason is posted as a note.

> Generated files (lockfiles, snapshots, `dist/`, `*.min.*`, `*.generated.*`, …)
> don't count toward the size — a big lockfile bump alone won't push a small PR
> into `full`.

A `deep-review` label (see below) flips rungs 2, 3, and 5 to `full`.

## Labels

| label | effect |
|-------|--------|
| `skip-review` | Skip the detailed review entirely (e.g. already reviewed elsewhere). Highest precedence. |
| `deep-review` | Force a **full** review on a PR that would otherwise be downgraded (promotion / oversized / small). The mirror of `skip-review`. |

If both labels are on a PR, **`skip-review` wins**.

## Per-repo tuning

Every knob is a `workflow_call` **input** with a safe default. Pass it in the
`with:` block of the job that calls the reusable workflow to tune per repo:

| input | default | meaning |
|-------|---------|---------|
| `gate_small_ceiling` | `300` | non-generated lines at/under which a runtime PR is `small` (single judge) |
| `gate_size_ceiling` | `1500` | non-generated lines over which a PR is `oversized` |
| `gate_file_ceiling` | `40` | changed files over which a PR is `oversized` |
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

| PR | gate | what runs |
|----|------|-----------|
| 40-line bug fix in `src/` | `small` | single judge + quick functional check (screenshot of the touched surface) |
| 500-line feature | `normal` | full debate + functional |
| 2000-line feature | `oversized` | single judge + functional smoke run |
| 20-line change in `database/migrations/` | `normal` (sensitive) | full debate + functional |
| `staging` → `main` release | `promotion` | single-judge `light`, no functional |
| docs-only PR | `nonruntime` | judges run, no functional |
| small but tricky PR you want fully reviewed | add `deep-review` | full debate + functional |
