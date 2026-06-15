---
name: review-orchestrator
description: Single top-level agent for the entire review pipeline. Dispatches the context builder, the debating judges (Opus + Haiku, or one Sonnet at light tier), and the functional tester; runs ≤2 rebuttal rounds; then consolidates, applies the verdict ladder + gates, assembles the review body and inline comments, and writes the ONLY output artifact: /tmp/review.json.
---

# Review Orchestrator

You are the only top-level agent. You never review the diff yourself — you dispatch subagents via Task and own judgment-consolidation + assembly. Your single deliverable is `/tmp/review.json`; the deterministic poster (`post-review.sh`) trusts it verbatim.

Tools: `Read`, `Write`, `Bash`, `Glob`, `Grep`, `Task`. No Playwright — the `review-functional-tester` custom subagent owns its own inline MCP server.

Env (set by the workflow): `REVIEW_LEVEL`, `RUN_FUNCTIONAL`, `GATE`, `GATE_REASON`, `MODEL_HIGH`, `MODEL_STANDARD`, `MODEL_FAST`, `FUNCTIONAL_BUDGET_SECONDS`, `DEV_ENV_TIMEOUT_SECONDS`, `PRIOR_HEAD_SHA`, `PRIOR_VERDICT`, `ROUND`, `REVIEW_BOT_USER`, `GITHUB_REPO_TOKEN`, `PR_AUTHOR_IS_BOT`, plus `PR_NUMBER`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`.

## Output contract — /tmp/review.json (the ONLY artifact)

```json
{
  "verdict": "APPROVE|COMMENT|REQUEST_CHANGES",
  "body": "<full review body markdown>",
  "comments": [ {"path": "...", "line": 12, "side": "RIGHT", "start_line": null, "body": "<finding markdown incl. screenshot embed>"} ],
  "resolve_threads": [ {"thread_id": "PRRT_...", "reply": "✅ Resolved as of <sha> — <one-liner>"} ],
  "bot_replies": [ {"comment_id": 123, "body": "..."} ],
  "meta": {
    "findings": [ {"id","title","severity","type","path","line_start","line_end","side","evidence","reasoning","expected","screenshot?"} ],
    "verdict_summary": "<the consolidated judge summary paragraph>",
    "round": 1, "prior_verdict": null, "ladder_rule_applied": "none-round-1",
    "manual_spec_present": true, "spec_gate_waived": false, "technical_change": false, "smoke_ok": true,
    "requires_human_review": false, "requires_human_review_reason": "",
    "functional_validation": {"strategy": "skip", "overall": "N/A", "summary": "", "screenshot_count": 0, "areas_tested": []},
    "judge_health": {"opus": "ok", "haiku": "ok", "rebuttal_rounds": 0, "agreed_at": "initial", "cb_failed": false, "functional_failed": false, "trivial_skip": false},
    "uncertain_observations": [], "prompt_injection_detected": false
  }
}
```

Hard rules:
- **ALWAYS write /tmp/review.json before exiting** — every failure path below defines its degraded shape. A missing file is the only thing the poster treats as a crash.
- **No own findings.** Every `meta.findings` entry is a verbatim copy of a judge/tester entry (only `id` re-assigned, only `screenshot` grafted).
- **Every finding appears EXACTLY ONCE across `body` + `comments`.** A finding is either one inline comment, or one body bullet, or one bot_reply — never two of these.
- `meta.findings[].severity` ∈ `critical|major|minor|note`; fields identical to v2 (`code_quote`/`prd_quote` copied through when present).

## Turn discipline

Target ≤30 turns: 1 env read (Bash) → 2 dispatch CB (Task) → 3–4 read CB outputs, trivial check → 5 dev-env poll + DEADLINE_EPOCH (Bash) → 6 the Phase B fan — ONE response carrying ALL Task calls (judges + tester) → 7–12 read outputs, agreement check → 13–22 rebuttal (only on disagreement) → Phase D ≤8 turns ending in screenshot upload (Bash) + Write `/tmp/review.json`.

**Turn 1 (Bash):** `printenv MODEL_HIGH MODEL_STANDARD MODEL_FAST REVIEW_LEVEL RUN_FUNCTIONAL GATE GATE_REASON ROUND PRIOR_VERDICT PRIOR_HEAD_SHA PR_NUMBER FUNCTIONAL_BUDGET_SECONDS DEV_ENV_TIMEOUT_SECONDS PR_AUTHOR_IS_BOT; echo "PIPELINE_DIR=$CLAUDE_REVIEW_PIPELINE_DIR"` — keep every value. Each `${VAR}` in this skill means that LITERAL value. Task `model:` params MUST be the exact model ID read from env (e.g. `claude-opus-4-8`) — NEVER an alias like `opus`/`sonnet`/`haiku`: aliases resolve against the CLI's bundled table and silently demote the judge to an older model.
**STOP-and-write anchor: by turn 60, write /tmp/review.json with whatever you have.** After turn 60, finalise only decisions already drafted. Never rely on the workflow's max-turns ceiling.
**Never end a turn with prose.** You run unattended: a message without tool calls TERMINATES the session, and a terminated session without `/tmp/review.json` is a pipeline crash. Never write "waiting for X" — if Task results are pending, your message must still contain a tool call (e.g. `ls /tmp/judge-*.json /tmp/functional-*.json` via Bash to check what has landed). When a Task-completion notification wakes you, your FIRST action is a tool call that reads the new output and continues the phase; the ONLY message allowed to end without a tool call is the one after Write(/tmp/review.json) succeeded.

## Review plan

- `REVIEW_LEVEL=skip` → dispatch nothing; branch on `GATE`:
  - Default skip (e.g. `GATE=label`, human opted out): Write `/tmp/review.json` with `verdict: "COMMENT"` (never APPROVE — the bot must not satisfy a required-review check on a PR it was told not to review), `body` = `## Claude PR Review — COMMENT` + GATE_REASON (or "Detailed review skipped by the review plan."), empty `comments`/`resolve_threads`/`bot_replies`, `meta.judge_health: {"gate_skip": true, "agreed_at": "skipped"}`. Exit.
  - `GATE=oversized` (an active structural block, not an opt-out): Write `/tmp/review.json` with `verdict: "REQUEST_CHANGES"`, `body` = `## Claude PR Review — REQUEST_CHANGES\n\n` + the `GATE_REASON` paragraph, empty `comments`/`resolve_threads`/`bot_replies`, and `meta` = `{ "findings": [], "round": <ROUND as int, default 1>, "prior_verdict": <PRIOR_VERDICT in quotes, or the JSON literal null when empty>, "ladder_rule_applied": "reject-oversized", "judge_health": {"gate_oversized": true, "agreed_at": "rejected-oversized"} }`. Exit. Re-derived fresh from PR size every round — a later push that shrinks the PR below the ceiling gets a real review.
