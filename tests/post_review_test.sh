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
# Real `gh api --input -` reads the body. A mock that exits without reading kills
# the upstream `jq` with SIGPIPE, and upload-screenshots.sh runs under
# `set -o pipefail` with `|| continue` — so a SUCCESSFUL upload is silently
# skipped, racily, on whichever file loses. Drain, don't keep: these payloads
# would otherwise land in GH_CAPTURE_DIR, which `payload_of` cats wholesale.
drain() { [ "$INPUT" = "-" ] && cat > /dev/null; return 0; }
case "$args" in
  *"--method PUT"*)
    echo '{}' ;;
  # The review-assets writes upload-screenshots.sh makes, driven through the
  # poster. Values come back already `--jq`-extracted, matching the mock in
  # upload_screenshots_test.sh. GH_ASSETS_FAIL=1 fails the blob POST so the
  # gallery's "published fewer than named" path is reachable.
  *"git/refs/heads/review-assets"*"--method PATCH"*)
    echo '{}' ;;
  *"git/refs/heads/review-assets"*)
    exit 1 ;;
  *"git/blobs"*)
    drain
    [ "${GH_ASSETS_FAIL:-0}" = "1" ] && exit 1
    echo "blobsha333" ;;
  *"git/trees"*)
    drain
    echo "treesha444" ;;
  *"git/commits"*"--method POST"*)
    echo "commitsha555" ;;
  *"git/refs"*"--method POST"*)
    echo '{}' ;;
  *"--method POST"*"/pulls/"*"/reviews"*)
    capture
    if [ "${GH_POST_FAIL:-0}" = "1" ]; then echo "HTTP 422: boom" >&2; exit 1; fi
    # GH_POST_NO_ID=1: the POST succeeds but the response carries no id. The
    # poster now reads the review list AFTER posting, so with no id to exclude
    # it cannot tell its own fresh review from a stale one.
    if [ "${GH_POST_NO_ID:-0}" = "1" ]; then echo '{"node_id": "PRR_x"}'; exit 0; fi
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
  # A HEALTHY DEV ENVIRONMENT IS THE DEFAULT. The poster suppresses the
  # screenshot gallery whenever the dev-env notice will render, because a body
  # cannot both claim `Functional pass: PASS — 3 screenshots` and report that no
  # browser test ran. A missing rc file means "never came up", so leaving it
  # missing would make every functional fixture below describe a broken run. The
  # cases that WANT a broken dev-env set DEVENV_RC themselves.
  printf '0' > "$work/healthy-dev-env-rc"
  # …AND ITS `started` MARKER. The poster now distinguishes "no bring-up was
  # started" from "one was started and finished", so a fixture with an rc but no
  # marker would describe an impossible run. Stamped in the past and the rc
  # touched to match, so the default reads "came up well inside the wait".
  printf '%s' "$(date +%s)" > "$work/healthy-dev-env-started"
  OUT=$(cd "$work" && \
    PATH="$MOCK_BIN:$PATH" \
    GH_LOG="$work/gh.log" GH_CAPTURE_DIR="$work/capture" \
    GH_FIXTURE_REVIEWS="${FIXTURE_REVIEWS:-}" GH_FIXTURE_FILES="${FIXTURE_FILES:-}" \
    GH_POST_FAIL="${POST_FAIL:-0}" GH_POST_NO_ID="${POST_NO_ID:-0}" \
    GH_TOKEN=x GITHUB_REPOSITORY=o/r PR_NUMBER=7 \
    REVIEW_BOT_USER="claude-bot[bot]" \
    HEAD_SHA="$( [ -n "${NO_HEAD_SHA:-}" ] && echo "" || echo abc123 )" GITHUB_STEP_SUMMARY="$work/summary.md" \
    GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}" GITHUB_RUN_ID="${RUN_ID:-}" \
    JOB_START="${JOB_START:-$work/no-job-start}" \
    SPEC_STATUS="$work/spec-status" \
    FUNCTIONAL_REQUESTED="${FUNCTIONAL_REQ:-}" \
    FUNCTIONAL_JSON="${FUNCTIONAL_FILE:-$work/no-such-functional.json}" \
    SCREENSHOT_DIR="${SHOT_DIR:-$work/no-such-shots}" \
    GH_ASSETS_FAIL="${ASSETS_FAIL:-0}" \
    DEV_ENV_RC_FILE="${DEVENV_RC:-$work/healthy-dev-env-rc}" \
    DEV_ENV_LOG_FILE="${DEVENV_LOG:-$work/no-such-log}" \
    DEV_ENV_STARTED_FILE="${DEVENV_STARTED:-$work/healthy-dev-env-started}" \
    DEV_ENV_TIMEOUT_SECONDS="${DEVENV_WAIT:-}" \
    REVIEW_JSON="$work/review.json" ORCH_LOG="$work/orchestrator-output.txt" \
    REVIEW_BODY_MAX="${BODY_MAX:-}" REVIEW_STATE_MAX="${STATE_MAX:-}" REVIEW_SCOPE="${SCOPE:-}" \
    ROUND="${ROUND_N:-}" \
    PRIOR_FINDINGS_JSON="${PRIOR_FINDINGS:-$work/no-such-priors.json}" \
    UNREVIEWED_FILE="${UNREVIEWED:-$work/no-such-unreviewed.txt}" \
    PRIOR_CHECKS_JSON="${PRIOR_CHECKS:-$work/no-such-prior-checks.json}" \
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
# Unescaped quote inside a string — the exact corruption seen in production.
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
# TWO, not one. $VALID_REVIEW's meta lists a single finding while the poster
# actually posts two — the in-hunk comment AND the out-of-hunk one that fell
# back to `### Also flagged`. #134 moved the summary onto the same floor the
# state block uses (`kept` + `dropped`, unioned with meta), because meta is
# model-written: a REQUEST_CHANGES carrying two criticals used to render
# `### Findings (0)`. The old "1" was the model's claim, not the review.
assert_contains "states the count the poster actually posted" "2 blocking finding" "$OUT"
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
#
# THE FIXTURE CHANGED IN #134 AND THE ASSERTION DID NOT. It used to make the two
# findings merely LATE in the file, which emptied the section only because the
# truncator cut by POSITION — the very defect #134 fixed. A **major** finding
# outranking twenty unrated checklist items is now the correct outcome, so the
# section is emptied the only way that is still meaningful: bullets that cannot
# fit at ANY position.
echo ""
echo "── (k3) truncation never leaves a dangling section header ──"
W=$(mktemp -d)
OVERLONG=$(python3 -c 'print("a bullet longer than the entire byte budget, " * 45, end="")')
{ echo "## Claude review — COMMENT"; echo ""
  echo "### What a human should review"
  for i in $(seq 1 20); do
    echo "- [ ] {{LINK:src/pkg/module$i/service.ts:$i}} — check the boundary condition on this call path carefully"
  done
  echo ""
  echo "### Findings (2)"
  echo "- **major** {{LINK:src/late/one.ts:9}} — $OVERLONG"
  echo "- **minor** {{LINK:src/late/two.ts:9}} — $OVERLONG"
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
# …and it is listed ONCE. The body already carries this finding, so a second
# bullet under `### Also flagged` would print it twice, back to back. The
# fallback exists for a dropped comment the body does NOT name; this is not one.
assert_not_contains "no duplicate fallback bullet for a finding the body lists" \
  "### Also flagged" "$BODY"
assert_eq "the finding is printed exactly once" "1" \
  "$(printf '%s\n' "$(visible_body "$BODY")" | grep -c 'gamma drops the lock')"
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
# …and is NOT also repeated under `### Also flagged`. The surviving bullet is
# already the fallback for this dropped comment; a second one prints it twice.
assert_not_contains "it is not repeated under a fallback header" "### Also flagged" "$BODY"
assert_eq "the dropped finding is printed exactly once" "1" \
  "$(printf '%s\n' "$(visible_body "$BODY")" | grep -c 'zeta leaks the handle')"
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
# The bullet is deliberately LONGER THAN THE WHOLE BUDGET: the truncator now
# skips an over-long line and keeps trying the rest (a single long paragraph used
# to drop every finding after it), so a finding is only really cut when it cannot
# fit at any position. That is the case this test needs.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nThe broker rewrite drops a lock on the retry path and the tenant cache key is incomplete, so two user-reachable defects survive verification here.\n\n"
               + "### Findings (1)\n"
               + "- **critical** {{LINK:src/foo.ts:5}} — delta drops the lock on the retry path, and every writer that enters the critical section while it is released commits its own partial state over the previous one, so the damage is durable and invisible until a reconciliation run notices the divergence weeks later"),
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
# Observed live: the model emitted 2 findings, and the state block
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

# p6b: replies are not state — re-read from the API every round, and at 2.1 KB
# per finding they would evict findings from the 4000-byte block, via a degrade
# path that sheds .fs and whole findings but has no idea .re exists.
W=$(mktemp -d)
P_RE=$(mktemp)
jq -n --arg big "$(head -c 700 /dev/zero | tr '\0' 'x')" '
  [{id: "7f3a1c2b", p: "src/foo.ts", l: 42, sev: "critical",
    t: "cache key omits the tenant", fs: "tenant B sees A rows", r: 1,
    re: [{who: "author", at: "2026-09-01", body: $big},
         {who: "author", at: "2026-09-02", body: $big},
         {who: "author", at: "2026-09-02", body: $big}]}]' > "$P_RE"
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nThe delta is clean.",
        comments: [], meta: {findings: [], resolved_prior: []}}' > "$W/review.json"
PRIOR_FINDINGS="$P_RE" ROUND_N=2 FIXTURE_REVIEWS="" FIXTURE_FILES="$P_WIDE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "the finding is still carried" "1" "$(echo "$STATE" | jq '.findings | length')"
assert_eq "…with no reply payload in the state" "null" "$(echo "$STATE" | jq -r '.findings[0].re // "null"')"
assert_eq "…and its scenario intact, not degraded away" "tenant B sees A rows" \
  "$(echo "$STATE" | jq -r '.findings[0].fs')"
rm -rf "$W" "$P_RE"

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
# `start_line` was on this list until check comments grew block anchoring. It is
# live now, so removing it here is the point — not an oversight.
for dead in '\.resolve_threads' '\.bot_replies' resolveReviewThread functional-meta.json; do
  if grep -qE "$dead" "$POSTER"; then
    echo "FAIL: post-review.sh still handles '$dead', which the v4 pipeline never produces"
    fail=$((fail + 1))
  else
    echo "OK:   no dead path for '$dead'"
  fi
done

# ── (k) human-review checks are inline comments ─────────────────────────────
# A check is an orientation note, not a defect: it goes inline so a human can
# walk the diff note by note, it carries no severity, and one that cannot be
# anchored comes back under its own heading rather than "Also flagged".
# The `meta.human_review` fixtures carry the LIVE item shape
# (start_line/end_line/what_to_know/spec_ref) — the step summary reads
# `.end_line // .line` and `.what_to_know`, so a fixture on the dead
# what_to_check shape would render an empty description and pass silently.
echo ""
echo "── (k) checks as inline comments ──"

