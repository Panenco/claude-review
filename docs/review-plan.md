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
| 3 | `oversized` | over the size ceiling (default 3000 lines / 60 files) | `skip` → blocking `REQUEST_CHANGES` (split the PR) | no |
| 4 | `nonruntime` | only tests / docs / lockfiles changed | `light` | no |
| 4 | `nonruntime` | a `.github/` (CI/workflow) file is touched — supply-chain surface | `full` | no |
| 4b | `tiny` | ≤ 10 non-generated lines, no sensitive paths | `light` | no |
| 5 | `small` | ≤ 300 non-generated lines, no sensitive paths | `light` | yes |
| 6 | `normal` | substantial, **or** touches a sensitive path | `full` | yes |

- **`full`** — the dual-judge debate (Opus + Haiku, with rebuttal).
- **`light`** — a single judge, no rebuttal. The fast path for the judge fan. At
  `small` and `tiny` the single judge runs on Opus (high recall on the path that
  gets the least scrutiny); at `nonruntime` / `promotion` it stays on Sonnet.
  Functional testing still runs at `small`, because runtime evidence is the
  review's centerpiece — small UI fixes are exactly where one screenshot beats
  prose. The test planner still scopes the run (a small diff with no
  user-observable surface plans `skip`; a trivial one plans a 1-scenario `quick`),
  so the cost scales with the surface, not the gate.
- **`tiny`** — a ≤ 10-line, non-sensitive runtime fix. One Opus judge reviews it
  statically; the functional **infra and run are skipped** (a trivial fix rarely
  needs a smoke pass, and the runtime-evidence gate is exempt when functional is
  off). Sensitive paths and `deep-review` still get the full review + functional.
  On round 2, a trivial since-last delta is reviewed by a single judge too.
- **`skip`** — no judges. For most skip reasons the reason is posted as a note;
  for `oversized` the orchestrator instead emits a blocking `REQUEST_CHANGES`
  asking to split the PR (no judge debate). The `deep-review` label overrides
  this and forces a full review.

### Runtime-evidence gate (applies across tiers)

Independently of the tier above, any PR the test planner judged has runtime
behaviour to exercise (`## Strategy ∈ {quick, functional}`) must produce smoke
evidence. If the smoke run returns no `PASS`/`WARN` — no `dev-start.sh`, the
bring-up failed or timed out, or the tester crashed — the orchestrator raises
the verdict to a blocking `REQUEST_CHANGES` (it carries no findings, so a later
round un-pins it once smoke runs). Docs-only / non-runtime PRs
(`## Strategy: skip`, and the `nonruntime` / `promotion` / `label` gates) are
exempt — there is nothing to test. On round 2, a deliberate `## Strategy: skip`
inherits the prior round's `PASS`/`WARN`; a prior `FAIL` still blocks.

> Generated files (lockfiles, snapshots, `dist/`, `*.min.*`, `*.generated.*`, …)
> don't count toward the size — a big lockfile bump alone won't push a small PR
> into `full`.

A `deep-review` label (see below) flips rungs 2, 3, and 5 to `full`.

## Round 2: same plan, scoped review

The plan resolves **fresh each round** from the PR's overall shape — the table
above, labels included, applies identically on every push. There is no separate
round-2 plan refinement. What makes follow-up rounds cheap is **context
scoping**, not a smaller plan: when a prior review exists (derived from the
PR's own review history), the context builder scopes the diff index to the
changes since the last reviewed commit, judges read only that, every open
thread is classified against it, and functional scenarios are planned against
the since-last diff (zero scenarios is a valid outcome for follow-ups with no
user-observable surface). The verdict ladder still pins unresolved prior
blockers regardless of how small the follow-up is.

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
| `gate_tiny_ceiling` | `10` | non-generated lines at/under which a runtime PR is `tiny` (single judge, functional skipped) |
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

| PR | gate | what runs |
|----|------|-----------|
| 40-line bug fix in `src/` | `small` | single judge + quick functional check (screenshot of the touched surface) |
| 2500-line feature | `normal` | full debate + functional (under the 3000 ceiling) |
| 3500-line feature | `oversized` | blocked: `REQUEST_CHANGES` asking to split — no judges (add `deep-review` to force a full review) |
| 20-line change in `database/migrations/` | `normal` (sensitive) | full debate + functional |
| `staging` → `main` release | `promotion` | single-judge `light`, no functional |
| docs-only PR | `nonruntime` | judges run, no functional |
| small but tricky PR you want fully reviewed | add `deep-review` | full debate + functional |
