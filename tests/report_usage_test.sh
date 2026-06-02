#!/usr/bin/env bash
set -uo pipefail

# report_usage_test.sh — fixture test for scripts/report-usage.sh.
#
# The script is best-effort by contract: every input is optional, every
# field falls back to a safe default, and the script always exits 0.
# Verifies that:
#   - bare run (no inputs) emits valid JSON with the expected schema
#   - realistic review-result.json + functional-meta.json populate fields
#   - malformed review-result.json doesn't crash the script
#   - PRIOR_STATE_AVAILABLE=true → round=2
#   - phase-summary.txt parses into the phases object
#   - script exits 0 even when jq itself errors mid-run
#
# No LLM key required; pure file-IO + jq.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/report-usage.sh"

fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Each subcase runs in its own working dir so review-result.json from one
# case doesn't leak into the next. The script writes to /tmp/usage.json
# globally — back it up between cases with mv-and-restore.
USAGE_OUT=/tmp/usage.json
PHASE_FILE=/tmp/phase-summary.txt
FN_META=/tmp/functional-meta.json
ORCH_FILE=/tmp/orchestrator-output.txt

reset_global() {
  rm -f "$USAGE_OUT" "$PHASE_FILE" "$FN_META" "$ORCH_FILE"
}

run_case() {
  local label="$1" wd="$2"
  shift 2
  rm -f "$USAGE_OUT"
  ( cd "$wd" && env -i PATH="$PATH" "$@" bash "$SCRIPT" >/dev/null 2>&1 )
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $label — script exited $rc (must always exit 0)"
    fail=$((fail + 1))
    return 1
  fi
  if [ ! -f "$USAGE_OUT" ]; then
    echo "FAIL: $label — $USAGE_OUT not written"
    fail=$((fail + 1))
    return 1
  fi
  if ! jq empty "$USAGE_OUT" >/dev/null 2>&1; then
    echo "FAIL: $label — $USAGE_OUT is not valid JSON:"
    cat "$USAGE_OUT"
    fail=$((fail + 1))
    return 1
  fi
  return 0
}