# (k1) an anchorable check posts inline and writes no body section
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nOne finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:11}} — off-by-one",
  "comments": [
    {"path": "src/foo.ts", "line": 12, "side": "RIGHT", "body": "**check** `assertTenant` scopes the query to the caller tenant before the admin override runs\n\n- Implements AC3 of `docs/tenancy-prd.md`"}
  ],
  "meta": {"findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11}],
           "human_review": [{"path": "src/foo.ts", "start_line": 11, "end_line": 12, "what_to_know": "assertTenant scopes the query to the caller tenant before the admin override runs", "spec_ref": "AC3 of docs/tenancy-prd.md"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "the check posts inline" "1" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "it keeps its **check** prefix" "**check** \`assertTenant\` scopes the query" \
  "$(echo "$PAYLOAD" | jq -r '.comments[0].body')"
assert_not_contains "an anchored check writes no body heading" "What a human should review" "$BODY"
assert_contains "the unrelated finding bullet survives" "off-by-one" "$BODY"
# The step summary reads the LIVE item shape. An empty `what_to_know` — which is
# what the dead what_to_check fixture rendered — fails this outright.
assert_contains "the step summary lists the note" "### For a human to review (1)" \
  "$(cat "$W/summary.md")"
assert_contains "…with what the block does, not an empty description" \
  "assertTenant scopes the query to the caller tenant" "$(cat "$W/summary.md")"
assert_contains "…anchored at the block end_line, not a missing line field" \
  "\`src/foo.ts:12\`" "$(cat "$W/summary.md")"
rm -rf "$W"

# (k2) an unanchorable check returns under its own heading, never "Also flagged"
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nNothing is provably broken.",
  "comments": [
    {"path": "src/foo.ts", "line": 99, "side": "RIGHT", "body": "**check** the migration backfills `tenant_id` on existing rows before the NOT NULL constraint lands\n\n- Implements AC1 of `docs/tenancy-prd.md`"}
  ],
  "meta": {"findings": [],
           "human_review": [{"path": "src/foo.ts", "start_line": 95, "end_line": 99, "what_to_know": "the migration backfills tenant_id on existing rows before the NOT NULL constraint lands", "spec_ref": "AC1 of docs/tenancy-prd.md"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "nothing posts inline" "0" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "it comes back under the human heading" "### What a human should review" "$BODY"
assert_contains "rendered as a checkbox with its note" \
  "- [ ] [src/foo.ts:99](" "$BODY"
assert_contains "the note survives the round trip" "the migration backfills" "$BODY"
assert_not_contains "a note is never 'Also flagged'" "Also flagged" "$BODY"
assert_contains "the step summary carries it too" \
  "backfills tenant_id on existing rows" "$(cat "$W/summary.md")"
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
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**check** `collectPage` walks the batch once per tenant and stops at the page ceiling\n\n- Implements AC5 of `docs/tenancy-prd.md`"}
  ],
  "meta": {"findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11},
                        {"title": "other", "severity": "minor", "path": "src/foo.ts", "line": 12}],
           "human_review": [{"path": "src/foo.ts", "start_line": 10, "end_line": 11, "what_to_know": "collectPage walks the batch once per tenant and stops at the page ceiling", "spec_ref": "AC5 of docs/tenancy-prd.md"}]}
}
EOF
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W"); BODY=$(echo "$PAYLOAD" | jq -r '.body')
assert_eq "both comments post inline" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_contains "the finding under the check keeps its bullet" "off-by-one" "$BODY"
assert_not_contains "the inline finding's own bullet is still stripped" "— other" "$BODY"
rm -rf "$W"

# ── (u) files a scan shard never reviewed are named, and carried in the state ──
# merge-scans.sh lists them; the poster must tell the reader and stamp them into
# the state block, or the next delta round never reads them.
echo ""
echo "── (u) unreviewed files reach the reader and the next round ──"
W=$(mktemp -d)
printf 'src/lost-a.ts\nsrc/lost-b.ts\n' > "$W/unreviewed.txt"
printf '%s' "$VALID_REVIEW" > "$W/review.json"
UNREVIEWED="$W/unreviewed.txt" FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_contains "the reader is told which files no shard reviewed" "2 file(s) were not reviewed this round" "$(visible_body "$BODY")"
assert_contains "…by name" '`src/lost-a.ts`' "$(visible_body "$BODY")"
assert_eq "…and the state block carries them for the next round" "src/lost-a.ts src/lost-b.ts" "$(state_block "$BODY" | jq -r '.unreviewed | join(" ")')"
rm -rf "$W"
# The count the reader sees is the count that was stamped; a list past the cap
# says so instead of promising a carry that does not happen.
W=$(mktemp -d)
seq 1 250 | sed 's|^|src/f|;s|$|.ts|' > "$W/unreviewed.txt"
printf '%s' "$VALID_REVIEW" > "$W/review.json"
UNREVIEWED="$W/unreviewed.txt" FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
N_STAMPED=$(state_block "$BODY" | jq '.unreviewed | length')
assert_eq "the stamped list is capped by bytes, not the raw 250" "capped" "$( [ "$N_STAMPED" -gt 0 ] && [ "$N_STAMPED" -lt 250 ] && echo capped || echo "not capped: $N_STAMPED" )"
assert_eq "…to at most half the state budget" "fits" "$( [ "$(state_block "$BODY" | jq -cj '.unreviewed' | wc -c | tr -d ' ')" -le 2000 ] && echo fits || echo over )"
assert_contains "…and the notice counts what was stamped, not the raw file" "$N_STAMPED of 250 are carried" "$(visible_body "$BODY")"
assert_eq "…and the carried findings were not shed to make room" "2" "$(state_block "$BODY" | jq '.findings | length')"
rm -rf "$W"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_not_contains "no unreviewed files → no notice" "not reviewed this round" "$BODY"
assert_eq "…and no key in the state block" "null" "$(state_block "$BODY" | jq -r '.unreviewed')"
# (k4) a check an earlier round posted on the same path:line is not posted again
# Checks have no cross-round carry-over, so round 4 posted the same check round 2
# had on the same line. A finding on that line is untouched, and the drop is
# announced rather than silent.
W=$(mktemp -d)
echo '[{"p": "src/foo.ts", "l": 11}]' > "$W/prior-checks.json"
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nRound two.",
  "comments": [
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**check** `collectPage` stops at the page ceiling, said again"},
    {"path": "src/foo.ts", "line": 12, "side": "RIGHT", "body": "**check** `flushBatch` writes the tenant id before the row"},
    {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**major** off-by-one"}
  ],
  "meta": {"findings": [{"title": "off-by-one", "severity": "major", "path": "src/foo.ts", "line": 11}], "human_review": []}
}
EOF
PRIOR_CHECKS="$W/prior-checks.json" FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
PAYLOAD=$(payload_of "$W")
assert_eq "the repeated check is dropped, the new check and the finding post" "2" "$(echo "$PAYLOAD" | jq '.comments | length')"
assert_not_contains "the repeated check is gone" "said again" "$PAYLOAD"
assert_contains "the new check on another line posts" "flushBatch" "$PAYLOAD"
assert_contains "the finding on the same line is untouched" "off-by-one" "$PAYLOAD"
assert_contains "the drop is announced" "1 check comment(s) not re-posted" "$OUT"
assert_not_contains "…and never falls back to the body heading" "What a human should review" "$(echo "$PAYLOAD" | jq -r '.body')"
rm -rf "$W"

# (k4b) a range check is remembered by the line it was POSTED on. A range over
# 50 lines collapses onto start_line before posting, so prior-checks.json holds
# the start; the next round's same check must match on that line too.
W=$(mktemp -d)
echo '[{"p": "src/foo.ts", "l": 10}]' > "$W/prior-checks.json"
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nRound three.",
  "comments": [
    {"path": "src/foo.ts", "start_line": 10, "line": 13, "side": "RIGHT", "body": "**check** `collectPage` stops at the page ceiling, ranged"}
  ],
  "meta": {"findings": [], "human_review": []}
}
EOF
PRIOR_CHECKS="$W/prior-checks.json" FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "a ranged check whose start a prior round posted is dropped" "0" "$(payload_of "$W" | jq '.comments | length')"
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

# (n3) THE SILENT CASE, AND THE WHOLE POINT OF THE BLOCK. A healthy rc is NOT
# evidence a tester ran: on one measured run the bring-up returned 0 with API and
# web both up, but only after the orchestrator's wait had expired, so no tester
# was ever dispatched — and because this block gated on `rc != 0`, the review
# said nothing at all. Requested + no functional.json = a notice is owed,
# whatever the rc says.
run_devenv_case true 0 "all good"
assert_contains "a healthy rc does NOT buy silence" "Functional pass requested but skipped" "$BODY"
assert_contains "…and it is a visible alert, not small print" "> [!WARNING]" "$BODY"
assert_contains "…saying no browser test ran" "No browser test ran" "$BODY"
assert_not_contains "…and never blaming a bring-up that worked" "did not finish starting" "$BODY"
rm -rf "$W"

# (n3b) rc 0 but written AFTER the wait expired — the exact production shape.
# "Came up 40s late" is a knob to turn; "never came up" is a broken bring-up.
# Reporting them identically is what made the real run unreadable.
W=$(mktemp -d); mkdir -p "$W/dev-env"
printf '%s' "$VALID_REVIEW" > "$W/review.json"
printf '0' > "$W/dev-env/rc"
printf '%s' "$(( $(date +%s) - 400 ))" > "$W/dev-env/started"
printf 'all good\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
  DEVENV_STARTED="$W/dev-env/started" DEVENV_WAIT=360 \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_contains "a late bring-up is named as late" "past the 360s the reviewer waits" "$BODY"
assert_contains "…and the fix is named" "dev_env_timeout_seconds" "$BODY"
assert_not_contains "…not reported as a failure it was not" "exited" "$BODY"
rm -rf "$W"

# (n3c) requested, but no bring-up was ever started (docs-only diff, or the repo
# ships no dev-start.sh). Still disclosed — the reader asked for a browser test —
# but never as a timeout, which would blame a script that never ran.
W=$(mktemp -d); mkdir -p "$W/dev-env"
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/no-rc" DEVENV_STARTED="$W/dev-env/no-started" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_contains "the skip is still disclosed" "Functional pass requested but skipped" "$BODY"
assert_contains "…as 'nothing was started'" "no dev environment was started" "$BODY"
assert_not_contains "…never as a timeout" "did not finish starting in time" "$BODY"
rm -rf "$W"

# (n3d) the tester DID run and the bring-up was clean → total silence. The banner
# must never appear over a pass that happened.
W=$(mktemp -d); mkdir -p "$W/dev-env" "$W/shots"
printf '%s' "$VALID_REVIEW" > "$W/review.json"
printf '0' > "$W/dev-env/rc"; printf '%s' "$(date +%s)" > "$W/dev-env/started"
printf '{"overall":"PASS","summary":"ok","screenshots":[],"untested":[]}' > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" \
  DEVENV_RC="$W/dev-env/rc" DEVENV_STARTED="$W/dev-env/started" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_not_contains "a completed pass gets no banner" "> [!WARNING]" "$BODY"
assert_not_contains "…and no skip claim" "Functional pass requested but skipped" "$BODY"
rm -rf "$W"

# (n4) NOT requested + dev-env failed → still nothing. A code-only review must
# not be told about a browser it never asked for.
run_devenv_case false 1 "ERROR: boom"
assert_not_contains "an unrequested pass is not mentioned" "Functional pass requested" "$BODY"
rm -rf "$W"

# ── (r) check comments anchor to the whole block ────────────────────────────
# A question about a handler pinned to one arbitrary line makes the reviewer
# reconstruct the block themselves. `start_line` anchors it to the code being
# questioned. GitHub 422s a malformed range and the POST is ATOMIC, so a bad
# range must collapse to a single-line comment rather than kill every comment.
echo ""
echo "── (r) block-anchored check comments ──"

# The shared fixture hunk covers RIGHT 10-13 in src/foo.ts.
check_review() { # check_review <start_line> <line>
  jq -n --argjson s "$1" --argjson l "$2" \
    '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne question.",
      comments: [{path: "src/foo.ts", start_line: $s, line: $l, side: "RIGHT",
                  body: "**check** `onRefuse` shows the refusal and skips the claim before navigating the fan\n\n- Implements AC3 of `docs/prds/fan-claim.md`\n- Refusal path and claim path share `navigate()`"}],
      meta: {findings: [], human_review: []}}'
}

# (r1) a range fully inside the hunk posts as a range
W=$(mktemp -d); check_review 10 13 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
assert_eq "exit 0" "0" "$RC"
assert_eq "the range survives to the POST" "10" "$(echo "$C" | jq -r '.start_line')"
assert_eq "…with a start_side GitHub requires" "RIGHT" "$(echo "$C" | jq -r '.start_side')"
assert_eq "…anchored at the end line" "13" "$(echo "$C" | jq -r '.line')"
rm -rf "$W"

# (r2) a range only PARTLY in the diff degrades to a single-line comment. It must
# not take the comment down with it: one note asked for 226-253 across a
# sparse diff, the whole check was rejected, and the question landed in the body
# — the one place a check must never be, because there nobody reads it.
W=$(mktemp -d); check_review 4 13 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "the check still posts inline" "1" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "…with the unusable range dropped" "null" \
  "$(payload_of "$W" | jq -r '.comments[0].start_line // "null"')"
assert_eq "…anchored at the end line" "13" "$(payload_of "$W" | jq -r '.comments[0].line')"
assert_not_contains "and it is NOT pushed into the body" "### What a human should review" "$BODY"
rm -rf "$W"

# (r2b) only an anchor line that is itself out of hunk falls back to the body.
W=$(mktemp -d); check_review 4 99 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "an unanchorable check posts nothing inline" "0" "$(payload_of "$W" | jq '.comments | length')"
assert_contains "…and only then reaches the body" "### What a human should review" "$BODY"
rm -rf "$W"

# (r3) a malformed range (start at or past the anchor) collapses to single-line
# instead of being dropped — the question is still worth asking.
for pair in "13 13" "13 11"; do
  set -- $pair
  W=$(mktemp -d); check_review "$1" "$2" > "$W/review.json"
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  C=$(payload_of "$W" | jq -c '.comments[0]')
  assert_eq "start=$1 line=$2 posts inline" "1" "$(payload_of "$W" | jq '.comments | length')"
  assert_eq "…as a single-line comment" "null" "$(echo "$C" | jq -r '.start_line // "null"')"
  rm -rf "$W"
done

# (r4) an absurd range is not a "block". Needs its own WIDE hunk: against the
# shared 10-13 fixture an over-long range is rejected for being out of hunk, so
# it would never reach the size rule at all.
#
# THE CAP IS 50, NOT 120. A range renders as a grey band down the diff, and past
# roughly fifty lines nobody reads the band — one review shipped a 119-line one
# and it read as noise. 120 was chosen to cover 96% of contiguous changed runs;
# coverage was the wrong thing to optimise. The cap still has to
# exist, because a run whose hunks could not be derived skips the in-hunk range
# check entirely and a 422 on a malformed range kills the ATOMIC post.
WIDE_FIXTURE=$(mktemp)
python3 - "$WIDE_FIXTURE" <<'WIDE'
import json, sys
patch = "@@ -10,300 +10,300 @@\n" + "\n".join(" line%d" % i for i in range(10, 310))
json.dump([{"filename": "src/foo.ts", "patch": patch}], open(sys.argv[1], "w"))
WIDE
W=$(mktemp -d); check_review 10 200 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE_FIXTURE" run_poster "$W"
assert_eq "a 190-line range still posts" "1" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "…collapsed to one line, not wrapping half the file" "null" \
  "$(payload_of "$W" | jq -r '.comments[0].start_line // "null"')"
# The boundary itself: 50 lines is a block, 51 is not.
W2=$(mktemp -d); check_review 20 70 > "$W2/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE_FIXTURE" run_poster "$W2"
assert_eq "exactly 50 lines is still a block" "20" \
  "$(payload_of "$W2" | jq -r '.comments[0].start_line // "null"')"
W3=$(mktemp -d); check_review 20 71 > "$W3/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE_FIXTURE" run_poster "$W3"
assert_eq "51 lines is not" "null" \
  "$(payload_of "$W3" | jq -r '.comments[0].start_line // "null"')"
# THE COLLAPSE LANDS ON THE START, NOT THE END — the regression that produced
# this cap. A measured run anchored a 120→239 note at 239, so the orientation
# arrived under the code it was meant to introduce. A rejected range must move
# the anchor up to the block opening, never leave it at the foot.
assert_eq "…and it collapses onto the block opening, not its last line" "20" \
  "$(payload_of "$W3" | jq -r '.comments[0].line // "null"')"
W4=$(mktemp -d); check_review 20 40 > "$W4/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$WIDE_FIXTURE" run_poster "$W4"
assert_eq "a 20-line block keeps its range" "20" \
  "$(payload_of "$W4" | jq -r '.comments[0].start_line // "null"')"
rm -rf "$W" "$W2" "$W3" "$W4" "$WIDE_FIXTURE"

# (r5) findings are unaffected: no start_line in, none out
W=$(mktemp -d); echo "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "a finding posts without a range" "null" \
  "$(payload_of "$W" | jq -r '.comments[0].start_line // "null"')"
rm -rf "$W"

# ── (r6) the spec link in a check comment ─────────────────────────────
# {{DOC:}} EXISTS BECAUSE {{LINK:}} CANNOT DO THIS. {{LINK:}} builds a
# `/pull/N/files#diff-<sha>` anchor, which only resolves for a file THIS PR
# changed. A governing spec is normally already merged and absent from the diff,
# so a {{LINK:}} to it lands on the Files tab and scrolls nowhere. {{DOC:}}
# points at the blob at HEAD_SHA instead.
#
# AND IT HAD TO BE TAUGHT TO INLINE COMMENTS. Expansion ran over the body alone,
# because until the spec link every placeholder lived there — so the first
# {{DOC:}} in a comment would have posted as literal braces.
echo ""
echo "── (r6) the spec link expands inside an inline comment ──"

doc_review() { # doc_review <placeholder>
  jq -n --arg ph "$1" \
    '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne note.",
      comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                  body: ("**check** `collectPage` stops at the page ceiling, so a tenant past it is silently truncated.\n\n" + $ph)}],
      meta: {findings: [], human_review: []}}'
}

W=$(mktemp -d); doc_review '{{DOC:docs/tenancy-prd.md:47}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
CB=$(payload_of "$W" | jq -r '.comments[0].body')
assert_contains "the placeholder resolves to a blob link at HEAD_SHA" \
  "https://github.com/o/r/blob/abc123/docs/tenancy-prd.md#L47" "$CB"
assert_contains "…rendered as the document path, not a bare URL" \
  "[docs/tenancy-prd.md](" "$CB"
assert_not_contains "…and no raw placeholder survives to GitHub" "{{DOC:" "$CB"
assert_contains "the prose above it is untouched" "silently truncated" "$CB"
rm -rf "$W"

