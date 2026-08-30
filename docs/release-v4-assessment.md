# Release assessment: `main` vs `v3`

Date: 2026-08-30 · `v3` = `889f23c` (2026-08-29) · `main` = `07b7dec` · 27 commits, 38 files, +7410 / −335

---

## 0. First: the framing is wrong

**`v3` is not "before the rework".** The seven-call → two-call rework shipped *before* the v3 tag. At `889f23c` the repo already contains:

| Artefact | Present at `v3`? |
|---|---|
| `docs/adr/0004-two-call-review.md` | yes |
| `scripts/guard.sh` | yes |
| `skills/review-scan.md`, `skills/review-verify.md` | yes |

Verify: `git cat-file -e v3:docs/adr/0004-two-call-review.md && git show v3:.github/workflows/pr-review.yml`.

So the decision is **not** old architecture vs new. It is `v3` vs **27 commits of fixes and features on the same architecture**. `v3` and `v3.7.3` point at the same commit.

---

## 1. What actually changed

| Theme | PRs | What a consumer gets |
|---|---|---|
| **`post-review.sh` correctness** | #131–#135 | Five adversarial audits, **29 defects**. Classes: code damage (a `**check**` carrying a ```suggestion``` fence over a multi-line range deletes code on Apply), lost reviews (byte budget cut positionally and ate `### Also flagged` / `### What a human should review` first — the sections that exist *because* those items had no other surface), silent drops (unterminated fence ate the rest of the body; one U+00A0 or U+200E "blank" line truncated the body to the title), double-printed findings with contradictory severities, a dismissal that ran before the POST and left the PR unblocked on a 422. Assertions for this file: **259 → 729**. |
| **Screenshots** | #123, #124, #137 | Captures now reach the PR on a *passing* functional run (previously they died in the artifact — the run where evidence matters most). Captions are labels, not truncated walls. `review-verify` can now see them, behind a PNG validator. |
| **Checks redesigned twice** | #125, #140 | #125: block-anchored, bulleted. #140: re-conceived — a check is **orientation** ("what is this block for, which spec criterion does it deliver"), not an interrogation handing work back to the reviewer. `why_unresolved` deleted. **APPROVE rebuilt**: zero findings + argued case + no sensitive paths + `review_effort ≤ 3`; zero notes is now a reason to approve. |
| **Depth scaling** | #136 | Review depth scales with non-generated diff size instead of three flat constants. A 20-line typo fix and a 2500-line refactor no longer get the same budget. |
| **Native second opinion restored** | #138, #139, ADR 0005 | `/review native` is back, SHA-pinned via a vendored local-path marketplace (`anthropics/claude-plugins-public` @ `ed404106`, sparse, `persist-credentials: false`). Fails soft. **Included in `/review all`.** |
| **Repo rules** | #130 | `.claude/rules/` is actually read now. Plus a `comment_noise` class (it previously filed under `prose` and was dead on arrival). |
| **Performance** | #141, #143, #144 | A ~600s dead wait removed (49–53% of wall clock on two measured runs). Turn 1 made kill-proof. Orchestrator moved off Opus onto `model_orchestrator` (Sonnet) — 7–19% of spend was pure plumbing. Skills trimmed 1.2%. |
| **Measurement** | #142, #145 | `run-breakdown.sh` (per-stage cost/wall clock for one run), `probe-score.sh` (score against a labelled PR corpus). Neither changes review behaviour. |

---

## 2. Risk — the honest case for not shipping

### What is verified live vs only unit-tested

