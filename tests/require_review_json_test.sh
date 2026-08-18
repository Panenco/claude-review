#!/usr/bin/env bash
set -uo pipefail

# require_review_json_test.sh — fixture test for scripts/require-review-json.sh.
#
# The script is a Claude Code `Stop` hook: it decides whether the review
# orchestrator is allowed to end its session. Allowed = exit 0 with no stdout.
# Refused = exit 0 with a JSON block decision on stdout.
#
# The regression this file exists for (#86, 2026-08-12): handing the fleet's
# newer CLI to claude-code-action gave the orchestrator backgrounded agents, so
# it ended a turn with "I'll pause here and wait for the background judge
# agents..." — prose only, session over, no /tmp/review.json, pipeline crash.
# The prompt already forbade exactly that. A request is not an enforcement, so
# the assertion here is that the HOOK refuses, not that the prompt asks.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/scripts/require-review-json.sh"
ORCHESTRATOR="$ROOT/skills/review-orchestrator.md"
WORKFLOW="$ROOT/.github/workflows/pr-review.yml"
ACTION="$ROOT/action.yml"
fail=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A representative Stop payload. The hook ignores the body and looks at disk, but
# feeding the real shape keeps the test honest if that ever changes.
EVENT='{"session_id":"abc123","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"I will pause here and wait for the background judge agents."}'

# run <review-json-path> <counter-path> [max] → sets OUT and RC.
# NOT `run ...`: command substitution runs in a subshell, so an RC set
# inside it never reaches the caller. Capture via a file and assign in-process.
run() {
  REVIEW_JSON="$1" STOP_BLOCK_COUNTER="$2" MAX_STOP_BLOCKS="${3:-3}" \
    bash "$HOOK" <<<"$EVENT" >"$WORK/out" 2>/dev/null
  RC=$?
  OUT=$(cat "$WORK/out")
}

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   — $1"
  else
    echo "FAIL — $1: expected [$2], got [$3]"
    fail=1
  fi
}

# --- 1. missing artifact → refuse the stop ---------------------------------
run "$WORK/missing.json" "$WORK/c1"
check "missing review.json blocks the stop" "block" \
  "$(jq -r '.hookSpecificOutput.decision' <<<"$OUT" 2>/dev/null)"
check "missing review.json exits 0 (block is via JSON, not exit code)" "0" "$RC"
check "block names the artifact" "yes" \
  "$(grep -q '/missing.json' <<<"$OUT" && echo yes || echo no)"

# The reason must actively counter the observed failure, not just say "continue".
check "reason forbids yielding for background agents" "yes" \
  "$(jq -r '.hookSpecificOutput.reason' <<<"$OUT" | grep -qi 'do not yield' && echo yes || echo no)"
check "reason offers the degraded-write escape hatch" "yes" \
  "$(jq -r '.hookSpecificOutput.reason' <<<"$OUT" | grep -qi 'degraded' && echo yes || echo no)"

# --- 2. valid artifact → allow the stop ------------------------------------
echo '{"verdict":"APPROVE","findings":[]}' > "$WORK/good.json"
run "$WORK/good.json" "$WORK/c2"
check "valid review.json allows the stop (no stdout)" "" "$OUT"
check "valid review.json exits 0" "0" "$RC"

# --- 3. malformed artifact → refuse ----------------------------------------
# `-f` alone would pass a truncated write, which is precisely the bad case.
printf '{"verdict":"APPROVE",' > "$WORK/truncated.json"
run "$WORK/truncated.json" "$WORK/c3"
check "truncated review.json blocks the stop" "block" \
  "$(jq -r '.hookSpecificOutput.decision' <<<"$OUT" 2>/dev/null)"

# --- 4. bounded: stops nudging after MAX_STOP_BLOCKS ------------------------
# Blocking forever would burn --max-turns and produce no review AND no banner.
C="$WORK/c4"
for i in 1 2; do run "$WORK/missing.json" "$C" 2; done
check "counter reached the cap" "2" "$(cat "$C")"
run "$WORK/missing.json" "$C" 2
check "past the cap the stop is ALLOWED (fail-open to the crash banner)" "" "$OUT"
check "past the cap exits 0" "0" "$RC"

# --- 5. wiring: the hook is actually reachable in the pipeline --------------
# A perfect hook that nothing registers is the failure mode this repo has hit
# before (github-action-runners: a values file, a config and an image, and no
# listener). Assert the pipeline installs and points at it.
check "workflow registers a Stop hook" "yes" \
  "$(grep -q '\.hooks\.Stop' "$WORKFLOW" && echo yes || echo no)"
check "workflow points the hook at require-review-json.sh" "yes" \
  "$(grep -q 'require-review-json.sh' "$WORKFLOW" && echo yes || echo no)"
check "settings land in the USER scope, which --setting-sources user reads" "yes" \
  "$(grep -q 'HOME/.claude/settings.json' "$WORKFLOW" && echo yes || echo no)"
check "action.yml completeness check covers the new script" "yes" \
  "$(grep -q 'require-review-json.sh' "$ACTION" && echo yes || echo no)"
check "orchestrator skill records that the rule is enforced" "yes" \
  "$(grep -qiE 'Stop.{0,2} hook' "$ORCHESTRATOR" && echo yes || echo no)"

# Grepping the YAML only proves the text is present. Run the workflow's ACTUAL
# merge expression against fixtures and assert the resulting settings.json
# matches the documented Stop contract — and that it preserves what was already
# there, since the runner image may ship its own user settings.
MERGE='.hooks.Stop = [{"hooks": [{"type": "command", "command": $cmd}]}]'
echo '{"model":"pre-existing","hooks":{"PreToolUse":[{"x":1}]}}' > "$WORK/settings.json"
jq --arg cmd "/pipeline/scripts/require-review-json.sh" "$MERGE" \
  "$WORK/settings.json" > "$WORK/merged.json" 2>/dev/null
check "merge yields a Stop entry with a command hook" "command" \
  "$(jq -r '.hooks.Stop[0].hooks[0].type' "$WORK/merged.json" 2>/dev/null)"
check "merge points that command at the hook script" "/pipeline/scripts/require-review-json.sh" \
  "$(jq -r '.hooks.Stop[0].hooks[0].command' "$WORK/merged.json" 2>/dev/null)"
check "merge preserves unrelated existing settings" "pre-existing" \
  "$(jq -r '.model' "$WORK/merged.json" 2>/dev/null)"
check "merge preserves other existing hooks" "1" \
  "$(jq -r '.hooks.PreToolUse[0].x' "$WORK/merged.json" 2>/dev/null)"

# --- 6. the hook itself obeys the repo's shell rule -------------------------
check "hook does not use set -e (bugbot.md)" "yes" \
  "$(grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$HOOK" && echo no || echo yes)"

exit $fail