# NO REF, NO LINK. HEAD_SHA is optional env, and a blob URL needs a ref: without
# one the only candidate is `blob/HEAD`, which silently points at whatever the
# default branch says today. A spec's line numbers move, so that link would rot
# into a confident pointer at the wrong paragraph. review-scan.md tells the model
# a stale link is worse than none; this is that rule enforced in the poster.
W=$(mktemp -d); doc_review '{{DOC:docs/tenancy-prd.md:47}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" NO_HEAD_SHA=1 run_poster "$W"
CB=$(payload_of "$W" | jq -r '.comments[0].body')
assert_contains "with no HEAD_SHA the path renders as plain code" '`docs/tenancy-prd.md`' "$CB"
assert_not_contains "…and never as a blob/HEAD link that would rot" "blob/HEAD" "$CB"
assert_not_contains "…and no raw placeholder survives" "{{DOC:" "$CB"
rm -rf "$W"

# A comment carrying no placeholder must come through byte-identical — the
# expansion pass is keyed off a grep, and a body-rewriting step that runs when it
# has nothing to do is how comments get mangled.
W=$(mktemp -d); check_review 10 13 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_contains "a comment with no placeholder is left alone" \
  "onRefuse\` shows the refusal" "$(payload_of "$W" | jq -r '.comments[0].body')"
rm -rf "$W"

# ── (q) a PASS publishes its screenshots ─────────────────────────────────────
# THE REGRESSION THIS PINS. v4 asked the orchestrator to run
# upload-screenshots.sh and embed the URLs "in the relevant comment body", but
# review-verify only writes a comment when the tester REPRODUCED a failure — so
# a PASS produced no comment, the upload never ran, and the captures died in the
# run artifact. The poster now owns both, so the gallery appears with no
# finding, no comment and nothing the model had to remember.
echo ""
echo "── (q) the functional screenshot gallery ──"

CLEAN_REVIEW='{"verdict":"APPROVE","body":"## Claude review — APPROVE\n\nNothing to flag.","comments":[],"meta":{"findings":[],"human_review":[]}}'

# 1x1 PNG, so `file --mime-type` in upload-screenshots.sh sees a real image.
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
make_shots() { # make_shots <dir> <name>...
  local d="$1"; shift
  mkdir -p "$d"
  for n in "$@"; do printf '%s' "$PNG_B64" | base64 -d > "$d/$n"; done
}

# (q1) PASS, zero findings → gallery in the body, outside the budget
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png 02-detail.png
jq -n '{overall: "PASS", summary: "Drove the order flow.",
        observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1 — list page with seeded data"},
                      {file: "/tmp/screenshots/02-detail.png", description: "AC2 — detail view"}]}'   > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots"   FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "no comment was needed to publish them" "0" "$(payload_of "$W" | jq '.comments | length')"
assert_contains "the gallery is there" "<details><summary>Functional pass: PASS — 2 screenshots</summary>" "$BODY"
assert_contains "first shot is labelled once, above the image" "**AC1 — list page with seeded data**" "$BODY"
assert_contains "…and embeds its uploaded URL" "![](https://github.com/o/r/raw/review-assets/pr-7/01-list.png)" "$BODY"
# The alt text is invisible on GitHub, so repeating the caption there only
# doubles the source the reader scrolls past to reach the next shot.
assert_not_contains "the caption is not duplicated into the alt text" "![AC1 —" "$BODY"
assert_contains "second shot too" "![](https://github.com/o/r/raw/review-assets/pr-7/02-detail.png)" "$BODY"
assert_contains "…with its own label" "**AC2 — detail view**" "$BODY"
assert_contains "the branch was actually written" "git/refs --method POST" "$(cat "$W/gh.log")"
# The gallery is appended after truncation and never measured, exactly like the
# state block — a run's own evidence must not evict a finding.
assert_contains "the verdict line survives alongside it" "## Claude review — APPROVE" "$BODY"
assert_not_contains "…and nothing was truncated to make room" "truncated to fit the review budget" "$BODY"
rm -rf "$W"

# (q2) singular, and a caption that would break out of the markdown or the HTML
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png
jq -n '{overall: "WARN", summary: "Partial run.", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1 [bracketed] <script>alert(1)</script>"}]}'   > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots"   FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "one shot reads as singular" "WARN — 1 screenshot</summary>" "$BODY"
assert_not_contains "a bracket cannot swallow the URL" "[bracketed]" "$BODY"
assert_not_contains "a caption cannot open a tag" "<script>" "$BODY"
assert_contains "the URL is still intact" "(https://github.com/o/r/raw/review-assets/pr-7/01-list.png)" "$BODY"
rm -rf "$W"

# (q2b) a long caption is cut on a word boundary, not mid-word. Observed on
# Measured: the tester's own descriptions ran past 120 chars and the body
# rendered "…the app has already la" and "…access code has e".
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png
jq -n '{overall: "FAIL", summary: "long", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png",
                       description: "AC1 — after submitting sign-up with the exhausted code: refusal notification shown correctly, but the app has already landed the fan on the audience"}]}' \
  > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a long caption is elided" "…" "$BODY"
assert_not_contains "…not cut mid-word" "notificatio…" "$BODY"
assert_not_contains "…and the tail is dropped" "already landed" "$BODY"
assert_contains "it ends on a whole word" "refusal notification…" "$BODY"
rm -rf "$W"

# (q2c) untested criteria are surfaced. A live run verified 3 of 7 criteria,
# listed the other 4 in `untested` with real reasons, and correctly reported
# PASS — "everything you exercised held". The body then said only
# "Functional pass: PASS — 2 screenshots", so a reader saw a green functional
# pass over a third of the spec. The tester was honest; the poster lost it.
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png
jq -n '{overall: "PASS", summary: "Partial.", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1 — list page"}],
        untested: ["AC2 — the dev seed has only one tenant-admin persona",
                   "AC3 — same seed limitation as AC2",
                   "AC7 — fill dialog not reached before the time budget ran out"]}' \
  > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the gap count is in the summary line, not buried" \
  "PASS — 1 screenshot · 3 criteria not verified</summary>" "$BODY"
assert_contains "the gaps are listed" "**Not verified by this run**" "$BODY"
assert_contains "…each one of them" "- AC7 — fill dialog not reached before the time budget ran out" "$BODY"
assert_contains "…alongside the screenshot" "**AC1 — list page**" "$BODY"
rm -rf "$W"

# (q2d) a run with gaps but NO screenshots still reports them. Nothing to
# upload is not the same as nothing to say.
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
jq -n '{overall: "WARN", summary: "Could not reach the app.", observations: [],
        screenshots: [], untested: ["AC1 — login wall, no seeded credentials"]}' \
  > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/no-shots" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "gaps reach the reader with no screenshots" "0 screenshots · 1 criteria not verified" "$BODY"
assert_contains "…and are listed" "AC1 — login wall, no seeded credentials" "$BODY"
assert_eq "…without calling the upload" "0" "$(grep -c 'git/blobs' "$W/gh.log")"
rm -rf "$W"

# (q3) the tester named a shot the upload could not publish → no half-broken
# embed, and the job log says how many were lost
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png
jq -n '{overall: "PASS", summary: "ok", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1"}]}' > "$W/functional.json"
ASSETS_FAIL=1 FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots"   FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "the review still posts" "0" "$RC"
assert_not_contains "no gallery is claimed" "<details><summary>Functional pass" "$BODY"
assert_contains "the loss is announced in the log" "were not published" "$OUT"
rm -rf "$W"

# (q4) the pass was never requested, or the tester never ran → silence, and NO
# upload. A repo carrying its own PNGs must never have them published as review
# evidence (checkout rewrites mtimes, so "recent" cannot discriminate — PR #30).
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" wl_logo.png
jq -n '{overall: "SKIP", summary: "No acceptance criteria.", observations: [], screenshots: []}'   > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots"   FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "a SKIP renders no gallery" "Functional pass:" "$BODY"
assert_eq "…and uploads nothing" "0" "$(grep -c 'git/blobs' "$W/gh.log")"
rm -rf "$W"

W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" wl_logo.png
jq -n '{overall: "PASS", summary: "ok", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1"}]}' > "$W/functional.json"
FUNCTIONAL_REQ=false FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots"   FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "an unrequested pass renders no gallery" "Functional pass:" "$BODY"
assert_eq "…and uploads nothing either" "0" "$(grep -c 'git/blobs' "$W/gh.log")"
rm -rf "$W"

# ── (s) a RANGE IS CHECKS-ONLY — a finding must never carry start_line ───────
# THE ONE BUG IN HERE THAT CAN DAMAGE A PR. skills/review-verify.md says ranges
# are "checks only" and that findings stay single-line because "a suggestion
# fence must replace exact lines". The range logic was applied to every comment
# instead, so a finding carrying a ```suggestion``` fence posted with
# start_line:10 line:13 made GitHub's Apply-suggestion button replace ALL FOUR
# lines with the one-line fix — silently deleting three lines of real code from
# the contributor's branch.
echo ""
echo "── (s) ranges are checks-only; findings stay single-line ──"

ranged_comment() { # ranged_comment <first-line-marker> <extra-body>
  jq -n --arg m "$1" --arg x "$2" \
    '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne item.",
      comments: [{path: "src/foo.ts", start_line: 10, line: 13, side: "RIGHT",
                  body: ($m + "\n\n" + $x)}],
      meta: {findings: [], human_review: []}}'
}

# (s1) THE DAMAGING CASE: a finding whose body carries a suggestion fence.
W=$(mktemp -d)
ranged_comment "**major** off-by-one in the loop bound" \
  '```suggestion
  for (let i = 0; i < xs.length; i++) {
```' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
assert_eq "exit 0" "0" "$RC"
assert_eq "the finding still posts inline" "1" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "a finding with a fence carries NO start_line" "null" "$(echo "$C" | jq -r '.start_line // "null"')"
assert_eq "…and no start_side either" "null" "$(echo "$C" | jq -r '.start_side // "null"')"
assert_eq "…and still anchors on its own line" "13" "$(echo "$C" | jq -r '.line')"
assert_contains "…with the suggestion intact" "suggestion" "$(echo "$C" | jq -r '.body')"
rm -rf "$W"

# (s2) every severity, fence or not — the rule is about KIND, not about whether
# this particular finding happened to include a fence.
for sev in critical major minor; do
  W=$(mktemp -d)
  ranged_comment "**$sev** the handler swallows the error" "detail" > "$W/review.json"
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  assert_eq "a $sev finding gets no range" "null" \
    "$(payload_of "$W" | jq -r '.comments[0].start_line // "null"')"
  rm -rf "$W"
done

# (s3) a CHECK still gets its block — the whole point of ranges. This is the
# other half of the rule: fixing (s1) by deleting ranges outright would undo
# fix/check-anchor-stays-in-diff.
W=$(mktemp -d)
ranged_comment "**check** Should a refused code still navigate the fan?" "detail" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
assert_eq "a check keeps its range" "10" "$(echo "$C" | jq -r '.start_line')"
assert_eq "…with the start_side GitHub requires" "RIGHT" "$(echo "$C" | jq -r '.start_side')"
assert_eq "…anchored at the end line" "13" "$(echo "$C" | jq -r '.line')"
rm -rf "$W"

# ── (t) the truncator SKIPS an over-long line, it does not stop at one ───────
# mode=fit used to `break` on the first line over the remaining budget and emit
# nothing further. Models write one line per paragraph, so a single long summary
# paragraph above `### Findings` dropped ITSELF AND EVERY FINDING AFTER IT.
# Measured on a real run: a 2492-byte first paragraph plus 15 findings produced a
# 496-byte body containing zero findings — while the job log said "posted 15
# findings" and 1300 of the 1800 bytes went unspent.
echo ""
echo "── (t) a long leading paragraph must not evict the findings ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'LONGPARA'
import json, sys
para = "This PR reworks the seat-allocation pipeline end to end. " * 45
lines = ["## Claude review — COMMENT", "", para, "", "### Findings (15)"]
for i in range(1, 16):
    lines.append("- **major** {{LINK:src/foo.ts:%d}} — finding number %d about the allocator" % (10 + i, i))
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
LONGPARA
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
SURVIVORS=$(printf '%s\n' "$BODY" | grep -c 'finding number')
assert_eq "all 15 findings survive the over-long paragraph" "15" "$SURVIVORS"
assert_contains "the heading survives too" "### Findings" "$BODY"
assert_contains "the reader is told something was cut" "truncated to fit" "$BODY"
# The paragraph itself is what did not fit; the budget went to the findings.
assert_not_contains "the over-long paragraph is the thing dropped" \
  "This PR reworks the seat-allocation pipeline" "$BODY"
# And the budget is actually SPENT, not abandoned at the first long line.
assert_eq "the body uses most of its budget" "1" \
  "$([ "$(printf '%s' "$BODY" | wc -c | tr -d ' ')" -gt 1000 ] && echo 1 || echo 0)"
rm -rf "$W"

# (t2) hardcut is preserved: when not even one line fits, cut mid-line rather
# than post an empty body.
W=$(mktemp -d)
python3 - "$W/review.json" <<'NOFIT'
import json, sys
one = "A single unbroken paragraph with no line break anywhere in it. " * 40
json.dump({"verdict": "COMMENT", "body": one, "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
NOFIT
BODY_MAX=300 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a body with no line break is still hard-cut, not lost" \
  "A single unbroken paragraph" "$BODY"
rm -rf "$W"

# ── (u) a finding is printed ONCE, and no header count lies ──────────────────
# The XOR strip matches only against `kept` (comments actually posted inline), by
# design — a bullet for a DROPPED comment is the fallback and must survive. But
# models emit findings on BOTH surfaces, so a comment that overflowed the cap
# kept its `### Findings` bullet AND collected a new `### Also flagged` one, and
# the reader saw the same finding twice, back to back. At 25 the duplicate list
# overflowed the budget and the truncator cut it, leaving `### Findings (15)` as
# a header over 9 bullets with 6 findings reaching nobody.
echo ""
echo "── (u) no finding twice, no header count that lies ──"

# Every `### Header (n)` must equal the bullets that actually follow it.
assert_honest_counts() { # assert_honest_counts <label> <body>
  local label="$1" bad
  bad=$(printf '%s\n' "$2" | awk '
    function flush() {
      if (hdr != "" && claimed >= 0 && claimed != n)
        print hdr " claims " claimed " over " n " bullet(s)"
    }
    /^[ \t]*###/ { flush(); hdr = $0; claimed = -1; n = 0
                   if (match($0, /\([0-9]+\)/)) claimed = substr($0, RSTART + 1, RLENGTH - 2) + 0
                   next }
    /^[ \t]*[-*][ \t]/ { n++ }
    END { flush() }')
  if [ -z "$bad" ]; then echo "OK:   $label"
  else echo "FAIL: $label — $bad"; fail=$((fail + 1)); fi
}

U_WIDE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,40 +1,40 @@\n" + ([range(40) | " ctx"] | join("\n")))}]' > "$U_WIDE"

# dup_review <n> — n findings listed in the body AND emitted as n comments, the
# double-surface shape models actually produce.
dup_review() {
  python3 - "$1" <<'DUP'
import json, sys
n = int(sys.argv[1])
lines = ["## Claude review — REQUEST_CHANGES", "", "Several issues.", "", "### Findings (%d)" % n]
comments = []
for i in range(1, n + 1):
    ln = 1 + (i % 30)
    lines.append("- **major** {{LINK:src/foo.ts:%d}} — finding %02d title" % (ln, i))
    comments.append({"path": "src/foo.ts", "line": ln, "side": "RIGHT",
                     "body": "**major** finding %02d title\n\ndetail" % i})
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines), "comments": comments,
           "meta": {"findings": [], "human_review": []}}, open("/dev/stdout", "w"))
DUP
}