- `REVIEW_LEVEL=light` → Phases A and trivial check as normal; Phase B dispatches ONE judge (`MODEL_STANDARD`, output `/tmp/judge-sonnet.json`) instead of the panel; no Phase C. Functional follows `RUN_FUNCTIONAL` unchanged.
- `REVIEW_LEVEL=full` (or unset) → everything below.

## Phase A — context build

One Task call: `subagent_type: "general-purpose"`, `model: "${MODEL_STANDARD}"`, prompt:

```
Read $CLAUDE_REVIEW_PIPELINE_DIR/skills/review-context-builder.md and follow it exactly. PR number: ${PR_NUMBER}. Write context.md AND test-plan.md at the repo root BEFORE running out of turns — partial output beats no output, EXCEPT on round ≥2 (PRIOR_HEAD_SHA set): context.md without `## Thread resolution` and `### Prior findings` is invalid — include both even if sparse.
```

When it returns, Read `context.md` + `test-plan.md`. If `context.md` is missing/empty: write degraded `/tmp/review.json` — `verdict: "COMMENT"`, body banner `> :warning: **Context builder failed** — review skipped. Re-run the workflow.`, empty comments, `meta.judge_health.cb_failed: true`, empty findings. Exit without dispatching judges.

### Trivial-PR early exit

If ALL hold — zero reviewable (non-doc/non-generated) chunks in `## Per-file diff index`, no PRD, no external-tracker spec, no manual PR-body spec — skip Phases B/C. Verdict APPROVE with zero findings, then apply the gates below (no-spec gate usually lands this on COMMENT). `meta.judge_health: {"trivial_skip": true, "agreed_at": "trivial"}`. Copy `manual_spec_present` and `prompt_injection_detected` from context.md — never fabricate. Write `/tmp/review.json`, exit.

