#!/usr/bin/env bash
set -uo pipefail

# post_review_test.sh — end-to-end tests for scripts/post-review.sh with a
# mocked `gh` (PATH shim). Covers the crash path (missing/invalid review.json,
# quota grep), hunk validation, verdict exit codes, POST failure, and
# crash-banner supersession.

cd "$(dirname "$0")/.."
POSTER="$(pwd)/scripts/post-review.sh"
[ -f "$POSTER" ] || { echo "FAIL: $POSTER not found"; exit 1; }

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "OK:   $label"; else echo "FAIL: $label — want '$want', got '$got'"; fail=$((fail + 1)); fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "OK:   $label" ;;
    *) echo "FAIL: $label — expected to find '$needle'"; fail=$((fail + 1)) ;;
  esac
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "FAIL: $label — did NOT expect '$needle'"; fail=$((fail + 1)) ;;
    *) echo "OK:   $label" ;;
  esac
}

# ── gh mock (PATH shim) ──────────────────────────────────────────────────────
# Logs every invocation to $GH_LOG; captures POSTed review payloads (incl.
# stdin via `--input -`) to $GH_CAPTURE_DIR; serves fixtures from
# GH_FIXTURE_REVIEWS / GH_FIXTURE_FILES / GH_FIXTURE_THREADS. GH_POST_FAIL=1
# makes review POSTs fail.
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
INPUT=""
prev=""
for a in "$@"; do
  [ "$prev" = "--input" ] && INPUT="$a"
  prev="$a"
done
capture() {
  local dest="$GH_CAPTURE_DIR/post-$(date +%s%N).json"
  if [ "$INPUT" = "-" ]; then cat > "$dest"; elif [ -n "$INPUT" ]; then cp "$INPUT" "$dest"; fi
}
case "$args" in
  *"--method PUT"*)
    echo '{}' ;;
  *"--method POST"*"/comments/"*"/replies"*)
    [ "$INPUT" = "-" ] && cat >/dev/null
    echo '{"id": 1}' ;;
  *"--method POST"*"/pulls/"*"/reviews"*)
    capture
    if [ "${GH_POST_FAIL:-0}" = "1" ]; then echo "HTTP 422: boom" >&2; exit 1; fi
    echo '{"id": 9001, "node_id": "PRR_x"}' ;;
  *graphql*resolveReviewThread*)
    echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}' ;;
  *graphql*)
    cat "${GH_FIXTURE_THREADS:-/dev/null}" 2>/dev/null || echo '[]' ;;
  *"/pulls/"*"/files"*)
    cat "${GH_FIXTURE_FILES:-/dev/null}" 2>/dev/null || echo '[]' ;;
  *"/pulls/"*"/reviews"*)
    cat "${GH_FIXTURE_REVIEWS:-/dev/null}" 2>/dev/null || echo '[]' ;;
  *)
    echo '{}' ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

# run_poster <workdir> — runs post-review.sh with mocks; sets OUT and RC.
run_poster() {
  local work="$1"
  mkdir -p "$work/capture"
  : > "$work/gh.log"
  : > "$work/summary.md"
  OUT=$(cd "$work" && \
    PATH="$MOCK_BIN:$PATH" \
    GH_LOG="$work/gh.log" GH_CAPTURE_DIR="$work/capture" \
    GH_FIXTURE_REVIEWS="${FIXTURE_REVIEWS:-}" GH_FIXTURE_FILES="${FIXTURE_FILES:-}" \
    GH_FIXTURE_THREADS="${FIXTURE_THREADS:-}" GH_POST_FAIL="${POST_FAIL:-0}" \
    GH_TOKEN=x GITHUB_REPOSITORY=o/r PR_NUMBER=7 \
    REVIEW_BOT_USER="claude-bot[bot]" ANALYZER_OUTCOME="${ANALYZER_OUTCOME:-success}" \
    HEAD_SHA=abc123 GITHUB_STEP_SUMMARY="$work/summary.md" \
    REVIEW_JSON="$work/review.json" ORCH_LOG="$work/orchestrator-output.txt" \
    bash "$POSTER" 2>&1)
  RC=$?
}