# (u1) 15 comments: 10 go inline, 5 overflow the cap. The 5 already have body
# bullets, so they must NOT also appear under `### Also flagged`.
W=$(mktemp -d)
dup_review 15 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$U_WIDE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "10 posted inline" "10" "$(payload_of "$W" | jq '.comments | length')"
DUPES=""
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
  c=$(printf '%s\n' "$BODY" | grep -c "finding $i title")
  [ "$c" -gt 1 ] && DUPES="$DUPES finding-$i(x$c)"
done
assert_eq "no finding is printed twice at 15" "" "$DUPES"
assert_honest_counts "no header count lies at 15" "$BODY"
# The overflowed findings still reach the reader — via the bullet they already had.
for i in 11 12 13 14 15; do
  assert_contains "finding $i still reaches the reader" "finding $i title" "$BODY"
done
rm -rf "$W"

# (u2) 25 comments: 10 inline, 15 overflow. This is the shape that used to
# overflow the budget on its own duplicates and cut real findings away.
W=$(mktemp -d)
dup_review 25 > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$U_WIDE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "still 10 inline" "10" "$(payload_of "$W" | jq '.comments | length')"
DUPES=""
MISSING=""
for i in 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  c=$(printf '%s\n' "$BODY" | grep -c "finding $i title")
  [ "$c" -gt 1 ] && DUPES="$DUPES finding-$i(x$c)"
  [ "$c" -eq 0 ] && MISSING="$MISSING finding-$i"
done
assert_eq "no finding is printed twice at 25" "" "$DUPES"
assert_eq "every over-cap finding still reaches the reader at 25" "" "$MISSING"
assert_honest_counts "no header count lies at 25" "$BODY"
rm -rf "$W"

# (u3) the count must also be honest after the TRUNCATOR cuts bullets, not just
# after the strip. mode=fit renumbers; it used to leave the model's number.
W=$(mktemp -d)
python3 - "$W/review.json" <<'STALE'
import json, sys
lines = ["## Claude review — COMMENT", "", "Intro.", "", "### Findings (15)"]
for i in range(1, 16):
    lines.append("- **major** {{LINK:src/foo.ts:%d}} — finding %02d with a long descriptive title that eats budget quickly"
                 % (1 + (i % 30), i))
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
STALE
BODY_MAX=700 FIXTURE_REVIEWS="" FIXTURE_FILES="$U_WIDE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the body really was truncated" "truncated to fit" "$BODY"
assert_not_contains "the model's stale count is gone" "### Findings (15)" "$BODY"
assert_honest_counts "the header renumbers to what survived truncation" "$BODY"
rm -rf "$W"

# (u4) the fallback is NOT suppressed when the body genuinely does not list the
# finding — that is the whole reason `### Also flagged` exists. Guards against
# "fixing" the duplicate by deleting the fallback outright.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nsee comments.",
        comments: [range(1;14) | {path: "src/foo.ts", line: (1 + .), side: "RIGHT",
                                  body: "**major** finding \(.)"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$U_WIDE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a body that lists nothing still gets its fallback" "### Also flagged (3)" "$BODY"
assert_honest_counts "and that fallback count is honest too" "$BODY"
rm -rf "$W" "$U_WIDE"

# ── (v) a malformed comment entry is DISCARDED LOUDLY ───────────────────────
# This script's header promises NOTHING IS SILENTLY DROPPED. A `null` or
# non-object entry in `comments` was removed by `map(select(type == "object"))`
# without a word — and under the inline-XOR-body rule the body carries no bullet
# for it, so whatever it flagged reached the human nowhere at all.
echo ""
echo "── (v) malformed comment entries are announced ──"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nIntro.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT", body: "**major** a real one"},
                   null, "a bare string", 42],
        meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "exit 0" "0" "$RC"
assert_contains "the discard is a ::warning::" "::warning::" "$OUT"
assert_contains "…naming how many were discarded" "3 malformed comment entries discarded" "$OUT"
assert_eq "the well-formed comment still posts" "1" "$(payload_of "$W" | jq '.comments | length')"
rm -rf "$W"

# (v2) a clean list says nothing — the warning must not fire on every review.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_not_contains "a well-formed list is not warned about" "malformed comment entries" "$OUT"
rm -rf "$W"

# ── (w) a CHECK never becomes an immortal round-2 finding ────────────────────
# The state block was built from split.json's `dropped` array with no `kind`
# filter, so a **check** that overflowed the cap was persisted as a finding with
# `sev: ""`. Round 2 can never "resolve" a question, so it was carried forever
# and rendered as `(, src/foo.ts)`. kept-keys.txt and fallback.md both already
# excluded checks; this arm was the one that missed it.
echo ""
echo "── (w) an over-cap check stays out of the state block ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'CHECKCAP'
import json, sys
comments = []
for i in range(1, 11):
    comments.append({"path": "src/foo.ts", "line": 1 + (i % 20), "side": "RIGHT",
                     "body": "**major** finding %02d title\n\ndetail" % i})
comments.append({"path": "src/foo.ts", "line": 7, "side": "RIGHT",
                 "body": "**check** Is the fan refund path intentional?\n\ndetail"})
json.dump({"verdict": "REQUEST_CHANGES", "body": "## Claude review — REQUEST_CHANGES\n\nIntro.",
           "comments": comments, "meta": {"findings": [], "human_review": []}},
          open(sys.argv[1], "w"))
CHECKCAP
W_WIDE=$(mktemp)
jq -n '[{filename: "src/foo.ts",
         patch: ("@@ -1,20 +1,20 @@\n" + ([range(20) | " ctx"] | join("\n")))}]' > "$W_WIDE"
FIXTURE_REVIEWS="" FIXTURE_FILES="$W_WIDE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "the cap still holds" "10" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "the over-cap check is NOT carried as a finding" "0" \
  "$(echo "$STATE" | jq '[.findings[] | select(.t | test("fan refund"))] | length')"
# The real tell: a check has no severity, so it could only ever be persisted with
# an empty one. No state finding may have an empty severity.
assert_eq "no state finding carries an empty severity" "0" \
  "$(echo "$STATE" | jq '[.findings[] | select(.sev == "")] | length')"
assert_eq "the 10 real findings are still carried" "10" "$(echo "$STATE" | jq '.findings | length')"
# …and the question still reaches a human, under its own heading, not as a finding.
assert_contains "the check reaches the reader as a question" \
  "### What a human should review" "$(visible_body "$BODY")"
rm -rf "$W" "$W_WIDE"

# ── (x) the body cannot contradict itself about the functional pass ─────────
# SHOT_GALLERY (2c) and DEV_ENV_NOTICE (2b) were computed independently, so a run
# printed `Functional pass: PASS — 3 screenshots` two lines above `⚠ Functional
# pass requested but skipped — the dev environment exited 5. No browser test
# ran`. Both cannot be true. And the notice was appended AFTER the footer, so a
# warning trailed the cost/logs line that is supposed to close the review.
#
# CORRECTED BY THE SECOND AUDIT. The first fix resolved the contradiction the
# wrong way round — it deleted the screenshots and kept "No browser test ran",
# even though a `functional.json` with a real `overall` is first-hand evidence
# the tester ran and rc is only written by a LATER phase (see (y6)). The
# contradiction is still impossible; the surviving side is now the evidence.
echo ""
echo "── (x) gallery and dev-env notice cannot contradict ──"

W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png 02-detail.png 03-cart.png
jq -n '{overall: "PASS", summary: "Drove the order flow.", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1"},
                      {file: "/tmp/screenshots/02-detail.png", description: "AC2"},
                      {file: "/tmp/screenshots/03-cart.png", description: "AC3"}]}' > "$W/functional.json"
mkdir -p "$W/dev-env"; printf '5' > "$W/dev-env/rc"
printf '::error::API never became ready at http://localhost:20001/api within 300s\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots" \
  DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" RUN_ID=99 \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the screenshots the tester took survive a missing rc" \
  "Functional pass: PASS — 3 screenshots" "$BODY"
assert_contains "the dev-env record is still disclosed" "The dev environment exited 5" "$BODY"
assert_not_contains "…but never as a claim that no browser test ran" \
  "No browser test ran" "$BODY"
assert_not_contains "…nor that the pass was skipped" "requested but skipped" "$BODY"
assert_contains "the cause is still quoted" "API never became ready" "$BODY"
rm -rf "$W"

# (x2) THE FOOTER CLOSES THE REVIEW. The notice is content and belongs above it.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
mkdir -p "$W/dev-env"; printf '1' > "$W/dev-env/rc"
printf 'ERROR: docker compose up failed\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" RUN_ID=99 \
  SPEC_STATE=none FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
NOTICE_LINE=$(printf '%s\n' "$BODY" | grep -n 'requested but skipped' | head -1 | cut -d: -f1)
SPEC_LINE=$(printf '%s\n' "$BODY" | grep -n 'No spec resolved' | head -1 | cut -d: -f1)
FOOTER_LINE=$(printf '%s\n' "$BODY" | grep -n 'logs\](' | head -1 | cut -d: -f1)
assert_eq "the dev-env notice comes BEFORE the footer" "1" \
  "$([ -n "$NOTICE_LINE" ] && [ -n "$FOOTER_LINE" ] && [ "$NOTICE_LINE" -lt "$FOOTER_LINE" ] && echo 1 || echo 0)"
assert_eq "the spec notice does too" "1" \
  "$([ -n "$SPEC_LINE" ] && [ -n "$FOOTER_LINE" ] && [ "$SPEC_LINE" -lt "$FOOTER_LINE" ] && echo 1 || echo 0)"
assert_eq "nothing follows the footer" "" \
  "$(printf '%s\n' "$BODY" | awk -v f="$FOOTER_LINE" 'NR > f && $0 !~ /^[ \t]*$/')"
rm -rf "$W"

# (x3) a healthy dev-env still gets its gallery — the suppression must be keyed
# on the failure, not on the gallery being inconvenient.
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png
jq -n '{overall: "PASS", summary: "ok", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1"}]}' > "$W/functional.json"
mkdir -p "$W/dev-env"; printf '0' > "$W/dev-env/rc"; printf 'all good\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots" \
  DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a healthy dev-env still publishes the gallery" "Functional pass: PASS" "$BODY"
assert_not_contains "…and says nothing about a skip" "requested but skipped" "$BODY"
rm -rf "$W"

# ── (y) the SECOND audit: five regressions from #131, and two older holes ────
# Everything below was introduced or left standing by the previous round's own
# fixes. Each block names the defect it pins and the shape that produced it.

# ── (y1) the fallback filter must not delete a DIFFERENT finding ─────────────
# `fbfilter` reused `isdup()`, which matches path+line OR path+title and never
# looks at severity. The XOR strip can afford that — it matches against comments
# actually being posted, where the same comment supplies both keys — but the
# fallback is matched against arbitrary `### Findings` bullets. So a dropped
# CRITICAL was deleted outright because an unrelated MINOR happened to sit at the
# same line, and the log announced the deletion as a de-duplication.
echo ""
echo "── (y1) a fallback bullet is only dropped when it is the same finding ──"

# (y1a) the path:line key: a minor nit and a critical at the same line.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nOne nit, one real bug.\n\n### Findings (1)\n- **minor** {{LINK:src/foo.ts:99}} — variable name is unclear",
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: "**critical** SQL injection via string concatenation\n\ndetail"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the critical still reaches the reader" \
  "SQL injection via string concatenation" "$BODY"
assert_contains "…under Also flagged, where a dropped comment belongs" "### Also flagged (1)" "$BODY"
assert_contains "…and the minor keeps its own bullet" "variable name is unclear" "$BODY"
assert_not_contains "nothing is announced as a duplicate" \
  "'Also flagged' bullet(s) the body already lists" "$OUT"
rm -rf "$W"

