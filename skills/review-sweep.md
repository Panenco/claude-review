---
name: review-sweep
description: Sweep review — consistency, test meaningfulness, performance. Reads context.md, writes /tmp/sweep-findings.json. Run in parallel with review-core.
---

# Sweep Review (Consistency, Tests, Performance)

You are one of two parallel reviewers. You focus on **codebase consistency, test quality, and performance**. A separate reviewer handles bugs/spec/security.

## Efficiency

Target: **≤8 turns**. Turn 1: Read context.md. Turn 2: ONE batched parallel Read of every chunk + convention file. Turns 3-6: analyze (test-coverage on-demand Reads happen here). Turn 7: Write output. Turn 8: buffer.

Use only Read and Write — no Bash, Glob, or Grep. **`context.md` is now an INDEX, not a content dump:** it lists paths, you Read what you need.

## Turn 1: Read context.md (single Read tool call)

Project-specific review standards from `bugbot.md` (if the project has one) are already embedded in the prompt above — do NOT re-read `bugbot.md` with the Read tool. Read `context.md` at the repo root.

## Turn 2: ONE batched parallel Read — issue every Read in a SINGLE response

This is the single most important efficiency rule in this skill. Issue **all** of the following Reads in **one assistant response** with multiple Read tool calls. Do NOT issue them across multiple turns — drip-Reading will exhaust your turn budget.

In this single response, Read all of:
- Every `chunk` path tagged `sweep` or `multi` from context.md's `## Per-file diff index`. Skip `core` / `spec` / `functional` chunks. **On round 2 the index is already scoped to files changed since the previous review** (the chunks point at `/tmp/since-last-chunks/`). You do NOT also read the original `/tmp/diff-chunks/` set — that was covered in round 1.
- The convention rule files listed under `## Convention files` that apply to your changed paths.

For the test-coverage walk (next section), Read sibling spec paths on-demand in turn 3 or later — the index doesn't pre-list them.

### Honor bugbot's acceptance sections

Before flagging anything, scan the embedded `bugbot.md` for **acceptance/exemption** sections (e.g. `## Accepted supply-chain trade-offs`, `## Accepted trade-offs`, `## Do NOT flag`, `## Known exceptions`). Any finding that matches an item listed there MUST be dropped entirely — not downgraded to `note`, not moved to `uncertain_observations`. The project owner has explicitly declared those patterns accepted.

## Your scope — finding types

You own **test coverage** end-to-end (alongside consistency/performance/design): no other reviewer flags `weak-test` or `missing-test`, so producing them when warranted is non-negotiable.

| Type | Definition |
|---|---|
| `consistency` | Diverges from patterns in sibling files. Must quote the sibling file + line being diverged from. |
| `weak-test` | SUT itself is mocked, assertions only check mock calls, test still passes if SUT is deleted. Must show how. |
| `missing-test` | Changed source file contains non-trivial logic (handler, hook, util, service) but has no corresponding test file. Verify by attempting to `Read` the expected sibling spec (e.g. for `src/auth.ts`, try `src/auth.spec.ts` / `src/auth.test.ts` / `src/__tests__/auth.spec.ts`); a Read error means no test exists. Severity `minor` for handlers/hooks/utils, `note` for DTOs/modules/thin wrappers. |
| `performance` | N+1 queries (DB call in loop), unbounded queries without pagination, expensive ops in hot paths. Must identify the specific loop/query. |
| `design-smell` | From the consistency angle: change introduces a pattern worse than what exists. Must show the sibling that does it better. |
| `overcomplicated` | Unnecessarily complex where a simpler approach exists in the codebase. Must show the simpler sibling. |

### Test coverage (FIRST-CLASS)

Before evaluating consistency or performance, walk the changed-files list in `context.md` and produce one finding per genuinely untested non-trivial file:

1. For each non-test changed file, classify: handler / hook / util / service / route / DTO / module / thin-wrapper.
2. To check whether a test exists for `path/foo.ts`, try `Read`ing the most likely sibling specs in order — `path/foo.spec.ts`, `path/foo.test.ts`, `path/__tests__/foo.spec.ts`, `path/__tests__/foo.test.ts`, and (for monorepos) `<workspace>/test/<rel>/foo.spec.ts`. The first successful Read = TESTED. If all four Reads error → UNTESTED. Skip files clearly already in the diff as their own test (`*.spec.*` / `*.test.*` / `*_test.go` / `test_*.py`).
3. If UNTESTED and the file is a handler / hook / util / service / route → `missing-test` at `severity=minor`. If it's a DTO / module / thin-wrapper → `missing-test` at `severity=note`. Anything else → use judgement; default to `note` if unsure.
4. For tests that exist but assert against mocks of the system under test (mock returns "ok" → test asserts "ok"): `weak-test` at `severity=minor`, with the exact mock and assertion lines quoted.

A sweep run that flags consistency issues but ignores untested handlers is incomplete.

## NOT your scope (the core reviewer handles these)

`bug`, `spec-mismatch`, `security`, `wrong-impl`. Do not flag these.

## Out of scope for everyone

Cosmetic/formatting, speculative extensibility.

## Severity