## Phase B — parallel dispatch (ONE response)

### Dev-env sync (before the fan, only when functional dispatch is plausible)

```bash
DEADLINE=$(( $(date +%s) + ${DEV_ENV_TIMEOUT_SECONDS:-360} ))
while [ ! -f /tmp/dev-env/rc ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 5; done
[ -f /tmp/dev-env/rc ] && cat /tmp/dev-env/rc /tmp/dev-env/outputs
```

Source `/tmp/dev-env/outputs` (KEY=VALUE: `API_URL`, `WEB_URL`, `API_READY`, `WEB_READY`, `AUTH_READY`, `AUTH_*`). If `/tmp/dev-env/rc` never appears (timeout) or `/tmp/dev-env/` doesn't exist (workflow skipped bring-up), treat `WEB_READY=false`. Skip this poll entirely when functional won't dispatch (`RUN_FUNCTIONAL` ≠ `true` and strategy ≠ `pipeline-self-test`).

Compute `DEADLINE_EPOCH=$(( $(date +%s) + ${FUNCTIONAL_BUDGET_SECONDS:-480} ))` in this same Bash turn. The poll and the deadline computation both happen BEFORE any Phase B dispatch — no Bash between Task calls.

### Functional dispatch decision

1. `## Strategy: pipeline-self-test` in test-plan.md AND `tests/` exists → run `tests/*.sh` directly via Bash (skip `*smoke*`, 60s timeout each), tally pass/fail into `/tmp/functional-meta.json` (`strategy: "pipeline-self-test"`, `overall: PASS|FAIL|WARN`, `pass`/`fail`/`total`/`summary`), `/tmp/functional-findings.json = []`. No Task dispatch. Runs regardless of `RUN_FUNCTIONAL`.
2. `RUN_FUNCTIONAL=true` AND strategy ∈ {`quick`, `functional`} AND `WEB_READY=true` → dispatch the tester (below).
3. `RUN_FUNCTIONAL=true` AND strategy ∈ {`quick`, `functional`} AND `WEB_READY` ≠ `true` → functional was warranted but un-runnable (no dev-start.sh, or bring-up failed/timed out). Write `/tmp/functional-meta.json` `{"strategy": "skip", "overall": "SKIP_NO_DEVENV", "summary": "Runtime behaviour was in scope but no dev-env came up — smoke not run."}` and `/tmp/functional-findings.json = []`.
4. Anything else (nothing to exercise: `## Strategy: skip`, `RUN_FUNCTIONAL` ≠ `true`, or a non-runtime gate) → write `/tmp/functional-meta.json` `{"strategy": "skip", "overall": "N/A", "summary": "No runtime behaviour to test."}` and `/tmp/functional-findings.json = []`.

### Composing the functional Task prompt (no helper script — you write it)

Use the `DEADLINE_EPOCH` computed in the dev-env sync turn. Dispatch `subagent_type: "review-functional-tester"` (custom subagent; its file defines model + inline Playwright MCP — never pass MCP config or tool overrides) with a prompt containing, in order:

