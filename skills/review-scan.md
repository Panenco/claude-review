---
name: review-scan
description: Stage 1 of the review pipeline. Reads the PR diff itself, self-scales its depth, and writes /tmp/scan.json — candidate findings, human-review items, and an argued approve/no-approve position. Never posts anything.
---

# Review Scan

You review the PR yourself and write ONE file: `/tmp/scan.json`. Nothing you write is posted directly — stage 2 (`review-verify`) refutes your findings and renders the review.

## Read the diff

```bash
gh pr diff ${PR_NUMBER}                      # the whole diff
gh pr view ${PR_NUMBER} --json title,body,closingIssuesReferences
```

Then `Read`/`Grep` the changed files **at HEAD** for anything you intend to flag. Skip lockfiles, snapshots, `dist/`, generated clients — a diff is not a defect.

## Round 2+ — review only what changed since last time

`ROUND` and `PRIOR_HEAD_SHA` are in your env. When `PRIOR_HEAD_SHA` is non-empty and is not HEAD, the previous round already read the rest of this PR and charging for it again is pure waste:

- Review **only** `git diff ${PRIOR_HEAD_SHA}..HEAD`. Read the wider file for context, but do not hunt for new findings outside that delta.
- Read the last review: `jq -r 'sort_by(.submitted_at) | last | .body' /tmp/prior-reviews.json`.
- For each finding it lists, `Read` that code at HEAD and decide **fixed** or **unresolved** — from the code, not from any reply. Put the unresolved ones in `prior_findings` (a finding object plus `"carried": true`); say nothing at all about the fixed ones.
- Never re-raise something the last review already raised as a fresh finding. Carry it, or drop it.

**Self-scale your depth.** A small, low-risk diff gets a light pass; a diff touching auth, money, migrations, concurrency, or data deletion gets a full pass with callers traced. Record which you chose in `depth_used` with one clause saying why. Target ≤15 turns; write the file by turn 25 whatever you have.

## The finding bar

**A finding without a `failure_scenario` — a concrete input or state that produces a concrete wrong output — MUST NOT be emitted. This is the single most important rule in this file.**

"Could break", "may be unsafe", "is not defensive", "should validate", "consider extracting" are not failure scenarios. If you cannot write *"when X, the code does Y, and the user gets Z"* with real values, you do not have a finding. Drop it. Do not downgrade it to `minor` to keep it — delete it.

**Zero findings is the correct and expected output for a clean PR.** An empty `findings` array is a successful review, not a failed one. Most PRs deserve one.

Every finding carries all of:

| Field | Bar |
|---|---|
| `path` | exists in `git ls-files` AND appears in the diff |
| `line` | a line inside a diff hunk, in NEW-file numbering (from `@@ -a,b +c,d @@`) |
| `title` | names the user-visible failure, ≤90 chars |
| `failure_scenario` | concrete input/state → concrete wrong output, ≤240 chars |
| `evidence` | 2–6 lines quoted from the file **as it exists at HEAD** |
| `fix` | a committable replacement for the cited lines — real code, not advice |
| `severity` | `critical` (security, data loss, broken build) / `major` (user-reachable logic bug) / `minor` (real but non-blocking) |

Out of scope, always: formatting, pre-existing issues in untouched files, speculative extensibility, missing tests you cannot tie to a broken behavior, style preferences.

## human_review — you choose these

0–3 items. Each is something a human should look at that **you could not settle yourself**. Do not pick from a category list; there is no category list. Do not pad to three — zero is fine, and a made-up item is worse than none.

Each item: `{path, line, what_to_check (≤140 chars), why_unresolved (≤120 chars)}`. `why_unresolved` says what stopped you (no spec, no runtime access, behavior depends on production data, the intent is ambiguous), never "for safety".

## The approval position

Set `human_review_adds_nothing: true` only if you can WRITE the argument for it: `approve_argument` (≤240 chars) says why a human pass over this diff changes nothing — what you verified and why the remaining risk is nil. An empty or hand-wavy argument means `false`. Stage 2 rejects an unargued approval anyway.

`review_effort` 1–5: how much judgement this diff needed (1 = mechanical, 5 = subtle/high-blast-radius).

## Functional results are NOT yours to read

The functional tester is dispatched in the **same response** as you and runs to its own wall-clock budget (up to 480s), so `/tmp/functional.json` does not exist while you are running. Do not wait for it, do not poll for it, do not mention it. `review-verify` runs after both of you and is the only consumer.

## Output — `/tmp/scan.json`

```json
{
  "depth_used": "light|full",
  "depth_reason": "one clause",
  "review_effort": 3,
  "summary": "What the PR does, one sentence, <=200 chars",
  "findings": [
    {
      "path": "src/foo.ts",
      "line": 42,
      "title": "...",
      "failure_scenario": "...",
      "evidence": "...",
      "fix": "...",
      "severity": "critical|major|minor"
    }
  ],
  "prior_findings": [
    {"path": "src/foo.ts", "line": 42, "title": "...", "failure_scenario": "...",
     "evidence": "...", "fix": "...", "severity": "major", "carried": true}
  ],
  "human_review": [
    {"path": "src/foo.ts", "line": 42, "what_to_check": "...", "why_unresolved": "..."}
  ],
  "human_review_adds_nothing": false,
  "approve_argument": "",
  "sensitive_paths_touched": false
}
```

`sensitive_paths_touched`: true when any changed path matches auth, oauth, authentication, authorization, security, payments, migrations, `.github/`, `.claude/`, `infra/`.

Write the file on every exit path. `evidence` and `fix` contain real code — escape every `"`, newline and backslash. Validate with `jq empty /tmp/scan.json` before you finish; an unparseable file is an invisible review.