assert_field() {
  local label="$1" jq_expr="$2" want="$3"
  local got
  got=$(jq -r "$jq_expr" "$USAGE_OUT" 2>/dev/null)
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — \`$jq_expr\` want '$want' got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# ── Case 1: bare run, no inputs at all ──
WD1="$TMP/case1"
mkdir -p "$WD1"
reset_global
run_case "bare run exits 0 + emits valid JSON" "$WD1" || true
assert_field "  schema_version=1"          '.schema_version'        '1'
assert_field "  repo defaults to empty"    '.repo'                  ''
assert_field "  pr_number defaults null"   '.pr_number'             'null'
assert_field "  round defaults to 1"       '.round'                 '1'
assert_field "  verdict defaults null"     '.verdict'               'null'
assert_field "  findings_count defaults 0" '.findings_count'        '0'
assert_field "  phases is object"          '.phases | type'         'object'
assert_field "  technical_change=false"    '.technical_change'      'false'
assert_field "  claude_cost_usd null"      '.claude_cost_usd'       'null'

# ── Case 2: realistic inputs, round 1 ──
WD2="$TMP/case2"
mkdir -p "$WD2"
reset_global
cat > "$WD2/review-result.json" <<'EOF'
{
  "verdict": "COMMENT",
  "findings": [
    {"id":"a","severity":"major"},
    {"id":"b","severity":"minor"}
  ],
  "technical_change": false,
  "requires_human_review": false,
  "functional_validation": {
    "strategy": "functional",
    "overall": "PASS",
    "screenshot_count": 3
  }
}
EOF
cat > "$FN_META" <<'EOF'
{"strategy":"functional","overall":"PASS","screenshots":["a.png","b.png","c.png"]}
EOF
cat > "$PHASE_FILE" <<'EOF'
context-build=42s
analyze=300s
EOF
run_case "realistic round-1 inputs populate fields" "$WD2" \
  GITHUB_REPOSITORY=panenco/seaters \
  GITHUB_RUN_ID=987654321 \
  GITHUB_RUN_ATTEMPT=1 \
  PR_NUMBER=464 \
  HEAD_SHA=deadbeef \
  ANALYZER_OUTCOME=success \
  POSTER_OUTCOME=success \
  PRIOR_STATE_AVAILABLE=false \
  || true
assert_field "  repo"                 '.repo'                  'panenco/seaters'
assert_field "  pr_number"            '.pr_number'             '464'
assert_field "  run_id"               '.run_id'                '987654321'
assert_field "  run_attempt"          '.run_attempt'           '1'
assert_field "  head_sha"             '.head_sha'              'deadbeef'
assert_field "  round=1"              '.round'                 '1'
assert_field "  verdict=COMMENT"      '.verdict'               'COMMENT'
assert_field "  findings_count=2"     '.findings_count'        '2'
assert_field "  functional_strategy"  '.functional_strategy'   'functional'
assert_field "  functional_overall"   '.functional_overall'    'PASS'
assert_field "  screenshot_count=3"   '.screenshot_count'      '3'
assert_field "  analyzer_outcome"     '.analyzer_outcome'      'success'
assert_field "  poster_outcome"       '.poster_outcome'        'success'
assert_field "  phases.context-build" '.phases."context-build"' '42'
assert_field "  phases.analyze"       '.phases.analyze'        '300'

# ── Case 3: PRIOR_STATE_AVAILABLE=true → round=2 ──
WD3="$TMP/case3"
mkdir -p "$WD3"
reset_global
echo '{"verdict":"APPROVE","findings":[]}' > "$WD3/review-result.json"
run_case "PRIOR_STATE_AVAILABLE=true → round=2" "$WD3" \
  GITHUB_REPOSITORY=panenco/qiv \
  PR_NUMBER=292 \
  PRIOR_STATE_AVAILABLE=true \
  || true
assert_field "  round=2"           '.round'           '2'
assert_field "  verdict=APPROVE"   '.verdict'         'APPROVE'
assert_field "  findings_count=0"  '.findings_count'  '0'

# ── Case 4: malformed review-result.json must not crash ──
WD4="$TMP/case4"
mkdir -p "$WD4"
reset_global
echo 'this is not json' > "$WD4/review-result.json"
run_case "malformed review-result.json doesn't crash" "$WD4" \
  GITHUB_REPOSITORY=panenco/qiv \
  || true
# Falls back to {} → defaults.
assert_field "  schema_version=1"        '.schema_version'    '1'
assert_field "  verdict null"            '.verdict'           'null'
assert_field "  findings_count=0"        '.findings_count'    '0'

# ── Case 5: review-result.json valid but missing keys uses safe defaults ──
WD5="$TMP/case5"
mkdir -p "$WD5"
reset_global
echo '{"unrelated":"data"}' > "$WD5/review-result.json"
run_case "review-result.json with no review fields" "$WD5" \
  GITHUB_REPOSITORY=panenco/qit \
  || true
assert_field "  verdict null"            '.verdict'           'null'
assert_field "  findings_count=0"        '.findings_count'    '0'
assert_field "  technical_change=false"  '.technical_change'  'false'

# ── Case 6: phases survives a malformed line in phase-summary.txt ──
WD6="$TMP/case6"
mkdir -p "$WD6"
reset_global
cat > "$PHASE_FILE" <<'EOF'
context-build=37s
oops not a phase line
analyze=120s
EOF
run_case "malformed phase line is skipped" "$WD6" \
  GITHUB_REPOSITORY=panenco/spendfuse \
  || true
assert_field "  phases is object"           '.phases | type'         'object'
assert_field "  phases.context-build=37"    '.phases."context-build"' '37'
assert_field "  phases.analyze=120"         '.phases.analyze'         '120'
assert_field "  phases has 2 keys"          '.phases | keys | length' '2'

# ── Case 7: claude_cost_usd = MAX total_cost_usd in the orchestrator log ──
# The orchestrator's stream-json log carries a cumulative total_cost_usd that
# grows over the run; subagent (judge/functional) costs roll into it, so the
# final/largest value is the run's total Claude spend. report-usage.sh greps
# the max from /tmp/orchestrator-output.txt.
WD7="$TMP/case7"
mkdir -p "$WD7"
reset_global
cat > "$ORCH_FILE" <<'EOF'
{"type":"assistant","message":{"usage":{"output_tokens":10}}}
{"type":"result","subtype":"success","total_cost_usd":0.69}
{"type":"result","subtype":"success","total_cost_usd":2.41}
EOF
run_case "claude_cost_usd = max total_cost_usd from orchestrator log" "$WD7" \
  GITHUB_REPOSITORY=owner/repo \
  || true
assert_field "  claude_cost_usd=2.41"  '.claude_cost_usd'  '2.41'

# ── Case 8: malformed/absent cost line → claude_cost_usd stays null ──
WD8="$TMP/case8"
mkdir -p "$WD8"
reset_global
echo '{"type":"result","subtype":"success","no_cost_here":true}' > "$ORCH_FILE"
run_case "no total_cost_usd in log → claude_cost_usd null" "$WD8" \
  GITHUB_REPOSITORY=owner/repo \
  || true
assert_field "  claude_cost_usd null"  '.claude_cost_usd'  'null'

reset_global
if [ "$fail" -eq 0 ]; then
  echo
  echo "All report-usage tests passed."
  exit 0
else
  echo
  echo "$fail report-usage test assertion(s) failed."
  exit 1
fi
