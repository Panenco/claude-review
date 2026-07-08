# Review-Quality Forcing Functions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make claude-review (v3, branch `feat/review-v3`) stop shipping low-confidence reviews on the highest-risk PRs by turning two silent gaps into hard blocks and de-demoting the lone small-PR judge.

**Architecture:** Three behavioural changes, shipped as **one cohesive PR** (no phased rollout):
1. **Oversized PRs** (>2500 non-generated lines or >60 files) stop getting a degraded single-judge pass — they get a blocking `REQUEST_CHANGES` that tells the author to split the PR. A new `review_level=reject-oversized` short-circuits the orchestrator (no judges run → whole-run cost saving). The `deep-review` label still forces a full review (escape hatch).
2. **Runtime-evidence gate (unified):** when the planner judged a PR has runtime behaviour to exercise (`## Strategy` ∈ {quick, functional}) but no smoke evidence was produced (`smoke_ok=false` — no `dev-start.sh`, failed/timed-out bring-up, or tester crash), the verdict becomes `REQUEST_CHANGES`. This **replaces** the existing `technical_change && !smoke_ok → COMMENT` gate (one mechanism, not two) and makes the functional skip honest (`overall: "SKIP_NO_DEVENV"`, not the old lie `"PASS"`). Docs-only / non-runtime PRs (`## Strategy: skip`) are exempt — "allowed to skip if there is nothing to test."
3. **P4 de-demotion:** the lone `light` judge runs on `${MODEL_HIGH}` (Opus) for `small` PRs (it is the *only* bug-finder on novel code). `promotion` PRs stay on `${MODEL_STANDARD}` (already-reviewed work — "trust steady state").

**Tech Stack:** Bash (`scripts/review-plan.sh`, `scripts/post-review.sh`), Claude Code agent skills in Markdown (`skills/review-orchestrator.md`), plain-bash test harness with a `gh` PATH-shim (`tests/*.sh`), consumer docs (`prompts/setup-review.md`, `README.md`, `docs/review-plan.md`).

**Owner constraints honoured:** recall > cost; no model demotions on quality roles (this *upgrades* one); cost cut only via whole-run savings (oversized short-circuit eliminates a run); no turn-limit trimming; reworks reduce surface (the runtime-evidence gate replaces the technical-change gate; the oversized branch is swapped, not added-beside); single cohesive rollout; AI/prompt edits preferred over new scripts; consumer-facing changes updated in `setup-review.md` + `README.md`.

---

## Decisions locked (from the requester)

