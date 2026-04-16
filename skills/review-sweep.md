---
name: review-sweep
description: Sweep review — consistency, test meaningfulness, performance. Reads context.md, writes /tmp/sweep-findings.json. Run in parallel with review-core.
---

# Sweep Review (Consistency, Tests, Performance)

You are one of two parallel reviewers. You focus on **codebase consistency, test quality, and performance**. A separate reviewer handles bugs/spec/security.

## Efficiency

Target: **≤6 turns**. Turn 1: Read inputs. Turns 2-4: analyze. Turn 5: Write output.

Use only Read and Write. Everything is in context.md — do NOT use Bash, Glob, or Grep.

## Turn 1: Read inputs

1. Read `bugbot.md` at the repo root — project-specific review philosophy and patterns to watch for.
2. Read `context.md` at the repo root — full diff, file contents, convention rules, build output.

## Your scope — finding types

| Type | Definition |
|---|---|
| `consistency` | Diverges from patterns in sibling files. Must quote the sibling file + line being diverged from. |
| `weak-test` | SUT itself is mocked, assertions only check mock calls, test still passes if SUT is deleted. Must show how. |
| `missing-test` | Changed source file contains non-trivial logic (handler, hook, util, service) but has no corresponding test file. Check context.md → "Test coverage" section — only flag files marked UNTESTED. Severity `minor` for handlers/hooks/utils, `note` for DTOs/modules/thin wrappers. |
| `performance` | N+1 queries (DB call in loop), unbounded queries without pagination, expensive ops in hot paths. Must identify the specific loop/query. |
| `design-smell` | From the consistency angle: change introduces a pattern worse than what exists. Must show the sibling that does it better. |
| `overcomplicated` | Unnecessarily complex where a simpler approach exists in the codebase. Must show the simpler sibling. |

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

**Verify the referenced artifact exists.** If a consistency finding says "use X from @qec/ui" or "import Y from next-intl", check the `# Repo capabilities snapshot` section of context.md. If the artifact isn't listed as installed/exported, DROP the finding — suggesting a replacement that doesn't exist is worse than flagging nothing. Also check `# User replies on prior findings`: if a maintainer already rebutted the same issue as a false positive, don't re-flag.

## Output: Write ONE file

**`/tmp/sweep-findings.json`** — array:

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

Write `[]` for empty findings. ALWAYS write the file.