# (y1b) the path+title key: same words, different severity, different line.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nTwo unrelated items.\n\n### Findings (1)\n- **minor** {{LINK:src/foo.ts:11}} — unused import",
        comments: [{path: "src/foo.ts", line: 77, side: "RIGHT",
                    body: "**critical** unused import\n\nthe module is loaded for its side effect, which runs the migration twice"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a same-titled critical is not eaten by a minor" "### Also flagged (1)" "$BODY"
assert_contains "…and it carries its own severity and line" "**critical** [src/foo.ts:77](" "$BODY"
rm -rf "$W"

# (y1c) THE OTHER DIRECTION: a genuine double-surface finding is still de-duped.
# Guards against "fixing" (y1a) by never dropping anything — the bug #131 fixed.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nOne finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:11}} — off-by-one in the loop bound",
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: "**major** off-by-one in the loop bound\n\ndetail"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "the same finding is not printed twice" "### Also flagged" "$BODY"
assert_eq "…and it is printed once" "1" \
  "$(printf '%s\n' "$BODY" | grep -c 'off-by-one in the loop bound')"
rm -rf "$W"

# ── (y2) a CHECK MUST NOT CARRY A COMMITTABLE FENCE ──────────────────────────
# #131 kept ranges for checks on the strength of a prompt rule — "a check never
# carries a fence". Nothing enforced it, so a `**check**` with a ```suggestion```
# fence posted with start_line:10 line:13 AND the fence, and one click replaced
# four lines of real code with one. The range is the feature; the fence is the
# hazard, so the fence goes.
echo ""
echo "── (y2) a check keeps its range and loses its suggestion fence ──"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne question.",
        comments: [{path: "src/foo.ts", start_line: 10, line: 13, side: "RIGHT",
                    body: "**check** Should an expired token still refresh the session?\n\nThe block below assumes it may.\n\n```suggestion\n  if (token.expired) return null;\n```\n\nThat is the shape I would expect."}],
        meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
CBODY=$(echo "$C" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the check still posts inline" "1" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "…and keeps the range that is the whole point of a check" "10" "$(echo "$C" | jq -r '.start_line')"
assert_eq "…anchored at the end line" "13" "$(echo "$C" | jq -r '.line')"
assert_not_contains "no committable fence survives on a check" 'suggestion' "$CBODY"
assert_not_contains "…nor the replacement code it would have committed" \
  "if (token.expired) return null;" "$CBODY"
assert_contains "the question itself is untouched" \
  "Should an expired token still refresh the session?" "$CBODY"
assert_contains "…and so is the prose after the fence" "That is the shape I would expect." "$CBODY"
assert_contains "the strip is announced, never silent" "fence" "$OUT"
rm -rf "$W"

# (y2b) a FINDING's fence is still posted — it is single-line, so applying it
# replaces exactly the line it is anchored to. Only the range is the danger.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne finding.",
        comments: [{path: "src/foo.ts", start_line: 10, line: 13, side: "RIGHT",
                    body: "**major** off-by-one in the loop bound\n\n```suggestion\n  for (let i = 0; i < xs.length; i++) {\n```"}],
        meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
assert_eq "a finding still carries no range" "null" "$(echo "$C" | jq -r '.start_line // "null"')"
assert_contains "…and keeps its suggestion" "suggestion" "$(echo "$C" | jq -r '.body')"
rm -rf "$W"

# ── (y3) mode=fit must skip a BLOCK, not a LINE ──────────────────────────────
# #131 turned `break` into `continue` so one long paragraph could not evict the
# findings — but fit mode has none of strip mode's continuation tracking, so a
# skipped bullet left its indented sub-bullets behind, dangling under the NEXT
# bullet and reading as its detail. A skipped `###` header did the same to a
# whole section: blocking findings reparented under `### Also flagged`, filed as
# "could not be posted inline".
echo ""
echo "── (y3) a skipped line takes the block it owns with it ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'ORPHAN'
import json, sys
big = "the token is compared with == against a user-supplied string, " * 30
lines = ["## Claude review — REQUEST_CHANGES", "", "### Findings (2)",
         "- **critical** {{LINK:src/foo.ts:11}} — " + big,
         "  - the comparison is not constant-time",
         "  - and the fallback path skips the audit log",
         "- **minor** {{LINK:src/foo.ts:12}} — the variable name is unclear"]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
ORPHAN
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_not_contains "the over-long bullet is dropped" "the token is compared with ==" "$BODY"
assert_not_contains "…and its first sub-bullet goes with it" "not constant-time" "$BODY"
assert_not_contains "…and its second" "skips the audit log" "$BODY"
assert_contains "the next finding still stands" "the variable name is unclear" "$BODY"
assert_contains "…under a header that counts only what is left" "### Findings (1)" "$BODY"
rm -rf "$W"

# (y3b) the same rule one level up: a header that does not fit takes its bullets
# with it, instead of leaving them under the PRECEDING heading.
W=$(mktemp -d)
python3 - "$W/review.json" <<'REPARENT'
import json, sys
hdr = "### Findings (2) — " + ("the two blocking defects in the seat-allocation handler, " * 34)
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Also flagged (1)",
         "- {{LINK:src/bar.ts:5}} — a small note about naming", "",
         hdr,
         "- **critical** {{LINK:src/foo.ts:11}} — auth bypass on the refresh path",
         "- **major** {{LINK:src/foo.ts:12}} — the token leaks into the log"]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
REPARENT
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the section that fits is intact" "a small note about naming" "$BODY"
assert_eq "…and its count is still honest" "1" \
  "$(printf '%s\n' "$BODY" | grep -c '### Also flagged (1)')"
assert_not_contains "a blocking finding never reparents under Also flagged" \
  "auth bypass on the refresh path" "$BODY"
assert_not_contains "…neither of them" "the token leaks into the log" "$BODY"
rm -rf "$W"

# ── (y4) renumber() counts FINDINGS, not lines that start with a dash ────────
# It matched `^[ \t]*[-*][ \t]`, so every indented sub-bullet inflated the count
# — and #131 made it run on EVERY truncation. A body whose Findings section lost
# nothing came out as `### Findings (6)` over two findings.
echo ""
echo "── (y4) a header counts top-level bullets only ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'SUBBULLETS'
import json, sys
para = "This PR reworks the seat-allocation pipeline end to end. " * 40
lines = ["## Claude review — COMMENT", "", para, "", "### Findings (2)",
         "- **major** {{LINK:src/foo.ts:11}} — the retry loop never caps",
         "  - it backs off but has no ceiling",
         "  - and the timer is never cleared",
         "- **minor** {{LINK:src/foo.ts:12}} — the variable name is unclear",
         "  - `x` is the tenant id",
         "  - the call site reads as a count"]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
SUBBULLETS
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the body really was truncated" "truncated to fit" "$BODY"
assert_contains "both findings survived whole" "the retry loop never caps" "$BODY"
assert_contains "…including their detail" "the timer is never cleared" "$BODY"
assert_contains "the header counts the two findings" "### Findings (2)" "$BODY"
assert_not_contains "…not the six lines that start with a dash" "### Findings (6)" "$BODY"
rm -rf "$W"

# ── (y5) an INLINE check must not poison the round-2 state ───────────────────
# #131 excluded checks from the `dropped` arm of the state builder and left the
# `kept` arm alone — and inline is the NORMAL home for a check. The tell is the
# severity: that arm derives one from the body text, and a check has none. The
# result was a state finding with `sev: ""` that round 2 could never resolve.
echo ""
echo "── (y5) an inline check stays out of the state block ──"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne question, one finding.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**check** Should an expired token still refresh the session?\n\ndetail"},
                   {path: "src/foo.ts", line: 12, side: "RIGHT",
                    body: "**major** the retry loop never caps\n\nit backs off forever"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
STATE=$(state_block "$BODY")
assert_eq "exit 0" "0" "$RC"
assert_eq "both still post inline" "2" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "no state finding carries an empty severity" "0" \
  "$(echo "$STATE" | jq '[.findings[] | select(.sev == "")] | length')"
assert_eq "the check is not a finding" "0" \
  "$(echo "$STATE" | jq '[.findings[] | select(.t | test("expired token"))] | length')"
assert_eq "the real finding still is" "1" "$(echo "$STATE" | jq '.findings | length')"

# …and the proof it is not carried: feed this state back as round 2's priors.
P2=$(mktemp)
echo "$STATE" | jq '.findings' > "$P2"
W2=$(mktemp -d)
jq -n '{verdict: "APPROVE", body: "## Claude review — APPROVE\n\nThe delta is clean.",
        comments: [], meta: {findings: [], resolved_prior: []}}' > "$W2/review.json"
PRIOR_FINDINGS="$P2" ROUND_N=2 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W2"
assert_not_contains "round 2 is not haunted by the question" \
  "expired token" "$(payload_of "$W2" | jq -r '.body')"
assert_not_contains "…and warns about no severity-less carry" \
  "::warning::Carried finding" "$(printf '%s' "$OUT" | grep 'Carried finding' | grep '(, ' || true)"
rm -rf "$W" "$W2" "$P2"

# ── (y6) EVIDENCE THE TESTER RAN BEATS A MISSING rc FILE ─────────────────────
# The gallery suppression keyed on `DEV_ENV_RC != 0`, but `/tmp/dev-env/rc` is
# written only when setup-dev-env.sh RETURNS, while the orchestrator gates the
# tester on `web_ready` — written much earlier. A slow or hung later phase means
# the tester genuinely ran and produced screenshots while rc never appeared, and
# #131 threw all of it away while asserting "No browser test ran". A
# `functional.json` carrying a valid `overall` is direct evidence to the contrary.
echo ""
echo "── (y6) a completed functional run keeps its evidence ──"

# (y6a) rc never written, tester ran: the gallery stands and nothing claims
# otherwise.
W=$(mktemp -d)
echo "$CLEAN_REVIEW" > "$W/review.json"
make_shots "$W/shots" 01-list.png 02-detail.png 03-cart.png
jq -n '{overall: "PASS", summary: "Drove the order flow.", observations: [],
        screenshots: [{file: "/tmp/screenshots/01-list.png", description: "AC1"},
                      {file: "/tmp/screenshots/02-detail.png", description: "AC2"},
                      {file: "/tmp/screenshots/03-cart.png", description: "AC3"}]}' > "$W/functional.json"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" SHOT_DIR="$W/shots" \
  DEVENV_RC="$W/dev-env-rc-that-was-never-written" DEVENV_LOG="$W/no-such-log" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the screenshots the tester took are published" \
  "Functional pass: PASS — 3 screenshots" "$BODY"
assert_not_contains "…and nothing claims no browser test ran" "No browser test ran" "$BODY"
assert_not_contains "…nor that the pass was skipped" "requested but skipped" "$BODY"
rm -rf "$W"

# (y6b) THE CONTRADICTION STAYS IMPOSSIBLE THE OTHER WAY. Dev-env failed and no
# functional.json exists: nothing proves a browser ran, so the notice is the fact
# and there is no gallery to disagree with it.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
mkdir -p "$W/dev-env"; printf '5' > "$W/dev-env/rc"
printf '::error::API never became ready at http://localhost:20001/api within 300s\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "with no evidence, the skip is still reported" \
  "No browser test ran" "$BODY"
assert_not_contains "…and no gallery contradicts it" "Functional pass:" "$BODY"
assert_contains "the cause is quoted, not the tautology" "API never became ready" "$BODY"
rm -rf "$W"

# (y6c) an empty or malformed functional.json is NOT evidence.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
printf '{"overall": "", "screenshots": []}' > "$W/functional.json"
mkdir -p "$W/dev-env"; printf '5' > "$W/dev-env/rc"
printf '::error::compose up failed\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true FUNCTIONAL_FILE="$W/functional.json" \
  DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a functional.json with no verdict proves nothing" \
  "No browser test ran" "$BODY"
assert_not_contains "…and publishes nothing" "Functional pass:" "$BODY"
rm -rf "$W"

# ── (y7) `${tail//</&lt;}` IS A NO-OP ON BASH 5.2 ────────────────────────────
# 5.2 turns on `patsub_replacement`, so `&` in the replacement expands to the
# text that matched: the expansion yields `<lt;`, not `&lt;`. GitHub's
# ubuntu-24.04 runners ship bash 5.2.x, so raw `<` from a consumer script's log
# reached an HTML `<sub>`/`<code>` block in a public review.
echo ""
echo "── (y7) the last-error line is HTML-escaped on bash 5.1 and 5.2 alike ──"

W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
mkdir -p "$W/dev-env"; printf '1' > "$W/dev-env/rc"
printf '::error::parse failed near <Suspense fallback={<Spinner/>}> & then gave up\n' > "$W/dev-env/log"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/rc" DEVENV_LOG="$W/dev-env/log" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the error is still quoted" "parse failed near" "$BODY"
assert_contains "a raw < becomes an entity" "&lt;Suspense" "$BODY"
assert_not_contains "…not bash 5.2's patsub artefact" "<lt;" "$BODY"
assert_not_contains "…and no raw tag reaches the HTML block" "<Spinner" "$BODY"
assert_contains "a raw > is escaped too" "&gt;" "$BODY"
assert_contains "…and the ampersand before it" "&amp; then gave up" "$BODY"
rm -rf "$W"

# ── (z) the THIRD audit: two regressions, a fence hole, and two silent drops ──
# Each block names the defect it pins and the shape that produced it. Every one
# was verified to FAIL against the script as #132 left it.

# ── (z1) the XOR strip must take a bullet's SUB-BULLETS with it ──────────────
# The strip keyed on isbullet(), which allows leading whitespace. An indented
# `  - ` detail line therefore entered the bullet arm, found no {{LINK:}}, got an
# empty key, skipped the duplicate test entirely, was written out as "kept" — and
# reset `skipping`, so the rest of the parent's block came back too. The parent
# was stripped and its details survived, reparented under the header.
#
# The worst shape is not cosmetic: renumber() counts top-level bullets only, so a
# Findings section holding nothing but orphans renders `### Findings (0)`, and
# prune() sees a non-empty section and keeps it. A review then declares ZERO
# findings directly above loose prose describing a critical auth bug. The orphans
# also sit EARLIER in the file than the real findings, so they outrank them for
# the byte budget.
echo ""
echo "── (z1) a stripped bullet takes its indented detail lines with it ──"

W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nTwo blocking findings.\n\n### Findings (2)\n- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens\n  - the helper is shared with the admin console\n- **critical** {{LINK:src/foo.ts:12}} — the token compare is not constant time\n  - an attacker can recover the token byte by byte",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens\n\ndetail"},
                   {path: "src/foo.ts", line: 12, side: "RIGHT",
                    body: "**critical** the token compare is not constant time\n\ndetail"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_eq "both findings went inline" "2" "$(payload_of "$W" | jq '.comments | length')"
assert_not_contains "a stripped bullet's detail line does not survive it" \
  "the helper is shared with the admin console" "$BODY"
assert_not_contains "…nor the second one" \
  "an attacker can recover the token byte by byte" "$BODY"
assert_not_contains "and no header is left claiming zero findings over orphaned prose" \
  "### Findings (0)" "$BODY"
assert_not_contains "the emptied section is pruned outright" "### Findings" "$BODY"
rm -rf "$W"

# (z1b) THE OTHER DIRECTION: a SURVIVING bullet keeps its own detail lines, and
# the skip ends at the next top-level bullet. Guards against "fixing" (z1) by
# swallowing everything after the first duplicate.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nTwo findings.\n\n### Findings (2)\n- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens\n  - the helper is shared with the admin console\n- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy\n  - it fires on every request",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens\n\ndetail"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "the duplicated bullet's detail goes with it" \
  "the helper is shared with the admin console" "$BODY"
assert_contains "the surviving bullet is still there" "the log line is noisy" "$BODY"
assert_contains "…and so is ITS detail line" "it fires on every request" "$BODY"
assert_contains "the header counts the one finding left" "### Findings (1)" "$BODY"
rm -rf "$W"

# ── (z2) fbdup() reintroduced #130's double-print ────────────────────────────
# #132 replaced the over-broad isdup() with path AND severity AND title and threw
# the LINE key away. Identity is now unanimous-or-nothing, so any drift on either
# field prints the finding twice — once under `### Findings`, once under
# `### Also flagged`, with two different severities on the same defect.
echo ""
echo "── (z2) a fallback bullet is dropped on drift, kept on a real second finding ──"

# (z2a) SEVERITY DRIFT. Same path, same line, same title; the body says critical
# and the comment says major. Models do this routinely.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nOne finding.\n\n### Findings (1)\n- **critical** {{LINK:src/foo.ts:99}} — the token compare is not constant time",
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: "**major** the token compare is not constant time\n\ndetail"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_not_contains "a severity drift does not print the finding twice" "### Also flagged" "$BODY"
assert_eq "…it is printed exactly once" "1" \
  "$(printf '%s\n' "$BODY" | grep -c 'the token compare is not constant time')"

# (z2b) MECHANICAL, no model inconsistency needed. The jq `title` def clamps to
# `.[:90]`, so the fallback bullet for a long-titled finding is a truncated
# PREFIX of the body's bullet. Comparing them whole can never match, so every
# finding with a title over 90 characters double-printed deterministically.
W=$(mktemp -d)
LONG_T='the token comparison in the session refresh path is not constant time and leaks the secret byte by byte'
jq -n --arg t "$LONG_T" '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:99}} — " + $t),
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: ("**major** " + $t + "\n\ndetail")}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "a >90-char title does not print the finding twice" "### Also flagged" "$BODY"
assert_eq "…it is printed exactly once" "1" \
  "$(printf '%s\n' "$BODY" | grep -c 'the token comparison in the session refresh path')"
rm -rf "$W"

# (z2c) the 90-character cut can land ON A SPACE, and jq's `title` trims what the
# cut left dangling while awk's substr does not. Both sides must cut AND trim the
# same way or the prefixes differ by one byte and the match is missed again.
W=$(mktemp -d)
SPACE_T='the token comparison in the session refresh path is not constant time and leaks the token byte by byte'
jq -n --arg t "$SPACE_T" '{verdict: "REQUEST_CHANGES",
        body: ("## Claude review — REQUEST_CHANGES\n\nOne finding.\n\n### Findings (1)\n- **major** {{LINK:src/foo.ts:99}} — " + $t),
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: ("**major** " + $t + "\n\ndetail")}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "a title whose 90th character is a space does not double-print" \
  "### Also flagged" "$BODY"
rm -rf "$W"