| Change | Live evidence |
|---|---|
| Screenshot captions | `seaters#2134` |
| Check anchoring (#126, #128) | `seaters#2134`; #128 also a replayed real payload |
| Partial functional run (#127) | live qiv + seaters runs |
| Native pass artifact (#139) | `/review all` probe on `seaters#2141` |
| Wall-clock fix (#141, #143) | qiv runs `33298278779`, `33305382018`; seaters `33301435436` |
| Check-authority bar (#129, #130) | 945 human review comments across six products (corpus, not a run) |
| **Depth scaling (#136)** | **none — 15 guard unit assertions only** |
| **Screenshots into review-verify (#137)** | **none stated** |
| **#140 check redesign end-to-end** | **none — measured against repo history, not run** |
| **The 5 rounds of `post-review.sh` fixes as a whole** | **none — unit tests only** |

The probe corpus (`probe-score.sh`) is the tool that would close this. **It has never been run**: only the placeholder `tests/fixtures/probe-corpus.example.json` is committed, and #145 prices a 39-entry sweep at **$78–234 and 7–13h** without performing it.

### The standing risk on `post-review.sh`

Five audit rounds. **Every round started from a green suite**, and most of each round's defects were regressions introduced by the previous round's own fixes. For this file specifically, "tests pass" is weak evidence. Assume a round six exists.

Counterweight, and it is real: those 29 defects are **live in `v3` today**. Consumers are currently exposed to a reviewer that can delete their code via a suggestion fence and silently drop a critical finding. Staying on `v3` is not the safe option it looks like.

### Blast radius

Consumers pin `panenco/claude-review/.github/workflows/pr-review.yml@v3` — a **moving tag**, with `secrets: inherit`, by explicit design (README, `bugbot.md`). Retagging `v3` pushes all 27 commits to every consumer on their next PR push, **instantly, with no opt-in and no staged rollout**. The escape hatch exists (`@v3.7.3` is immutable at the same commit) but requires every consumer to edit their caller workflow under pressure.

---

## 3. `v3` or `v4`? The versioning call

### Caller-contract check — `workflow_call`

| | `v3` | `main` |
|---|---|---|
| Inputs | 27 | 28 |
| Removed | — | **none** |
| Newly required | — | **none** (all optional with defaults) |
| Added | — | `model_orchestrator` (default `claude-sonnet-5`) — additive, safe |
| Secrets | 7 | 7, **identical** |
| `permissions:` | — | **unchanged** |

**Strictly by the input contract, this is not breaking.** Semver says `v3.8.0`.

### But the observable behaviour changes

| Change | Consumer-visible effect |
|---|---|
| `model_standard`, `native_review_scope` deprecated no-ops → **live** | Not breaking, but surprising. |
| `/review all` now includes the native pass | **Costs money they did not previously spend.** At `v3`, `all` = code + functional. On `main`, `all` = code + functional + native, and that plugin fans out to ~10 short-lived subagents on Sonnet. Auto reviews on push are unaffected (`run_native` defaults false). |
| APPROVE rebuilt (#140) | A PR that got COMMENT at `v3` can now get **APPROVE**. Verdict distribution moves. |
| Checks are orientation notes, not questions | Comment content and tone change materially. |
| Depth scales with diff size | Small PRs get fewer comments, large PRs get more. |

### Recommendation: **cut `v4.0.0`, leave `v3` frozen at `889f23c`**

Not because the input contract broke — it did not — but because `@v3` is a moving tag with no staged rollout, and the *output* changes (verdict distribution, comment shape, a new billable pass on `/review all`) are exactly the kind a consumer should opt into. `v4` is the only mechanism available to give them that choice.

| Option | Cost |
|---|---|
| **Retag `v3` (`v3.8.0`)** | Zero consumer effort, fixes reach everyone immediately. But every consumer gets a changed verdict distribution and a new billable pass with no warning, off unit-test evidence for the file with the worst defect history. |
| **Cut `v4`, freeze `v3`** ← recommended | One-line edit per consumer, opt-in, `v3` is a real escape hatch. Cost: consumers stay on the 29-defect `post-review.sh` until they move — so **migrate promptly, do not treat `v3` as a comfortable long-term home**. |
| Cut `v4`, do not migrate anyone | Worst of both. `v3` rots with known code-damaging bugs. |

---

## 4. Release checklist

`scripts/release.sh vX.Y.Z` is the whole ship step. It: fetches `--tags --force`, resolves `origin/main`'s tip, refuses if `vX.Y.Z` is already published at a *different* commit, then `git tag -f vX.Y.Z && git tag -f vX && git push origin vX.Y.Z && git push origin vX --force`. **`MAJOR` is derived from the version string** — so `release.sh v4.0.0` tags `v4` and leaves `v3` untouched. It is idempotent and has `--dry-run`. There is **no release automation**; merging to `main` publishes nothing.

Before running it:

| # | Item | Status |
|---|---|---|
| 1 | **`pipeline_ref` default is still `"v3"`** (`pr-review.yml:44`). The install step checks out the pipeline at this ref. Cutting `v4` without bumping it means a `@v4` caller runs **v4 orchestration on v3 skills/scripts** — the documented max-turns failure. | **BLOCKER for the v4 path** |
| 2 | `warm-cache.yml@v3` referenced in `README.md:175` and `prompts/setup-review.md:122` — needs the same bump. | open |
| 3 | `@v3` hardcoded in ~15 places: `README.md` (Quick Start L56, L129, tag table L742–745), `prompts/setup-review.md` (L12, L69, L249, L252, L552, L555), `bugbot.md` (L20, L23, L35, L36). | open |
| 4 | **No CHANGELOG exists.** README's "Migration" sections are the de-facto release notes; they need a v3→v4 entry covering the APPROVE bar, the check shape, and `/review all` cost. | open |
| 5 | **Stray file: `pr-324-review.md` at repo root** — a 46-line dump of a review of `Panenco/qiv#324`, committed in `4df874b`. It is not pipeline code and should not ship in a tag. | **delete before tagging** |
| 6 | Consumers need a migration note: "`/review all` now bills a third pass; use `/review code functional` for the old behaviour." | open |
| 7 | Optional but high value: run one `probe-score.sh` sweep (or a handful of entries) against real merged PRs before tagging — it is the only evidence that would cover the `post-review.sh` and #140 gaps. | open |

Suggested order: (5) → (1) → (2)(3)(4)(6) in one PR → merge → `scripts/release.sh v4.0.0 --dry-run` → `scripts/release.sh v4.0.0`.