# Shared fixtures: one hunk in src/foo.ts covering RIGHT lines 10-13.
FILES_FIXTURE=$(mktemp)
cat > "$FILES_FIXTURE" <<'EOF'
[{"filename": "src/foo.ts", "patch": "@@ -10,3 +10,4 @@\n line10\n-old\n+new11\n+new12\n ctx"}]
EOF

VALID_REVIEW=$(cat <<'EOF'
{
  "verdict": "REQUEST_CHANGES",
  "body": "## Claude PR Review\n\nFindings below.",
  "comments": [
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**[BUG] in-hunk finding**"},
    {"path": "src/foo.ts", "line": 99, "side": "RIGHT", "body": "**[BUG] out-of-hunk finding**"}
  ],
  "resolve_threads": [],
  "bot_replies": [],
  "meta": {
    "findings": [{"id": "j1", "title": "boom", "severity": "major", "type": "bug", "path": "src/foo.ts", "line_start": 11}],
    "round": 1,
    "functional_validation": {"strategy": "skip", "overall": "N/A", "screenshot_count": 0}
  }
}
EOF
)

# ── (a) missing review.json → crash review + exit 1 ─────────────────────────
echo "── (a) missing review.json ──"
W=$(mktemp -d)
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 1" "1" "$RC"
assert_contains "emits ::error::" "::error::" "$OUT"
PAYLOAD=$(cat "$W"/capture/* 2>/dev/null || echo "")
assert_contains "crash review posted" "<!-- claude-review-crash -->" "$PAYLOAD"
assert_contains "crash review is COMMENT" '"event": "COMMENT"' "$PAYLOAD"
assert_contains "generic crash message" "Claude Review — incomplete" "$PAYLOAD"
rm -rf "$W"

# ── (b) quota grep → quota-specific banner ───────────────────────────────────
echo ""
echo "── (b) quota exhaustion ──"
W=$(mktemp -d)
echo '{"error": "rate_limit"} hit your limit · resets 7pm' > "$W/orchestrator-output.txt"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 1" "1" "$RC"
assert_contains "quota error annotation" "quota exhausted" "$OUT"
PAYLOAD=$(cat "$W"/capture/* 2>/dev/null || echo "")
assert_contains "quota-specific banner" "Claude Review — quota exhausted" "$PAYLOAD"
assert_contains "reset window surfaced" "resets 7pm" "$PAYLOAD"
rm -rf "$W"

# ── (c) invalid JSON → exit 1 ────────────────────────────────────────────────
echo ""
echo "── (c) invalid review.json ──"
W=$(mktemp -d)
echo 'this is not json' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 1" "1" "$RC"
assert_contains "crash banner posted" "<!-- claude-review-crash -->" "$(cat "$W"/capture/* 2>/dev/null || echo "")"
rm -rf "$W"

# ── (d) out-of-hunk comment moved to body ────────────────────────────────────
echo ""
echo "── (d) hunk validation ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
PAYLOAD=$(cat "$W"/capture/* 2>/dev/null || echo "{}")
assert_eq "one inline comment survives" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_eq "surviving comment is the in-hunk one" "11" "$(echo "$PAYLOAD" | jq '.comments[0].line')"
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_contains "body gets the outside-hunks section" "### Findings outside diff hunks" "$BODY"
assert_contains "moved finding carries path:line" "src/foo.ts:99" "$BODY"
rm -rf "$W"

# ── (e) REQUEST_CHANGES → exit 0 with warning ────────────────────────────────
echo ""
echo "── (e) REQUEST_CHANGES is green ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
assert_contains "emits ::warning::" "::warning::" "$OUT"
assert_contains "names the verdict" "REQUEST_CHANGES" "$OUT"
assert_contains "states finding count" "1 blocking finding" "$OUT"
assert_not_contains "no ::error::" "::error::" "$OUT"
assert_contains "step summary has verdict header" "## Claude Review: REQUEST_CHANGES" "$(cat "$W/summary.md")"
rm -rf "$W"

# ── (f) POST failure → exit 1 ────────────────────────────────────────────────
echo ""
echo "── (f) POST failure ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
POST_FAIL=1 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 1" "1" "$RC"
assert_contains "emits ::error::" "::error::" "$OUT"
assert_contains "says POST failed" "POST failed" "$OUT"
rm -rf "$W"

# ── (g) prior crash banner superseded on success ─────────────────────────────
echo ""
echo "── (g) crash-banner supersession + stale dismissal ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
REVIEWS_FIXTURE=$(mktemp)
cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 777, "user": {"login": "claude-bot[bot]"}, "state": "COMMENTED",
   "body": "<!-- claude-review-crash -->\n\n> **Claude Review — incomplete** :warning:",
   "commit_id": "old1", "submitted_at": "2026-06-01T00:00:00Z"},
  {"id": 778, "user": {"login": "claude-bot[bot]"}, "state": "CHANGES_REQUESTED",
   "body": "## Claude PR Review — prior round", "commit_id": "old2", "submitted_at": "2026-06-02T00:00:00Z"}
]
EOF
FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
GH_CALLS=$(cat "$W/gh.log")
assert_contains "crash banner PUT to reviews/777" "reviews/777" "$GH_CALLS"
assert_contains "superseded marker in PUT body" "claude-review-superseded" "$GH_CALLS"
assert_contains "prior blocking review dismissed" "reviews/778/dismissals" "$GH_CALLS"
rm -rf "$W" "$REVIEWS_FIXTURE"

# ── (h) reject-oversized → body-only REQUEST_CHANGES ─────────────────────────
echo ""
echo "── (h) reject-oversized posts body-only REQUEST_CHANGES ──"
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "REQUEST_CHANGES",
  "body": "## Claude PR Review\n\nThis PR is too large to review safely — please split it.",
  "comments": [],
  "resolve_threads": [],
  "bot_replies": [],
  "meta": {
    "findings": [],
    "round": 1,
    "ladder_rule_applied": "reject-oversized"
  }
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
PAYLOAD=$(cat "$W"/capture/* 2>/dev/null || echo "{}")
assert_eq "event is REQUEST_CHANGES" "REQUEST_CHANGES" "$(echo "$PAYLOAD" | jq -r '.event')"
assert_eq "no inline comments" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "no runtime-evidence banner" "no runtime evidence" "$(cat "$W/summary.md")"
rm -rf "$W"

# ── (i) runtime-evidence → step-summary banner ───────────────────────────────
echo ""
echo "── (i) runtime-evidence renders the step-summary banner ──"
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "REQUEST_CHANGES",
  "body": "## Claude PR Review\n\nNo runtime evidence — wire up dev-start.sh.",
  "comments": [],
  "resolve_threads": [],
  "bot_replies": [],
  "meta": {
    "findings": [],
    "round": 1,
    "ladder_rule_applied": "runtime-evidence"
  }
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
PAYLOAD=$(cat "$W"/capture/* 2>/dev/null || echo "{}")
assert_eq "event is REQUEST_CHANGES" "REQUEST_CHANGES" "$(echo "$PAYLOAD" | jq -r '.event')"
assert_eq "no inline comments" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "step summary has runtime-evidence banner" "no runtime evidence" "$(cat "$W/summary.md")"
rm -rf "$W"

rm -rf "$MOCK_BIN" "$FILES_FIXTURE"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All post-review tests passed."
  exit 0
else
  echo "$fail post-review test(s) failed."
  exit 1
fi