# ── (z3) a FOUR-backtick fence bypassed both the stripper and its warning ────
# GitHub accepts three OR MORE backticks for a suggestion fence, and both
# regexes hardcoded exactly three. So a `**check**` carrying ````suggestion kept
# its range AND a committable fence, with nothing warned anywhere — the exact
# code-deleting shape (y2) was written to eliminate.
echo ""
echo "── (z3) a 3-or-more backtick suggestion fence is stripped from a check ──"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne question.",
        comments: [{path: "src/foo.ts", start_line: 10, line: 13, side: "RIGHT",
                    body: "**check** Should an expired token still refresh the session?\n\n````suggestion\n  if (token.expired) return null;\n````\n\nThat is the shape I would expect."}],
        meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
C=$(payload_of "$W" | jq -c '.comments[0]')
CBODY=$(echo "$C" | jq -r '.body')
assert_eq "exit 0" "0" "$RC"
assert_eq "the check still posts inline" "1" "$(payload_of "$W" | jq '.comments | length')"
assert_eq "…and keeps its range" "10" "$(echo "$C" | jq -r '.start_line')"
assert_not_contains "no four-backtick fence survives on a check" 'suggestion' "$CBODY"
assert_not_contains "…nor the code it would have committed" \
  "if (token.expired) return null;" "$CBODY"
assert_contains "the question itself is untouched" \
  "Should an expired token still refresh the session?" "$CBODY"
assert_contains "…and so is the prose after the fence" "That is the shape I would expect." "$CBODY"
assert_contains "the strip is announced, never silent" "fence" "$OUT"
rm -rf "$W"

# ── (z4) an UNTERMINATED fence must not eat the rest of the question ─────────
# The in-fence flag never cleared without a closer, so every line the model wrote
# after the opener was discarded — and the warning said a fence was stripped, not
# that the question went with it. Against this file's own NOTHING IS SILENTLY
# DROPPED banner. Only the opener line is dropped now.
echo ""
echo "── (z4) an unterminated fence loses the fence, never the question ──"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne question.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**check** Should an expired token still refresh the session?\n\n```suggestion\n  if (token.expired) return null;\n\nThat matters because the admin console shares this helper."}],
        meta: {findings: [], human_review: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
CBODY=$(payload_of "$W" | jq -r '.comments[0].body')
assert_eq "exit 0" "0" "$RC"
assert_contains "the question survives" "Should an expired token still refresh the session?" "$CBODY"
assert_contains "…and so does everything the model wrote after the opener" \
  "That matters because the admin console shares this helper." "$CBODY"
assert_not_contains "the committable opener is gone" '```suggestion' "$CBODY"
rm -rf "$W"

# ── (z5) the dev-env return code is FILE CONTENT, and it reached HTML raw ────
# `why` was interpolated straight into the `<sub>` block while its sibling `tail`
# two lines below went through html_escape.
echo ""
echo "── (z5) the dev-env rc is HTML-escaped like every other quoted log byte ──"

W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
mkdir -p "$W/dev-env"; printf '%s' '<b>&amp; oops</b>' > "$W/dev-env/rc"
FUNCTIONAL_REQ=true DEVENV_RC="$W/dev-env/rc" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the rc is still reported" "exited" "$BODY"
assert_not_contains "no raw tag from the rc file reaches the HTML block" "<b>" "$BODY"
assert_not_contains "…nor its closer" "</b>" "$BODY"
assert_contains "it is escaped instead" "&lt;b&gt;" "$BODY"
assert_contains "…ampersand first, so the entities are not double-escaped" "&amp;amp;" "$BODY"
rm -rf "$W"

# ── (aa) the FOURTH audit: a budget that cut by position, an ASCII-only blank,
#        a title cut on two different strings, and a dismissal that ran too early
# Every block names the defect it pins. Each was verified to FAIL against the
# script as #133 left it.

# ── (aa1) THE BUDGET MUST CUT BY VALUE, NOT BY POSITION ──────────────────────
# `### What a human should review` and `### Also flagged` are appended to the END
# of the body, and the truncator cut positionally — so overflow always ate them
# first. Those are the sections whose items could NOT be posted inline: they have
# no other surface, and cutting one deletes the finding from the review outright.
# Reproduced at the DEFAULT budget: an out-of-hunk **critical** vanished from
# every surface while two **minor** nits survived, and `### Also flagged (1)`
# renumbered honestly so nothing on the page hinted at the loss.
echo ""
echo "── (aa1) overflow eats prose, never the findings with no other surface ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'VALUECUT'
import json, sys
filler = "The broker rewrite touches the retry path and the tenant cache key. " * 24
lines = ["## Claude review — REQUEST_CHANGES", "", filler, "",
         "### Findings (2)",
         "- **minor** {{LINK:src/foo.ts:11}} — the variable name is unclear",
         "- **minor** {{LINK:src/foo.ts:12}} — this comment restates the code"]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 99, "side": "RIGHT",
                         "body": "**critical** auth middleware is skipped for admin routes"}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
VALUECUT
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the body really was over budget" "truncated to fit" "$BODY"
assert_contains "the critical that has no other surface survives" \
  "auth middleware is skipped for admin routes" "$BODY"
assert_contains "…under its own heading" "### Also flagged (1)" "$BODY"
assert_not_contains "ordinary prose is what the budget took instead" \
  "The broker rewrite touches the retry path" "$BODY"
assert_honest_counts "and every header still counts what follows it" "$BODY"
rm -rf "$W"

# (aa1b) SEVERITY IS RESPECTED INSIDE THE PRIORITISED SECTIONS TOO. A critical
# that fell back outranks a minor in `### Findings`, and both outrank prose.
W=$(mktemp -d)
python3 - "$W/review.json" <<'SEVCUT'
import json, sys
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Findings (2)",
         "- **minor** {{LINK:src/foo.ts:11}} — " + ("the variable name is unclear and " * 6),
         "- **minor** {{LINK:src/foo.ts:12}} — " + ("this comment restates the code and " * 6)]
cs = [{"path": "src/foo.ts", "line": 900 + i, "side": "RIGHT",
       "body": "**critical** dropped critical number %d about the admin auth path" % i}
      for i in range(1, 4)]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines), "comments": cs,
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
SEVCUT
BODY_MAX=420 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
for n in 1 2 3; do
  assert_contains "dropped critical $n outranks a minor for the budget" \
    "dropped critical number $n" "$BODY"
done
assert_honest_counts "counts stay honest under value-ordered truncation" "$BODY"
rm -rf "$W"

# (aa1c) AND IF ONE IS STILL CUT, IT IS NAMED. The only diagnostic used to be a
# generic "over the 1800-byte budget — truncating"; a finding with no other
# surface disappeared with nothing on the page or in the log pointing at it.
# This file's own banner: NOTHING IS SILENTLY DROPPED.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nsee below.",
        comments: [range(1;13) | {path: "src/foo.ts", line: (900 + .), side: "RIGHT",
                                  body: "**major** dropped finding number \(.) on the admin auth path"}],
        meta: {findings: []}}' > "$W/review.json"
BODY_MAX=300 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "a cut fallback item is named in the log" \
  "::warning::Over the 300-byte body budget: dropped" "$OUT"
assert_contains "…and the log says where it now reaches the reader" \
  "reaches the reader nowhere" "$OUT"
LOST_NAMED=$(printf '%s\n' "$OUT" | grep -c 'Over the 300-byte body budget: dropped')
LOST_MISSING=0
for n in $(seq 1 12); do
  case "$BODY" in *"dropped finding number $n "*) ;; *) LOST_MISSING=$((LOST_MISSING + 1)) ;; esac
done
assert_eq "every item the budget cut is named, none more" "$LOST_MISSING" "$LOST_NAMED"
rm -rf "$W"

# ── (aa2) ONE NON-ASCII "BLANK" LINE DELETED THE REST OF THE BODY ────────────
# isblank() was `/^[ \t]*$/` — ASCII only — and it is shared by mode=strip,
# mode=fit and prune(). A U+00A0, a U+200B or a lone CR on the line after a
# stripped `### Findings` bullet therefore never cleared `skipping`, so every
# line to the end of the body went with the duplicate. Measured: 7 lines gone,
# the body ending at the title, and the only diagnostic was "Dropped 7 body
# line(s) duplicating an inline comment" — they duplicated nothing.
echo ""
echo "── (aa2) an invisible character is a blank line, not content ──"

# The codepoint is passed as a NUMBER, not as a character: a shell round-trip
# through a heredoc is exactly where an invisible byte gets normalised away, and
# a test that silently posted a plain empty line would pass against the bug.
for pair in "nbsp:160" "zwsp:8203" "cr:13" "nnbsp:8239" "bom:65279"; do
  name="${pair%%:*}"; esc="${pair#*:}"
  W=$(mktemp -d)
  python3 - "$W/review.json" "$esc" <<'INVIS'
import json, sys
blank = chr(int(sys.argv[2]))
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Findings (2)",
         "- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens",
         blank,
         "The same helper backs the admin console, so the blast radius is the whole tenant.",
         "A reviewer should read the migration notes before merging this."]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 11, "side": "RIGHT",
                         "body": "**critical** the auth guard is bypassed for expired tokens"}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
INVIS
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
  assert_contains "[$name] the stripped bullet does not swallow the prose below it" \
    "the blast radius is the whole tenant" "$BODY"
  assert_contains "[$name] …nor the line after that" \
    "read the migration notes" "$BODY"
  assert_contains "[$name] the surviving finding is still there" \
    "the log line is noisy" "$BODY"
  assert_contains "[$name] the header counts what is left" "### Findings (1)" "$BODY"
  rm -rf "$W"
done

# (aa2b) THE SAME PREDICATE IN mode=fit. An invisible line between a paragraph
# the budget cannot fit and the prose after it meant the prose was treated as a
# continuation of the dropped block and went with it.
W=$(mktemp -d)
python3 - "$W/review.json" <<'INVISFIT'
import json, sys
big = "a paragraph far longer than the whole byte budget, " * 20
lines = ["## Claude review — COMMENT", "", big, " ",
         "The tenant cache key omits the region, so a lookup can cross tenants."]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
INVISFIT
BODY_MAX=400 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_not_contains "the over-long paragraph is still what goes" \
  "a paragraph far longer than the whole byte budget" "$BODY"
assert_contains "the prose after an invisible blank is not part of it" \
  "a lookup can cross tenants" "$BODY"
rm -rf "$W"

# ── (aa3) THE TWO SURFACES MUST CUT THE SAME STRING ──────────────────────────
# t90() cuts 90 bytes of the NORMALISED title; jq's `title` cut 90 CODEPOINTS of
# the RAW one. Any title over 90 characters whose normalisation changes length
# inside that window desyncs the two keys — and #133's double-print comes back.
echo ""
echo "── (aa3) the 90-character identity is cut on one string, not two ──"

# (aa3a) 40 A, TWO spaces, 60 B — one finding, one path, one line, one severity.
for gap in "  " $'\t ' $' \r'; do
  W=$(mktemp -d)
  TITLE="$(printf 'A%.0s' $(seq 1 40))${gap}$(printf 'B%.0s' $(seq 1 60))"
  jq -n --arg t "$TITLE" \
    '{verdict: "REQUEST_CHANGES",
      body: ("## Claude review — REQUEST_CHANGES\n\n### Findings (1)\n- **critical** {{LINK:src/foo.ts:99}} — " + $t),
      comments: [{path: "src/foo.ts", line: 99, side: "RIGHT", body: ("**critical** " + $t)}],
      meta: {findings: []}}' > "$W/review.json"
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
  HITS=$(printf '%s\n' "$BODY" | grep -c 'BBBBBBBBBB')
  assert_eq "a whitespace-drifted 102-char title is printed once, not twice" "1" "$HITS"
  assert_not_contains "…so no second heading is opened for it" "### Also flagged" "$BODY"
  rm -rf "$W"
done

# (aa3b) THE CONTROL: the single-space form deduped even before the fix, so the
# assertion above is pinning the desync and not the de-duplication itself.
W=$(mktemp -d)
TITLE="$(printf 'A%.0s' $(seq 1 40)) $(printf 'B%.0s' $(seq 1 60))"
jq -n --arg t "$TITLE" \
  '{verdict: "REQUEST_CHANGES",
    body: ("## Claude review — REQUEST_CHANGES\n\n### Findings (1)\n- **critical** {{LINK:src/foo.ts:99}} — " + $t),
    comments: [{path: "src/foo.ts", line: 99, side: "RIGHT", body: ("**critical** " + $t)}],
    meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "the single-space control still prints once" "1" \
  "$(printf '%s\n' "$BODY" | grep -c 'BBBBBBBBBB')"
rm -rf "$W"

# (aa3c) THE MIRROR. The same desync deletes a GENUINELY DIFFERENT finding: the
# raw 90-codepoint cut of the dropped comment, once normalised, was byte-equal to
# the body bullet of an unrelated shorter finding on the same path — so the
# fallback bullet was filtered out and BETA reached the reader nowhere.
W=$(mktemp -d)
python3 - "$W/review.json" <<'MIRROR'
import json, sys
P = "X" * 40
R = "Y" * 43 + "ALPHA"          # 48 chars
alpha = P + " " + R             # 89 chars, a finding of its own
beta  = P + "  " + R + "BETA"   # raw-cut at 90 normalises to exactly `alpha`
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — " + alpha]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 99, "side": "RIGHT",
                         "body": "**critical** " + beta}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
MIRROR
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the body finding is untouched" "### Findings (1)" "$BODY"
assert_contains "the genuinely different dropped finding still reaches the reader" \
  "### Also flagged (1)" "$BODY"
assert_contains "…anchored at its own line" "src/foo.ts:99" "$BODY"
rm -rf "$W"

# ── (aa4) A REJECTED POST MUST NOT LEAVE THE PR UNBLOCKED ────────────────────
# Section 5 dismissed the standing CHANGES_REQUESTED BEFORE section 7 posted the
# replacement. On a 422 the sequence was: dismiss succeeds, POST fails, exit 1 —
# and the PR was left with no blocking review at all. The banner then classified
# on `[ -s "$REVIEW_JSON" ]`, always true by then, so it told the reader the
# output "could not be parsed", called it "a transient serialization slip" and
# advised a re-run. The output parsed fine and a re-run hits the same 422.
echo ""
echo "── (aa4) a POST rejection leaves the block standing and says so ──"

W=$(mktemp -d)
STANDING=$(mktemp)
cat > "$STANDING" <<'EOF'
[{"id": 778, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "prior review"}]
EOF
printf '%s' "$VALID_REVIEW" > "$W/review.json"
POST_FAIL=1 FIXTURE_REVIEWS="$STANDING" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
GH_CALLS=$(cat "$W/gh.log")
assert_eq "exit 1" "1" "$RC"
assert_not_contains "the standing blocking review is NOT dismissed" "dismissals" "$GH_CALLS"
PAYLOAD=$(payload_of "$W")
assert_contains "the banner names the real failure" "GitHub rejected the review" "$PAYLOAD"
assert_not_contains "not the unreadable-output variant" "result unreadable" "$PAYLOAD"
assert_not_contains "…and it does not promise a retry will work" \
  "usually succeeds on retry" "$PAYLOAD"
assert_contains "it says a re-run hits the same rejection" \
  "will be rejected the same way" "$PAYLOAD"
assert_contains "…and that the standing review was left alone" \
  "left in place" "$PAYLOAD"
rm -rf "$W" "$STANDING"

