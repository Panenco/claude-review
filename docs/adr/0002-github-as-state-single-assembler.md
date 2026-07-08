---
status: accepted
date: 2026-06-11
---

# 0002 — GitHub as the only round-2 state store; single assembler + slim poster

## Context

Round-2 reviews depended on a cross-run `review-state` artifact plus a shallow
clone: when the artifact was missing (retention, a failed prior run, a missing
`actions: read` on the caller) or the prior SHA wasn't in the clone, round 2
silently degraded to a full-price re-review — and the state-sync machinery
(artifact upload/download, run-id lookup, inherit/amend merging) was its own
fleet of failure modes. Separately, the path from judge output to posted review
ran through a large bash assembly layer (`build-review.sh` + `verdict-gate.sh`)
that re-merged findings the orchestrator had already deduped — double-posting
findings — and accounted for most pipeline-failure classes.

## Decision

**(a) GitHub is the only round-2 state store.** The prior round's reviewed SHA
and verdict come from the PR's own review history: the newest own-bot,
non-crash, non-superseded review's `commit_id` and state. The checkout is a
full clone, so `git diff <prior>...HEAD` is always computable. State artifacts
and the shallow-clone fallback are deleted; `actions: read` is no longer
needed. State can no longer be lost, only read — the silent full-price
re-review class disappears.

**(b) One assembler agent, one slim deterministic poster.** The orchestrator
owns judgment AND assembly: merge/dedup, verdict ladder, gates, body and inline
comments — emitted as a single artifact, `/tmp/review.json`. The poster
(`post-review.sh`) only validates it (JSON shape, hunk anchoring), POSTs the
review atomically, resolves threads, and sets the check via its exit code
(green = review posted, including REQUEST_CHANGES; red = pipeline failure).
Everything that was bash between orchestration and POST is now prompt rules —
findings are assembled once, by the agent that judged them.

## Considered options

- **Keep the artifact, add fallbacks.** More babysitting machinery for the
  state sync — the failure class this removes.
- **Keep a bash assembly layer.** Deterministic, but it duplicated the
  orchestrator's dedup/ladder logic and was the main source of double-posts
  and pipeline reds.
- **Chosen:** state read from GitHub; judgment + assembly in one agent; a
  ≤320-line poster that can be unit-tested with a mocked `gh`.

## Consequences

- Round 2 never silently degrades; consumers need no `actions: read`.
- One handoff contract (`/tmp/review.json`) instead of several intermediate
  files; the poster trusts it verbatim.
- Ladder/merge behavior now lives in prompts, so it is exercised by dogfood
  runs rather than bash unit tests; poster tests cover the deterministic rim.
