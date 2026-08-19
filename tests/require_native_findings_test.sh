#!/usr/bin/env bash
set -uo pipefail

# require_native_findings_test.sh — fixture test for
# scripts/require-native-findings.sh.
#
# The script is a Claude Code `SubagentStop` hook: it decides whether the
# `review-native` subagent is allowed to finish. Allowed = exit 0 with no stdout.
# Refused = a TOP-LEVEL {"decision":"block","reason":...} on stdout AND the reason
# on stderr AND exit 2 — the same two independent block channels as
# `require-review-json.sh`, whose Stop-event measurement showed the DOCUMENTED
# `hookSpecificOutput` nesting fails OPEN.
#
# The regression this file exists for: on the first dogfood run of the in-session
# native pass, the subagent "got stuck waiting on its own already-completed
# subagents and never produced real output" — the #86 failure one level down. The
# skill already forbids it in prose. A request is not an enforcement.
#
# The OTHER half of the contract is just as important and is asserted just as
# hard: `SubagentStop` takes no matcher, so this hook fires for the context
# builder, both judges and the functional tester too. Blocking one of THOSE over
# a file it was never asked to write would be worse than the bug. Identification
# therefore FAILS OPEN, and the tests below pin that.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/scripts/require-native-findings.sh"
SKILL="$ROOT/skills/review-native.md"
ORCHESTRATOR="$ROOT/skills/review-orchestrator.md"
WORKFLOW="$ROOT/.github/workflows/pr-review.yml"
ACTION="$ROOT/action.yml"
fail=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   — $1"
  else
    echo "FAIL — $1: expected [$2], got [$3]"
    fail=1
  fi
}

# event <transcript-path> → a representative SubagentStop payload.
event() {
  jq -nc --arg t "$1" \
    '{session_id:"abc123", hook_event_name:"SubagentStop", stop_hook_active:false, transcript_path:$t}'
}

# run <findings-path> <counter-path> <transcript-path> [pr] [max] → OUT, ERR, RC.
# NOT `out=$(run …)`: command substitution runs in a subshell, so an RC set inside
# it never reaches the caller. Capture via files and assign in-process.
run() {
  NATIVE_FINDINGS_JSON="$1" NATIVE_STOP_BLOCK_COUNTER="$2" \
  PR_NUMBER="${4:-7}" MAX_NATIVE_STOP_BLOCKS="${5:-3}" \
    bash "$HOOK" <<<"$(event "$3")" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
}

# Transcripts. The native pass's own transcript names only its skill; every other
# subagent's names its own; a PARENT-session transcript names them all, which is
# the shape that would appear if a future CLI pointed transcript_path at the
# parent instead of the subagent.
printf 'Read /pipeline/skills/review-native.md and follow it exactly.\n' > "$WORK/t-native.jsonl"
printf 'Read /pipeline/skills/review-judge.md and follow it exactly.\n' > "$WORK/t-judge.jsonl"
printf 'Read /pipeline/skills/review-functional-tester.md.\n' > "$WORK/t-tester.jsonl"
printf 'Read /pipeline/skills/review-context-builder.md.\n' > "$WORK/t-cb.jsonl"
printf 'review-orchestrator dispatches review-native, review-judge and review-functional-tester.\n' \
  > "$WORK/t-parent.jsonl"

MISSING="$WORK/missing.json"

# --- 1. identification fails OPEN for every other subagent ------------------
# These all run with NO findings file on disk — the ONLY thing keeping them from
# being blocked is that the hook cannot positively identify them as the native
# pass. A regression here nudges judges to write a file they know nothing about.
for who in judge tester cb parent; do
  run "$MISSING" "$WORK/c-$who" "$WORK/t-$who.jsonl"
  check "a '$who' transcript is NEVER blocked (no stdout)" "" "$OUT"
  check "a '$who' transcript exits 0" "0" "$RC"
done
run "$MISSING" "$WORK/c-none" "$WORK/does-not-exist.jsonl"
check "an unreadable/absent transcript fails open" "0" "$RC"

# --- 2. the native pass with no artifact → refuse the stop ------------------
# SCHEMA REGRESSION GUARD, inherited from require-review-json.sh: the block must
# be TOP-LEVEL. The `hookSpecificOutput` nesting the docs show is not read for
# stop-class events — it parses fine and enforces nothing, which is the worst
# possible failure for a hook.
run "$MISSING" "$WORK/c1" "$WORK/t-native.jsonl"
check "missing native-findings blocks via TOP-LEVEL decision" "block" \
  "$(jq -r '.decision' <<<"$OUT" 2>/dev/null)"
check "block decision is NOT nested under hookSpecificOutput (fails open)" "null" \
  "$(jq -r '.hookSpecificOutput.decision // "null"' <<<"$OUT" 2>/dev/null)"
check "missing native-findings exits 2 (the second, independent block channel)" "2" "$RC"
check "reason is also on stderr, which is what exit 2 feeds back" "yes" \
  "$(grep -q 'SUBAGENT STOP BLOCKED' <<<"$ERR" && echo yes || echo no)"
check "reason forbids yielding for the plugin's subagents" "yes" \
  "$(jq -r '.reason' <<<"$OUT" | grep -qi 'do not yield' && echo yes || echo no)"
check "reason names the pr_number requirement" "yes" \
  "$(jq -r '.reason' <<<"$OUT" | grep -q 'pr_number' && echo yes || echo no)"

# --- 3. a valid artifact for THIS PR → allow -------------------------------
GOOD="$WORK/good.json"
echo '{"status":"ok","pr_number":7,"summary":"s","findings":[]}' > "$GOOD"
run "$GOOD" "$WORK/c2" "$WORK/t-native.jsonl"
check "valid native-findings allows the stop (no stdout)" "" "$OUT"
check "valid native-findings exits 0" "0" "$RC"