# (aa4b) THE OTHER DIRECTION: a POST that succeeds still dismisses. Guards
# against "fixing" (aa4) by never dismissing at all.
W=$(mktemp -d)
STANDING=$(mktemp)
cat > "$STANDING" <<'EOF'
[{"id": 778, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "prior review"}]
EOF
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="$STANDING" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
GH_CALLS=$(cat "$W/gh.log")
assert_eq "exit 0" "0" "$RC"
assert_contains "the stale block is dismissed once the replacement is up" \
  "reviews/778/dismissals" "$GH_CALLS"
rm -rf "$W" "$STANDING"

# (aa4c) THE HAZARD THE MOVE CREATED, CLOSED. The review list is now re-read
# AFTER the POST, so the review this run just created is in it — and a
# REQUEST_CHANGES review dismissing itself would unblock the PR just as surely
# as the old order did. The id the POST returned is excluded by id.
W=$(mktemp -d)
STANDING=$(mktemp)
cat > "$STANDING" <<'EOF'
[{"id": 778, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "prior review"},
 {"id": 9001, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "the review this run just posted"}]
EOF
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="$STANDING" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
GH_CALLS=$(cat "$W/gh.log")
assert_contains "the stale one is still dismissed" "reviews/778/dismissals" "$GH_CALLS"
assert_not_contains "the review this run just posted never dismisses itself" \
  "reviews/9001/dismissals" "$GH_CALLS"
rm -rf "$W" "$STANDING"

# (aa4d) …and with NO id to exclude, nothing is dismissed at all. A stale block
# is a nuisance; an unblocked PR is the failure this whole section exists to
# prevent, so the ambiguous case resolves the safe way and says so.
W=$(mktemp -d)
STANDING=$(mktemp)
cat > "$STANDING" <<'EOF'
[{"id": 778, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "prior review"}]
EOF
printf '%s' "$VALID_REVIEW" > "$W/review.json"
POST_NO_ID=1 FIXTURE_REVIEWS="$STANDING" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "the review still posted" "0" "$RC"
assert_not_contains "nothing is dismissed without an id to exclude" \
  "dismissals" "$(cat "$W/gh.log")"
assert_contains "…and the run log says why" "returned no review id" "$OUT"
rm -rf "$W" "$STANDING"

# ── (aa5) THE STEP SUMMARY MUST COUNT WHAT THE POSTER POSTED ─────────────────
# It counted `meta.findings` alone. 4c documents that meta is model-written and
# can be empty while three criticals post inline — and rebuilds the state block
# from `kept` + `dropped`. The summary was never moved onto that floor, so a
# REQUEST_CHANGES carrying two criticals rendered `### Findings (0)` and
# `::warning::Claude review: REQUEST_CHANGES — 0 blocking finding(s).`
echo ""
echo "── (aa5) a blocking review never reports zero findings ──"

W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nSee the inline comments.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens"},
                   {path: "src/foo.ts", line: 12, side: "RIGHT",
                    body: "**critical** the token compare is not constant time"}],
        meta: {}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
SUMMARY_TEXT=$(cat "$W/summary.md")
assert_eq "exit 0" "0" "$RC"
assert_eq "both criticals really went inline" "2" "$(payload_of "$W" | jq '.comments | length')"
assert_contains "the summary counts them" "### Findings (2)" "$SUMMARY_TEXT"
assert_not_contains "…and never claims zero" "### Findings (0)" "$SUMMARY_TEXT"
assert_contains "the first is listed" "the auth guard is bypassed" "$SUMMARY_TEXT"
assert_contains "the second too" "the token compare is not constant time" "$SUMMARY_TEXT"
assert_contains "the annotation agrees with the summary" \
  "REQUEST_CHANGES — 2 blocking finding(s)" "$OUT"
rm -rf "$W"

# (aa5b) meta is still USED — it carries the model's own wording and its
# failure_scenario. A review whose meta lists findings the poster posted inline
# must not double-count them.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
SUMMARY_TEXT=$(cat "$W/summary.md")
assert_contains "meta and the inline comment are one finding, not two" \
  "### Findings (2)" "$SUMMARY_TEXT"
assert_eq "the summary count matches the state block" \
  "$(state_block "$(payload_of "$W" | jq -r '.body')" | jq '.findings | length')" \
  "$(printf '%s\n' "$SUMMARY_TEXT" | sed -n 's/^### Findings (\([0-9]*\))$/\1/p')"
rm -rf "$W"

# ── (aa6) "FIRST SEEN" MUST NOT RESET WHEN A FINDING IS RE-LISTED ────────────
# `r` was inherited only through `carried_from`, the re-wording escape valve. A
# finding the model simply re-listed in the same words got a fresh id match, no
# `carried_from`, and `r: $round`. Verified over three rounds: R1 files it (r:1),
# R2 re-lists it verbatim (r:2), R3 reports `_(first seen round 2)_` — which
# understates the age of exactly the findings that have been ignored longest.
echo ""
echo "── (aa6) the round a finding was first seen survives a re-list ──"

W=$(mktemp -d)
FID=$(printf '%s\n%s' "src/foo.ts" "the auth guard is bypassed for expired tokens" \
      | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-8)
cat > "$W/priors.json" <<EOF
[{"id": "$FID", "p": "src/foo.ts", "l": 11, "sev": "critical",
  "t": "the auth guard is bypassed for expired tokens", "r": 1, "inline": true}]
EOF
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\nStill open.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens"}],
        meta: {findings: []}}' > "$W/review.json"
ROUND_N=2 PRIOR_FINDINGS="$W/priors.json" \
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
STATE=$(state_block "$(payload_of "$W" | jq -r '.body')")
assert_eq "the re-listed finding keeps the round it was first seen" "1" \
  "$(echo "$STATE" | jq -r --arg id "$FID" '.findings[] | select(.id == $id) | .r')"
assert_eq "…and the round stamp on the block is still this round" "2" \
  "$(echo "$STATE" | jq '.round')"
rm -rf "$W"

# ── (aa7) `### Findings (0)` OVER LOOSE PROSE IS STILL REACHABLE ─────────────
# #133 closed the sub-bullet route. Blank-line-separated prose inside the section
# is the other one: prune() saw a non-blank line and kept the header, renumber()
# counted top-level bullets and wrote (0).
echo ""
echo "── (aa7) a findings section with no findings is dropped, prose and all ──"

W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\n### Findings (1)\n- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens\n\nThe same helper backs the admin console, so the blast radius is the whole tenant.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_not_contains "no header claiming zero findings" "### Findings (0)" "$BODY"
assert_not_contains "the emptied section is gone outright" "### Findings" "$BODY"
assert_not_contains "…and so is the prose stranded inside it" \
  "the blast radius is the whole tenant" "$BODY"
rm -rf "$W"

# (aa7b) THE OTHER DIRECTION: a section that still has a bullet keeps its prose.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\n### Findings (2)\n- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens\n- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy\n\nBoth land on the same admin path.",
        comments: [{path: "src/foo.ts", line: 11, side: "RIGHT",
                    body: "**critical** the auth guard is bypassed for expired tokens"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the section that kept a finding stays" "### Findings (1)" "$BODY"
assert_contains "…with its prose" "Both land on the same admin path" "$BODY"
rm -rf "$W"

# ── (aa8) fbindex MUST USE istop, NOT THE LOOSE BULLET PREDICATE ─────────────
# It still inlined the `/^[ \t]*[-*][ \t]/` that #133 deleted `isbullet` to
# prevent. An indented detail line carrying a {{LINK:}} of its own was indexed as
# a body finding — enough for fbdup() to delete the real fallback bullet at that
# path, which is the only surface that finding had.
echo ""
echo "── (aa8) an indented detail line is not a body finding ──"

W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES",
        body: "## Claude review — REQUEST_CHANGES\n\n### Findings (1)\n- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy\n  - see also {{LINK:src/foo.ts:99}} — auth bypass on admin routes",
        comments: [{path: "src/foo.ts", line: 99, side: "RIGHT",
                    body: "**critical** auth bypass on admin routes"}],
        meta: {findings: []}}' > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the dropped critical still gets its fallback bullet" \
  "### Also flagged (1)" "$BODY"
assert_contains "…carrying its severity" "**critical**" "$BODY"
rm -rf "$W"

# ── (ab1) mode=fit NEVER SPLITS A FENCED REGION ──────────────────────────────
# `fit` had no fence awareness: a blank line inside a fence split it, and a
# `- name: build` at column 0 inside a YAML fence was an `istop` top-level
# bullet. Opener, body and closer were then admitted independently. Both halves
# damage the page — a dropped opener renders YAML config lines as `### Context`
# bullets (the review asserting changes the model never claimed), and a dropped
# closer leaves the fence open, so `### Findings`, the truncation marker, the
# footer and the `<!-- claude-review-state {...} -->` block all render as
# literal preformatted text with dead links and the internal JSON on show.
# skills/review-verify.md mandates a ```mermaid diagram, so this is not theory.
echo ""
echo "── (ab1) a fenced region is one indivisible block ──"

for MAXB in 300 320 340 360 380 400 420 440 460 480 500 540 600; do
  W=$(mktemp -d)
  python3 - "$W/review.json" <<'FENCEBODY'
import json, sys
lines = ["## Claude review — COMMENT", "",
         "The control flow after this change:", "",
         "```mermaid", "graph TD", "  A[request] --> B[authguard]", "",
         "  B --> C[handler]", "  C --> D[response]", "```", "",
         "### Context", "",
         "```yaml", "- name: build", "  run: make", "- name: test",
         "  run: make test", "```", "",
         "### Findings (2)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens on the admin console",
         "- **minor** {{LINK:src/foo.ts:12}} — the log line repeats the request id twice on every single call"]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
FENCEBODY
  BODY_MAX=$MAXB FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  # The RAW posted body, not visible_body(): an unbalanced fence swallows the
  # state block, and that is the half of this defect that leaks internal JSON.
  RAW=$(payload_of "$W" | jq -r '.body')
  MARKERS=$(printf '%s\n' "$RAW" | grep -c '^```' || true)
  assert_eq "[$MAXB] every fence the body kept is closed" "0" "$(( MARKERS % 2 ))"
  # Content without its opener is the other half: the fence body renders as
  # ordinary markdown, and the YAML lines become bullets of the section above.
  case "$RAW" in
    *"graph TD"*) assert_contains "[$MAXB] mermaid content implies its opener" '```mermaid' "$RAW" ;;
    *) assert_not_contains "[$MAXB] a dropped mermaid fence leaves no opener" '```mermaid' "$RAW" ;;
  esac
  case "$RAW" in
    *"name: build"*) assert_contains "[$MAXB] yaml content implies its opener" '```yaml' "$RAW" ;;
    *) assert_not_contains "[$MAXB] a dropped yaml fence leaves no opener" '```yaml' "$RAW" ;;
  esac
  rm -rf "$W"
done

# (ab1b) AN UNTERMINATED FENCE IN THE SOURCE RUNS TO END OF INPUT. The model
# opened a fence and never closed it; the splitter must still treat everything
# after it as one block rather than admitting the opener alone.
for MAXB in 200 250 350 650; do
  W=$(mktemp -d)
  python3 - "$W/review.json" <<'UNTERM'
import json, sys
pad = "diagram text that exists purely to outweigh the byte budget here"
lines = ["## Claude review — COMMENT", "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens",
         "", "```yaml", "- name: build", "  run: make", "",
         "- name: test"] + ["  run: " + pad for _ in range(12)]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
UNTERM
  BODY_MAX=$MAXB FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  RAW=$(payload_of "$W" | jq -r '.body')
  assert_not_contains "[$MAXB] an unterminated fence is dropped whole, opener included" '```yaml' "$RAW"
  assert_not_contains "[$MAXB] …and its config lines do not survive as bullets" "name: build" "$RAW"
  assert_contains "[$MAXB] the finding it was cut for survives" "the auth guard is bypassed" "$RAW"
  assert_contains "[$MAXB] …and the header counts findings, not YAML keys" "### Findings (1)" "$RAW"
  rm -rf "$W"
done

# (ab1d) NOTHING INSIDE A FENCE IS MARKUP. The same istop() that split the fence
# also COUNTED its lines: a `- name: build` in a YAML fence was a top-level
# bullet to renumber() and to prune(), so a section holding one finding and two
# lines of workflow config was published as `### Findings (3)` — the header
# claiming two findings that do not exist.
for MAXB in 1800 500; do
  W=$(mktemp -d)
  python3 - "$W/review.json" <<'FENCECOUNT'
import json, sys
lines = ["## Claude review — COMMENT", "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — the workflow step list is wrong",
         "", "```yaml", "- name: build", "- name: test", "```"]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 12, "side": "RIGHT",
                         "body": "**minor** unrelated, forces the strip pass to run"}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
FENCECOUNT
  BODY_MAX=$MAXB FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
  assert_contains "[$MAXB] YAML keys in a fence are not counted as findings" \
    "### Findings (1)" "$BODY"
  rm -rf "$W"
done

# (ab1c) A TABLE AND A BLOCKQUOTE GET THE SAME TREATMENT. Both are already
# indivisible in practice — neither can carry a blank line and neither starts a
# line with `- `, so the continuation rule happened to hold them together — so
# this is a characterization test, not a reproduction. It pins the invariant
# against the next change to the splitter.
for MAXB in 500 600 700 800 900 1000; do
  W=$(mktemp -d)
  python3 - "$W/review.json" <<'TBLQUOTE'
import json, sys
lines = ["## Claude review — COMMENT", "",
         "### Context", "",
         "| field | before | after |", "|-------|--------|-------|",
         "| ttl   | 60     | 3600  |", "| scope | user   | tenant |", "",
         "> The migration note claims the cache is flushed on deploy.",
         "> That does not hold for the tenant shard.", "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens"]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
TBLQUOTE
  BODY_MAX=$MAXB FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  RAW=$(payload_of "$W" | jq -r '.body')
  ROWS=$(printf '%s\n' "$RAW" | grep -c '^|' || true)
  case "$ROWS" in
    0|4) echo "OK:   [$MAXB] the table is whole or gone, never part of one" ;;
    *) echo "FAIL: [$MAXB] the table was split — $ROWS of 4 rows kept"; fail=$((fail + 1)) ;;
  esac
  QUOTES=$(printf '%s\n' "$RAW" | grep -c '^>' || true)
  case "$QUOTES" in
    0|2) echo "OK:   [$MAXB] the blockquote run is whole or gone" ;;
    *) echo "FAIL: [$MAXB] the blockquote run was split — $QUOTES of 2 lines kept"; fail=$((fail + 1)) ;;
  esac
  rm -rf "$W"
done

# ── (ab2) THE INVISIBLE-BLANK SET STOPPED ONE CODEPOINT SHORT ────────────────
# initinvis() looped `for (i = 128; i <= 141; i++)` — U+2000..U+200D — and
# stopped exactly before U+200E LEFT-TO-RIGHT MARK and U+200F RIGHT-TO-LEFT
# MARK. U+061C, U+180E, U+2061..U+2064 and U+FFF9..U+FFFB were missing too, as
# were the bidi embedding/override controls and isolates that sit between them.
# Any one of them puts (aa2) back verbatim: the line reads as content, the
# strip's `skipping` never clears, and the rest of the body goes with a
# duplicate bullet under the misleading "Dropped N body line(s) duplicating an
# inline comment."
echo ""
echo "── (ab2) the completed invisible-character set ──"

