---
status: accepted
date: 2026-08-28
---

# 0003 — The cache warm gets its own workflow, on a write-capable trigger

## Context

`pr-review.yml` carried a `warm-cache` job gated `if: github.event_name ==
'pull_request_target'`. Its purpose was to write the package-manager store, the
browser stack and the opt-in `dev_cache_*` entries into the default branch's
cache scope, so that every PR's review — which only restores — starts warm.

It never wrote a single entry. Not once, on any consumer, since the feature
shipped.

GitHub grants write access to the default branch's cache scope to `push`,
`workflow_dispatch`, `repository_dispatch`, `schedule`, `delete`,
`registry_package` and `page_build` only. Every other event that resolves to the
default branch gets **read-only** access, and the reference names the excluded
ones explicitly: `pull_request_target`, `issue_comment`, `workflow_run` — the
triggers whose payload or initiating actor can be influenced from outside the
repo. It is cache-poisoning protection: an attacker who could plant an entry in
the default branch's scope would be planting it for every later privileged run
that restores and trusts it.

Three properties turned that into a year-shaped blind spot:

1. **A reusable workflow inherits the caller's event.** `warm-cache` could not
   pick its own trigger; it got whatever fired the review.
2. **A refused save is a warning, not a failure.** The job went green every
   time.
3. **`permissions:` cannot buy the access.** `actions: write` is a measured
   no-op — A/B run `33105704317`, event held constant, both jobs on the same
   pool, `ac` claim byte-identical with and without it.

Measured cost while it stood: ~460 jobs/day org-wide (~2.4% of fleet minutes),
each one re-running its full `pnpm fetch` and dev-cache warm and discarding the
result; roughly 18–25 runner-hours per month per consumer. Downstream, every
review job reported `Cache not found for input keys: …` because nothing had ever
been written. Server-side the refusals were the entire volume behind
`alert-cache-write-denied` — 195–566 log events/day, misread for two
investigations as fork-PR churn
(Panenco/github-action-runners#141, panenco/claude-review#101).

## Decision

**(a) The warm moves into its own reusable workflow,
`.github/workflows/warm-cache.yml`.** `pr-review.yml` keeps no cache-writing
step at all: it restores, never saves. That includes the browser-assets step,
which was an all-in-one `actions/cache` whose post-save was likewise refused on
every comment-triggered review; it is now `actions/cache/restore`.

**(b) The caller owns the trigger, and must make it write-capable.** Consumers
add a second workflow (`claude-review-warm.yml`) on `push` to the default branch
+ a weekly `schedule` + `workflow_dispatch`. It needs no secrets.

**(c) `warm-cache.yml` asserts its caller's event before doing any work, and
fails if that event cannot write.** A warning would reproduce the original
failure mode exactly. It runs on the default branch, never as a PR check, so a
red here blocks nobody and names its own remedy.

**(d) The review job's event gate becomes an allowlist.** It previously excluded
`pull_request_target` and admitted everything else, which was safe only while
`pull_request_target` was the one other trigger consumers were told to wire.
Consumers now add write-capable triggers; under a denylist each would have
started an unasked review with no PR number.

**(e) `pr-review.yml` keeps the `dev_cache_warm_command` input, documented as
accepted-but-unused.** Removing a `workflow_call` input is a startup failure for
every caller still passing it.

## Alternatives considered

**Re-gate the job in place** — keep `warm-cache` in `pr-review.yml` and change
its `if:` to the write-capable events. Consumers would add ~4 lines of `on:`
triggers to their existing caller and no new file. Rejected: it puts a
default-branch producer and a PR-scoped consumer behind one trigger list, so
every review caller carries triggers most of its jobs must ignore, and the two
halves stay coupled through a workflow that has nothing else to do with warming.

**Delete the warm entirely.** Recovers the wasted ~460 jobs/day immediately and
needs zero consumer change, but leaves every functional review installing cold —
which is the wall-clock the feature exists to remove.

**Warm from the PR scope instead** (`pull_request`, which *can* write, to
`refs/pull/N/merge`). Rejected: that scope is visible only to re-pushes of the
same branch, so the first push of every PR pays full price and the warm cost
multiplies by PR count rather than amortising across the repo.

## Consequences

- Consumers must add one workflow file to get warm caches. Until they do,
  reviews still work — they install cold, exactly as they have all along.
  Nothing regresses, because nothing was ever warm.
- Two config sites per consumer for the `dev_cache_*` values, and `runner` must
  match on both sides (keys are scoped by `runner.os` **and** `runner.arch`).
  `tests/warm_cache_wiring_test.sh` asserts the agreement for this repo's own
  callers; consumers get the constraint in `prompts/setup-review.md` Step 5's
  checklist.
- The `alert-cache-write-denied` volume in Panenco/github-action-runners should
  drop close to zero once consumers roll out; its threshold was raised to 60 as
  a stopgap in that repo's PR #139 and can come back down afterwards.
- A consumer that wires the warm to a read-only trigger gets a red workflow on
  its default branch rather than a green one that stores nothing. That is the
  intended trade.
