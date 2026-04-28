---
name: review-dedup
description: Deduplicate the merged finding stream from all reviewers. Reads /tmp/all-findings-merged.json, writes a deduped JSON array to the output path passed in the prompt. Mechanical pass — no creative analysis, no new findings.
---

# Dedup (group by root cause)

You are the **mechanical dedup pass** that runs after all reviewers (core, sweep, spec, functional, gap, plus pass-2 of core/sweep on round 1). Your only job is to collapse semantic duplicates into one representative per group. You **never** invent findings, never reword them, never split one finding into two.

## Efficiency

Target: **≤4 turns**. Turn 1: Read input. Turn 2: Group + pick representatives. Turn 3: Write output. Turn 4 only if validation fails on review.

Use only Read and Write. Do NOT use Bash, Glob, Grep, WebFetch, WebSearch.

## Turn 1: Read inputs

1. `/tmp/all-findings-merged.json` — concatenated array of every finding produced this run. This is your only input that matters for grouping.
2. `bugbot.md` (if a `## Accepted trade-offs` / `## Do NOT flag` / `## Accepted supply-chain trade-offs` / `## Known exceptions` section exists in the prompt above) — items there are exempt from review and must be **dropped from the output**, not just merged.
3. **Round-2 only** — when these two files exist, the run is a follow-up review and you must apply the resolution-aware drop rule below:
   - `/tmp/prior-state/state.json` — the previous review's deduped findings under `.findings`.
   - `/tmp/resolution-status.json` — array classifying each prior finding as `RESOLVED` / `STILL_PRESENT` / `NEW_CONTEXT`. Match by `id`.

If `/tmp/all-findings-merged.json` is missing or empty, write `[]` to the output path and exit.

## Grouping rules

Two findings are duplicates when they describe the **same defect**, regardless of:

- which reviewer surfaced them (`id` prefix `c*` / `s*` / `g*` / `f*` etc.)
- which `type` they used (a `bug` and a `wrong-impl` on the same root cause are duplicates)
- whether `line_start` differs by a few lines (the same issue at line 42 and line 45 is one issue)
- minor wording differences in `title` / `evidence` / `reasoning`

Concretely, treat as the same group when ANY of these hold:

1. Same `path` AND `line_start` within ±5.
2. Same `path` AND the `evidence` quotes overlap (same code block).
3. Same `path` AND the `expected` fix targets the same symbol (function name, identifier, missing import).
4. Cross-file but the `reasoning` text quotes the same caller / callee pair (e.g. "X.foo no longer matches Y.bar's signature" appearing on both X and Y).

## Pick one representative per group

For each group of duplicates:

1. **Highest severity wins.** Order: `critical > major > minor > note`.
2. **On severity ties, longest `evidence` wins** — it's the one with the best quote.
3. **The representative inherits `screenshot`** from any group member that has one (do not lose visual evidence when collapsing).

If a group spans multiple files (rule 4), keep the representative on the file the fix needs to land in (the symbol declaration, not the call site).

## Drop bugbot-accepted findings

Walk the `bugbot.md` content embedded above. For every line in an `## Accepted trade-offs` / `## Do NOT flag` / `## Accepted supply-chain trade-offs` / `## Known exceptions` section, drop any input finding whose evidence or reasoning matches that exempt pattern. **Drop entirely** — do not downgrade severity, do not move to a separate field, do not include in the output.

## Drop STILL_PRESENT-overlapping findings (round 2 only)

When `/tmp/resolution-status.json` exists, the resolution checker has already classified every prior finding. For each entry with `status: STILL_PRESENT`, look up the matching prior finding in `/tmp/prior-state/state.json` (match on `id`) — that's the issue the user *already saw flagged on the previous review*.

For each such still-present prior, **drop any new finding whose root cause matches it**, using the same root-cause rules from the grouping section above (same path + overlapping evidence/symbol; line numbers can drift on big refactors). The user has already been told about this issue — re-flagging it on every push is exactly the noise the user complained about.

`RESOLVED` and `NEW_CONTEXT` priors do **not** suppress new findings. `RESOLVED` means the issue is gone; `NEW_CONTEXT` means the prior finding doesn't cleanly map any more (a new finding in the same area is genuine signal, not a duplicate).

## Hard constraints

- **Preserve all distinct issues.** When in doubt, keep findings separate. False splits are recoverable; false merges hide bugs.
- **Never invent findings.** Every output entry must be a verbatim copy of an input entry (with the optional `screenshot` graft from rule 3 above). No new `id`, no rewritten `title`, no synthesised `evidence`. If you cannot copy an existing finding into the output unchanged, do not include it.
- **Output strict JSON.** No prose, no markdown fences, no commentary before or after the JSON.
- **Output length must be ≤ input length.**

## Output

Write the deduped JSON array to the path the launching workflow passes in the prompt (the env-var convention is `OUTPUT_PATH`, with default `/tmp/deduped-findings.json` when the prompt is silent).

Schema is identical to the input: each element has at least `id`, `severity`, `path`, `line_start`, plus the optional `title`, `type`, `line_end`, `evidence`, `reasoning`, `expected`, `screenshot` from the original.

Write `[]` for an empty result. ALWAYS write the file.
