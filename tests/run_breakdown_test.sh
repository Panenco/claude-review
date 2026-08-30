#!/usr/bin/env bash
set -uo pipefail

# run_breakdown_test.sh — fixture test for scripts/run-breakdown.sh.
#
# The three arithmetic traps this pins, because each one silently produces a
# plausible-looking table rather than an error:
#
#  1. DUPLICATE ASSISTANT ENTRIES. The stream emits one entry per content block
#     and every one of them repeats the SAME message.usage. Summing them made
#     one measured run's input side ~40% too high, which moved the biggest
#     spender in the table. Deduping is by message.id.
#  2. THE PLACEHOLDER OUTPUT COUNT. An assistant entry's output_tokens comes
#     from message_start and is 1-17, not the real count. Reading it as truth
#     under-reports output by ~99% — output has to come from the result entry's
#     modelUsage, and the top-level session's exact figures from result.usage.
#  3. HIDDEN SUBAGENTS. The native pass's plugin fans out to its own agents
#     whose messages some runs never carry. Their spend is real and is in
#     modelUsage, so the shortfall must land on the stage that owns them —
#     never smeared across the stages that happen to share the model.
#
# Everything here is fixtures: no gh, no network, no model.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/run-breakdown.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
fail=0

ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label — want '$want', got '$got'"; fi
}
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) ok "$label" ;; *) bad "$label — expected to find '$needle'" ;; esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# field <stage> <key> — pull one number out of the --json breakdown in $JSON.
field() {
  printf '%s' "$JSON" | jq -r --arg s "$1" --arg k "$2" '.stages[] | select(.stage == $s) | .[$k]'
}

