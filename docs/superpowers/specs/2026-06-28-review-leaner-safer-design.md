# Review pipeline v3: leaner where safe, no unsupervised churn, fewer false blocks

Date: 2026-06-28
Status: proposed (awaiting review)

## Context

v3 has run hundreds of reviews on qiv + seaters (@v3). Log + output analysis surfaced
that (a) developers largely **auto-fix bot comments via Claude without reading them**, so
inline findings are effectively *executed unsupervised*; (b) trivial PRs (docs-only,
≤10-line fixes) and trivial round-2 re-pushes pay full-review / functional cost they don't
need; (c) a recent change (`b96fcd3`) promoted minor `design`/`consistency` findings to
inline, where they get auto-applied as out-of-scope refactors (verified harm: seaters#992,
qiv#624 — a minor finding drove a 5-file refactor that was reverted 8h later).

**Hard constraints (governing):**
- This is a **generic, multi-stack reviewer** (16 repos, varied languages). No
  framework/domain-specific logic (no tenant/auth/ORM specifics).
- **No added complexity / shrink surface.** Extend existing mechanisms; add no new subsystems.
- **No model demotions, no max-turns cuts.** Cheaper tiers reuse the existing `light`
  single-judge path; recall on sensitive paths is untouched. Recall stays the north star.
- Ships as **one cohesive change** (not phased). Consumer-facing changes get parallel
  updates in `prompts/setup-review.md` + `README.md`.

## Changes

Three engine files + tests + consumer docs. No new scripts, no new mechanisms.

### 1. `scripts/review-plan.sh` — two new deterministic classifications

- **`tiny` gate (new).** New env `GATE_TINY_CEILING` (default `10`). After the `small`
  check is reworked: a runtime PR with `ng_lines ≤ GATE_TINY_CEILING`, non-sensitive,
  non-generated source → `emit "light" "false" "tiny" …`. Single judge, **functional OFF**
  (skips dev-env + Playwright setup and the functional run). Sensitive paths and
  `deep-review` still force `full` + functional, so a tiny auth/migration change is never
  downgraded. `small` (≤300) keeps functional ON as today.
- **`nonruntime` → `light` (docs/tests/locks only; CI stays `full`).** Change the
  all-non-runtime branch from `full` to `light` (functional already off) — but **only when no
  `.github/` file is in the diff.** A CI/workflow change is a supply-chain surface and keeps
  the dual-judge `full` review. So: all-non-runtime AND no `.github/` touch → `light`;
  all-non-runtime WITH a `.github/` touch → `full` (unchanged).
- **Model tier for the new light gates (quality-first, not a demotion).** In the
  orchestrator's `light` judge-model selection (review-orchestrator.md ~line 116), map
  `tiny` to `MODEL_HIGH` (Opus) — same tier as `small`, since it's runtime code, just
  smaller; only the *functional run* is dropped. Map `nonruntime` (docs/tests/CI) to
  `MODEL_STANDARD`. This keeps tiny runtime fixes at full single-judge quality.
- Bias note in the header stays: ambiguous = runtime = full. Only confident, clearly-trivial
  shapes downgrade.

### 2. `skills/review-orchestrator.md` — emit discipline + round-2 delta gating

- **Inline-eligibility (line ~210, the `b96fcd3` narrowing).** Minor findings go inline
  only when their `type` is correctness (`bug` / `wrong-impl` / functional-failure types).
  `design` / `consistency` / `missing-abstraction` minors → **body advisory list only**.
  `note` + anchorless rules unchanged. Critical/major inline requirement (line 211) unchanged.
- **Model tier for the new light gates (line ~116).** Add `tiny` to the `MODEL_HIGH` branch
  alongside `small` (Opus single judge — runtime code, not a demotion); `nonruntime` falls to
  `MODEL_STANDARD`. Only the functional *run* is dropped for `tiny`.
- **No unearned "verified" (resolve_threads / bot_replies wording, lines ~241/243).** A
  resolution/reply may cite the fixing sha + what changed, but must **not** assert runtime
  verification ("Functionally verified", "confirmed working") unless
  `functional_validation.overall ∈ {PASS, WARN}` this round.
- **Round-2 empty-delta = whole-run skip, NO post.** When `ROUND ≥ 2` and the since-last
  effective delta is empty / merge-from-base only, the run skips like the bot-actor gate:
  green check + `::notice::`, **no review posted**. The prior review stays the live verdict
  (GitHub-as-state). Posting a "no change" note here would itself add a review object every
  merge-from-main push — the churn we're removing — so it must NOT post. This is handled at
  the plan/workflow layer (item 3), not as an orchestrator note.

### 3. Round-2 delta classification (the round-2 speed win — at the PLAN level)

Today the plan step classifies the **whole PR** every round, so a docs-only re-push still
pays full+functional. Fix at the correct layer, reusing the classifier and the existing
runtime-evidence **inheritance** path (so no false "no runtime evidence" block):

- Workflow (`.github/workflows/pr-review.yml`): when `PRIOR_HEAD_SHA` is set, compute the
  since-last delta file list (`git diff PRIOR_HEAD..HEAD --numstat`) and feed it as
  `GATE_FILES_TSV` to `review-plan.sh` instead of the whole-PR list. A trivial delta then
  lands on `tiny` / `nonruntime` automatically.
- **Empty delta:** `review-plan.sh` currently falls through to `full` when `GATE_FILES_TSV`
  is empty (the `total_files==0` path). Add an explicit guard: empty delta → emit a
  `nochange` skip, and gate the orchestrate + post-review steps on it so the run ends with a
  `::notice::` and **no posted review** (whole-run elimination — the sanctioned cost lever).
- **Validation gate (do this before trusting the non-empty trivial case):** read
  `skills/review-context-builder.md` to confirm a `run_functional=false` round-2 delta with a
  prior `Strategy: skip` + prior `PASS/WARN` inherits smoke evidence via
  `review-orchestrator.md:175`. If the inheritance doesn't cover this case, extend that
  clause. If inconclusive, ship only the empty-delta skip this round.

### 4. `skills/review-judge.md` — fewer false/no-op findings, one suppression-discipline fix

- **No-op suppression (strengthen self-check rule 7).** If you cannot name a concrete code
  change as the fix, it is not a finding → `uncertain_observations`. (Catches the
  seaters#982 "Expected: no change required" inline that line 81's rules let through.)
- **Resolve the duplication threshold contradiction (lines 51 vs 55).** A 2-site duplication
  with **no concrete consequence** is `note` (→ body, non-blocking via line 210), reserving
  `minor`+ for systemic (≥3 sites) or consequential duplication. No new threshold; removes an
  existing internal inconsistency.
- **Sibling-pattern clause in the false-positive self-check.** Add: if the changed code
  follows the same pattern as its siblings/peers in the same unit, that pattern alone is not
  a `bug`/`major` — it's the local convention (fixes the seaters#991 false blockers).
- **Suppression-discipline for other-bot security findings (cross-check, lines 144-152).** A
  HIGH/CRITICAL `security` finding from another bot may only be Refuted/Skipped with positive
  evidence **from HEAD** that it is wrong — never via "pre-existing convention / deferred to
  X". Mirrors the critical/major DROP floor at line 139. Fixes the verified qiv#599/#601 harm
  (bot dropped aikido tenant-isolation findings).

### 5. Tests — `tests/review_plan_test.sh`

Add cases: ≤10-line runtime → `light`/`tiny`/functional-off; 11–300-line runtime → `small`
/functional-on (unchanged); ≤10-line **sensitive** → `full`/functional-on (floor holds);
all-docs → `light`/`nonruntime`/functional-off; `deep-review` label still overrides `tiny`.

### 6. Consumer docs (parity)

`prompts/setup-review.md` + `README.md`: document the `tiny` tier, `GATE_TINY_CEILING`,
docs→single-judge, and the round-2 delta classification, so consumers understand why a small
PR/re-push gets a lighter pass and how to force full (`deep-review` label).

## Explicitly out of scope (deliberate)

- **Model-alias pin fix** (judges silently running on aliases). Correctness-critical but
  needs empirical confirmation of what `claude-code-action@v1.0.146` accepts; pinning the
  wrong token risks the silent demotion we're avoiding. Separate, verified change.
- **Auth-finding *origination* (the cross-file caller-graph).** The judge can't grep for
  callers (`review-judge.md:18-20`: Read/Write only), so *raising* an auth finding the diff
  doesn't show genuinely needs a context-builder caller-graph = the complexity vetoed this
  turn. This change fixes only the *suppression* half (item 4, bullet 4 — stop dropping other
  bots' security findings). Origination stays a known, deferred gap.
- **Identifier severity floor — dropped.** Contradicts `review-judge.md:81` ("identifier
  accuracy is `note`, never blocking") and addressed one marginal case. Not worth the conflict.

## Risk / self-review

- Downgrades are **confidence-gated and reuse the existing `light` tier** — no new model or
  turn behavior; sensitive paths and `deep-review` are untouched (recall protected). `tiny`
  runtime fixes keep the Opus single judge; only the *functional run* is skipped.
- The runtime-evidence gate already exempts `run_functional=false` (functional_warranted is
  false), so `tiny`/`nonruntime` PRs are not false-blocked for "no runtime evidence".
- Relocating design minors to the body doesn't fully stop a "pipe the whole review" auto-fix;
  paired with the duplication→`note` reframe (fewer such findings exist at all), which is the
  real lever.
- **Round-2 delta classification is the one item with an integration risk** — the
  runtime-evidence inheritance path (review-orchestrator.md:175) must cover the round-2
  `run_functional=false` case or it could false-block a clean re-push. Validate against the
  context-builder first; otherwise ship only the empty-delta short-circuit.
- `tiny` could under-review a small-but-critical change. Mitigated by the sensitive-path
  floor and that a single Opus judge still statically reviews the code.
- Overlap to retire: this narrows `b96fcd3`'s inline-promotion rather than layering on top
  (per "reworks reduce surface area").