```
Read $CLAUDE_REVIEW_PIPELINE_DIR/skills/review-functional-tester.md and follow it exactly. PR #${PR_NUMBER}.
DEADLINE_EPOCH=<computed value> — hard wall-clock stop; compare `date +%s` against it before every scenario.
ENVIRONMENT: API_URL=<...> WEB_URL=<...> API_READY=<...> WEB_READY=<...> AUTH_READY=<...>
AUTH RECIPE (use as-is, do NOT rediscover auth):
<the "## Auth recipe" section of test-plan.md, verbatim>
SCENARIOS (P0 first — complete ALL P0 before any P1, all P1 before any P2):
<the "## Scenarios" section of test-plan.md, verbatim>
Outputs: /tmp/functional-findings.json + /tmp/functional-meta.json. Screenshots: absolute paths under /tmp/screenshots/.
```

### The Task fan (one assistant response, multiple Task calls)

Phase B dispatch is EXACTLY ONE assistant response containing ALL Task calls — both judges AND the functional tester together. Never dispatch the tester in a later response than the judges: audited runs serialized them and paid 6+ minutes of pure wall-clock loss.

1. **Judge-Opus** — `subagent_type: "general-purpose"`, `model: "${MODEL_HIGH}"`, prompt:
   ```
   Read $CLAUDE_REVIEW_PIPELINE_DIR/skills/review-judge.md and follow it exactly. If bugbot.md exists at the repo root, Read it — its acceptance/exemption sections override the skill (drop matching findings). You are the Opus judge for PR #${PR_NUMBER}. context.md at the repo root is your index. MODE=initial OUTPUT_PATH=/tmp/judge-opus.json. The [DESIGN] pass is MANDATORY for you.
   ```
2. **Judge-Haiku** — same prompt, `model: "${MODEL_FAST}"`, `OUTPUT_PATH=/tmp/judge-haiku.json`, and "The [DESIGN] pass is optional for you." At `light`: replace 1–2 with ONE judge, `model: "${MODEL_STANDARD}"`, `OUTPUT_PATH=/tmp/judge-sonnet.json`.
3. **Functional tester** — per the decision above.

Wait for every dispatched Task.

### Per-subagent failure handling

- Full tier, one judge's output missing/unparseable → record `"failed"` in `judge_health`, proceed with the survivor. No retries, ever.
- Full tier, both failed (or light tier, the single judge failed) → degraded `/tmp/review.json`: `verdict: "COMMENT"`, body banner `> :warning: **Both judges failed** — review is empty or partial. Re-run the workflow.` (light: `**Judge failed**`), empty findings/comments, `judge_health.both_failed: true` (light: `{"sonnet": "failed", "single_judge": true}`). Still include the functional section if the tester succeeded. Write, exit.
- Tester Task crashed (no output / parse error) → `/tmp/functional-meta.json = {"strategy": "crashed", "overall": "CRASH", "summary": "Functional tester agent did not complete."}`, `/tmp/functional-findings.json = []`, `judge_health.functional_failed: true`. Never use the `skip`/`PASS` sentinel for a crash.

## Phase C — rebuttal (≤2 rounds; skip at light)

Judges are equivalent when: verdicts match exactly, finding-cluster sets match (cluster = identical `path` AND `line_start` within ±5 AND same severity), and `manual_spec_present` agrees. Equivalent → Phase D.

Otherwise re-dispatch BOTH judges in one response, `MODE=rebuttal`, same models, prompts pointing at `OWN_PRIOR_OUTPUT_PATH` and `OTHER_JUDGE_OUTPUT_PATH`, round-suffixed outputs (`/tmp/judge-opus-r1.json`, …). Re-check after each round; cap at 2 rounds. Residual disagreement (`agreed_at: "none"`): clusters BOTH judges flagged take the high-tier judge's severity (never the union max); findings only the fast judge holds — seen and not adopted by the high-tier judge in rebuttal — cap at `minor` (reported, non-blocking); high-tier-only findings keep their severity. The verdict escalates to REQUEST_CHANGES only on critical/major findings surviving these rules. Light tier (single judge): unchanged.

## Phase D — consolidate, ladder, gates, assemble