for pair in "lrm:8206" "rlm:8207" "alm:1564" "mvs:6158" "fa:8289" "invtimes:8290" \
            "invsep:8291" "invplus:8292" "lre:8234" "rlo:8238" "lri:8296" "pdi:8297" \
            "iaanchor:65529" "iaterm:65531"; do
  name="${pair%%:*}"; esc="${pair#*:}"
  W=$(mktemp -d)
  python3 - "$W/review.json" "$esc" <<'INVIS2'
import json, sys
blank = chr(int(sys.argv[2]))
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Findings (2)",
         "- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens",
         blank,
         "The same helper backs the admin console, so the blast radius is the whole tenant.",
         "A reviewer should read the migration notes before merging this."]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 11, "side": "RIGHT",
                         "body": "**critical** the auth guard is bypassed for expired tokens"}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
INVIS2
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
  assert_contains "[$name] the stripped bullet does not swallow the prose below it" \
    "the blast radius is the whole tenant" "$BODY"
  assert_contains "[$name] …nor the line after that" \
    "read the migration notes" "$BODY"
  assert_contains "[$name] the header counts what is left" "### Findings (1)" "$BODY"
  rm -rf "$W"
done

# (ab2b) FALSE POSITIVES. A byte-oriented gsub over multi-byte sequences is only
# safe if none of them can appear INSIDE a character that carries meaning. Each
# probe shares a lead byte, a two-byte prefix or a plane with something in the
# set, and each is the ONLY content of a `### Notes` section: prune() deletes a
# section holding nothing but blank lines, and mode=fit never assigns a blank
# line to a block at all, so a line wrongly read as blank disappears twice over.
# Codepoints are passed as NUMBERS — a shell round-trip through a heredoc is
# exactly where an exotic character gets normalised into something else.
for probe in "zwj-emoji:128105,8205,128187" "hangul-filler:12644" "hangul-syllable:44032" \
             "ufefe:65278" "cjk-e3:19990,30028" "arabic-d8:1572" "arabic-d89d:1565" \
             "mongolian-e1a0:6176" "fullwidth-efbf:65377" "astral:120792" \
             "math-e281:8263" "reserved-e28x:8261" "ogham-e19a:5761" "hyphen-e280:8208"; do
  name="${probe%%:*}"; cps="${probe#*:}"
  W=$(mktemp -d)
  python3 - "$W/review.json" "$cps" <<'FPPROBE'
import json, sys
probe = "".join(chr(int(c)) for c in sys.argv[2].split(","))
lines = ["## Claude review — REQUEST_CHANGES", "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens",
         "", "### Notes", "", probe]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines),
           "comments": [{"path": "src/foo.ts", "line": 11, "side": "RIGHT",
                         "body": "**critical** the auth guard is bypassed for expired tokens"}],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
FPPROBE
  FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
  assert_contains "[fp:$name] a line of real content is not a blank line" "### Notes" "$BODY"
  rm -rf "$W"
done

# ── (ab3) THE TITLE LINE CANNOT BE CUT ───────────────────────────────────────
# A paragraph on the line immediately after `## Claude review — X`, with no blank
# between, was folded into the title block by the continuation rule. Over budget,
# the title went with it: the posted body opened with a blank line and then
# `### Findings (2)`, with no `## Claude review` line at all. hardcut() only
# fires when NOTHING was admitted, so it did not rescue this. The existing
# "header survives truncation" case always put a blank line after the title, so
# it never reached this shape.
echo ""
echo "── (ab3) the review title is unconditionally present ──"

W=$(mktemp -d)
python3 - "$W/review.json" <<'NOBLANK'
import json, sys
para = ("This PR reworks the authentication middleware, and the reasoning needs "
        "more room than one line. " * 30)
lines = ["## Claude review — REQUEST_CHANGES", para, "",
         "### Findings (2)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed for expired tokens",
         "- **minor** {{LINK:src/foo.ts:12}} — the log line is noisy"]
json.dump({"verdict": "REQUEST_CHANGES", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
NOBLANK
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the title survives an over-budget paragraph glued to it" \
  "## Claude review — REQUEST_CHANGES" "$BODY"
assert_eq "…and it is the first line of the body" \
  "## Claude review — REQUEST_CHANGES" "$(printf '%s\n' "$BODY" | head -n1)"
assert_not_contains "the paragraph that busted the budget is what went" \
  "the reasoning needs more room" "$BODY"
assert_contains "the findings still made it" "the auth guard is bypassed" "$BODY"
rm -rf "$W"

# (ab3b) THE SAME AT SEVERAL BUDGETS, AND WITH THE BLANK LINE PRESENT: whatever
# else the cut takes, the body never opens mid-sentence.
for MAXB in 200 300 500 900 1800; do
  for GAP in "" "x"; do
    W=$(mktemp -d)
    python3 - "$W/review.json" "$GAP" <<'TITLEALWAYS'
import json, sys
gap = [] if sys.argv[2] else [""]
para = "prose that exists only to be far too large for the budget. " * 40
lines = ["## Claude review — COMMENT"] + gap + [para, "",
         "### Findings (1)",
         "- **critical** {{LINK:src/foo.ts:11}} — the auth guard is bypassed"]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
TITLEALWAYS
    BODY_MAX=$MAXB FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
    BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
    assert_contains "[$MAXB/gap=${GAP:-none}] the body opens with the review title" \
      "## Claude review" "$(printf '%s\n' "$BODY" | head -n1)"
    rm -rf "$W"
  done
done

# (ab3c) hardcut() CUTS ON A UTF-8 BOUNDARY. It walked byte by byte with no
# boundary check, unlike t90()/utrim(), so a budget landing inside the em dash of
# `## Claude review — X` left an orphan byte that jq renders as U+FFFD.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT",
        body: "## Claude review — COMMENT\n\nmore prose than will ever fit here",
        comments: [], meta: {findings: [], human_review: []}}' > "$W/review.json"
BODY_MAX=61 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(payload_of "$W" | jq -r '.body')
assert_not_contains "a hard cut never leaves a replacement character" "�" "$BODY"
rm -rf "$W"

# ── (ab4) A SKIP-MARKED RUN MUST NOT SUPERSEDE A CRASH BANNER ────────────────
# Section 7 already refuses to dismiss standing reviews for a body that read no
# code. Section 5 ran unconditionally, so guard.sh's oversized split request
# PATCHed a standing `<!-- claude-review-crash -->` banner — whose text is
# "**Action required:** a human should review this PR" — into "_Superseded by a
# newer Claude review run on this PR._" A run that judged nothing cleared a
# human-action signal about an earlier, still-unresolved failure.
echo ""
echo "── (ab4) a skip-marked run leaves crash banners standing ──"
for marker in "<!-- claude-review-skipped -->" "<!-- claude-review-oversized -->"; do
  W=$(mktemp -d)
  jq -n --arg body "$marker"$'\n\n## Claude review — REQUEST_CHANGES\n\nToo large to review well.' \
    '{verdict: "REQUEST_CHANGES", body: $body, comments: [], meta: {findings: []}}' > "$W/review.json"
  REVIEWS_FIXTURE=$(mktemp)
  cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 777, "user": {"login": "claude-bot[bot]"}, "state": "COMMENTED",
   "body": "<!-- claude-review-crash -->\n\n> **Action required:** a human should review this PR",
   "commit_id": "old1", "submitted_at": "2026-06-01T00:00:00Z"}
]
EOF
  FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
  assert_eq "exit 0 ($marker)" "0" "$RC"
  assert_not_contains "crash banner NOT superseded ($marker)" \
    "claude-review-superseded" "$(cat "$W/gh.log")"
  assert_contains "…and the log says why ($marker)" \
    "leaving prior crash banners standing" "$OUT"
  rm -rf "$W" "$REVIEWS_FIXTURE"
done

# (ab4b) THE CONTROL: a JUDGED review still supersedes the banner.
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
REVIEWS_FIXTURE=$(mktemp)
cat > "$REVIEWS_FIXTURE" <<'EOF'
[
  {"id": 777, "user": {"login": "claude-bot[bot]"}, "state": "COMMENTED",
   "body": "<!-- claude-review-crash -->\n\n> **Action required:** a human should review this PR",
   "commit_id": "old1", "submitted_at": "2026-06-01T00:00:00Z"}
]
EOF
FIXTURE_REVIEWS="$REVIEWS_FIXTURE" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_contains "a judged review still supersedes the crash banner" \
  "claude-review-superseded" "$(cat "$W/gh.log")"
rm -rf "$W" "$REVIEWS_FIXTURE"

# ── (ab5) THE BUDGET IS NOT SPENT ON WHAT prune() DELETES ────────────────────
# A prose block inside `### Findings` could PULL IN that header, and prune() then
# deleted the pair — a bullet-list section holding no bullet is not a section.
# The bytes were charged all the same, so content that would have fit was cut for
# a header and a paragraph nobody ever saw.
echo ""
echo "── (ab5) budget is not charged for blocks prune() deletes ──"
W=$(mktemp -d)
python3 - "$W/review.json" <<'PRUNEWASTE'
import json, sys
huge = "a finding whose bullet is far larger than the byte budget allows. " * 12
lines = ["## Claude review — COMMENT", "",
         "### Findings (1)",
         "- **minor** {{LINK:src/foo.ts:12}} — " + huge, "",
         "Prose inside the findings section that no bullet keeps alive.", "",
         "### Notes", "",
         "The tenant cache key omits the region, so a lookup can cross tenants."]
json.dump({"verdict": "COMMENT", "body": "\n".join(lines), "comments": [],
           "meta": {"findings": [], "human_review": []}}, open(sys.argv[1], "w"))
PRUNEWASTE
BODY_MAX=200 FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body')")
assert_contains "the section prune() would have kept gets the bytes" \
  "a lookup can cross tenants" "$BODY"
assert_not_contains "…and the section it would have deleted is not charged for" \
  "no bullet keeps alive" "$BODY"
rm -rf "$W"


echo ""
echo "── why this is not an approve ──"
# A COMMENT with no findings left the reader guessing at which gate held it.
W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "## Claude review — COMMENT\n\nRound-2 delta fixes the carried bug; nothing new survives.",
  "comments": [],
  "meta": {"findings": [], "human_review": [],
           "approve_blocked_by": ["sensitive_path", "effort"]}
}
EOF
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_eq "exit 0" "0" "$RC"
assert_contains "the reader is told it was not approved" "Not approved because" "$BODY"
assert_contains "…and BOTH gates are named, not one" "sensitive path" "$BODY"
assert_contains "…including the second" "more judgement than an unread approval allows" "$BODY"
assert_contains "…and that nothing was actually wrong" "No defect was found" "$BODY"
rm -rf "$W"

W=$(mktemp -d)
printf '%s\n' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_not_contains "a review with findings does not explain itself twice" "Not approved because" "$BODY"
rm -rf "$W"

W=$(mktemp -d)
cat > "$W/review.json" <<'EOF'
{"verdict": "APPROVE", "body": "## Claude review — APPROVE\n\nClean.", "comments": [],
 "meta": {"findings": [], "human_review": [], "approve_blocked_by": []}}
EOF
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_not_contains "an approve explains nothing" "Not approved" "$BODY"
rm -rf "$W"

# A review that recorded no gate is not editorialised over.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nfine.", comments: [], meta: {}}' > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_not_contains "a review with no gate field is not editorialised over" "Not approved" "$BODY"
rm -rf "$W"

# THE REGRESSION THIS PINS. The field shipped as a STRING; `map` over one is a
# jq error the stage swallows, so the disclosure was dead on its own contract.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nnothing new.", comments: [],
        meta: {findings: [], human_review: [], approve_blocked_by: "sensitive_path"}}' > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_contains "a single string still renders the gate" "sensitive path" "$BODY"
rm -rf "$W"

# `none`, `findings` and anything unrecognised name no gate the author can act
# on, so none of them reach the body as raw jargon.
W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nnothing new.", comments: [],
        meta: {findings: [], human_review: [], approve_blocked_by: ["none", "vibes", "effort"]}}' > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
NOTICE=$(printf '%s\n' "$BODY" | grep -o 'Not approved because [^<]*')
assert_eq "only the gate we know is named" \
  "Not approved because the diff needed more judgement than an unread approval allows. No defect was found." \
  "$NOTICE"
rm -rf "$W"

# `meta` is model-written and can be empty while criticals post inline. "No
# defect was found" printed under those criticals is the review contradicting
# itself, so a REQUEST_CHANGES never reaches the notice and a severity-marked
# comment suppresses it even when meta.findings is empty.
W=$(mktemp -d)
jq -n '{verdict: "REQUEST_CHANGES", body: "## Claude review — REQUEST_CHANGES\n\nBroken.",
        comments: [{path: "src/a.ts", line: 5, side: "RIGHT",
                    body: "**critical** the lock is dropped\n\nTwo writers reach it."}],
        meta: {findings: [], human_review: [], approve_blocked_by: ["sensitive_path"]}}' > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_not_contains "a REQUEST_CHANGES never says no defect was found" "No defect was found" "$BODY"
rm -rf "$W"

W=$(mktemp -d)
jq -n '{verdict: "COMMENT", body: "## Claude review — COMMENT\n\nOne minor.",
        comments: [{path: "src/a.ts", line: 5, side: "RIGHT",
                    body: "**minor** the log line carries the token\n\nIt reaches the log."}],
        meta: {findings: [], human_review: [], approve_blocked_by: ["effort"]}}' > "$W/review.json"
FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
BODY=$(visible_body "$(payload_of "$W" | jq -r '.body // ""')")
assert_not_contains "…nor does a COMMENT whose finding lives only in a comment" "No defect was found" "$BODY"
rm -rf "$W"

# The skill says the field is an array. If that schema line ever goes back to a
# bare string the poster still works, but the instruction must stay honest.
if grep -q '"approve_blocked_by": \[' skills/review-verify.md; then
  echo "OK:   review-verify.md asks for approve_blocked_by as an array"
else
  echo "FAIL: review-verify.md no longer asks for an array — the poster reads one"
  fail=$((fail + 1))
fi


# ── (s) the state block records what this round read ────────────────────────
# prior-review-state.sh finds the last FULL pass by this stamp, and guard.sh
# decides from it when the delta rounds have outgrown that read. Unset is full:
# that is what every round was before the stamp existed.
echo ""
echo "── (s) review state carries the scope ──"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "unset scope is stamped full" "full" "$(state_block "$(payload_of "$W" | jq -r '.body')" | jq -r '.scope')"
rm -rf "$W"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
SCOPE=delta FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "a delta round is stamped delta" "delta" "$(state_block "$(payload_of "$W" | jq -r '.body')" | jq -r '.scope')"
rm -rf "$W"
W=$(mktemp -d)
printf '%s' "$VALID_REVIEW" > "$W/review.json"
SCOPE=bogus FIXTURE_REVIEWS="" FIXTURE_FILES="$FILES_FIXTURE" run_poster "$W"
assert_eq "an unknown scope falls back to full, never to a guess" "full" "$(state_block "$(payload_of "$W" | jq -r '.body')" | jq -r '.scope')"
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