run_bd() {
  OUT=$(bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture A — one orchestrator, one review-scan, one duplicated message.
#
# review-scan's second entry repeats message id m2 with a different content
# block. Counted twice its cache-read reads 400000 and its cost lands at
# $0.23; counted once the table says 200000 and $0.13126.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$WORK/a.json" <<'JSON'
[
  {"type":"system","subtype":"init","model":"claude-opus-5"},
  {"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{
     "id":"m1","model":"claude-opus-5","role":"assistant",
     "content":[{"type":"tool_use","id":"t_scan","name":"Agent",
                 "input":{"subagent_type":"review-scan","prompt":"scan it"}}],
     "usage":{"input_tokens":1,"cache_read_input_tokens":1000,"output_tokens":2,
              "cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}},
  {"type":"assistant","parent_tool_use_id":"t_scan","timestamp":"2026-01-01T00:01:00.000Z","message":{
     "id":"m2","model":"claude-opus-5","role":"assistant",
     "content":[{"type":"text","text":"looking"}],
     "usage":{"input_tokens":2,"cache_read_input_tokens":200000,"output_tokens":1,
              "cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0}}}},
  {"type":"assistant","parent_tool_use_id":"t_scan","timestamp":"2026-01-01T00:01:01.000Z","message":{
     "id":"m2","model":"claude-opus-5","role":"assistant",
     "content":[{"type":"tool_use","id":"t_b1","name":"Bash","input":{"command":"ls"}}],
     "usage":{"input_tokens":2,"cache_read_input_tokens":200000,"output_tokens":1,
              "cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0}}}},
  {"type":"result","subtype":"success","total_cost_usd":0.14691,
   "usage":{"input_tokens":5,"cache_read_input_tokens":5000,"output_tokens":400,
            "cache_creation":{"ephemeral_5m_input_tokens":500,"ephemeral_1h_input_tokens":0}},
   "modelUsage":{"claude-opus-5":{"inputTokens":7,"outputTokens":1400,
                 "cacheReadInputTokens":205000,"cacheCreationInputTokens":1500,"costUSD":0.14691}}}
]
JSON

run_bd --transcript "$WORK/a.json" --json
assert_eq "A: exits 0" 0 "$RC"
JSON="$OUT"
assert_eq "A: scan cache-read deduped by message.id" 200000 "$(field review-scan cr)"
assert_eq "A: scan counted as one API call, not two"       1 "$(field review-scan calls)"
assert_eq "A: orchestrator output comes from result.usage, not the placeholder" 400 "$(field orchestrator out)"
assert_eq "A: orchestrator cache-read comes from result.usage"                 5000 "$(field orchestrator cr)"
# rem = modelUsage 1400 - orchestrator's known 400; scan is the only other stage
assert_eq "A: scan absorbs the whole remaining model output" 1000 "$(field review-scan out)"
assert_eq "A: scan cost priced at opus rates"    0.13126 "$(field review-scan cost)"
assert_eq "A: orchestrator cost priced at opus rates" 0.01565 "$(field orchestrator cost)"
assert_eq "A: attributed total matches the session's own figure" \
  "$(printf '%s' "$JSON" | jq -r '.reported * 100000 | round')" \
  "$(printf '%s' "$JSON" | jq -r '.attributed * 100000 | round')"
assert_eq "A: no unattributed row when the transcript is complete" \
  0 "$(printf '%s' "$JSON" | jq '[.stages[] | select(.stage == "(unattributed)")] | length')"

run_bd --transcript "$WORK/a.json"
assert_contains "A: table names the stage"      "review-scan"   "$OUT"
assert_contains "A: table prints a TOTAL row"   "TOTAL"         "$OUT"
assert_contains "A: table prints the timeline"  "Stage timeline" "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Fixture B — review-native dispatches a subagent whose messages never arrive.
#
# Sonnet's modelUsage is far larger than what review-native's own visible
# messages account for. The gap belongs to review-native, not to the
# review-functional-tester that merely shares the model.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$WORK/b.json" <<'JSON'
[
  {"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{
     "id":"m1","model":"claude-opus-5","role":"assistant",
     "content":[{"type":"tool_use","id":"t_nat","name":"Agent",
                 "input":{"subagent_type":"review-native","prompt":"second opinion"}},
                {"type":"tool_use","id":"t_fun","name":"Agent",
                 "input":{"subagent_type":"review-functional-tester","prompt":"drive it"}}],
     "usage":{"input_tokens":1,"cache_read_input_tokens":1000,"output_tokens":2,
              "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}},
  {"type":"assistant","parent_tool_use_id":"t_nat","timestamp":"2026-01-01T00:01:00.000Z","message":{
     "id":"m2","model":"claude-sonnet-5","role":"assistant",
     "content":[{"type":"tool_use","id":"t_kid","name":"Agent",
                 "input":{"subagent_type":"general-purpose","prompt":"audit"}}],
     "usage":{"input_tokens":1,"cache_read_input_tokens":100000,"output_tokens":1,
              "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}},
  {"type":"system","subtype":"task_started","task_type":"local_agent","tool_use_id":"t_kid",
   "description":"audit"},
  {"type":"assistant","parent_tool_use_id":"t_fun","timestamp":"2026-01-01T00:02:00.000Z","message":{
     "id":"m3","model":"claude-sonnet-5","role":"assistant",
     "content":[{"type":"text","text":"clicked"}],
     "usage":{"input_tokens":1,"cache_read_input_tokens":100000,"output_tokens":1,
              "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}},
  {"type":"result","subtype":"success","total_cost_usd":0.36001,
   "usage":{"input_tokens":1,"cache_read_input_tokens":1000,"output_tokens":100,
            "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}},
   "modelUsage":{
     "claude-opus-5":{"inputTokens":1,"outputTokens":100,"cacheReadInputTokens":1000,
                      "cacheCreationInputTokens":0,"costUSD":0.0030},
     "claude-sonnet-5":{"inputTokens":2,"outputTokens":2000,"cacheReadInputTokens":1000000,
                        "cacheCreationInputTokens":0,"costUSD":0.3300}}}
]
JSON

run_bd --transcript "$WORK/b.json" --json
assert_eq "B: exits 0" 0 "$RC"
JSON="$OUT"
assert_eq "B: the missing subagent is credited to its owner" \
  "review-native" "$(printf '%s' "$JSON" | jq -r '.hidden | join(",")')"
# sonnet cache-read 1000000, of which the tester's own 100000 is visible
assert_eq "B: native absorbs the sonnet cache-read shortfall" 900000 "$(field review-native cr)"
assert_eq "B: the functional tester keeps only its own"       100000 "$(field review-functional-tester cr)"
assert_eq "B: no unattributed row when the owner is unambiguous" \
  0 "$(printf '%s' "$JSON" | jq '[.stages[] | select(.stage == "(unattributed)")] | length')"

# ─────────────────────────────────────────────────────────────────────────────
# Fixture C — a model with no price. A zero would read as a free stage and
# send the optimisation at the wrong target, so it has to be an error.
# ─────────────────────────────────────────────────────────────────────────────
sed 's/claude-opus-5/claude-zeta-9/g' "$WORK/a.json" > "$WORK/c.json"
run_bd --transcript "$WORK/c.json"
assert_eq "C: an unpriced model fails"                1 "$RC"
assert_contains "C: and names the model"  "claude-zeta-9" "$OUT"
assert_contains "C: and says where to fix it" "PRICES"    "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Fixture D — workflow step timings join in when a jobs payload is given.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$WORK/jobs.json" <<'JSON'
{"jobs":[{"name":"review","steps":[
  {"name":"Checkout PR head","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:00:10Z"},
  {"name":"Review: orchestrate","startedAt":"2026-01-01T00:00:10Z","completedAt":"2026-01-01T00:01:40Z"},
  {"name":"Skipped step","startedAt":"2026-01-01T00:01:40Z","completedAt":"2026-01-01T00:01:40Z"}]}]}
JSON
run_bd --transcript "$WORK/a.json" --jobs "$WORK/jobs.json"
assert_eq "D: exits 0" 0 "$RC"
assert_contains "D: reports the job total"        "job 100s"            "$OUT"
assert_contains "D: shows the orchestrate share"  "Review: orchestrate" "$OUT"
case "$OUT" in *"Skipped step"*) bad "D: a 0s step is noise and must be dropped" ;;
               *) ok "D: a 0s step is dropped" ;; esac

# ─────────────────────────────────────────────────────────────────────────────
# Argument handling.
# ─────────────────────────────────────────────────────────────────────────────
run_bd
assert_eq "E: no arguments is a usage error"  2 "$RC"
run_bd 12345
assert_eq "E: a run id without a repo is a usage error" 2 "$RC"
run_bd --transcript "$WORK/nope.json"
assert_eq "E: an unreadable transcript fails" 1 "$RC"
run_bd --bogus
assert_eq "E: an unknown flag is a usage error" 2 "$RC"
run_bd --transcript
assert_eq "E: a flag with no value is a usage error" 2 "$RC"

echo
if [ "$fail" -eq 0 ]; then echo "run_breakdown_test.sh: all assertions passed"; exit 0; fi
echo "run_breakdown_test.sh: $fail assertion(s) failed"; exit 1