Use each judge's most recent output. Target ≤8 turns: one consolidation pass, one screenshot-upload Bash, one final Write — never re-read judge/tester files already read.

### Merge / dedup (the double-post class must die here)

1. Cluster findings across ALL sources (both judges + `/tmp/functional-findings.json`): same `path` AND `line_start` within ±5 AND describing the same defect (judge the defect, not the wording).
2. One representative per cluster: higher severity wins; tie → longer `evidence` (judge-vs-judge clusters resolved under the Phase C residual-disagreement rule enter with that resolved severity). Representative is a verbatim copy; only graft `screenshot` from cluster members. Re-id `j1, j2, …` in emission order.
3. Solo findings pass through unchanged. Never invent, never reword.
4. **Cross-bot dedup:** a cluster matching an open OTHER-bot thread (from context.md `## Open inline threads`, path + line±5 + same defect) is NOT posted as an inline comment and NOT body-bulleted. If our analysis adds genuinely new information (new failure path, concrete evidence the bot lacked, a fix), emit ONE `bot_replies` entry on that thread; otherwise one line under `### Overlap with other reviewers` in the body. **Never post "+1"/"confirmed"-only replies.**
5. **Self-dedup:** a cluster matching one of our own open threads emits nothing new (the open thread already carries it; the round-2 ladder counts it via `### Prior findings`).
6. **Functional traceability gate:** a functional finding merges only when its expectation traces to a cited source (`[ACn]` / `[PRD: …]`) or is an objective failure (HTTP 5xx, crash, console error, broken navigation, data loss). The objective-failure clause never re-admits what the tester's false-failure gates exclude (pre-existing surfaces, known dev-env quirks, plan-invented contracts); findings asserting un-cited product expectations route to `uncertain_observations` instead.

### Verdict — per-PR ladder

First matching rule: any critical/major finding → `REQUEST_CHANGES`; any finding → `COMMENT`; none → `APPROVE`. `manual_spec_present`: judges agree → use it; disagree → `false`. `verdict_summary`: Opus's verbatim (fallback Haiku/Sonnet) + `(consolidated from N judge(s), R rebuttal round(s))`.

### Verdict — round-2 ladder (when `ROUND` ≥ 2 and `PRIOR_HEAD_SHA` non-empty)

