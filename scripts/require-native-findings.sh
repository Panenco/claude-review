#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): explicit exits on every path instead.

# require-native-findings.sh — Claude Code `SubagentStop` hook for the
# `review-native` pass. Refuses to let that subagent end while
# /tmp/native-findings.json is missing, unparseable, or left over from a
# DIFFERENT PR.
#
# THE FAILURE THIS EXISTS FOR. On the dogfood run of the in-session native pass,
# the `review-native` subagent "got stuck waiting on its own already-completed
# subagents and never produced real output" — it concluded it could yield and be
# woken. That is the SAME root cause as #86, one level down: the plugin prompt it
# follows fans out to ~10 Task subagents, and a newer CLI makes "I'll wait for
# them" look like a legal move. It is not: a message without tool calls ends the
# agent permanently, and the orchestrator then reads a file that was never
# written. `skills/review-native.md` carries anti-yield discipline in prose, and
# prose is what stopped working on 2026-08-12. This is the enforcement.
#
# CONTRACT. Modelled on `scripts/require-review-json.sh`, whose block shape was
# MEASURED against the real CLI (2.1.234) rather than taken from the docs: the
# documented `hookSpecificOutput` nesting is NOT read for stop-class events and
# fails OPEN. So the block is emitted BOTH ways on purpose — top-level
# `{"decision":"block","reason":…}` on stdout AND the reason on stderr with exit
# 2. Read that script's CONTRACT note for the full measurement. The measurement
# was taken for `Stop`; `SubagentStop` shares its handler shape, but this
# specific event was NOT re-measured — which is exactly why both channels are
# emitted here rather than one.
#
# WHICH SUBAGENT AM I? `SubagentStop` takes no matcher — it fires when ANY
# subagent finishes, including the context builder, both judges and the
# functional tester. Blocking one of those over a file it was never asked to
# write would be worse than the bug this fixes, so identification FAILS OPEN:
# unless there is positive evidence that the finishing subagent is the native
# pass, the stop is allowed. Evidence = the event payload (and the transcript it
# points at, when readable) mentions `review-native` AND mentions none of the
# other review skills. That second half is the important one: if a future CLI
# points `transcript_path` at the PARENT session instead of the subagent's, the
# parent transcript mentions every skill, the exclusion fires, and this hook
# degrades to a no-op instead of nudging judges to write a native findings file.
#
# Env overrides exist for the fixture test: NATIVE_FINDINGS_JSON,
# NATIVE_STOP_BLOCK_COUNTER, MAX_NATIVE_STOP_BLOCKS, PR_NUMBER.

NATIVE_JSON="${NATIVE_FINDINGS_JSON:-/tmp/native-findings.json}"
COUNTER="${NATIVE_STOP_BLOCK_COUNTER:-/tmp/native-stop-blocks}"
MAX_BLOCKS="${MAX_NATIVE_STOP_BLOCKS:-3}"
PR="${PR_NUMBER:-}"

# Drain stdin — the payload IS needed here (unlike the Stop hook) to tell which
# subagent finished, but it must be consumed either way or the caller can EPIPE.
PAYLOAD=$(cat 2>/dev/null)

# ── Identification (fail-open) ─────────────────────────────────────────────
HAYSTACK="$PAYLOAD"
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  HAYSTACK="$HAYSTACK
$(cat "$TRANSCRIPT" 2>/dev/null)"
fi

case "$HAYSTACK" in
  *review-native*) ;;
  *) exit 0 ;;   # no evidence this is the native pass — never block a stranger
esac
case "$HAYSTACK" in
  # Any other review skill in the same transcript means we are looking at the
  # parent session (or some other agent), not the native pass. Fail open.
  *review-judge*|*review-functional-tester*|*review-context-builder*|*review-orchestrator*) exit 0 ;;
esac

# ── Is the artifact actually there, parseable, and THIS PR's? ──────────────
# `-f` alone would pass a truncated write, which is precisely the bad case.
# The PR check is the stale-file guard: self-hosted runners are reused, and a
# leftover /tmp/native-findings.json from a previous PR would otherwise be read
# by Phase D as this PR's second opinion — another PR's findings posted onto
# this one.
ok=no
if [ -f "$NATIVE_JSON" ] && jq empty "$NATIVE_JSON" >/dev/null 2>&1; then
  if [ -z "$PR" ]; then
    ok=yes
  elif [ "$(jq -r '.pr_number // "" | tostring' "$NATIVE_JSON" 2>/dev/null)" = "$PR" ]; then
    ok=yes
  fi
fi
[ "$ok" = "yes" ] && exit 0

# BOUNDED, AND FAIL-OPEN ON PURPOSE. Blocking forever would burn the session's
# turn budget and turn a recoverable stall into a timeout with no review at all.
# After MAX_BLOCKS nudges we let the subagent end; the orchestrator already
# treats a missing/unparseable native file as a silent no-op, so the review still
# ships — just without the second opinion.
blocks=0
if [ -f "$COUNTER" ]; then
  blocks=$(cat "$COUNTER" 2>/dev/null)
fi
case "$blocks" in
  '' | *[!0-9]*) blocks=0 ;;
esac

if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
  echo "require-native-findings: $NATIVE_JSON still missing after $blocks nudges — allowing exit; the orchestrator degrades to no second opinion." >&2
  exit 0
fi

printf '%s' "$((blocks + 1))" > "$COUNTER" 2>/dev/null

REASON="SUBAGENT STOP BLOCKED: ${NATIVE_JSON} is missing, unparseable, or carries a different pr_number, so the orchestrator would get no second opinion from this pass.

Do NOT yield to wait for the plugin's reviewer subagents. There is no notification that will wake you — a message without tool calls ends this agent permanently, and its results are discarded.

If you are waiting on Task results, they have already returned: use what you have. Poll with a tool call instead of ending the turn:
  ls -la /tmp/native-*.json 2>/dev/null

Write ${NATIVE_JSON} NOW from whatever you have — it MUST include \"pr_number\": ${PR:-the number of the PR under review} and a \"status\" of \"ok\", \"skipped\" or \"unavailable\" — then validate it with \`jq empty ${NATIVE_JSON}\`. A partial, honest file is a successful pass; no file throws away everything you already did."

# Both channels — see the CONTRACT note above. Top-level keys, NOT nested under
# hookSpecificOutput: the nested form parses fine and blocks nothing.
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'
printf '%s\n' "$REASON" >&2
exit 2