# --- 4. STALE FILE FROM ANOTHER PR → refuse --------------------------------
# Self-hosted runners are reused and /tmp survives between jobs. A leftover file
# would otherwise be read by Phase D as this PR's second opinion — another PR's
# findings posted as inline comments here.
STALE="$WORK/stale.json"
echo '{"status":"ok","pr_number":99,"summary":"other PR","findings":[{"id":"n1"}]}' > "$STALE"
run "$STALE" "$WORK/c3" "$WORK/t-native.jsonl" 7
check "another PR's findings file blocks the stop" "block" \
  "$(jq -r '.decision' <<<"$OUT" 2>/dev/null)"
check "stale-PR file exits 2" "2" "$RC"

NOPR="$WORK/nopr.json"
echo '{"status":"skipped","summary":"no pr_number at all","findings":[]}' > "$NOPR"
run "$NOPR" "$WORK/c4" "$WORK/t-native.jsonl" 7
check "a file WITHOUT pr_number is treated as stale" "block" \
  "$(jq -r '.decision' <<<"$OUT" 2>/dev/null)"

# --- 5. malformed artifact → refuse ----------------------------------------
# `-f` alone would pass a truncated write, which is precisely the bad case.
TRUNC="$WORK/truncated.json"
printf '{"status":"ok","pr_number":7,' > "$TRUNC"
run "$TRUNC" "$WORK/c5" "$WORK/t-native.jsonl"
check "truncated native-findings blocks the stop" "block" \
  "$(jq -r '.decision' <<<"$OUT" 2>/dev/null)"
check "truncated native-findings also exits 2" "2" "$RC"

# --- 6. bounded: stops nudging after MAX_NATIVE_STOP_BLOCKS ----------------
# Blocking forever would burn the session's turn budget. The orchestrator already
# degrades silently on a missing native file, so failing open here costs the
# second opinion and nothing else.
C="$WORK/c6"
for _ in 1 2; do run "$MISSING" "$C" "$WORK/t-native.jsonl" 7 2; done
check "counter reached the cap" "2" "$(cat "$C")"
run "$MISSING" "$C" "$WORK/t-native.jsonl" 7 2
check "past the cap the stop is ALLOWED (fail-open, review still ships)" "" "$OUT"
check "past the cap exits 0" "0" "$RC"

# --- 7. wiring: the hook is actually reachable in the pipeline -------------
# A perfect hook that nothing registers is a failure mode this repo has hit
# before. Assert the pipeline installs and points at it.
check "workflow registers a SubagentStop hook" "yes" \
  "$(grep -q '\.hooks\.SubagentStop' "$WORKFLOW" && echo yes || echo no)"
check "workflow points that hook at require-native-findings.sh" "yes" \
  "$(grep -q 'require-native-findings.sh' "$WORKFLOW" && echo yes || echo no)"
check "workflow clears a stale native-findings file before the run" "yes" \
  "$(grep -q '/tmp/native-findings.json' "$WORKFLOW" && echo yes || echo no)"
check "workflow clears the stale nudge counter too" "yes" \
  "$(grep -q '/tmp/native-stop-blocks' "$WORKFLOW" && echo yes || echo no)"
check "action.yml completeness check covers the new script" "yes" \
  "$(grep -q 'require-native-findings.sh' "$ACTION" && echo yes || echo no)"
check "the native skill records that the rule is enforced" "yes" \
  "$(grep -qi 'SubagentStop' "$SKILL" && echo yes || echo no)"
check "the native skill carries explicit anti-yield discipline" "yes" \
  "$(grep -qi 'Never end a turn with prose' "$SKILL" && echo yes || echo no)"
check "the native skill mandates pr_number on the output" "yes" \
  "$(grep -q 'pr_number' "$SKILL" && echo yes || echo no)"
check "the orchestrator rejects a mismatched pr_number in Phase D" "yes" \
  "$(grep -q 'pr_number' "$ORCHESTRATOR" && echo yes || echo no)"

# Grepping the YAML only proves the text is present. Run the workflow's ACTUAL
# merge expression against fixtures and assert BOTH hooks land, and that what was
# already in the user settings survives.
MERGE='.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd}]}]
       | .hooks.SubagentStop = [{"hooks": [{"type": "command", "command": $sub}]}]'
echo '{"model":"pre-existing","hooks":{"PreToolUse":[{"x":1}]}}' > "$WORK/settings.json"
jq --arg cmd "/pipeline/scripts/require-review-json.sh" \
   --arg sub "/pipeline/scripts/require-native-findings.sh" "$MERGE" \
  "$WORK/settings.json" > "$WORK/merged.json" 2>/dev/null
check "merge points SubagentStop at the hook script" "/pipeline/scripts/require-native-findings.sh" \
  "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$WORK/merged.json" 2>/dev/null)"
check "merge keeps the existing Stop hook" "/pipeline/scripts/require-review-json.sh" \
  "$(jq -r '.hooks.Stop[0].hooks[0].command' "$WORK/merged.json" 2>/dev/null)"
check "merge preserves unrelated existing settings" "pre-existing" \
  "$(jq -r '.model' "$WORK/merged.json" 2>/dev/null)"
check "merge preserves other existing hooks" "1" \
  "$(jq -r '.hooks.PreToolUse[0].x' "$WORK/merged.json" 2>/dev/null)"

# --- 8. the hook itself obeys the repo's shell rule ------------------------
check "hook does not use set -e (bugbot.md)" "yes" \
  "$(grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$HOOK" && echo no || echo yes)"

exit $fail
