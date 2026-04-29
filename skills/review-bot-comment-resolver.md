---
name: review-bot-comment-resolver
description: Round-2 only. Classifies open inline comments left by OTHER review bots (cursor, aikido, etc.) against the new diff. For each, decides RESOLVED / STILL_PRESENT / NEW_CONTEXT. The post-review step uses RESOLVED entries to reply + close the thread, so the PR UI reflects what the new commits actually fixed.
---

# Bot Comment Resolver (round 2 only)

You run alongside the resolution checker on follow-up reviews. Where the resolution checker classifies **our own** prior findings, you classify **other bots'** (cursor, aikido, dependabot, etc.) inline comments — the threads that accumulate on every PR and never close themselves.

Your output drives `post-review.sh`'s thread-resolution step. RESOLVED entries get a `✅ Resolved as of <sha>` reply on the bot's thread and a GraphQL `resolveReviewThread` mutation. STILL_PRESENT and NEW_CONTEXT entries get nothing — silence is the default, action is the exception.

## Efficiency

Target: **≤8 turns**. Use only Read and Write — no Bash, Glob, Grep.

Turn 1: Read inputs.
Turns 2-N: classify each comment. For each, you may need a focused Read of the cited file at the cited line — that's expected. Don't re-read the whole file; jump to the line range.
Final turn: Write `/tmp/bot-resolution-status.json`.

The vast majority of runs produce a small number of RESOLVED entries (or zero). That's correct. **Don't pad output with speculative classifications** — STILL_PRESENT is the safe default when in doubt.

## Turn 1: Read inputs

1. `/tmp/other-bot-comments.json` — array of open top-level inline comments from non-Claude bots. Each entry has `id` (numeric GitHub comment id), `node_id`, `user` (e.g. `cursor[bot]`, `aikido-pr-checks[bot]`), `path`, `line`, `body` (truncated to ~500 chars). **You must read this fully.**
2. `/tmp/since-last.diff` — the diff between the prior review's HEAD and the current HEAD. Defines the scope of what could have been fixed since the bot last looked. **You must read this fully.**
3. `context.md` at the repo root — the full diff index lives at `## Per-file diff index`. When you need to inspect a specific file at a specific line, Read the chunk path the index points to (under `/tmp/diff-chunks/<file>.diff` or `/tmp/since-last-chunks/<file>.diff`).

If `/tmp/other-bot-comments.json` is missing or empty (`[]`), or `/tmp/since-last.diff` is missing, write `[]` to `/tmp/bot-resolution-status.json` and exit. Round-1 runs and rounds with no prior bot comments hit this path — that's normal.

## What to classify, what to skip

**In scope (classify):**
- `cursor[bot]` structured findings (recognizable by `### <title>` followed by `**<Severity>**`).
- Other code-review bots' substantive findings: bugbot, deepcode, sonarcloud, snyk-bot, etc.
- `aikido-pr-checks[bot]` HIGH/CRITICAL severity findings.

**Out of scope (skip — do NOT emit any classification):**
- `aikido-pr-checks[bot]` low-severity style notes ("extract helper to reduce nesting", "use early returns") — those are style-tooling territory; whether the author addresses them is a design choice, not a fix. Resolving them is noise.
- `dependabot[bot]` / `renovate[bot]` PR comments — they manage their own threads.
- Bot comments that aren't anchored to a specific file/line (`path == null`).
- Comments older than the prior review's HEAD when the file or line range was rewritten before round 1 — out of round-2 scope.

If a comment's body is too truncated to understand the finding, classify as `NEW_CONTEXT` (you can't tell). Don't guess.

## Classification

For each in-scope comment, classify as exactly one:

### RESOLVED

The finding no longer applies in the current code. Genuine signals:
- The flagged lines were deleted entirely, and the surrounding code no longer exhibits the defect.
- The flagged code was rewritten in a way that addresses the bot's reasoning. E.g. "discards Promise.all result" → new code now destructures both elements; "@Data on bidirectional entity" → new code adds `@ToString.Exclude` / `@EqualsAndHashCode.Exclude`.
- The whole file/feature was reverted or removed.

Do NOT mark RESOLVED based on:
- The line number shifted but the same defect persists elsewhere in the file. (That's STILL_PRESENT.)
- Adjacent lines changed but the flagged code is unchanged. (STILL_PRESENT.)
- The comment was downvoted by a maintainer reply. (Not your call — leave the thread alone.)

### STILL_PRESENT

The flagged code is unchanged or still exhibits the defect. The default when in doubt — **silence is correct here**, no reply gets posted.

Examples:
- `since-last.diff` doesn't touch `path` at all.
- `path` is in the diff but the flagged line range is unchanged.
- The diff modifies the surrounding code but the bug pattern remains.

### NEW_CONTEXT

The diff substantially rewrote the area. You cannot confidently say whether the defect is gone. Examples:
- The function the comment cited was renamed, moved, or split — the new shape doesn't map cleanly to the comment's reasoning.
- The bot's reasoning relied on context now refactored away.
- You'd need to read code outside the diff to be sure. Don't.

Like STILL_PRESENT, NEW_CONTEXT produces no reply. The difference is purely audit-trail.

## Hard rules

- **One classification per in-scope comment**, in input order. Out-of-scope comments produce **no entry** (don't emit STILL_PRESENT for skipped aikido style notes — keep the output focused on what's actionable).
- **`comment_id`** in the output MUST equal the input comment's `id` (numeric, not `node_id`). The poster needs the REST id to find the GraphQL thread by the comment chain.
- **`evidence`** is mandatory for RESOLVED. Cite the diff line(s) you based the call on (e.g. `"new code at since-last-chunks/foo.ts.diff +59 destructures both Promise.all results"`). For STILL_PRESENT / NEW_CONTEXT, evidence can be a one-liner ("path unchanged in since-last.diff" / "function renamed, can't trace flagged behavior").
- **`bot_user`** in the output MUST equal the input comment's `user` field. Used for diagnostics in the poster log.
- **No new findings.** This skill exists to close stale threads — surfacing new bugs is the focused round-2 fan's job. Out of scope.

## Output: `/tmp/bot-resolution-status.json`

Array, one entry per in-scope comment that you actively classified:

```json
[
  {
    "comment_id": 2178293441,
    "bot_user": "cursor[bot]",
    "path": "backend/node/src/api/communications/messaging/handlers/getPersonalizedRsvpPreviewAssets.handler.ts",
    "line": 69,
    "status": "RESOLVED",
    "evidence": "since-last-chunks/backend--node--src--api--...--getPersonalizedRsvpPreviewAssets.handler.ts.diff line 7 now destructures both Promise.all results into [themeFallback, templateFallback] and uses templateFallback in buildPersonalizedRsvpPreviewTemplate"
  },
  {
    "comment_id": 2178401522,
    "bot_user": "cursor[bot]",
    "path": "backend/java/core/domain/src/main/java/com/seaters/domain/core/fangroup/WaitingListInvitationCommunicationTranslation.java",
    "line": 41,
    "status": "STILL_PRESENT",
    "evidence": "path unchanged in since-last.diff; bidirectional @Data still present"
  }
]
```

Write `[]` when there are no in-scope comments to classify (or when every in-scope comment is STILL_PRESENT and you choose to omit them — STILL_PRESENT entries are optional, RESOLVED entries are mandatory). Write the file even on partial failure — the poster reads it best-effort.

ALWAYS write the file. On any failure path, write `[]`.
