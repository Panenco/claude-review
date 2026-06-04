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
| 3 | `oversized` | over the size ceiling (default 1500 lines / 40 files) | `light` | no |
| 4 | `nonruntime` | only tests / docs / CI / lockfiles changed | `full` | no |
| 5 | `small` | ≤ 300 non-generated lines, no sensitive paths | `light` | no |
| 6 | `normal` | substantial, **or** touches a sensitive path | `full` | yes |

- **`full`** — the dual-judge debate (Opus + Haiku, with rebuttal).
- **`light`** — a single judge, no rebuttal, no functional. The fast path.
- **`skip`** — no judges; the reason is posted as a note.

> Generated files (lockfiles, snapshots, `dist/`, `*.min.*`, `*.generated.*`, …)
> don't count toward the size — a big lockfile bump alone won't push a small PR
> into `full`.

A `deep-review` label (see below) flips rungs 2, 3, and 5 to `full`.

> **Rollout:** the classification above — and turning functional off for `light` —
> is live now. The orchestrator's single-judge handling for `light` lands alongside
> it; until that ships, a `light` PR is classified correctly and skips functional but
> still runs the two-judge debate. See [ADR 0001](adr/0001-risk-tiered-review-depth.md).

## Labels

| label | effect |
|-------|--------|
| `skip-review` | Skip the detailed review entirely (e.g. already reviewed elsewhere). Highest precedence. |
| `deep-review` | Force a **full** review on a PR that would otherwise be downgraded (promotion / oversized / small). The mirror of `skip-review`. |

If both labels are on a PR, **`skip-review` wins**.

## Per-repo tuning

Every knob is an environment variable with a safe default. Set it on the
`env:` of the job that calls the reusable workflow to tune behavior per repo:

| variable | default | meaning |
|----------|---------|---------|
| `GATE_SMALL_CEILING` | `300` | non-generated lines at/under which a runtime PR is `small` (single judge) |
| `GATE_SIZE_CEILING` | `1500` | non-generated lines over which a PR is `oversized` |
| `GATE_FILE_CEILING` | `40` | changed files over which a PR is `oversized` |
| `GATE_SENSITIVE_GLOBS` | auth.* / oauth / authentication / authorization / security / payments / migrations | path globs that force `full` even when small |
| `GATE_DEEP_LABEL` | `deep-review` | label that forces a full review |
| `GATE_SKIP_LABEL` | `skip-review` | label that skips review |
| `GATE_PROMOTION_BASES` | `main master production prod` | base branches treated as release targets |
| `GATE_PROMOTION_HEADS` | `staging develop dev release hotfix` | head branches treated as promotion sources |

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
Note that setting the variable **replaces** the default list, so include
everything you want treated as sensitive:

```yaml
# in the env: of your caller workflow's job
GATE_SENSITIVE_GLOBS: "*/auth/* */oauth/* */security/* */payments/* */migrations/*"
```

## Examples

| PR | gate | what runs |
|----|------|-----------|
| 40-line bug fix in `src/` | `small` | single-judge `light`, fast |
| 500-line feature | `normal` | full debate + functional |
| 20-line change in `database/migrations/` | `normal` (sensitive) | full debate + functional |
| `staging` → `main` release | `promotion` | single-judge `light` |
| docs-only PR | `nonruntime` | judges run, no functional |
| small but tricky PR you want fully reviewed | add `deep-review` | full debate + functional |