- **Block everything** — no library/no-app opt-out. A repo with runtime PRs but no `dev-start.sh` gets blocked. (The review engine's *own* repo is unaffected because it uses `## Strategy: pipeline-self-test`, which runs `tests/*.sh` regardless and produces a real PASS/FAIL — see Task 2 note.)
- **Block on any skip when there is runtime to test**, including a `dev-start.sh` that exists but crashed/timed out. The discriminator is *"did the planner want to exercise runtime behaviour?"* (`## Strategy` ∈ {quick, functional}), **not** "is `dev-start.sh` present."
- **Allow skip only when there is nothing to test** — docs-only / non-runtime PRs (`## Strategy: skip`, `gate=nonruntime`, `promotion`, `label`). These never trip the gate.
- **Bots are NOT waived** for the runtime-evidence gate (the fix is repo-level: wire `dev-start.sh` once). The existing no-spec `spec_gate_waived` for bots is left untouched.

---

## File structure (what each change touches)

| File | Responsibility | Change |
|---|---|---|
| `scripts/review-plan.sh` | Deterministic PR-shape classifier (pre-LLM) | Oversized branch emits `reject-oversized`/`false`; header comment updated |
| `skills/review-orchestrator.md` | Top-level agent: dispatch, verdict ladder, gates, banners | New `reject-oversized` branch; split functional-skip writer; unified runtime-evidence gate replaces technical-change gate; round-2 non-pin rule; `small`→Opus judge |
| `scripts/post-review.sh` | Posts the verdict as a GitHub review; step summary | Step-summary banner generalised from technical-change to runtime-evidence (cosmetic) |
| `tests/review_plan_test.sh` | Unit tests for the classifier | Update oversized expectations; deep-review override stays green |
| `tests/post_review_test.sh` | Unit tests for posting | Add a `reject-oversized` fixture asserting a body-only `REQUEST_CHANGES` is posted |
| `prompts/setup-review.md` | Consumer setup guide (separate surface) | dev-start contract + depth/verdict semantics now blocking |
| `README.md` | Consumer reference | Degradation matrix + smoke-gate + review-depth wording |
| `docs/review-plan.md` | Canonical tier table | Oversized row + verdict semantics |

All line numbers below are against `feat/review-v3` @ `92496b2`. Re-`grep` before editing — line numbers drift as earlier tasks land.

---

## Task 1: Oversized PR → `reject-oversized` structural block

**Files:**
- Modify: `scripts/review-plan.sh` (oversized branch ~166-171; header comment ~8-31)
- Modify: `skills/review-orchestrator.md` (Review plan section ~50-54)
- Test: `tests/review_plan_test.sh` (oversized cases ~59-66)

- [ ] **Step 1: Update the failing test first**

In `tests/review_plan_test.sh`, the two oversized assertions currently expect `light true oversized`. Change them to expect the new emit. Find the block (the harness helper `summary_of` prints `<review_level> <run_functional> <gate>`):

```bash
# oversized by file count
assert_eq "oversized (65 files) → reject" "reject-oversized false oversized" \
  "$(summary_of "$(run_plan_files_65)")"
# oversized by line count
assert_eq "oversized (2600 lines) → reject" "reject-oversized false oversized" \
  "$(summary_of "$(run_plan_lines_2600)")"
```

Leave the existing "deep-review on an oversized PR → full true normal" and "huge lockfile ALONE → not oversized" assertions unchanged — they must still pass (escape hatch + generated-file exclusion are untouched).

- [ ] **Step 2: Run the test, verify it fails**

Run: `bash tests/review_plan_test.sh`
Expected: FAIL on the two oversized assertions (`got "light true oversized"`).

- [ ] **Step 3: Change the oversized emit in `review-plan.sh`**

Replace the oversized branch (currently lines ~166-171):

```bash
# ── 3) Oversized (non-promotion)? Blocking "split this PR". No judges run —
#       reviewing a huge diff with a single judge is low-confidence and wasteful.
#       deep-review (FORCE_FULL) suppresses this and forces a full review. ──
if [ "$FORCE_FULL" = false ] && [ "$oversized" = true ]; then
  emit "reject-oversized" "false" "oversized" "PR too large to review well (${ng_files} files, ${ng_lines} non-generated lines; ceiling ${FILE_CEILING} files / ${SIZE_CEILING} lines). Split it into smaller, self-contained PRs (team limit: 400 lines). If it genuinely must ship as one unit (e.g. a generated migration or vendored bump), add the '$DEEP_LABEL' label to force a full review; add '$SKIP_LABEL' only if this bundles already-reviewed work."
  exit 0
fi
```

- [ ] **Step 4: Update the header comment block in `review-plan.sh`**

In the top comment (lines ~8-31), add `reject-oversized` to the `review_level` enum line and the description list, and fix the oversized mapping row:

```bash
#   review_level=full|light|skip|reject-oversized
...
#   review_level (consumed by review-orchestrator.md):
#     full            — dual-judge debate (+ rebuttal); functional per run_functional
#     light           — single judge, no rebuttal; functional per run_functional
#     skip            — early-return: no judges; post the reason as a COMMENT note
#     reject-oversized — early-return: no judges; post a blocking REQUEST_CHANGES asking to split
...
#   oversized   → reject-oversized / functional off  (too big to review well — block & ask to split;
#                                                      deep-review overrides to a full review)
```

- [ ] **Step 5: Add the `reject-oversized` branch to the orchestrator**

In `skills/review-orchestrator.md`, the "Review plan" section (~50-54) lists `REVIEW_LEVEL=skip|light|full`. Add a bullet directly after the `skip` bullet:

```markdown
- `REVIEW_LEVEL=reject-oversized` → dispatch nothing (no context build, no judges, no functional). Write `/tmp/review.json` with `verdict: "REQUEST_CHANGES"`, `body` = `## Claude PR Review — REQUEST_CHANGES` + the `GATE_REASON` paragraph (the split-PR message), empty `comments`/`resolve_threads`/`bot_replies`, and `meta: { "findings": [], "round": ${ROUND}, "prior_verdict": ${PRIOR_VERDICT}, "ladder_rule_applied": "reject-oversized", "judge_health": {"gate_oversized": true, "agreed_at": "rejected-oversized"} }`. Exit. The block is re-derived fresh from PR size every round (the resolver re-runs on the whole-PR shape), so a later push that shrinks the PR below the ceiling gets a real review; do NOT run the round-2 findings ladder here.
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `bash tests/review_plan_test.sh`
Expected: PASS (all assertions, including the unchanged deep-review + lockfile cases).

- [ ] **Step 7: Commit**

```bash
git add scripts/review-plan.sh skills/review-orchestrator.md tests/review_plan_test.sh
git commit -m "feat(review): oversized PRs request a split instead of a weak single-judge pass"
```

---

## Task 2: Honest functional sentinel + unified runtime-evidence escalation gate

This is the core change. It (a) makes a skipped-but-wanted functional run write an honest non-PASS sentinel, and (b) replaces the `technical_change && !smoke_ok → COMMENT` gate with one `runtime-evidence` gate that escalates to `REQUEST_CHANGES`.

**Files:**
- Modify: `skills/review-orchestrator.md` (functional dispatch decision ~84-88; Gates section ~165-167; banners ~218)
- Modify: `scripts/post-review.sh` (step-summary banner ~302-304 — cosmetic)

- [ ] **Step 1: Split the functional-skip writer (the synthetic `{skip, PASS}` line)**

In `skills/review-orchestrator.md`, the "Functional dispatch decision" (~84-88) ends with case 3 `Anything else → ... {"strategy": "skip", "overall": "PASS", ...}`. Replace case 3 with two cases:

```markdown
3. `RUN_FUNCTIONAL=true` AND strategy ∈ {`quick`, `functional`} BUT `WEB_READY` ≠ `true` (no dev-env, or bring-up failed/timed out) → functional was WARRANTED but could not run. Write `/tmp/functional-meta.json` `{"strategy": "skip", "overall": "SKIP_NO_DEVENV", "summary": "Functional testing was required but no dev environment was available (no .github/claude-review/dev-start.sh, or the bring-up failed/timed out)."}` and `/tmp/functional-findings.json = []`. This yields `smoke_ok=false` → the runtime-evidence gate blocks (see Gates).
4. Anything else — `RUN_FUNCTIONAL` ≠ `true`, or the planner chose `## Strategy: skip` (no runtime surface to exercise) → write `/tmp/functional-meta.json` `{"strategy": "skip", "overall": "N/A", "summary": "Functional testing not applicable — no runtime surface to exercise."}` and `/tmp/functional-findings.json = []`.
```

> Note: `## Strategy: pipeline-self-test` is case 1 (unchanged) and runs `tests/*.sh` regardless of `RUN_FUNCTIONAL`, producing a real `PASS|FAIL|WARN`. That is why the review engine's own repo (which has no app) is never blocked by this gate — its functional "runs" via the self-test path.

- [ ] **Step 2: Replace the technical-change gate with the unified runtime-evidence gate**

In the "Gates (downgrades only, applied after the ladder)" section (~162-167), **delete** the `**Technical-change smoke:**` bullet entirely and **insert** this in its place. Also rename the section header to `### Gates (applied after the ladder)` since one gate now escalates:

```markdown
- **Runtime-evidence gate (ESCALATION — the only gate that can raise the verdict):** functional was *warranted* this round when `## Strategy` ∈ {`quick`, `functional`} (the planner judged there is runtime behaviour to exercise). `smoke_ok = true` when functional `overall` ∈ {PASS, WARN}; OR inherited — `ROUND ≥ 2` AND the planner deliberately chose `## Strategy: skip` AND context.md's `Prior functional result:` is PASS/WARN; OR waived — functional was not warranted (`## Strategy: skip` / `RUN_FUNCTIONAL` ≠ `true` — nothing to test). When functional was warranted AND `!smoke_ok` (no dev-env, bring-up failed/timed out, or tester `overall=CRASH`) → verdict = **REQUEST_CHANGES**; set `meta.ladder_rule_applied: "runtime-evidence"`. Bots are NOT waived — the fix (wiring `dev-start.sh`) is repo-level. This gate is recomputed from live signals every round and carries no finding, so it never pins the round-2 findings ladder: once a real smoke runs and passes, it stops firing and the prior block is dismissed. Render the banner below. (Refactor/"no behaviour change" PRs are a subset — the planner gives them `## Strategy: functional`, so this gate subsumes the old technical-change-smoke downgrade; `## Technical change: true` remains a context.md signal but no longer needs its own gate.)
```

- [ ] **Step 3: Fold the MCP-crash case into the gate, keep human-review flag**

In the same section, change the `**Functional crash:**` bullet so a crash routes through the new gate but still flags engine-side causes:

```markdown
- **Functional crash → human review:** functional `overall` = CRASH makes `smoke_ok=false`, so the runtime-evidence gate already sets `REQUEST_CHANGES`. Additionally set `requires_human_review: true` with the crash reason when the cause is MCP unavailability (engine-side, not the author's fault — a human should sanity-check before the author chases a false block).
```

- [ ] **Step 4: Update the body banner**

In the "Banners" list (~218), replace the `**APPROVE withheld — smoke test did not pass**` banner with a blocking one:

```markdown
   - `> :no_entry: **REQUEST_CHANGES — runtime behaviour was not verified** (functional overall=\`<X>\`). This PR changes runtime code but no smoke test ran. Wire up \`.github/claude-review/dev-start.sh\` (see README → 'dev-start.sh contract') or fix the bring-up so the reviewer can exercise the change. Docs-only / non-runtime PRs are exempt.`
```

- [ ] **Step 5: Generalise the post-review step-summary banner (cosmetic)**

In `scripts/post-review.sh` (~302-304), the step-summary banner currently fires on `TECHNICAL_CHANGE && SMOKE_OK==false`. The authoritative verdict is already decided by the orchestrator, so this is only a step-summary note. Change its condition to read the new `meta.ladder_rule_applied` so the summary matches the verdict:

```bash
LADDER_RULE=$(jq -r '.meta.ladder_rule_applied // ""' "$WORK/review.json")
if [ "$LADDER_RULE" = "runtime-evidence" ]; then
  echo "> :no_entry: REQUEST_CHANGES — runtime behaviour not verified (no smoke run). Wire up .github/claude-review/dev-start.sh." >> "$SUMMARY"
fi
```

(If `SMOKE_OK`/`TECHNICAL_CHANGE` variables become unused after this edit, delete them — do not leave dead reads.)

- [ ] **Step 6: Validate (no bash unit test — orchestrator logic is LLM-evaluated)**

The gate logic lives in the agent skill, not a script, so there is no bash unit test for it. Validate by:
1. `grep -n "SKIP_NO_DEVENV\|runtime-evidence\|Technical-change smoke" skills/review-orchestrator.md` — confirm the new strings exist and the old `Technical-change smoke` gate string is gone.
2. A dogfood run (Task 7) on a fixture PR with runtime code and no `dev-start.sh` must produce `REQUEST_CHANGES`; a docs-only PR must produce its normal verdict.

- [ ] **Step 7: Commit**

```bash
git add skills/review-orchestrator.md scripts/post-review.sh
git commit -m "feat(review): block runtime PRs with no smoke evidence (unifies the technical-change gate)"
```

---

## Task 3: Round-2 non-deadlock for structural blocks

A structural block (`reject-oversized` or `runtime-evidence`) carries zero findings. The round-2 `degraded-pin-max` rule fails closed to `REQUEST_CHANGES` when the `### Prior findings` table is missing — which would wrongly pin a PR forever even after it is split / `dev-start.sh` is wired. Close that.

**Files:**
- Modify: `skills/review-orchestrator.md` (round-2 ladder table ~150-158)
- Modify: `skills/review-context-builder.md` (round-2 prior-findings reconstruction — emit the section even when empty)

- [ ] **Step 1: Add a `prior-structural-block` rule above `degraded-pin-max`**

In the round-2 ladder table, insert this row immediately **above** `degraded-pin-max`:

```markdown
| `prior-structural-block` | `PRIOR_VERDICT=REQUEST_CHANGES` AND the prior review recorded **zero** findings (it was a structural block — `reject-oversized` or `runtime-evidence`) | Re-evaluate from this round's live gates only (the block re-fires iff its condition still holds — still oversized, or still no smoke). Never pin: a now-split / now-smoke-tested PR reaches its per-judges verdict. |
```

- [ ] **Step 2: Scope `degraded-pin-max` to findings-bearing priors**

Edit the `degraded-pin-max` row condition so it only fail-closes when the prior RC actually had findings to reconstruct:

```markdown
| `degraded-pin-max` | `## Thread resolution` missing/unusable, OR `### Prior findings` table missing on round ≥2 with `PRIOR_VERDICT=REQUEST_CHANGES` **AND the prior review recorded ≥1 finding** | max(PRIOR_VERDICT, per-PR) on REQUEST_CHANGES > COMMENT > APPROVE; unknown PRIOR_VERDICT → treat as REQUEST_CHANGES (fail closed). A zero-finding prior RC is handled by `prior-structural-block` above. |
```

- [ ] **Step 3: Make the CB always emit the prior-findings section when round ≥ 2**

In `skills/review-context-builder.md`, find the round-2 reconstruction that writes `### Prior findings`. Add an explicit instruction that when the prior review recorded no findings, the CB still emits the section header with a single line `- none (prior verdict was a structural block: <reject-oversized|runtime-evidence|other>)`. This distinguishes "table genuinely missing (reconstruction failed)" from "prior RC legitimately had zero findings," which is exactly what `degraded-pin-max` keys on.

- [ ] **Step 4: Validate**

`grep -n "prior-structural-block\|recorded ≥1 finding\|none (prior verdict was a structural block" skills/review-orchestrator.md skills/review-context-builder.md` — confirm all three strings exist. Confirm with the Task 7 dogfood: a re-run after splitting an oversized PR (or after wiring dev-start) clears the block.

- [ ] **Step 5: Commit**

```bash
git add skills/review-orchestrator.md skills/review-context-builder.md
git commit -m "fix(review): structural blocks (oversized/runtime-evidence) re-evaluate fresh each round, never pin"
```

---

## Task 4: P4 — `small` single judge runs on Opus; `promotion` stays standard

After Task 1, the only `light` paths are `small` and `promotion`. The lone judge is the *only* bug-finder, so on novel code (`small`) it must be the strong model. `promotion` is already-reviewed work — keep it cheap.

**Files:**
- Modify: `skills/review-orchestrator.md` (judge dispatch ~109-113; review-plan bullet ~53; degraded-handling ~118-121)

- [ ] **Step 1: Change the light-judge model selection**

In the Phase-B "Task fan" (~113), the light delta currently reads: `At light: replace 1–2 with ONE judge, model: "${MODEL_STANDARD}", OUTPUT_PATH=/tmp/judge-sonnet.json.` Replace with:

```markdown
   At `light`: replace judges 1–2 with ONE judge, `OUTPUT_PATH=/tmp/judge-light.json`, the `[DESIGN]` pass MANDATORY (a lone judge cannot skip it). Model: `"${MODEL_HIGH}"` when `GATE=small` — the single judge is the only bug-finder on novel code, so it gets the strong model — and `"${MODEL_STANDARD}"` when `GATE=promotion` (source already reviewed on its own PRs).
```

- [ ] **Step 2: Update the two `judge-sonnet.json` ripple references**

- In the Review-plan `REVIEW_LEVEL=light` bullet (~53): change `Phase B dispatches ONE judge (\`MODEL_STANDARD\`, output \`/tmp/judge-sonnet.json\`)` → `Phase B dispatches ONE judge (model per GATE — see Phase B; output \`/tmp/judge-light.json\`)`.
- In the per-subagent failure handling (~118-121): change the single-judge degraded record from `{"sonnet": "failed", "single_judge": true}` and the `/tmp/judge-sonnet.json` path → `{"single": "failed", "single_judge": true}` and `/tmp/judge-light.json`.

`grep -n "judge-sonnet" skills/review-orchestrator.md` must return nothing after this step.

- [ ] **Step 3: Validate**

`grep -n "judge-light.json\|GATE=small\|GATE=promotion" skills/review-orchestrator.md` — confirm the model split is present and references are consistent.

- [ ] **Step 4: Commit**

```bash
git add skills/review-orchestrator.md
git commit -m "feat(review): small-PR single judge runs on Opus (promotion stays standard)"
```

---

## Task 5: Consumer-doc parity (separate surface — required)

The behaviour above is consumer-visible. Update the docs so they don't describe the old (now-wrong) behaviour. Quote-and-replace the specific wrong sentences.

**Files:**
- Modify: `prompts/setup-review.md`, `README.md`, `docs/review-plan.md`

- [ ] **Step 1: `prompts/setup-review.md`**

- dev-start contract (~251, ~258): the current "absence → degraded mode (judges only), reviews still pass" framing is now wrong. Replace with: absence (or a failing bring-up) on a **runtime** PR now yields `REQUEST_CHANGES`; only docs-only / non-runtime PRs skip cleanly. Pure-no-app repos either wire a no-op `dev-start.sh` or rely on `## Strategy: pipeline-self-test` if they ship bash tests.
- depth/verdict semantics (~480): "oversized PRs (a quick 1-scenario smoke)" → "oversized PRs are not reviewed — they get `REQUEST_CHANGES` asking for a split (override with the `deep-review` label)."

- [ ] **Step 2: `README.md`**

- Review depth (~143): "small or oversized PRs take a lighter single-judge pass … oversized still gets a smoke run" → "small PRs take a single **Opus** judge; oversized PRs are blocked with a split request (`deep-review` overrides)."
- Degradation matrix (~442, ~449) + smoke-gate (~457-459) + migration note (~536): every "downgraded from APPROVE → COMMENT" / "degraded mode, judges still run, reviews pass" sentence about missing `dev-start.sh` becomes "→ `REQUEST_CHANGES` on runtime PRs (docs-only PRs exempt)."

- [ ] **Step 3: `docs/review-plan.md`**

- Update the tier table: the `oversized` row maps to `reject-oversized` (no judges, `REQUEST_CHANGES`, "split"), and the verdict-semantics note reflects the runtime-evidence gate (block, not downgrade).

- [ ] **Step 4: Commit**

```bash
git add prompts/setup-review.md README.md docs/review-plan.md
git commit -m "docs(review): document oversized-reject + runtime-evidence block + small-PR Opus"
```

---

## Task 6: Posting test for the reject-oversized path

**Files:**
- Test: `tests/post_review_test.sh`

- [ ] **Step 1: Add a reject-oversized fixture test**

Copy the existing REQUEST_CHANGES test pattern (`post_review_test.sh` case (e), ~172-184) which uses the `gh` PATH-shim + capture dir. Add a case feeding a canned `reject-oversized` `review.json` (`verdict: "REQUEST_CHANGES"`, `comments: []`, `meta.ladder_rule_applied: "reject-oversized"`, `meta.findings: []`) and assert:

```bash
# ── (h) reject-oversized → posts body-only REQUEST_CHANGES, exit 0 ──
W=$(mktemp -d)
printf '%s' '{"verdict":"REQUEST_CHANGES","body":"## Claude PR Review — REQUEST_CHANGES\n\nPR too large to review well. Split it.","comments":[],"resolve_threads":[],"bot_replies":[],"meta":{"findings":[],"ladder_rule_applied":"reject-oversized"}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
assert_eq "posts REQUEST_CHANGES event" "REQUEST_CHANGES" "$(cat "$W"/capture/* | jq -r '.event')"
assert_eq "no inline comments" "0" "$(cat "$W"/capture/* | jq -r '.comments | length')"
```

- [ ] **Step 2: Run it, verify it passes against the unchanged poster**

Run: `bash tests/post_review_test.sh`
Expected: PASS — `post-review.sh` already accepts a body-only `REQUEST_CHANGES`; this test pins that contract so a future poster change can't silently break the reject path.

- [ ] **Step 3: Commit**

```bash
git add tests/post_review_test.sh
git commit -m "test(review): pin body-only REQUEST_CHANGES posting for reject-oversized"
```

---

## Task 7: Dogfood validation + self-review

- [ ] **Step 1: Run the whole bash suite**

Run: `for t in tests/*.sh; do echo "== $t"; bash "$t" || echo "FAIL $t"; done`
Expected: all green.

- [ ] **Step 2: Dogfood the orchestrator changes on fixture PRs**

The orchestrator gate logic has no bash unit test, so verify behaviourally (open throwaway PRs against a repo running this branch, or use the pipeline-self-test path):
1. Runtime PR (touches `apps/*` source), repo without `dev-start.sh` → expect `REQUEST_CHANGES` + the runtime-evidence banner.
2. Docs-only PR → expect normal verdict, no block (`## Strategy: skip`, gate `nonruntime`).
3. PR > 2500 non-generated lines → expect `REQUEST_CHANGES` "split this PR", no judges dispatched (check the run has no judge artifacts).
4. Same oversized PR + `deep-review` label → expect a full Opus+Haiku review.
5. Small runtime PR with a working `dev-start.sh` → expect the single judge to be Opus (`/tmp/judge-light.json`, model `claude-opus-4-8`) and a normal verdict.
6. Re-run case 3 after splitting (or case 1 after wiring `dev-start.sh`) → expect the prior block to clear (no deadlock).

- [ ] **Step 3: Self-review against this plan**

- Every "wrong wording" doc sentence from Task 5 actually replaced? `grep -rn "degraded mode" README.md prompts/setup-review.md` and confirm none still imply a passing review on a runtime PR.
- `grep -rn "Technical-change smoke\|judge-sonnet\|overall\": \"PASS\"" skills/` — the deleted gate string, the old judge path, and the skip-as-PASS lie are all gone (except the legitimate `pipeline-self-test` PASS).
- Verdict-ladder internal consistency: the runtime-evidence gate is the only escalating gate; `prior-structural-block` precedes `degraded-pin-max`.

- [ ] **Step 4: Open the PR (single cohesive rollout)**

```bash
git push -u origin <branch>
gh pr create --base feat/review-v3 --title "feat(review): forcing functions for review quality" --body "<summary of the 3 behaviour changes + escape hatches>"
```

---

## Notes / open flags for the reviewer

- **Blast radius is intentional.** On merge to `feat/review-v3`, every consumer on `@v3` immediately starts blocking runtime PRs that have no `dev-start.sh`. That is the requested forcing function. mason is the first target (it currently skips functional on 100% of runs).
- **Bots are blocked too** (not waived). If dependabot/renovate noise becomes a problem, adding `|| PR_AUTHOR_IS_BOT == "true"` to the runtime-evidence waiver is a one-line change — deliberately left out per the "block everything" decision.
- **MCP-crash blocks but flags human review.** If engine-side MCP flakiness produces false blocks in practice, soften the crash case to COMMENT+human-review (one bullet in Task 2 Step 3).
- **Not in scope (deliberately):** the `note`-only → COMMENT behaviour (P6) — v3 already made the judge skill and ladder consistent; the requester did not ask to change it.
