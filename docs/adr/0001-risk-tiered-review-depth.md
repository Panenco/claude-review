---
status: superseded
superseded-by: 0003
date: 2026-06-04
---

# 0001 — Risk-tiered review depth

> **SUPERSEDED by [ADR 0003](0003-two-call-review.md) (2026-08-27).** There are
> no depth tiers any more. `scripts/review-plan.sh`, `docs/review-plan.md` and
> the `deep-review` label are deleted; `skills/review-scan.md` reads the diff and
> scales its own depth, and `scripts/guard.sh` decides only whether a model runs
> at all. `gate_deep_label`, `gate_small_ceiling`, `gate_tiny_ceiling` and
> `gate_sensitive_globs` survive as deprecated, ignored workflow inputs. The
> sensitive-path list moved to review-verify, where it gates APPROVE rather than
> forcing a tier. Everything below is kept for the record.

## Context

The review pipeline ran the full treatment on every runtime PR: a dual-judge
debate (Opus + Haiku, with up to two rebuttal rounds) plus a functional
app-test. That depth is right for a substantial or risky change, but most PRs
are small, and a single strong judge is enough for a small, focused diff.
Running the full debate + functional on everything makes routine reviews slow
and costly for no extra signal.

## Decision

Review depth scales with the PR. The deterministic resolver
(`scripts/review-plan.sh`) classifies each PR before any model runs; a runtime
PR takes one of two paths:

- **small** — at or under `GATE_SMALL_CEILING` (default **300**) non-generated
  changed lines, with no sensitive paths → a single-judge `light` pass.
- **full** — over the ceiling, **or** it touches a sensitive path → the
  dual-judge debate.

**Scope note (added when reviews became on demand).** This ADR is now about judge
DEPTH only. Functional testing left the tier: it runs when the `/review` comment
asks for it, at any tier. The cost argument below still holds for the judges; the
infrastructure the tiers used to ration is now rationed by the command.

Two overrides:

- A **`deep-review`** label forces `full` on a PR that would otherwise be
  downgraded (promotion / oversized / small). It mirrors the existing
  `skip-review` label; if both are present, `skip-review` wins.
- **Sensitive paths** (`GATE_SENSITIVE_GLOBS`) force `full` regardless of size —
  `auth.*` files and `oauth` / `authentication` / `authorization` / `security` /
  `payments` / `migrations` directories by default.

### Why 300

300 non-generated lines sits at the shoulder of the real PR-size distribution
(most PRs are well under it) and below the common 400-line-per-PR guideline, so
the debate is reserved for the larger and over-limit PRs, not routine changes.

### Why a bare `auth/` directory is NOT sensitive by default

It is tempting to treat any `auth/` directory as sensitive. But many frontends
use `views/auth/` (or `pages/auth/`) as the *signed-in route group* — the entire
authenticated area of the app lives under it. Flagging that would force almost
every frontend PR into a full review, defeating the purpose. The default
therefore matches auth *files* (`auth.*`) and unambiguous full-word directories;
a repo whose `auth/` holds real auth logic opts it back in via
`GATE_SENSITIVE_GLOBS`.

## Considered options

- **Keep the full debate on every PR.** Simplest, but leaves routine reviews
  slow and costly — the problem being solved.
- **Single judge on every PR.** Fastest, but drops the second perspective and
  rebuttal on the large/sensitive changes where they matter most.
- **Risk-tiered (chosen).** Single judge for small/safe PRs, full debate for
  substantial or sensitive ones — fast where it's safe, deep where it counts.
- **Auto-escalate** a single-judge pass to the full debate on a blocking
  finding. Deferred — it adds two-phase orchestration; revisit only if real
  misses appear. The `deep-review` label covers the manual case.

## Consequences

- Most PRs get a faster, cheaper single-judge review.
- A small change to genuinely risky code (auth logic, payments, migrations,
  security) still gets the full debate via the sensitive-path rule.
- The classification is a pure, no-LLM function of the diff + branch + labels —
  deterministic and unit-tested (`tests/review_plan_test.sh`).
- It is *structural*, not *semantic*: it cannot tell that a 40-line change is
  unusually risky unless its path says so. `deep-review` is the manual override.
- Realized in two steps: the resolver classification, then the orchestrator
  honoring `light` with a single judge.