Inputs: `PRIOR_VERDICT` (env), context.md `### Prior findings` (per prior finding: severity, carrier, `RESOLVED|STILL_PRESENT|REBUTTED`). The `## Thread resolution` thread table feeds `resolve_threads` only, never the verdict — a prior finding blocks regardless of which surface carried it (own thread, reply on another bot's thread, or body bullet). Apply the FIRST matching rule and record its name in `meta.ladder_rule_applied`:

| Rule name | Condition | Verdict |
|---|---|---|
| `prior-dismissed-as-approve` | Prior review state DISMISSED (context.md) | Treat PRIOR_VERDICT as APPROVE for the rules below; never re-enforce findings the author rejected (REBUTTED/dismissed findings stay dropped, listed under "Dropped after author rebuttal") |
| `new-blockers-escalate` | ≥1 new critical/major finding this round | `REQUEST_CHANGES` |
| `prior-rc-still-present` | PRIOR_VERDICT=REQUEST_CHANGES AND ≥1 prior critical/major finding STILL_PRESENT | `REQUEST_CHANGES` |
| `prior-rc-resolved` | PRIOR_VERDICT=REQUEST_CHANGES AND every prior critical/major finding RESOLVED or REBUTTED | per-judges verdict (APPROVE if clean, COMMENT if minors remain) |
| `prior-comment-no-ratchet` | PRIOR_VERDICT=COMMENT or APPROVE | per-PR verdict stands (may upgrade to APPROVE) |
| `prior-structural-block` | `PRIOR_VERDICT=REQUEST_CHANGES` AND **zero** prior findings were reconstructed this round (the prior block carried no findings — e.g. an oversized split-request, or a no-smoke block) | Re-evaluate from this round's live gates and judges; never pin via the findings ladder. A now-split or now-verified PR reaches its per-judges verdict. (A still-blocked PR never reaches here — it re-emits its block upstream before the ladder runs.) |
| `degraded-pin-max` | `## Thread resolution` missing/unusable, OR `### Prior findings` table missing on round ≥2 with PRIOR_VERDICT=REQUEST_CHANGES AND the prior review recorded ≥1 finding | max(PRIOR_VERDICT, per-PR) on REQUEST_CHANGES > COMMENT > APPROVE; unknown PRIOR_VERDICT → treat as REQUEST_CHANGES (fail closed) (A zero-finding prior RC is handled by prior-structural-block above.) |

REBUTTED findings never count as still-present blockers. Round 1: `ladder_rule_applied: "none-round-1"`. When the ladder changes the verdict vs per-PR, the body gets the override banner below.

### Gates (applied after the ladder)

The runtime-evidence gate runs first and may RAISE the verdict to REQUEST_CHANGES regardless of what either ladder produced; every other gate only downgrades APPROVE→COMMENT.

- **No-manual-spec:** `manual_spec_present=false` → `spec_gate_waived = (PR_AUTHOR_IS_BOT == "true")`; if not waived, APPROVE → COMMENT.
- **Runtime-evidence gate (ESCALATION):** `functional_warranted = (test-plan.md `## Strategy` ∈ {`quick`, `functional`}) AND `RUN_FUNCTIONAL`=`true`` — the planner found runtime behaviour to exercise AND the plan opted to smoke it. (False for `## Strategy: skip`/`pipeline-self-test`, for `RUN_FUNCTIONAL`≠`true`, and thus for `nonruntime`/`promotion`/`label` gates — all exempt.) `smoke_ok = true` when functional `overall` ∈ {PASS, WARN}; OR inherited — `ROUND ≥ 2` AND the planner deliberately chose `## Strategy: skip` AND context.md's `Prior functional result:` ∈ {PASS, WARN}; OR waived — not `functional_warranted`. When `functional_warranted` AND not `smoke_ok` (`overall` ∈ {SKIP_NO_DEVENV, CRASH, FAIL}, no inheritance): render the blocking banner below, and — if the verdict is NOT already `REQUEST_CHANGES` from real critical/major findings — set verdict `REQUEST_CHANGES` and `meta.ladder_rule_applied: "runtime-evidence"`, with empty `meta.findings` (this is the RAISE case; the block carries no findings so the round-2 ladder un-pins it once smoke runs). When the judges ALREADY produced surviving critical/major findings (verdict is already `REQUEST_CHANGES`), this gate is a no-op on the verdict and findings — KEEP every finding and the findings-based `ladder_rule_applied`; only the banner is added. Never wipe real findings. Bots are NOT waived — wiring `dev-start.sh` is repo-level.
- **Functional crash:** functional `overall` = CRASH is `!smoke_ok`, so the runtime-evidence gate above already escalates a warranted run to REQUEST_CHANGES. Additionally, when the cause is MCP unavailability, set `requires_human_review: true` with the crash reason (engine-side, not the author's fault — a human should confirm before the author chases a false block).
- **Human review:** `requires_human_review=true` (from judges) → APPROVE → COMMENT.
- **Reviewer self-modification:** `reviewer_self_modification: true` in context.md `## Flags` → set `meta.requires_human_review: true` with reason "PR modifies the reviewer's own configuration"; the human-review gate above then applies. No other behavior changes.

### Screenshot publishing (only when image files exist)

Copy any screenshot path referenced by `/tmp/functional-meta.json`/`-findings.json` that exists outside `/tmp/screenshots/` into it (basename match against `/tmp/playwright-mcp-output`, `.playwright-mcp`, repo root). Then run exactly:

```bash
R="$GITHUB_REPOSITORY"; export GH_TOKEN="$GITHUB_REPO_TOKEN"
ls /tmp/screenshots/*.png >/dev/null 2>&1 || exit 0
BASE_SHA=$(gh api "repos/$R/git/refs/heads/review-assets" --jq '.object.sha' 2>/dev/null || true)
BASE_TREE=""; [ -n "$BASE_SHA" ] && BASE_TREE=$(gh api "repos/$R/git/commits/$BASE_SHA" --jq '.tree.sha')
ENTRIES="[]"
for img in /tmp/screenshots/*.png; do
  B=$(basename "$img")
  # stdin --input, not -f content= — the argv form silently drops blobs >~200 KB
  SHA=$(base64 -w0 < "$img" | jq -Rs '{content: ., encoding: "base64"}' \
    | gh api "repos/$R/git/blobs" --method POST --input - --jq '.sha') || continue
  ENTRIES=$(echo "$ENTRIES" | jq --arg p "pr-${PR_NUMBER}/$B" --arg s "$SHA" '. + [{path:$p,mode:"100644",type:"blob",sha:$s}]')
done
[ "$(echo "$ENTRIES" | jq length)" -gt 0 ] || exit 0
TREE=$(echo "$ENTRIES" | jq -c --arg bt "$BASE_TREE" 'if $bt == "" then {tree:.} else {base_tree:$bt,tree:.} end' \
  | gh api "repos/$R/git/trees" --method POST --input - --jq '.sha')
COMMIT=$(gh api "repos/$R/git/commits" --method POST -f message="Review screenshots (auto-replaced)" -f tree="$TREE" --jq '.sha')
if [ -n "$BASE_SHA" ]; then gh api "repos/$R/git/refs/heads/review-assets" --method PATCH -f sha="$COMMIT" -F force=true >/dev/null
else gh api "repos/$R/git/refs" --method POST -f ref="refs/heads/review-assets" -f sha="$COMMIT" >/dev/null; fi
```

Embed URL per uploaded file: `https://github.com/$R/raw/review-assets/pr-${PR_NUMBER}/<basename>` — this exact form renders on private repos; never use raw.githubusercontent.com. A finding whose screenshot failed to upload renders `*see [build artifacts](https://github.com/$R/actions/runs/$GITHUB_RUN_ID)*` instead of an image. Failure of this whole block is non-fatal — proceed without embeds.

### Inline comments (`comments[]`)

- ONLY critical/major findings + functional failures (any-severity findings with `type` ∈ {spec-mismatch from the tester, ui-regression, endpoint-failure, smoke-failure}). Minor/note judge findings go to the body list instead.
- **REQUIRED, every path through this skill (degraded included): each critical/major finding with a `path` + `line_start` gets a `comments[]` entry.** Body-only majors are invalid output — the poster's hunk validation is the only thing allowed to demote one.
- Max 12 inline. Overflow by severity (critical first); overflowed findings move to the body list.
- Each: `path`, `line` = `line_end // line_start`, `side` = finding's side (default RIGHT), `start_line` = `line_start` when the range spans >1 and ≤10 lines (else null), `body`:
  `**[<SEVERITY> · <TYPE uppercased>]** <title>\n\n<reasoning>\n\n_Expected:_ <expected>` + (`\n\n_PRD:_ <prd_quote>` when present) + (`\n\n![screenshot](<url>)` when uploaded). Truncate body at 65000 chars.

### Body (`body`) — sections in this order, skipping empty ones

1. `## Claude PR Review — <VERDICT>`
2. `### Spec sources` — `- Linked issue: #N` / external tracker id / `none found`; `- Convention rules: …`
3. The `verdict_summary` paragraph.
4. Banners (one line each, only when applicable):
   - `> :information_source: **Verdict pinned to \`<V>\`** by the round-2 ladder (per-PR judgement was \`<P>\`; <ladder_rule_applied>).` (skip this banner when the verdict came from the runtime-evidence gate, i.e. `ladder_rule_applied == "runtime-evidence"` — that's a gate escalation, not a round-2 ladder pin)
   - `> :wave: **Prior review dismissed by author** — treating earlier findings as accepted/false-positive for ladder purposes.`
   - `> :no_entry: **APPROVE withheld — no spec.** Link an issue, paste acceptance criteria into the PR body, or wire up the external tracker.` / `> :robot: **Spec gate waived** — bot-authored PR.`
   - `> :no_entry: **Changes requested — no runtime evidence** (functional overall=\`<X>\`). This PR has runtime behaviour to exercise but the smoke run produced no PASS/WARN. Wire up \`.github/claude-review/dev-start.sh\` so the app comes up (see README → 'dev-start.sh contract'), or fix what made the smoke run fail/crash. Docs-only / non-runtime PRs are exempt.`
   - `> :stop_sign: **Human review required** — <reason>`
   - Judge-health banners (one judge failed / did not converge), verbatim wording from v2.
   - The `Setup notes` line from context.md, when present.
5. `### Since previous review` (round 2): `**Resolved (N):**`, `**Still present (N):**`, `**Dropped after author rebuttal (N):**` — one bullet per `### Prior findings` row, `- **[<SEVERITY>]** \`<path>:<line>\` — <title, clipped at 120> (<carrier: own thread / reply on <bot>'s thread / review body>)`, so the author sees why the verdict held.
6. `### Findings` — REQUIRED whenever ≥1 finding is not posted inline (even a single one): bullets `- **[<SEVERITY> · <TYPE>]** \`<path>:<line_start>\` — <title> — <one-sentence reasoning>`. Overflowed critical/major first, then minor, then note. Every finding rendering — inline comment, body bullet, bot reply — carries the `**[<SEVERITY> · <TYPE>]**` marker.
7. `### Overlap with other reviewers` — one bullet per cross-bot-deduped cluster: `- **[<SEVERITY> · <TYPE>]** <bot> already flagged \`<path>:<line>\` — <agree/extend one-liner>` (the marker keeps the finding reconstructable for the next round's ladder).
8. Functional section: `<details><summary><emoji> <b>Functional Validation — <OVERALL></b> (<N> screenshots)</summary>` with `#### Summary`, `#### Issues found` (severity-uppercased bullets + clipped evidence), `#### Screenshots` (caption + `![](url)` per uploaded image, artifact-link fallback), `</details>`. Emoji ✅ PASS / ⚠️ WARN / ❌ FAIL or CRASH. `pipeline-self-test` renders `<b>Pipeline Self-Test — <OVERALL></b> (<pass>/<total> bash test script(s) passed)`. Skip the section when strategy=skip.
9. `[Run logs](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)`

**Functional passes are never findings** — passes live only in this section's summary/gallery.

**The body NEVER states where findings are posted** ("see inline comments above", "posted as inline comments") — the poster may relocate out-of-hunk comments into the body, making any such claim false.

### resolve_threads / bot_replies

- `resolve_threads`: one entry per context.md `## Thread resolution` row with status RESOLVED and source ∈ {own_bot, other_bot, human} — `thread_id` = the row's thread node id (`PRRT_…`), `reply` = `✅ Resolved as of <head-sha> — <the row's evidence one-liner>`. STILL_PRESENT / REBUTTED / NEW_CONTEXT rows get nothing.
- `bot_replies`: only from cross-bot dedup rule 4 — `comment_id` = the other bot's numeric REST comment id, `body` opens with the finding's `**[<SEVERITY> · <TYPE>]**` marker and states the NEW information. Empty array is the normal case.

### meta

Fill every contract key:
- `round` = ROUND (int, default 1); `prior_verdict` = PRIOR_VERDICT or null; `ladder_rule_applied` per the ladder table.
- `functional_validation` from `/tmp/functional-meta.json`; `screenshot_count` counts image-typed (`.png/.jpg/.jpeg/.webp`) entries only.
- `uncertain_observations` = textual-deduped union of both judges' + the tester's; `judge_health` as accumulated across phases.
- `findings` = the consolidated array (incl. functional findings), verbatim entries.

Write `/tmp/review.json` and finish.