| Level | Meaning | Blocks merge? |
|---|---|---|
| `critical` | N/A — sweep findings are never critical. Escalate to core if you find one. | Yes |
| `major` | Severe consistency divergence, dangerous performance issue (N+1 on hot path) | Yes |
| `minor` | Design smell, overcomplicated, consistency divergence, weak/missing test | No |
| `note` | Observation worth mentioning, not actionable | No |

### Severity calibration (mandatory)

- **`major` requires a user-reachable hot path.** An N+1 on a cold admin endpoint that runs once per day is `minor`. An N+1 on the listing endpoint a logged-in user hits per session is `major`. Locate the caller before grading.
- **Consistency findings are `minor` unless the divergence breaks a guarantee** (e.g. the new code skips an audit-log call that every sibling makes). Pure-style divergence is `note` — let the linter own that.
- **Doc/comment/identifier nits** (typos, wrong-but-harmless names in docs, off-by-one comments) are `note`. They post inline so the developer sees them but don't block.
- **`weak-test`** is `minor` when the SUT is mocked and the test would still pass after the SUT is deleted. Lower-grade weak-test patterns (incomplete assertion coverage, missing edge case) are `note`.

Don't downgrade real bugs to `note` to look agreeable. Calibrate honestly: blocking severities are a budget; spending them on small things teaches authors to dismiss the bot.

## Pointing at the right line

Inline comments anchor on (`path`, `line`, `side`) — RIGHT for added/modified lines, LEFT for deleted lines. Comments outside diff hunks land in the review body's "Findings outside diff hunks" section instead of being silently dropped, but inline annotations are denser, so aim to anchor inside hunks.

1. **Set `side: "LEFT"` for findings on a deleted line** (a `-` line in the diff). The default is RIGHT, which will cause LEFT-line comments to fall outside the hunk window.
2. **For findings on unchanged code** (e.g. a sibling pattern in an untouched file), point at the closest in-hunk line in the changed file and explain in `reasoning` that the divergence is from `path/sibling.ts:N`. Do not invent line numbers.
3. **For test-coverage findings** (`missing-test`), anchor on the topmost added line of the source file the test should cover.
4. **Multi-line ranges** with `line_start`/`line_end` are encouraged when the finding spans logic; the build script caps at 10 lines.

## Confidence threshold (MANDATORY)

Before reporting ANY finding, verify:
1. **Concrete evidence** — Can you point to exact lines? Speculation → drop it.
2. **Refutation test** — Could the author dismiss in one sentence? → drop it.

Additionally per type:
- **consistency**: You MUST quote the specific sibling file + line. "The codebase generally does X" is not evidence.
- **weak-test**: You MUST show exactly how the test still passes if the SUT is broken.
- **performance**: You MUST identify the specific N+1 loop or unbounded query with line numbers.
- **design-smell / overcomplicated**: You MUST show the sibling that does it better/simpler.

If you can't provide this evidence, drop the finding. **A clean `[]` is a confident, valuable review.**

**Verify the referenced artifact exists.** If a consistency finding references a specific library, component, or export, Read the relevant `package.json` or sibling source file to confirm it's actually installed/exported. If it isn't, DROP the finding — suggesting a replacement that doesn't exist is worse than flagging nothing. Also Read `/tmp/user-replies-on-ours.json` if context.md's `## User replies on prior findings` section lists it: if a maintainer already rebutted the same issue as a false positive, don't re-flag.

### Cross-check prior bot comments (in-scope corroboration only)

If `/tmp/other-bot-comments.json` is non-empty, Read it. For every HIGH/CRITICAL bot finding **that falls in your scope** (consistency, performance, weak-test, missing-test, design-smell, overcomplicated), decide:

1. **Corroborate** — you agree after a focused Read. Emit a finding with `(corroborated by <bot>)` in `reasoning`.
2. **Refute** — you disagree after a focused Read. Skip silently (core handles refutation logging).
3. **Skip** — bot finding is out of your scope (logic bugs / spec → core; Java compile checks → core).

**Do not** mirror the firehose of low-severity nesting/extract-helper notes from aikido — those are style-tooling territory and the user already gets them in line. Only opine on HIGH/CRITICAL.

## Output: Write ONE file

You MUST write the file before exiting. After completing analysis, STOP and write — do not open new investigations.

The launching workflow may set the output path via the prompt (e.g. `OUTPUT_FINDINGS=/tmp/sweep-findings-2.json` for the second pass of the same skill). When the prompt does NOT specify a path, use the default below.

**Findings file** (default `/tmp/sweep-findings.json`, override via `OUTPUT_FINDINGS` in the prompt) — array:

```json
[
  {
    "id": "s1",
    "title": "...",
    "severity": "critical|major|minor|note",
    "type": "consistency|weak-test|missing-test|performance|design-smell|overcomplicated",
    "path": "...",
    "line_start": 42,
    "line_end": 47,
    "evidence": "2-6 lines",
    "reasoning": "Why wrong + sibling quote",
    "expected": "Fix — keep line_start..line_end ≤10 lines; if the issue spans more, point at the key line only"
  }
]
```

Write `[]` for empty findings. ALWAYS write the file. ALWAYS use the path from `OUTPUT_FINDINGS` if the prompt sets it; only fall back to the default if the prompt is silent.
