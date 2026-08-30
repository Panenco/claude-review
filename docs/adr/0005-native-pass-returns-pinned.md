---
status: accepted
date: 2026-08-30
amends: 0004
---

# 0005 — The native pass returns, pinned by a vendored checkout

## Context

ADR 0004 deleted the `/review native` pass along with the judge panel it
second-guessed. Two reasons were given, and they are not equally strong.

The first was **cost and redundancy**: a third opinion on top of scan + verify
bought signal the pipeline could already produce. That is a judgement call, and
it is contested — the pass has a concrete track record on `Panenco/hr4cast`
(a missing `if (!userId)` authz guard, a Postgres privilege regression,
silently removed abuse limits, a deploy-breaking unique migration), all found
where the bespoke reviewer walked past. It fails *differently*, which is the
only thing a second opinion is for.

The second was **supply chain, and it was the load-bearing one**. Running the
pass required `plugin_marketplaces` pointing at
`https://github.com/anthropics/claude-plugins-public.git` — an unpinned live
git ref, and the only third-party reference in `pr-review.yml` that was not
SHA-pinned. `bugbot.md` recorded its removal as a *resolved* exposure. Whatever
one thinks of the cost argument, re-adding an unpinnable marketplace to a job
holding `contents: write` + `pull-requests: write` was not acceptable, and
"accepted trade-off" had already been tried once.

The workflow comment deleted in 0004 documented, correctly and in detail, why
it could not be pinned. Every claim in it was verified and every claim was
true — of the **URL form**:

- `MARKETPLACE_URL_REGEX` in the action's `install-plugins.ts` is anchored
  `/^https:\/\/[…]+\.git$/`, so `…public.git@<sha>`, `…public.git#<ref>` and
  `…public.git?ref=` all fail validation.
- `addMarketplace()` shells out to exactly `claude plugin marketplace add <url>`
  and the action exposes no ref input.
- Claude Code's docs state git-based *marketplace* sources support `ref`
  (branch/tag) but not `sha`; only *plugin* sources take a `sha`.
- `anthropics/claude-plugins-public` publishes no tags and no releases, so even
  `ref` would only buy another moving pointer.

What that analysis never asked was whether the marketplace had to be a URL at
all.

## Decision

**The pass comes back, opt-in, with the marketplace vendored at a pinned commit
SHA and installed from a local path.**

```
actions/checkout (repository: anthropics/claude-plugins-public, ref: <40-hex SHA>, sparse)
   -> rewrite the catalog to the single `code-review` entry
   -> plugin_marketplaces: <workspace>/__claude-plugins-marketplace   (a PATH)
   -> plugins: code-review@pinned-upstream-review
```

Three facts make it work, each verified rather than assumed:

- **`actions/checkout` takes `repository:` + `ref:`, and `ref:` accepts a full
  commit SHA.** That is the pin, and it is the *same* mechanism as every other
  third-party pin in `pr-review.yml` — not a weaker substitute.
- **claude-code-action accepts a path here, not only a URL.** In
  `base-action/src/install-plugins.ts` at the action SHA the workflow already
  pins (`ac7e24bf`), `isLocalPath()` returns true for `/`, `./` and `../`, and
  `validateMarketplaceInput()` then returns early — *"Local paths are passed
  directly to Claude Code which handles them"* — never reaching the URL regex
  that rejected every ref suffix.
- **A directory marketplace is first-class in the CLI.** `claude plugin
  marketplace add --help` (2.1.251): *"Add a marketplace from a URL, path, or
  GitHub repo"*. It is recorded in settings.json as
  `{"source":"directory","path":…}`.

And the pin reaches all the way down: `code-review`'s catalog entry is
`"source": "./plugins/code-review"` — a path *inside* the tree just checked out
— so the prompt that runs is exactly the prompt at that SHA. No sibling
plugin's third-party `git-subdir` source is ever resolved, because the
rewritten catalog lists one plugin and nothing else.

**The catalog must be rewritten, and that is a CLI constraint, not a
preference.** The upstream name `claude-plugins-official` is reserved: a
directory source claiming it is refused with *"The name … is reserved for
official Anthropic marketplaces and can only be used with GitHub sources from
the 'anthropics' organization"*, and any lookalike name is refused with
*"Marketplace name impersonates an official Anthropic/Claude marketplace"*.
So the vendored **catalog** is renamed to `pinned-upstream-review` and cut to
one entry. The **plugin's own files are never touched** — only the index that
points at them.

**The pass is advisory, opt-in, and fails soft.** `/review native` (or
`/review all`) turns it on; nothing else does. Both vendoring steps are
`continue-on-error`, and the action inputs are gated on their success, so a
marketplace that will not resolve costs the PR a second opinion and nothing
else. Its findings are **candidates**: `review-verify` refutes them at exactly
the bar it holds `review-scan`'s to, with no deference for their authorship,
and deduplicates them against scan keeping scan's wording. The review still
speaks with one voice and still posts exactly one comment.

## Consequences

- `bugbot.md`'s resolved-exposure paragraph is **restated, not deleted**. The
  history stays; what changed is that the exposure is now closed by a pin
  rather than by absence. The invariant it protects is unchanged and still
  absolute: every third-party reference in `pr-review.yml` is SHA-pinned, and a
  new unpinned one IS a finding — including any change that puts an `https://…`
  back into `plugin_marketplaces` or swaps the checkout's 40-hex `ref:` for a
  branch or tag.
- `model_standard` and `native_review_scope` are **live inputs again**. They
  had been kept as deprecated no-ops only because a reusable workflow errors on
  an undefined input; callers that still pass them now get what they always
  meant.
- `skills/review-native.md` and `agents/review-native.md` return, adapted to
  v4: they write `/tmp/native.json` in `review-scan`'s finding shape, and
  `review-verify` is their only consumer. Every finding must carry a
  `failure_scenario` — the v4 bar, which the plugin's own rubric does not
  impose.
- **`scripts/require-native-findings.sh` does NOT return.** The v3 `SubagentStop`
  hook that enforced the output file was itself a source of bugs (it could
  self-disable), and the pass no longer needs it: a missing `/tmp/native.json`
  is a silent no-op, exactly like a missing `/tmp/functional.json`. Advisory
  passes degrade; they do not get enforcement machinery.
- The `native` removal notice is gone from `review-command.sh`, so no token
  emits a `message` on a proceeding run today. The workflow step that posts one
  **stays wired** — the menu step is gated on the run *not* proceeding, so a
  notice attached to a proceeding run has no other way out, and deleting the
  step is how that notice was once rendered and never posted.
- Bumping the pinned SHA is an ordinary dependency bump: change it, re-run.
- What would make this fail: upstream restructuring the repo so
  `plugins/code-review/commands/code-review.md` moves. That is a soft failure
  (the skill writes `status: "unavailable"`), and the sparse-checkout paths and
  the pin are the two places to fix it.
