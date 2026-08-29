#!/usr/bin/env bash
set -uo pipefail

# post_review_test.sh — end-to-end tests for scripts/post-review.sh with a
# mocked `gh` (PATH shim). Covers the crash path (missing/invalid review.json,
# quota grep), the v4 rendering contract ({{LINK:}} expansion, footer, the
# 1200-byte PRE-EXPANSION body budget and its interaction with link expansion,
# the 5×700-BYTE inline-comment budget and the body-bullet fallback for anything
# that cannot be posted inline), hunk validation, verdict exit codes, POST
# failure, and crash-banner supersession.

cd "$(dirname "$0")/.."
POSTER="$(pwd)/scripts/post-review.sh"
# The body budget the poster enforces (REVIEW_BODY_MAX default). These tests
# pin the MECHANISM — enforced, cut on a line boundary, hard cut when nothing
# fits — so the number lives here once instead of in every assertion.
BUDGET=1800
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

# The anchor GitHub uses on the Files tab: sha256 of the raw path string, lowercase
# hex. Computed here the same two ways the script does, so the test is not just
# restating the implementation's own output.
path_sha() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi
}

# ── gh mock (PATH shim) ──────────────────────────────────────────────────────
# Logs every invocation to $GH_LOG; captures POSTed review payloads (incl.
# stdin via `--input -`) to $GH_CAPTURE_DIR; serves fixtures from
# GH_FIXTURE_REVIEWS / GH_FIXTURE_FILES. GH_POST_FAIL=1 makes review POSTs fail.
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
  *"--method POST"*"/pulls/"*"/reviews"*)
    capture
    if [ "${GH_POST_FAIL:-0}" = "1" ]; then echo "HTTP 422: boom" >&2; exit 1; fi
    echo '{"id": 9001, "node_id": "PRR_x"}' ;;
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
  # build-spec.sh writes this token on every run; `document` is the ordinary
  # case, so only the cases that set SPEC_STATE see the "no spec" notice.
  printf '%s\n' "${SPEC_STATE:-document}" > "$work/spec-status"
  [ "${SPEC_STATE:-document}" = absent ] && rm -f "$work/spec-status"
  OUT=$(cd "$work" && \
    PATH="$MOCK_BIN:$PATH" \
    GH_LOG="$work/gh.log" GH_CAPTURE_DIR="$work/capture" \
    GH_FIXTURE_REVIEWS="${FIXTURE_REVIEWS:-}" GH_FIXTURE_FILES="${FIXTURE_FILES:-}" \
    GH_POST_FAIL="${POST_FAIL:-0}" \
    GH_TOKEN=x GITHUB_REPOSITORY=o/r PR_NUMBER=7 \
    REVIEW_BOT_USER="claude-bot[bot]" \
    HEAD_SHA=abc123 GITHUB_STEP_SUMMARY="$work/summary.md" \
    GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}" GITHUB_RUN_ID="${RUN_ID:-}" \
    JOB_START="${JOB_START:-$work/no-job-start}" \
    SPEC_STATUS="$work/spec-status" \
    FUNCTIONAL_REQUESTED="${FUNCTIONAL_REQ:-}" \
    DEV_ENV_RC_FILE="${DEVENV_RC:-$work/no-such-rc}" \
    DEV_ENV_LOG_FILE="${DEVENV_LOG:-$work/no-such-log}" \
    REVIEW_JSON="$work/review.json" ORCH_LOG="$work/orchestrator-output.txt" \
    REVIEW_BODY_MAX="${BODY_MAX:-}" REVIEW_STATE_MAX="${STATE_MAX:-}" \
    ROUND="${ROUND_N:-}" \
    PRIOR_FINDINGS_JSON="${PRIOR_FINDINGS:-$work/no-such-priors.json}" \
    bash "$POSTER" 2>&1)
  RC=$?
}
payload_of() { cat "$1"/capture/* 2>/dev/null || echo '{}'; }
# The posted body minus the round-2 state block. The block is invisible to the
# reader and outside the 1200-byte budget, so every assertion about what the
# HUMAN sees, and every byte count, is against this — not against the raw body.
visible_body() { local v; v=$(printf '%s' "$1" | sed '/<!-- claude-review-state/,/^-->$/d'); printf '%s' "$v"; }
state_block()  { printf '%s' "$1" | sed -n '/<!-- claude-review-state/,/^-->$/p' | sed '1d;$d'; }

# Shared fixtures: one hunk in src/foo.ts covering RIGHT lines 10-13.
FILES_FIXTURE=$(mktemp)
cat > "$FILES_FIXTURE" <<'EOF'
[{"filename": "src/foo.ts", "patch": "@@ -10,3 +10,4 @@\n line10\n-old\n+new11\n+new12\n ctx"}]
EOF

VALID_REVIEW=$(cat <<'EOF'
{
  "verdict": "REQUEST_CHANGES",
  "body": "## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:11}} — off-by-one",
  "comments": [
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**major** in-hunk finding"},
    {"path": "src/foo.ts", "line": 99, "side": "RIGHT", "body": "**major** out-of-hunk finding"}
  ],
  "meta": {
    "findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11}],
    "human_review": []
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
PAYLOAD=$(payload_of "$W")
assert_contains "crash review posted" "<!-- claude-review-crash -->" "$PAYLOAD"
assert_contains "crash review is COMMENT" '"event": "COMMENT"' "$PAYLOAD"
assert_contains "no-output crash message" "Claude Review — incomplete" "$PAYLOAD"
assert_not_contains "not the unreadable variant" "result unreadable" "$PAYLOAD"
rm -rf "$W"

# ── (b) quota grep → quota-specific banner ───────────────────────────────────
echo ""
echo "── (b) quota exhaustion ──"
W=$(mktemp -d)
echo '{"error": "rate_limit"} hit your limit · resets 7pm' > "$W/orchestrator-output.txt"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 1" "1" "$RC"
assert_contains "quota error annotation" "quota exhausted" "$OUT"
PAYLOAD=$(payload_of "$W")
assert_contains "quota-specific banner" "Claude Review — quota exhausted" "$PAYLOAD"
assert_contains "reset window surfaced" "resets 7pm" "$PAYLOAD"
rm -rf "$W"

# ── (c) invalid JSON (output present) → unreadable banner, exit 1 ────────────
echo ""
echo "── (c) invalid review.json ──"
W=$(mktemp -d)
# Unescaped quote inside a string — the exact qiv#679 corruption.
printf '%s\n' '{"verdict":"COMMENT","body":"shows a "bad" quote"}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
assert_eq "exit 1" "1" "$RC"
assert_contains "crash banner posted" "<!-- claude-review-crash -->" "$PAYLOAD"
assert_contains "unreadable variant, not incomplete" "result unreadable" "$PAYLOAD"
assert_contains "tells the human to re-run" "re-run the workflow" "$PAYLOAD"
assert_not_contains "does not say human must review" "a human should review" "$PAYLOAD"
rm -rf "$W"

# ── (d) hunk validation: out-of-hunk comments fall back to a body bullet ─────
# GitHub 422s the atomic POST if any comment sits outside a hunk, so it cannot be
# posted inline — but under v4's inline-XOR-body rule the body does NOT already
# name it, so dropping it erases the finding from the review entirely.
echo ""
echo "── (d) hunk validation ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "one inline comment survives" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_eq "surviving comment is the in-hunk one" "11" "$(echo "$PAYLOAD" | jq '.comments[0].line')"
assert_contains "the drop is announced in the log" "outside a diff hunk" "$OUT"
assert_contains "the fallback is announced in the log" "body bullets instead" "$OUT"
assert_contains "the dropped finding gets a body bullet" "### Also flagged (1)" "$BODY"
assert_contains "the bullet carries its severity and title" \
  "**major** [src/foo.ts:99](" "$BODY"
assert_contains "the bullet keeps the comment's own title" "out-of-hunk finding" "$BODY"
rm -rf "$W"

# ── (d2) a large file with no `.patch` still gets its finding into the body ──
# GitHub omits `patch` for large files, so no line of that file can be validated
# and every comment on it is undeliverable inline. A `critical` there used to
# vanish with only a run-log warning.
echo ""
echo "── (d2) large file with no .patch ──"
W=$(mktemp -d)
NOPATCH_FILES=$(mktemp)
cat > "$NOPATCH_FILES" <<'EOF'
[{"filename": "src/foo.ts", "patch": "@@ -10,3 +10,4 @@\n line10\n-old\n+new11\n+new12\n ctx"},
 {"filename": "src/huge.ts"}]
EOF
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nOne blocking finding.",
        comments: [{path: "src/huge.ts", line: 4200, side: "RIGHT",
                    body: "**critical** unbounded read of attacker input"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$NOPATCH_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "nothing posted inline on the patch-less file" "0" \
  "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the critical reaches the body instead" \
  "**critical** [src/huge.ts:4200](" "$BODY"
assert_contains "with its title" "unbounded read of attacker input" "$BODY"
rm -rf "$W" "$NOPATCH_FILES"

# ── (d3) comments past the inline cap fall back too ─────────────────────────
echo ""
echo "── (d3) over-cap comments fall back to the body ──"
W=$(mktemp -d)
WIDE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,20 +1,20 @@\n" + ([range(20) | " ctx"] | join("\n")))}]' > "$WIDE"
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nsee comments.",
        comments: [range(1;14) | {path: "src/foo.ts", line: (1 + .), side: "RIGHT",
                                 body: "**major** finding \(.)"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "still capped inline" "10" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the 3 over the cap are listed in the body" "### Also flagged (3)" "$BODY"
assert_contains "over-cap fallback is announced" "over the inline cap" "$OUT"
for n in 11 12 13; do
  assert_contains "finding $n survives in the body" "finding $n" "$BODY"
done
rm -rf "$W" "$WIDE"

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
   "body": "## Claude review — prior round", "commit_id": "old2", "submitted_at": "2026-06-02T00:00:00Z"}
]
EOF
FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
GH_CALLS=$(cat "$W/gh.log")
assert_contains "crash banner PUT to reviews/777" "reviews/777" "$GH_CALLS"
assert_contains "superseded marker in PUT body" "claude-review-superseded" "$GH_CALLS"
assert_contains "prior blocking review dismissed" "reviews/778/dismissals" "$GH_CALLS"
rm -rf "$W" "$REVIEWS_FIXTURE"

# ── (g2) a skip-marked review must NOT dismiss the standing block ────────────
# It judged nothing (guard.sh renders it with no model call): dismissing would
# un-block a PR nobody re-reviewed, and the next round would read its prior
# verdict off a DISMISSED review.
echo ""
echo "── (g2) skip-marked review leaves the standing block alone ──"
for marker in "<!-- claude-review-skipped -->" "<!-- claude-review-oversized -->"; do
  W=$(mktemp -d)
  jq -n --arg body "$marker"$'\n\n## Claude review — REQUEST_CHANGES\n\nToo large to review well.' \
    '{verdict: "REQUEST_CHANGES", body: $body, comments: [], meta: {findings: []}}' > "$W/review.json"
  REVIEWS_FIXTURE=$(mktemp)
  cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 778, "user": {"login": "claude-bot[bot]"}, "state": "CHANGES_REQUESTED",
   "body": "## Claude review — REQUEST_CHANGES\n\nprior round", "commit_id": "old2",
   "submitted_at": "2026-06-02T00:00:00Z"}
]
EOF
  FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  assert_eq "exit 0 ($marker)" "0" "$RC"
  assert_not_contains "standing block NOT dismissed ($marker)" "dismissals" "$(cat "$W/gh.log")"
  rm -rf "$W" "$REVIEWS_FIXTURE"
done

# ── (g3) a JUDGED review that quotes a marker still dismisses ────────────────
# The skip guard is anchored to the body's first line. This repo reviews itself,
# so a finding quoting a marker is a live case — an unanchored grep would read a
# real review as a skip and leave the stale block standing. Same for the crash
# marker, which supersede_crash_banners uses to REWRITE bodies it matches.
echo ""
echo "── (g3) judged review quoting markers still dismisses/does not clobber ──"
W=$(mktemp -d)
jq -n --arg body '## Claude review — REQUEST_CHANGES

### Findings (1)
- **major** `scripts/guard.sh:53` — stamps `<!-- claude-review-skipped -->` where the
  oversized branch stamps `<!-- claude-review-oversized -->`.' \
  '{verdict: "REQUEST_CHANGES", body: $body, comments: [], meta: {findings: []}}' > "$W/review.json"
REVIEWS_FIXTURE=$(mktemp)
cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 778, "user": {"login": "claude-bot[bot]"}, "state": "CHANGES_REQUESTED",
   "body": "## Claude review — REQUEST_CHANGES\n\nprior round", "commit_id": "old2",
   "submitted_at": "2026-06-02T00:00:00Z"},
  {"id": 779, "user": {"login": "claude-bot[bot]"}, "state": "COMMENTED",
   "body": "## Claude review — COMMENT\n\nquotes <!-- claude-review-crash --> in a finding",
   "commit_id": "old3", "submitted_at": "2026-06-03T00:00:00Z"}
]
EOF
FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
GH_CALLS=$(cat "$W/gh.log")
assert_eq "exit 0" "0" "$RC"
assert_contains "stale block still dismissed" "reviews/778/dismissals" "$GH_CALLS"
assert_not_contains "crash-quoting review not superseded" "reviews/779" "$GH_CALLS"
rm -rf "$W" "$REVIEWS_FIXTURE"

# ── (h) oversized split request → body-only REQUEST_CHANGES ──────────────────
echo ""
echo "── (h) guard.sh split request posts body-only REQUEST_CHANGES ──"
W=$(mktemp -d)
GATE_FILES_TSV="$(for i in $(seq 1 65); do printf 'src/f%d.ts\t10\t10\n' "$i"; done)" \
  bash scripts/guard.sh | awk '/^body<<GUARD_BODY$/{f=1;next} /^GUARD_BODY$/{f=0} f' > "$W/guard-body.md"
jq -n --rawfile body "$W/guard-body.md" \
  '{verdict: "REQUEST_CHANGES", body: $body, comments: [], meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
PAYLOAD=$(payload_of "$W")
assert_eq "event is REQUEST_CHANGES" "REQUEST_CHANGES" "$(echo "$PAYLOAD" | jq -r '.event')"
assert_eq "no inline comments" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the split request survives to the PR" "Split it into focused PRs" \
  "$(echo "$PAYLOAD" | jq -r '.body')"
rm -rf "$W"

# ── (i) {{LINK:}} placeholders become real GitHub file links ─────────────────
# The models emit NO urls — only this script knows repo + PR number.
echo ""
echo "── (i) link placeholder expansion ──"
W=$(mktemp -d)
jq -n '{verdict: "COMMENT",
        body: "## Claude review — COMMENT\n\n### What a human should review\n- [ ] {{LINK:src/foo.ts:11}} — check the loop bound\n- [ ] {{LINK:src/bar.ts}} — whole-file rewrite\n\nAlso see {{LINK:src/foo.ts:11}} again.",
        comments: [], meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
FOO_SHA=$(path_sha "src/foo.ts")
BAR_SHA=$(path_sha "src/bar.ts")
assert_eq "exit 0" "0" "$RC"
assert_contains "path:line becomes a linked label" \
  "[src/foo.ts:11](https://github.com/o/r/pull/7/files#diff-${FOO_SHA}R11)" "$BODY"
assert_contains "a path with no line omits the R suffix" \
  "[src/bar.ts](https://github.com/o/r/pull/7/files#diff-${BAR_SHA})" "$BODY"
assert_not_contains "no placeholder survives" "{{LINK:" "$BODY"
assert_eq "every occurrence is expanded, not just the first" "2" \
  "$(printf '%s' "$BODY" | grep -c "diff-${FOO_SHA}R11")"
assert_eq "the sha is lowercase hex sha256 of the raw path" "yes" \
  "$(printf '%s' "$FOO_SHA" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"
rm -rf "$W"

# ── (j) footer: duration · cost · logs, appended here and not by the model ───
echo ""
echo "── (j) footer ──"
W=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nNothing to flag.",
        comments: [], meta: {findings: [], human_review: []}}' > "$W/review.json"
printf '{"total_cost_usd": 0.618}\n' > "$W/orchestrator-output.txt"
printf '%s\n' "$(( $(date +%s) - 245 ))" > "$W/job-start"
JOB_START="$W/job-start" RUN_ID=4242 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0 (APPROVE)" "0" "$RC"
assert_contains "footer is a <sub> line" "<sub>" "$BODY"
# 245s, but the clock can tick between writing job-start and the poster reading
# it — assert the minute, not the exact second, or this flakes ~1 run in 60.
case "$BODY" in
  *"4m 5s"*|*"4m 6s"*) echo "OK:   footer carries the wall clock" ;;
  *) echo "FAIL: footer carries the wall clock — expected '4m 5s' or '4m 6s'"; fail=$((fail + 1)) ;;
esac
assert_contains "footer carries the cost, 2dp" '$0.62' "$BODY"
assert_contains "footer links the run" "[logs](https://github.com/o/r/actions/runs/4242)" "$BODY"
rm -rf "$W"

# A run that knows none of the three must not post an empty <sub></sub>.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nfine.", comments: [], meta: {}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_not_contains "no footer when nothing is known" "<sub>" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W"

# ── (j2) "no spec resolved" is visible, and is NEVER a verdict gate ──────────
# 42% of real PRs resolve no spec. Saying so is honest; withholding a verdict
# over it would be a ratchet, so APPROVE with no spec still approves.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nfine.", comments: [], meta: {}}' > "$W/review.json"
SPEC_STATE=none FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_contains "a run with no spec says so in the body" \
  "No spec resolved — reviewed on the diff alone" "$(visible_body "$(payload_of "$W" | jq -r '.body')")"
rm -rf "$W"

W=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nNothing to flag.", comments: [], meta: {}}' > "$W/review.json"
SPEC_STATE=none FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "…and it does not fail the run" "0" "$RC"
assert_eq "…the review is still submitted as an approval" "APPROVE" "$(payload_of "$W" | jq -r '.event')"
assert_contains "…and the body still says APPROVE" "APPROVE" "$(payload_of "$W" | jq -r '.body')"
assert_contains "…alongside the notice" "No spec resolved" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nfine.", comments: [], meta: {}}' > "$W/review.json"
SPEC_STATE=document FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_not_contains "a run that had a spec says nothing about it" "No spec resolved" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nfine.", comments: [], meta: {}}' > "$W/review.json"
SPEC_STATE=absent FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "…and a missing status file is not a crash" "0" "$RC"
assert_not_contains "…nor an invented claim" "No spec resolved" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W"

# ── (j3) the injection flag is a RECORD: it marks the review, moves nothing ──
# v3 escalated prompt_injection_detected to human review, which is a verdict
# gate; ADR 0003 bans those. So it must reach the reader and stop there.
echo ""
echo "── (j3) prompt_injection_detected marks without gating ──"
W=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nNothing to flag.",
        comments: [], meta: {findings: [], human_review: [], prompt_injection_detected: false}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
CLEAN_RC=$RC
CLEAN_EVENT=$(payload_of "$W" | jq -r '.event')
assert_not_contains "no marker when the flag is false" "injection-shaped" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W"

W=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nNothing to flag.",
        comments: [], meta: {findings: [], human_review: [], prompt_injection_detected: true}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_contains "the footer carries the marker" "injection-shaped text in the PR input" \
  "$(payload_of "$W" | jq -r '.body')"
assert_contains "the step summary says the verdict did not move" "no verdict changed" \
  "$(cat "$W/summary.md")"
assert_eq "…and the verdict is unchanged" "$CLEAN_EVENT" "$(payload_of "$W" | jq -r '.event')"
assert_eq "…and so is the exit code" "$CLEAN_RC" "$RC"
rm -rf "$W"

# ── (k) body budget: enforced, cut on a line boundary, footer kept ──────────
# Prompt-only budgets historically did not hold (measured median body 1560
# chars), so the cap is enforced here.
echo ""
echo "── (k) body budget ──"
W=$(mktemp -d)
{ echo "## Claude review — COMMENT"; echo ""
  for i in $(seq 1 60); do echo "- **major** finding number $i that goes on and on about a thing"; done
} > "$W/long-body.md"
jq -n --rawfile b "$W/long-body.md" \
  '{verdict: "COMMENT", body: $b, comments: [], meta: {findings: []}}' > "$W/review.json"
printf '{"total_cost_usd": 0.5}\n' > "$W/orchestrator-output.txt"
RUN_ID=99 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
BYTES=$(visible_body "$BODY" | wc -c | tr -d ' ')
assert_eq "exit 0" "0" "$RC"
if [ "$BYTES" -le "$BUDGET" ]; then
  echo "OK:   body held to the budget ($BYTES bytes)"
else
  echo "FAIL: body is $BYTES bytes, over the $BUDGET budget"; fail=$((fail + 1))
fi
assert_contains "truncation is announced to the reader" "truncated" "$BODY"
assert_contains "the footer survives truncation" "[logs](" "$BODY"
assert_contains "the header survives truncation" "## Claude review — COMMENT" "$BODY"
# Cut on a line boundary: no bullet may end mid-word.
assert_not_contains "no half-written bullet" "finding number 60 that goes on and" "$BODY"
rm -rf "$W"

# ── (k2) THE INTERACTION: budget × link expansion ────────────────────────────
# (k) truncates a body with NO placeholders; (i) expands placeholders in a body
# far under budget. Neither catches the case that actually shipped: a body the
# model rendered WITHIN its stated budget ("count {{LINK:path:line}} as
# path:line", review-verify.md) where expansion adds ~130 bytes per link and
# pushes the rendered text past 1200. Enforcing the cap after expansion cut both
# finding bullets and left a dangling `### Findings (2)` — and under the
# inline-XOR-body rule those findings existed NOWHERE else in the review.
echo ""
echo "── (k2) a budget-compliant body with links loses nothing ──"
W=$(mktemp -d)
{ echo "## Claude review — REQUEST_CHANGES"; echo ""
  echo "Reworks the broker's claim handling and the tenant cache; two user-reachable defects survive verification, and two questions need a human who knows the upstream timeout policy and the tenancy model to settle them properly."
  echo ""
  echo "### Context"
  echo "Claim handling turns an uploaded claim into a broker submission, scoped per tenant."
  echo "- moves retry and backoff out of the handler and into the service"
  echo "- adds a warm-start path to the tenant cache"
  echo "- reworks the 401 refresh so a claim is never submitted twice"
  echo ""
  echo "### What a human should review"
  echo "- [ ] {{LINK:src/alpha/policy.ts:31}} — confirm the backoff ceiling still honours the broker contract after the move (needs the contract)"
  echo "- [ ] {{LINK:src/beta/warm.ts:18}} — confirm the warm-start path cannot serve a cache entry built for another tenant (needs prod data)"
  echo "- [ ] {{LINK:src/alpha/service.ts:120}} — confirm the retry budget matches the upstream gateway timeout; the policy doc is out of date (no spec)"
  echo "- [ ] {{LINK:src/beta/handler.ts:44}} — confirm the cache key includes the tenant id on every path, including the warm-start branch (needs prod data)"
  echo ""
  echo "### Findings (2)"
  echo "- **critical** {{LINK:src/alpha/service.ts:131}} — token refresh loops forever on a 401 and pins a core"
  echo "- **major** {{LINK:src/beta/handler.ts:52}} — cross-tenant cache hit returns another tenant's rows"
} > "$W/linked-body.md"
NLINKS=$(grep -o '{{LINK:' "$W/linked-body.md" | wc -l | tr -d ' ')
# What the model was told to count: the placeholder measured as `path:line`,
# i.e. the raw bytes minus the 9-byte `{{LINK:` … `}}` wrapper.
MEASURED=$(( $(wc -c < "$W/linked-body.md") - 9 * NLINKS ))
if [ "$MEASURED" -le "$BUDGET" ]; then
  echo "OK:   the fixture is a budget-compliant body ($MEASURED bytes as the model counts them)"
else
  echo "FAIL: fixture is $MEASURED bytes pre-expansion — it must be UNDER $BUDGET to test this"; fail=$((fail + 1))
fi
jq -n --rawfile b "$W/linked-body.md" \
  '{verdict: "REQUEST_CHANGES", body: $b, comments: [], meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
BYTES=$(visible_body "$BODY" | wc -c | tr -d ' ')
assert_eq "exit 0" "0" "$RC"
if [ "$BYTES" -gt "$BUDGET" ]; then
  echo "OK:   expansion really does push it past $BUDGET ($BYTES bytes) — the case is live"
else
  echo "FAIL: expanded body is only $BYTES bytes; the fixture no longer exercises the interaction"
  fail=$((fail + 1))
fi
assert_not_contains "nothing was truncated" "truncated to fit" "$BODY"
assert_contains "the Findings header survives" "### Findings (2)" "$BODY"
assert_contains "the critical finding survives" "token refresh loops forever on a 401" "$BODY"
assert_contains "the major finding survives" "another tenant's rows" "$BODY"
assert_contains "the context block survives with the findings" "### Context" "$BODY"
assert_eq "all four placeholders expanded" "$NLINKS" \
  "$(printf '%s' "$BODY" | grep -c 'files#diff-')"
assert_not_contains "no placeholder survives" "{{LINK:" "$BODY"
rm -rf "$W"

# ── (k3) genuinely over budget with links → truncate, drop the empty header ──
# A `### Findings (2)` header above nothing reads as a rendering bug and tells
# the reader the review lost content without saying what.
echo ""
echo "── (k3) truncation never leaves a dangling section header ──"
W=$(mktemp -d)
{ echo "## Claude review — COMMENT"; echo ""
  echo "### What a human should review"
  for i in $(seq 1 20); do
    echo "- [ ] {{LINK:src/pkg/module$i/service.ts:$i}} — check the boundary condition on this call path carefully"
  done
  echo ""
  echo "### Findings (2)"
  echo "- **major** {{LINK:src/late/one.ts:9}} — this bullet is past the budget"
  echo "- **minor** {{LINK:src/late/two.ts:9}} — so is this one"
} > "$W/long-linked.md"
jq -n --rawfile b "$W/long-linked.md" \
  '{verdict: "COMMENT", body: $b, comments: [], meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_contains "truncation is announced" "truncated to fit" "$BODY"
assert_not_contains "the emptied Findings header is gone" "### Findings (2)" "$BODY"
assert_contains "the section that kept its items stays" "### What a human should review" "$BODY"
assert_not_contains "no placeholder survives truncation" "{{LINK:" "$BODY"
# The budget is measured pre-expansion, so what survives is judged that way too.
RAW_KEPT=$(printf '%s' "$BODY" | grep -c 'files#diff-')
if [ "$RAW_KEPT" -gt 3 ]; then
  echo "OK:   truncation kept $RAW_KEPT linked items (pre-expansion budgeting keeps far more than post-expansion did)"
else
  echo "FAIL: only $RAW_KEPT linked items survived — the budget is still being spent on expanded URLs"
  fail=$((fail + 1))
fi
rm -rf "$W"

# ── (k4) a body with no line break must not lose 100% of its content ─────────
# The line-boundary truncator exits on the first line that does not fit, so a
# single long line yielded a body of just the marker and the footer.
echo ""
echo "── (k4) hard cut when no line boundary fits ──"
W=$(mktemp -d)
LONGLINE="## Claude review — COMMENT: $(printf 'the review body arrived as one unbroken line %.0s' $(seq 1 120))"
jq -n --arg b "$LONGLINE" \
  '{verdict: "COMMENT", body: $b, comments: [], meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
BYTES=$(visible_body "$BODY" | wc -c | tr -d ' ')
assert_eq "exit 0" "0" "$RC"
assert_contains "the verdict header survives" "## Claude review — COMMENT" "$BODY"
assert_contains "real content survives the hard cut" "one unbroken line" "$BODY"
assert_contains "truncation is announced" "truncated to fit" "$BODY"
if [ "$BYTES" -gt $(( BUDGET - 400 )) ] && [ "$BYTES" -le "$BUDGET" ]; then
  echo "OK:   the single line was cut mid-line to fill the budget ($BYTES bytes)"
else
  echo "FAIL: single-line body came out $BYTES bytes — expected a mid-line cut near the $BUDGET budget"
  fail=$((fail + 1))
fi
rm -rf "$W"

# ── (k5) inline-XOR-body: a finding posted inline is stripped from the body ──
# skills/review-verify.md says each finding appears exactly once — inline OR as a
# `### Findings` bullet. The model does not hold that (observed on PR #109: two
# findings listed in the body AND posted inline on the same path:line), so the
# poster enforces it. Matching is against `kept` — the comments really going
# inline — on path+line OR path+title.
echo ""
echo "── (k5) findings posted inline are stripped from the body ──"

# k5a: every bullet in the section is a duplicate → the header goes with them.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n"
               + "### Findings (2)\n"
               + "- **critical** {{LINK:src/foo.ts:11}} — alpha loops forever\n"
               + "- **major** {{LINK:src/foo.ts:12}} — beta returns another tenant"),
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT", body: "**critical** alpha loops forever"},
                   {path: "src/foo.ts", line: 12, side: "RIGHT", body: "**major** beta returns another tenant"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "both findings posted inline" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
VIS=$(visible_body "$BODY")
STATE=$(state_block "$BODY")
assert_not_contains "the emptied Findings header is gone" "### Findings" "$VIS"
assert_not_contains "the critical is not repeated to the reader" "alpha loops forever" "$VIS"
assert_not_contains "the major is not repeated to the reader" "another tenant" "$VIS"
# …and the whole reason the strip is safe: both survive where round 2 will look.
assert_contains "the critical is carried in the review state" "alpha loops forever" "$STATE"
assert_contains "the major is carried in the review state" "another tenant" "$STATE"
assert_eq "both findings are in the state block" "2" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "state block is machine-readable" "1" "$(echo "$STATE" | jq '.v')"
assert_contains "the verdict prose survives" "Two blocking findings." "$VIS"
assert_contains "the strip is announced in the log" "duplicating an inline comment" "$OUT"
rm -rf "$W"

# k5b: one of two is a duplicate → the header renumbers to the survivor count.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n"
               + "### Findings (2)\n"
               + "- **critical** {{LINK:src/foo.ts:11}} — alpha loops forever\n"
               + "- **major** {{LINK:src/foo.ts:12}} — beta returns another tenant"),
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT", body: "**critical** alpha loops forever"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_contains "the header is renumbered to the survivor count" "### Findings (1)" "$BODY"
assert_not_contains "the stale count is gone" "### Findings (2)" "$BODY"
assert_not_contains "the inlined finding is stripped" "alpha loops forever" "$(visible_body "$BODY")"
assert_contains "the body-only finding survives" "another tenant" "$BODY"
rm -rf "$W"

# k5c: the comment was DROPPED out of hunk, so it is NOT in `kept` — its bullet
# is the only place the finding reaches the reader and must survive. Matching the
# model's ORIGINAL comment list instead of `kept` would erase it.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **critical** {{LINK:src/foo.ts:99}} — gamma drops the lock"),
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT", body: "**critical** gamma drops the lock"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "nothing posted inline" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the out-of-hunk finding keeps its Findings bullet" "gamma drops the lock" "$BODY"
assert_contains "and the section header stays at 1" "### Findings (1)" "$BODY"
assert_contains "the fallback section is still rendered" "### Also flagged (1)" "$BODY"
rm -rf "$W"

# k5d: only `### Findings` is de-duplicated. A human-review item may legitimately
# point at the very line a finding was posted on.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT",
        body: ("## Claude review — COMMENT\n\nOne finding, one open question.\n\n"
               + "### What a human should review\n"
               + "- [ ] {{LINK:src/foo.ts:11}} — confirm the retry budget matches the gateway timeout\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/foo.ts:11}} — alpha loops forever"),
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT", body: "**major** alpha loops forever"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_contains "the human-review section survives" "### What a human should review" "$BODY"
assert_contains "the human-review item on the same line survives" \
  "confirm the retry budget matches the gateway timeout" "$BODY"
assert_not_contains "the duplicated finding is stripped" "alpha loops forever" "$(visible_body "$BODY")"
assert_not_contains "and its emptied header with it" "### Findings" "$BODY"
rm -rf "$W"

# k5e: a bullet that shares neither the line nor the title is a different
# finding, not a duplicate — matching either half alone would silently delete it.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/foo.ts:12}} — delta off by one"),
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT", body: "**major** epsilon, a different defect"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the comment is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the off-by-one bullet is NOT stripped" "delta off by one" "$BODY"
assert_contains "the header keeps its count" "### Findings (1)" "$BODY"
rm -rf "$W"

# k5f: the strip runs BEFORE the budget, so the bytes it frees keep the
# remaining content out of the truncator.
W=$(mktemp -d)
K5_WIDE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,20 +1,20 @@\n" + ([range(20) | " ctx"] | join("\n")))}]' > "$K5_WIDE"
{ echo "## Claude review — REQUEST_CHANGES"; echo ""
  echo "Five defects survive verification across the broker's claim handling and the tenant cache."
  echo ""
  echo "### Findings (5)"
  for i in 1 2 3 4 5; do
    echo "- **major** {{LINK:src/foo.ts:$i}} — defect $i leaves the request in a state the caller cannot recover from, the retry path repeats it on every attempt, and the surrounding transaction is committed anyway so the damage is durable"
  done
} > "$W/dup-body.md"
NL=$(grep -o '{{LINK:' "$W/dup-body.md" | wc -l | tr -d ' ')
MEASURED=$(( $(wc -c < "$W/dup-body.md") - 9 * NL ))
if [ "$MEASURED" -gt 1200 ]; then
  echo "OK:   the fixture is over budget before the strip ($MEASURED bytes)"
else
  echo "FAIL: fixture is only $MEASURED bytes — it must be OVER 1200 to test this"; fail=$((fail + 1))
fi
jq -n --rawfile b "$W/dup-body.md" \
  '{verdict: "REQUEST_CHANGES", body: $b,
    comments: [range(1;4) | {path: "src/foo.ts", line: ., side: "RIGHT", body: "**major** defect \(.)"}],
    meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$K5_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_not_contains "stripping the duplicates kept it under budget" "truncated to fit" "$BODY"
assert_contains "the header renumbers to the two survivors" "### Findings (2)" "$BODY"
assert_contains "survivor 4 is intact" "defect 4 leaves the request" "$BODY"
assert_contains "survivor 5 is intact" "defect 5 leaves the request" "$BODY"
assert_not_contains "the inlined bullets are gone" "defect 1 leaves the request" "$BODY"
rm -rf "$W" "$K5_WIDE"

# k5g: THE RE-ANCHOR BUG. review-verify is told "Wrong anchor → fix it from your
# Read", so it may move a comment to a different hunk line than the one already
# written into the body bullet. path:line alone then misses and the reader gets
# the duplicate this strip exists to prevent. The title is identical in both by
# construction, so path+title catches it.
W=$(mktemp -d)
REANCHOR_FILES=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -40,6 +40,6 @@\n" + ([range(6) | " ctx"] | join("\n")))}]' > "$REANCHOR_FILES"
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/foo.ts:40}} — cache key omits the tenant"),
        comments: [{path: "src/foo.ts", line: 42, side: "RIGHT", body: "**major** cache key omits the tenant"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the re-anchored comment is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_eq "at the line verify re-anchored it to" "42" "$(echo "$PAYLOAD" | jq '.comments[0].line')"
assert_not_contains "the bullet two lines off is still stripped" "cache key omits the tenant" "$(visible_body "$BODY")"
assert_not_contains "and its emptied header with it" "### Findings" "$BODY"
rm -rf "$W"

# k5h: same path, same line, different title — the original exact match still
# strips. Title matching is an ADDITION to path:line, not a replacement.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/foo.ts:41}} — eta rewords the same defect"),
        comments: [{path: "src/foo.ts", line: 41, side: "RIGHT", body: "**major** eta, phrased differently inline"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the comment is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "the same-line bullet is stripped on the anchor alone" \
  "eta rewords the same defect" "$BODY"
rm -rf "$W"

# k5i: the same title in a DIFFERENT file is a different finding. Title alone
# would erase it, which is why the rule is path AND title.
W=$(mktemp -d)
TWOFILE_FIXTURE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -40,6 +40,6 @@\n" + ([range(6) | " ctx"] | join("\n")))},
        {filename: "src/bar.ts",
         patch: ("@@ -40,6 +40,6 @@\n" + ([range(6) | " ctx"] | join("\n")))}]' > "$TWOFILE_FIXTURE"
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/bar.ts:40}} — unbounded retry loop"),
        comments: [{path: "src/foo.ts", line: 42, side: "RIGHT", body: "**major** unbounded retry loop"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$TWOFILE_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the comment on the other file is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the same title in another file is NOT stripped" "unbounded retry loop" "$BODY"
assert_contains "the header keeps its count" "### Findings (1)" "$BODY"
rm -rf "$W" "$TWOFILE_FIXTURE"

# k5j: a title carrying backticks and its own em dashes. Only the FIRST ` — `
# after the placeholder is the separator; the ones inside the title are content
# and must not shift the extracted title.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne blocking finding.\n\n"
               + "### Findings (1)\n"
               + "- **major** {{LINK:src/foo.ts:40}} — `retry()` — the backoff — never caps"),
        comments: [{path: "src/foo.ts", line: 43, side: "RIGHT",
                    body: "**major** `retry()` — the backoff — never caps"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the comment is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "the backtick/em-dash title still matches" "never caps" "$(visible_body "$BODY")"
assert_not_contains "and its emptied header with it" "### Findings" "$BODY"
rm -rf "$W"

# k5k: a DROPPED comment (out of hunk) whose title matches a surviving bullet.
# It is not in `kept`, so it contributes no title key — its bullet is the only
# place that finding reaches the reader and must survive.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n"
               + "### Findings (2)\n"
               + "- **major** {{LINK:src/foo.ts:40}} — theta double-frees the buffer\n"
               + "- **major** {{LINK:src/foo.ts:41}} — zeta leaks the handle"),
        comments: [{path: "src/foo.ts", line: 40, side: "RIGHT", body: "**major** theta double-frees the buffer"},
                   {path: "src/foo.ts", line: 99, side: "RIGHT", body: "**major** zeta leaks the handle"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "only the in-hunk comment posts inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "the inlined finding's bullet is stripped" "theta double-frees" "$(visible_body "$BODY")"
assert_contains "the dropped comment's bullet survives" "zeta leaks the handle" "$BODY"
assert_contains "the header renumbers to the one survivor" "### Findings (1)" "$BODY"
assert_contains "and it is also listed as a fallback" "### Also flagged (1)" "$BODY"
rm -rf "$W"

# k5l: ONE-TO-ONE. Two bullets in the same file share a title and only one
# comment carries it — a set-membership test would delete both and silently lose
# the second finding, the same class of bug as the missed re-anchor. The first
# bullet claims the comment; the second finds nothing left and survives.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n"
               + "### Findings (2)\n"
               + "- **major** {{LINK:src/foo.ts:40}} — unchecked cast\n"
               + "- **major** {{LINK:src/foo.ts:41}} — unchecked cast"),
        comments: [{path: "src/foo.ts", line: 43, side: "RIGHT", body: "**major** unchecked cast"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the one comment is posted inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_eq "exactly one of the twin bullets is stripped" "1" \
  "$(visible_body "$BODY" | grep -c 'unchecked cast')"
assert_not_contains "the bullet that claimed the comment is gone" "[src/foo.ts:40]" "$BODY"
assert_contains "the finding no comment carries survives" "[src/foo.ts:41]" "$BODY"
assert_contains "the header renumbers to the survivor" "### Findings (1)" "$BODY"
rm -rf "$W"

# k5m: two comments really do carry both twins → both bullets go, header with them.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n"
               + "### Findings (2)\n"
               + "- **major** {{LINK:src/foo.ts:40}} — unchecked cast\n"
               + "- **major** {{LINK:src/foo.ts:41}} — unchecked cast"),
        comments: [{path: "src/foo.ts", line: 42, side: "RIGHT", body: "**major** unchecked cast"},
                   {path: "src/foo.ts", line: 43, side: "RIGHT", body: "**major** unchecked cast\n\nsecond site"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$REANCHOR_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "both comments are posted inline" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "both twin bullets are stripped" "unchecked cast" "$(visible_body "$BODY")"
assert_not_contains "and the emptied header with them" "### Findings" "$BODY"
assert_contains "the verdict prose survives" "Two blocking findings." "$BODY"
rm -rf "$W" "$REANCHOR_FILES"

# ── (l) inline comments: capped, critical/major first ───────────────────────
echo ""
echo "── (l) inline-comment cap ──"
W=$(mktemp -d)
WIDE_FILES=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,20 +1,20 @@\n" + ([range(20) | " ctx"] | join("\n")))}]' > "$WIDE_FILES"
jq -n '
  {verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nsee comments.",
   comments: (
     [range(1;5)   | {path: "src/foo.ts", line: (1 + .), side: "RIGHT", body: "**minor** minor \(.)"}] +
     [range(5;11)  | {path: "src/foo.ts", line: (1 + .), side: "RIGHT", body: "**critical** critical \(.)"}] +
     [range(11;17) | {path: "src/foo.ts", line: (1 + .), side: "RIGHT", body: "**major** major \(.)"}]),
   meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE_FILES" run_poster "$W"
PAYLOAD=$(payload_of "$W")
assert_eq "exit 0" "0" "$RC"
assert_eq "capped" "10" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_eq "all 6 criticals kept" "6" \
  "$(echo "$PAYLOAD" | jq '[.comments[] | select(.body | startswith("**critical**"))] | length')"
assert_eq "the remaining slots go to majors, not minors" "4" \
  "$(echo "$PAYLOAD" | jq '[.comments[] | select(.body | startswith("**major**"))] | length')"
assert_eq "no minor survives the cap" "0" \
  "$(echo "$PAYLOAD" | jq '[.comments[] | select(.body | startswith("**minor**"))] | length')"
assert_eq "criticals keep the model's own order" "6" \
  "$(echo "$PAYLOAD" | jq '.comments[0].line')"
rm -rf "$W" "$WIDE_FILES"

# ── (m) each inline comment <= 700 BYTES, cut suggestion fence dropped ───────
# jq's `length` counts CODEPOINTS, so the old clamp let a comment of accented
# text through at ~2x the budget. And a ```suggestion cut mid-block used to be
# re-closed — syntactically valid, semantically a one-click commit that deletes
# the tail of the replacement code. Drop the fence instead.
echo ""
echo "── (m) 700-byte inline budget ──"
W=$(mktemp -d)
jq -n '{verdict: "COMMENT",
        body: "## Claude review — COMMENT\n\nsee comment.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: ("**major** long one\n\nbreaks when x is null\n\n```suggestion\n"
                           + ([range(80) | "const someVeryLongLineOfCode = 1;"] | join("\n")) + "\n```")}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
CBODY=$(payload_of "$W" | jq -r '.comments[0].body')
CBYTES=$(printf '%s' "$CBODY" | wc -c | tr -d ' ')
assert_eq "exit 0" "0" "$RC"
if [ "$CBYTES" -le 700 ]; then
  echo "OK:   inline comment held to the budget ($CBYTES bytes)"
else
  echo "FAIL: inline comment is $CBYTES bytes, over the 700 budget"; fail=$((fail + 1))
fi
assert_not_contains "the cut suggestion fence is dropped, not re-closed" '```' "$CBODY"
assert_contains "the finding itself survives" "breaks when x is null" "$CBODY"
assert_contains "clamp is visible to the reader" "…" "$CBODY"
rm -rf "$W"

# ── (m2) the byte clamp holds for multibyte text ─────────────────────────────
# 900 `é` is 900 codepoints and 1800 bytes: the codepoint clamp emitted 696
# codepoints = 1383 bytes, near 2x the budget. Even pure ASCII overshot by 2
# (the ellipsis is 3 bytes, and the old clamp only reserved 1 char for it).
echo ""
echo "── (m2) the inline clamp counts bytes, not codepoints ──"
for glyph in "é" "→" "x"; do
  W=$(mktemp -d)
  jq -n --arg g "$glyph" '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nsee comment.",
     comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                 body: ("**major** t " + ([range(900) | $g] | join("")))}],
     meta: {findings: []}}' > "$W/review.json"
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  CBYTES=$(payload_of "$W" | jq -j '.comments[0].body' | wc -c | tr -d ' ')
  if [ "$CBYTES" -le 700 ]; then
    echo "OK:   900×'$glyph' clamped to $CBYTES bytes"
  else
    echo "FAIL: 900×'$glyph' clamped to $CBYTES bytes, over the 700 budget"; fail=$((fail + 1))
  fi
  rm -rf "$W"
done

# ── (n) meta the v4 pipeline no longer emits must not break the poster ───────
echo ""
echo "── (n) tolerates the slimmed schema ──"
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nno meta at all."}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0 with no comments and no meta" "0" "$RC"
assert_eq "posts an empty comment array" "0" "$(payload_of "$W" | jq '.comments | length')"
assert_contains "step summary still renders" "## Claude Review: COMMENT" "$(cat "$W/summary.md")"
rm -rf "$W"

# ── (p) round-2 state block ──────────────────────────────────────────────────
# The state block is the ONLY surface that carries a finding into the next round
# intact: 4a deletes inlined findings from the body and the truncator deletes
# overflow. It is appended after truncation, after expansion and after the
# footer, so it can neither evict content nor be evicted.
echo ""
echo "── (p) round-2 state block ──"
P_WIDE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,20 +1,20 @@\n" + ([range(20) | " ctx"] | join("\n")))}]' > "$P_WIDE"

# p1: two inline + one body-only finding, all three in the state block.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nThree findings.\n\n"
               + "### Findings (3)\n"
               + "- **critical** {{LINK:src/foo.ts:3}} — alpha loops forever\n"
               + "- **major** {{LINK:src/foo.ts:4}} — beta returns another tenant\n"
               + "- **minor** {{LINK:src/foo.ts:5}} — gamma logs the token"),
        comments: [{path: "src/foo.ts", line: 3, side: "RIGHT", body: "**critical** alpha loops forever"},
                   {path: "src/foo.ts", line: 4, side: "RIGHT", body: "**major** beta returns another tenant"}],
        meta: {findings: [
          {path: "src/foo.ts", line: 3, title: "alpha loops forever", severity: "critical", failure_scenario: "a 401 spins the refresh"},
          {path: "src/foo.ts", line: 4, title: "beta returns another tenant", severity: "major", failure_scenario: "warm cache serves tenant A to B"},
          {path: "src/foo.ts", line: 5, title: "gamma logs the token", severity: "minor", failure_scenario: "the bearer lands in stdout"}]}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "the state block carries all three findings" "3" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "it is versioned" "1" "$(echo "$STATE" | jq '.v')"
assert_eq "and stamped with the round" "1" "$(echo "$STATE" | jq '.round')"
assert_eq "every finding has an 8-hex id" "3" \
  "$(echo "$STATE" | jq '[.findings[] | select(.id | test("^[0-9a-f]{8}$"))] | length')"
assert_eq "every finding has path, line, severity and title" "3" \
  "$(echo "$STATE" | jq '[.findings[] | select(.p != "" and .l > 0 and .sev != "" and .t != "")] | length')"
assert_eq "the critical sorts first" "critical" "$(echo "$STATE" | jq -r '.findings[0].sev')"
rm -rf "$W"

# p2: THE HEADLINE REGRESSION. The truncator eats the whole `### Findings`
# section; the finding it deleted is still readable by the next round.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nThe broker rewrite drops a lock on the retry path and the tenant cache key is incomplete, so two user-reachable defects survive verification here.\n\n"
               + "### Findings (1)\n"
               + "- **critical** {{LINK:src/foo.ts:5}} — delta drops the lock"),
        comments: [],
        meta: {findings: [{path: "src/foo.ts", line: 5, title: "delta drops the lock",
                           severity: "critical", failure_scenario: "two writers enter the section"}]}}' > "$W/review.json"
BODY_MAX=200 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
VIS=$(visible_body "$BODY")
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_contains "the reader is told the body was cut" "truncated to fit" "$VIS"
assert_not_contains "and the finding really is gone from the body" "delta drops the lock" "$VIS"
assert_contains "but round 2 can still see it" "delta drops the lock" "$STATE"
assert_eq "with its severity intact" "critical" "$(echo "$STATE" | jq -r '.findings[0].sev')"
rm -rf "$W"

# p3: the block is outside the budget — adding findings must not shrink what the
# human sees.
W=$(mktemp -d)
P_BODY="## Claude review — COMMENT\n\nNothing blocking; two notes are posted inline."
jq -n --arg b "$P_BODY" '{verdict: "COMMENT", body: $b, comments: [], meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
VIS_EMPTY=$(visible_body "$(payload_of "$W" | jq -r '.body')" | wc -c | tr -d ' ')
rm -rf "$W"
W=$(mktemp -d)
jq -n --arg b "$P_BODY" '{verdict: "COMMENT", body: $b,
  comments: [{path: "src/foo.ts", line: 3, side: "RIGHT", body: "**major** epsilon leaks the handle"},
             {path: "src/foo.ts", line: 4, side: "RIGHT", body: "**minor** zeta logs too much"}],
  meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
VIS_FULL=$(visible_body "$(payload_of "$W" | jq -r '.body')" | wc -c | tr -d ' ')
assert_eq "the state block costs the reader nothing" "$VIS_EMPTY" "$VIS_FULL"
assert_eq "even though it carries two findings" "2" \
  "$(state_block "$(payload_of "$W" | jq -r '.body')" | jq '.findings | length')"
rm -rf "$W"

# p4: meta absent entirely — the floor is what the POSTER decided to post.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nno meta at all.",
        comments: [{path: "src/foo.ts", line: 3, side: "RIGHT", body: "**critical** eta corrupts the ledger"}]}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "the inline comment alone builds the state" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_contains "with the finding's own words" "eta corrupts the ledger" "$STATE"
rm -rf "$W"

# p4b: ONE finding worded two ways is ONE finding in the state.
# Observed live on qiv #1442: the model emitted 2 findings, and the state block
# recorded 3. Its meta.findings title ("Failed save fetch leaves the button on
# X") differed from the title it wrote at the top of the inline comment ("A
# failed save fetch leaves the button reading X"), and the id is path +
# normalised TITLE — so the same defect split in two. Round 2 then has to
# account for a finding that does not exist, and because a carried finding is
# KEPT when uncertain, the phantom carries forward every round after.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne finding.\n\n"
               + "### Findings (1)\n"
               + "- **minor** {{LINK:src/foo.ts:3}} — Failed save leaves the button on Saving"),
        comments: [{path: "src/foo.ts", line: 3, side: "RIGHT",
                    body: "**minor** A failed save fetch leaves the button reading Saving forever"}],
        meta: {findings: [
          {path: "src/foo.ts", line: 3, title: "Failed save leaves the button on Saving",
           severity: "minor", failure_scenario: "a rejected fetch never updates the label"}]}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "one defect on two surfaces is ONE state entry" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "…and it is recorded as having taken the inline slot" "true" \
  "$(echo "$STATE" | jq -r '.findings[0].inline')"

# …but two DIFFERENT findings on the same line are still two.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nTwo findings.\n\n"
               + "### Findings (2)\n"
               + "- **minor** {{LINK:src/foo.ts:3}} — the label never resets\n"
               + "- **minor** {{LINK:src/foo.ts:3}} — the token is logged here too"),
        comments: [],
        meta: {findings: [
          {path: "src/foo.ts", line: 3, title: "the label never resets",
           severity: "minor", failure_scenario: "a rejected fetch never updates the label"},
          {path: "src/foo.ts", line: 3, title: "the token is logged here too",
           severity: "minor", failure_scenario: "the bearer lands in stdout"}]}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "two real findings on one line stay two" "2" "$(echo "$STATE" | jq '.findings | length')"

# p5: a skip-marked body judged nothing — a state block there would tell round 2
# "round N found nothing", and section 5 must still leave the standing block up.
W=$(mktemp -d)
jq -n --arg body '<!-- claude-review-oversized -->

## Claude review — REQUEST_CHANGES

Too large to review well.' '{verdict: "REQUEST_CHANGES", body: $body, comments: [], meta: {findings: []}}' > "$W/review.json"
REVIEWS_FIXTURE=$(mktemp)
cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 778, "user": {"login": "claude-bot[bot]"}, "state": "CHANGES_REQUESTED",
   "body": "## Claude review — REQUEST_CHANGES\n\nprior round", "commit_id": "old2",
   "submitted_at": "2026-06-02T00:00:00Z"}
]
EOF
FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_not_contains "no state block on a review that judged nothing" "claude-review-state" "$BODY"
assert_not_contains "standing block still NOT dismissed" "dismissals" "$(cat "$W/gh.log")"
rm -rf "$W" "$REVIEWS_FIXTURE"

# p6: carry-forward, and the explicit NO-GATE test. A carried finding nobody
# accounted for stays in the state and gets a warning — it does NOT touch the
# verdict, and an APPROVE still posts as an APPROVE.
W=$(mktemp -d)
P_PRIORS=$(mktemp)
jq -n '[{id: "7f3a1c2b", p: "src/foo.ts", l: 42, sev: "critical",
         t: "cache key omits the tenant", fs: "tenant B sees A rows", r: 1}]' > "$P_PRIORS"
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nThe delta is clean.",
        comments: [], meta: {findings: [], resolved_prior: []}}' > "$W/review.json"
PRIOR_FINDINGS="$P_PRIORS" ROUND_N=2 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
STATE=$(state_block "$(echo "$PAYLOAD" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "the verdict is still the model's own" "APPROVE" "$(echo "$PAYLOAD" | jq -r '.event')"
assert_eq "the unaccounted critical is still carried" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "under its original id" "7f3a1c2b" "$(echo "$STATE" | jq -r '.findings[0].id')"
assert_eq "and its original first-seen round" "1" "$(echo "$STATE" | jq '.findings[0].r')"
assert_contains "the run log names it" "::warning::Carried finding 7f3a1c2b" "$OUT"
assert_contains "the step summary lists it" "### Carried from earlier rounds (1)" "$(cat "$W/summary.md")"
rm -rf "$W"

# p7: the same carry, resolved with evidence — gone from the state, no warning.
W=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nThe delta is clean.",
        comments: [], meta: {findings: [],
        resolved_prior: [{id: "7f3a1c2b", evidence: "the tenant id joins the cache key at line 138"}]}}' > "$W/review.json"
PRIOR_FINDINGS="$P_PRIORS" ROUND_N=2 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "the resolved finding is no longer carried" "0" "$(echo "$STATE" | jq '.findings | length')"
assert_not_contains "and nothing is warned about" "::warning::Carried finding" "$OUT"
assert_contains "the summary records it as resolved" "### Resolved since earlier rounds (1)" "$(cat "$W/summary.md")"
assert_contains "with the evidence that closed it" "joins the cache key at line 138" "$(cat "$W/summary.md")"
rm -rf "$W"

# p8: re-wording. `carried_from` re-keys the new finding to the old id, so the
# same defect is counted once and keeps the round it was FIRST seen.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nStill broken.",
        comments: [],
        meta: {findings: [{path: "src/foo.ts", line: 44, title: "the cache key still ignores tenancy",
                           severity: "critical", failure_scenario: "tenant B sees A rows",
                           carried_from: "7f3a1c2b"}]}}' > "$W/review.json"
PRIOR_FINDINGS="$P_PRIORS" ROUND_N=2 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "the re-worded finding is not a second finding" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "it adopts the carried id" "7f3a1c2b" "$(echo "$STATE" | jq -r '.findings[0].id')"
assert_eq "and keeps the round it was first seen" "1" "$(echo "$STATE" | jq '.findings[0].r')"
assert_contains "under this round's wording" "still ignores tenancy" "$STATE"
assert_not_contains "no unaccounted-carry warning" "::warning::Carried finding" "$OUT"
rm -rf "$W" "$P_PRIORS"

# p9: a title carrying every character that could break the carrier — a quote, a
# newline, backticks, an em dash, and a literal comment terminator.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne odd title.",
        comments: [],
        meta: {findings: [{path: "src/foo.ts", line: 3, severity: "major",
                           title: "`retry()` says \"soon\" — but -->\nnever caps",
                           failure_scenario: "the -->\"backoff\" never caps"}]}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "the state block is still valid JSON" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_not_contains "no literal terminator can close the block early" "\-\->" "$STATE"
assert_eq "one closing delimiter in the posted body" "1" \
  "$(printf '%s' "$BODY" | grep -c '^-->$')"
rm -rf "$W"

# p10: the state block has its own cap, so it can never evict visible content.
# It degrades by dropping failure scenarios, then the least severe findings.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nSix findings.",
        comments: [],
        meta: {findings: [
          {path: "src/a.ts", line: 3, title: "c1", severity: "critical", failure_scenario: "a long scenario that eats the budget all on its own"},
          {path: "src/b.ts", line: 4, title: "c2", severity: "critical", failure_scenario: "another long scenario that eats the budget"},
          {path: "src/c.ts", line: 5, title: "m1", severity: "major", failure_scenario: "a major scenario, also long"},
          {path: "src/d.ts", line: 6, title: "m2", severity: "major", failure_scenario: "a second major scenario, also long"},
          {path: "src/e.ts", line: 7, title: "n1", severity: "minor", failure_scenario: "a minor scenario"},
          {path: "src/f.ts", line: 8, title: "n2", severity: "minor", failure_scenario: "another minor scenario"}]}}' > "$W/review.json"
STATE_MAX=300 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "the block says it was degraded" "true" "$(echo "$STATE" | jq -r '.truncated')"
assert_eq "no minor survives the cap" "0" \
  "$(echo "$STATE" | jq '[.findings[] | select(.sev == "minor")] | length')"
if [ "$(echo "$STATE" | jq '[.findings[] | select(.sev == "critical")] | length')" -ge 1 ]; then
  echo "OK:   a critical survives the cap"
else
  echo "FAIL: the cap dropped every critical"; fail=$((fail + 1))
fi
STATE_BYTES=$(printf '%s' "$STATE" | wc -c | tr -d ' ')
if [ "$STATE_BYTES" -le 300 ]; then
  echo "OK:   the block held its own cap ($STATE_BYTES bytes)"
else
  echo "FAIL: the block is $STATE_BYTES bytes, over the 300 cap"; fail=$((fail + 1))
fi
rm -rf "$W"

# p11: no carry-over file at all — round 1, or a run whose consolidation failed.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
PRIOR_FINDINGS="$W/definitely-not-here.json" FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0 with no prior-findings file" "0" "$RC"
assert_contains "and a state block is still written" "claude-review-state" "$(payload_of "$W" | jq -r '.body')"
rm -rf "$W" "$P_WIDE"

# ── (o) house rules ──────────────────────────────────────────────────────────
echo ""
echo "── (o) house rules ──"
for sh in "$POSTER" "$(pwd)/scripts/prior-findings.sh"; do
  if grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$sh"; then
    echo "FAIL: ${sh##*/} uses set -e (banned, bugbot.md)"; fail=$((fail + 1))
  else
    echo "OK:   ${sh##*/} does not use set -e"
  fi
