#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): explicit exits on every path instead.

# require-review-json.sh — Claude Code `Stop` hook for the review orchestrator.
# Refuses to let the session end while /tmp/review.json is missing or invalid.
#
# WHY THIS IS A HOOK AND NOT ANOTHER PROMPT LINE.
# `skills/review-orchestrator.md` has carried "Never end a turn with prose" for as
# long as it has existed, and pr-review.yml repeats it in the inline prompt. Both
# are REQUESTS, and on 2026-08-12 the model stopped honouring one. Handing the
# fleet's own CLI to claude-code-action (#86) swaps it from the action's pinned
# 2.1.175 to the runner's 2.1.233+; newer Claude Code supports backgrounded
# tasks/agents, so the orchestrator concluded it could yield and be woken, and
# ended a turn with:
#
#   "I'll pause here and wait for the background judge agents and monitor to
#    notify me of completion."
#
# A prose-only turn TERMINATES the session. No /tmp/review.json is written and
# `Post review + gate` fails. Reproduced on #86 twice (including a clean re-run)
# and on #87, against an APPROVED control run on unmodified `@v3`.
#
# THE LATENT HALF IS THE REAL REASON, though, and it is true with or without #86:
# the pool's CLI moves on EVERY job via the npm refresh (`enableClaudeCliRefresh`),
# so which affordances the orchestrator has is already non-deterministic today. A
# rule that holds only while the CLI happens to lack background agents is not a
# rule. This makes the harness enforce what the prompt could only ask for.
#
# CONTRACT — VERIFIED AGAINST THE CLI, NOT THE DOCS, BECAUSE THE DOCS ARE WRONG
# HERE. code.claude.com/docs/en/hooks documents the block decision as nested under
# `hookSpecificOutput`. It is not read there for `Stop`. Measured against the real
# CLI (2.1.234) by registering a hook that blocks once and counting invocations:
#
#   {"hookSpecificOutput":{...,"decision":"block",...}}  -> 1 call, session ENDED
#   {"decision":"block","reason":"..."}                  -> 2 calls, session CONTINUED
#   reason on stderr + exit 2                            -> 2 calls, session CONTINUED
#
# The nested form fails OPEN and silently enforces nothing, which is the worst
# possible failure for this script — it would look installed and do nothing.
#
# So the block is emitted BOTH ways on purpose: top-level `decision`/`reason` on
# stdout AND the reason on stderr with exit 2. Either mechanism alone blocks on
# 2.1.234; together they survive the CLI moving under us, which it does on every
# job via the npm refresh. The combination was verified too (2 calls, continued).
#
# Allowing the stop is exit 0 with no stdout. `Stop` takes no matcher — it always
# fires.
#
# Env overrides exist for the fixture test: REVIEW_JSON, STOP_BLOCK_COUNTER,
# MAX_STOP_BLOCKS.

REVIEW_JSON="${REVIEW_JSON:-/tmp/review.json}"
COUNTER="${STOP_BLOCK_COUNTER:-/tmp/review-stop-blocks}"
MAX_BLOCKS="${MAX_STOP_BLOCKS:-3}"

# Drain stdin. The event payload is not needed to decide — the artifact on disk is
# the only thing that says whether this review produced anything — but leaving the
# pipe unread risks EPIPE on the caller.
cat >/dev/null 2>&1

# The artifact must be present AND parseable. A half-written file is the failure
# this hook is here to catch, so `-f` alone would let exactly the wrong case
# through; post-review.sh validates the same way.
if [ -f "$REVIEW_JSON" ] && jq empty "$REVIEW_JSON" >/dev/null 2>&1; then
  exit 0
fi

# BOUNDED, AND FAIL-OPEN ON PURPOSE. Blocking forever would burn the whole
# `--max-turns 100` budget and turn a recoverable stall into a timeout with no
# review and no banner. After MAX_BLOCKS nudges we let the session end so
# post-review.sh reaches its existing crash path, which PATCHes a visible
# "Claude Review — incomplete" banner onto the PR. A loud crash beats a silent
# 100-turn spin.
blocks=0
if [ -f "$COUNTER" ]; then
  blocks=$(cat "$COUNTER" 2>/dev/null)
fi
case "$blocks" in
  '' | *[!0-9]*) blocks=0 ;;
esac

if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
  echo "require-review-json: $REVIEW_JSON still missing after $blocks nudges — allowing exit so the pipeline reports a crash rather than spinning." >&2
  exit 0
fi

printf '%s' "$((blocks + 1))" > "$COUNTER" 2>/dev/null

# The reason is fed back to the model as its next input, so it is written as an
# instruction, not a complaint — and it names the specific wrong move observed,
# because "keep going" alone is what the prompt already said.
REASON="STOP BLOCKED: ${REVIEW_JSON} does not exist yet, so ending now would crash the pipeline with no review posted.

Do NOT yield to wait for background agents. There is no notification that will wake you — a message without tool calls ends the session permanently.

If you are waiting on Task results, poll them with a tool call instead:
  ls -la /tmp/scan.json /tmp/verify.json /tmp/functional.json 2>/dev/null

If the results you need are already there, continue the phase. If they are not going to arrive, write a DEGRADED ${REVIEW_JSON} now from what you do have and validate it with \`jq empty\` — a degraded review is a successful pipeline run; no file is a crash."

# Both channels — see the CONTRACT note above. Top-level keys, NOT nested under
# hookSpecificOutput: the nested form parses fine and blocks nothing.
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
printf '%s\n' "$REASON" >&2
exit 2