done
for dead in '\.resolve_threads' '\.bot_replies' resolveReviewThread functional-meta.json start_line; do
  if grep -qE "$dead" "$POSTER"; then
    echo "FAIL: post-review.sh still handles '$dead', which the v4 pipeline never produces"
    fail=$((fail + 1))
  else
    echo "OK:   no dead path for '$dead'"
  fi
done

# ── (k) human-review checks are inline comments ─────────────────────────────
# A check is a question, not a defect: it goes inline so a human can walk the
# review comment by comment, it carries no severity, and one that cannot be
# anchored comes back under its own heading rather than "Also flagged".
echo ""
echo "── (k) checks as inline comments ──"

# (k1) an anchorable check posts inline and writes no body section
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nOne finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:11}} — off-by-one",
  "comments": [
    {"path": "src/foo.ts", "line": 12, "side": "RIGHT", "body": "**check** confirm the tenant guard covers admins\n\nneeds a product decision"}
  ],
  "meta": {"findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11}],
           "human_review": [{"path": "src/foo.ts", "line": 12, "what_to_check": "confirm the tenant guard covers admins", "why_unresolved": "needs a product decision"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "the check posts inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "it keeps its **check** prefix" "**check** confirm the tenant guard" \
  "$(echo "$PAYLOAD" | jq -r '.comments[0].body')"
assert_not_contains "an anchored check writes no body heading" "What a human should review" "$BODY"
assert_contains "the unrelated finding bullet survives" "off-by-one" "$BODY"
rm -rf "$W"

# (k2) an unanchorable check returns under its own heading, never "Also flagged"
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nNothing is provably broken.",
  "comments": [
    {"path": "src/foo.ts", "line": 99, "side": "RIGHT", "body": "**check** confirm the migration is reversible\n\nneeds production data"}
  ],
  "meta": {"findings": [],
           "human_review": [{"path": "src/foo.ts", "line": 99, "what_to_check": "confirm the migration is reversible", "why_unresolved": "needs production data"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "nothing posts inline" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "it comes back under the human heading" "### What a human should review" "$BODY"
assert_contains "rendered as a checkbox with its question" \
  "- [ ] [src/foo.ts:99](" "$BODY"
assert_contains "the question survives the round trip" "confirm the migration is reversible" "$BODY"
assert_not_contains "a question is never 'Also flagged'" "Also flagged" "$BODY"
rm -rf "$W"

# (k3) a check must not strip a body bullet at the same path:line
# A check may legitimately sit on the same line as a finding. If it entered the
# inline-XOR-body strip index, it would delete that finding's `### Findings`
# bullet — and the finding is not posted inline, so it would vanish entirely.
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nOne finding.\n\n### Findings (2)\n- **major** {{LINK:src/foo.ts:11}} — off-by-one\n- **minor** {{LINK:src/foo.ts:12}} — other",
  "comments": [
    {"path": "src/foo.ts", "line": 12, "side": "RIGHT", "body": "**minor** other"},
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**check** is this loop bound intentional\n\nthe intent is ambiguous"}
  ],
  "meta": {"findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11},
                        {"title": "other", "severity": "minor", "path": "src/foo.ts", "line": 12}],
           "human_review": [{"path": "src/foo.ts", "line": 11, "what_to_check": "is this loop bound intentional", "why_unresolved": "the intent is ambiguous"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "both comments post inline" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the finding under the check keeps its bullet" "off-by-one" "$BODY"
assert_not_contains "the inline finding's own bullet is still stripped" "— other" "$BODY"
rm -rf "$W"

# ── (m) a functional finding carries a screenshot through the poster ─────────
# upload-screenshots.sh is covered in isolation, and the tester is covered by
# nothing that runs here — but the SEAM between them is this poster. A
# functional-derived finding is an ordinary `**severity**` comment whose body
# embeds the uploaded PNG, so it must classify as a finding (not a check), keep
# its URL intact, and fall back to `### Also flagged` rather than the
# human-review heading when it cannot be anchored.
echo ""
echo "── (m) screenshot-bearing functional finding ──"

SHOT='https://github.com/o/r/raw/review-assets/pr-7/checkout-step-3.png'

# (m1) in-hunk: posts inline with the embed intact, alongside a check
W=$(mktemp -d)
jq -n --arg shot "$SHOT" '
  {verdict: "COMMENT",
   body: "## Claude review — COMMENT\n\nOne reproduced failure.",
   comments: [
     {path: "src/foo.ts", line: 11, side: "RIGHT",
      body: ("**major** checkout total renders 0,00 after applying a voucher\n\nReproduced against the running app.\n\n![step 3](" + $shot + ")")},
     {path: "src/foo.ts", line: 12, side: "RIGHT",
      body: "**check** confirm the voucher rounding rule with finance\n\nneeds a product decision"}
   ],
   meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "both the finding and the check post inline" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the screenshot URL survives verbatim" "$SHOT" \
  "$(echo "$PAYLOAD" | jq -r '.comments[].body')"
assert_not_contains "the embed is not clamped mid-URL" "review-assets/pr-7/checkout-step-3.pn…" \
  "$(echo "$PAYLOAD" | jq -r '.comments[].body')"
assert_not_contains "no body heading is written when both anchored" "What a human should review" "$BODY"
rm -rf "$W"

# (m2) out-of-hunk: the finding goes to `### Also flagged`, the check to its own
# heading. A reproduced defect must never be filed as a question.
W=$(mktemp -d)
jq -n --arg shot "$SHOT" '
  {verdict: "COMMENT",
   body: "## Claude review — COMMENT\n\nOne reproduced failure.",
   comments: [
     {path: "src/foo.ts", line: 99, side: "RIGHT",
      body: ("**major** checkout total renders 0,00 after applying a voucher\n\n![step 3](" + $shot + ")")},
     {path: "src/foo.ts", line: 98, side: "RIGHT",
      body: "**check** confirm the voucher rounding rule with finance\n\nneeds a product decision"}
   ],
   meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "neither can be anchored" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the functional finding lands under Also flagged" "### Also flagged" "$BODY"
assert_contains "…carrying its severity" "**major**" "$BODY"
assert_contains "the check lands under its own heading" "### What a human should review" "$BODY"
assert_contains "…as a checkbox" "- [ ] " "$BODY"
# The discriminator: a screenshot comment misclassified as a check would be
# rendered as a question, losing the severity a reproduced defect carries.
CHECKS_SECTION=$(printf '%s' "$BODY" | awk '/^### What a human should review/{p=1;next} /^###/{p=0} p')
assert_not_contains "the finding is NOT filed as a question" "checkout total renders" "$CHECKS_SECTION"
rm -rf "$W"

# ── (n) a requested functional pass that never ran says so ──────────────────
# The reviewer asked for a browser test, got a static review, and nothing said
# why: the dev-env failure was silent. setup-dev-env.sh even promises it is
# "surfaced in the review body's setup-health section" — a section v4 deleted.
echo ""
echo "── (n) skipped functional pass is disclosed ──"

run_devenv_case() {  # $1=label $2=rc-file-content("" = none) $3=log lines
  W=$(mktemp -d); mkdir -p "$W/dev-env"
  printf '%s' "$VALID_REVIEW" > "$W/review.json"
  [ -n "$2" ] && printf '%s' "$2" > "$W/dev-env/rc"
  printf '%s\n' "$3" > "$W/dev-env/log"
  FUNCTIONAL_REQ="$1" DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
    FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(payload_of "$W" | jq -r '.body')
}

# (n1) requested + dev-env exited non-zero → notice carries the reason and the error
run_devenv_case true 1 "info: building
ERROR: docker compose up failed: port 5432 already allocated"
assert_contains "the skip is disclosed" "Functional pass requested but skipped" "$BODY"
assert_contains "…with the exit status" "exited 1" "$BODY"
assert_contains "…and the last error from the bring-up" "port 5432 already allocated" "$BODY"
assert_contains "…and says the review is static only" "static only" "$BODY"
assert_contains "the findings still post" "off-by-one" "$BODY"
rm -rf "$W"

# (n1b) THE REAL SHAPE: setup-dev-env.sh appends its own generic line AFTER the
# consumer script's `::error::`. Taking the last error-ish line quoted that
# tautology back at the reader; the cause must win.
run_devenv_case true 1 "info: building
::error::API never became ready at http://localhost:20001/api within 300s
ERROR: .github/claude-review/dev-start.sh exited non-zero — dev environment did not come up."
assert_contains "the notice quotes the CAUSE" "API never became ready" "$BODY"
assert_not_contains "…not the wrapper's tautology" "exited non-zero" "$BODY"
assert_not_contains "…and not the ::error:: marker itself" "::error::" "$BODY"
rm -rf "$W"

# (n2) requested + no rc at all → it timed out, not "exited"
run_devenv_case true "" "info: still installing"
assert_contains "a missing rc reads as a timeout" "did not finish starting in time" "$BODY"
assert_not_contains "…never as an exit status" "exited " "$BODY"
rm -rf "$W"

# (n3) requested + dev-env fine → no notice. A healthy run must stay quiet.
run_devenv_case true 0 "all good"
assert_not_contains "a healthy dev-env says nothing" "Functional pass requested but skipped" "$BODY"
rm -rf "$W"

# (n4) NOT requested + dev-env failed → still nothing. A code-only review must
# not be told about a browser it never asked for.
run_devenv_case false 1 "ERROR: boom"
assert_not_contains "an unrequested pass is not mentioned" "Functional pass requested" "$BODY"
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
