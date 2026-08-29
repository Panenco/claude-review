#!/usr/bin/env bash
set -uo pipefail

# upload_screenshots_test.sh — fixture test for scripts/upload-screenshots.sh
# with a mocked `gh` (PATH shim).
#
# This script is the ONLY privileged GitHub API surface the review session has,
# and it exists so `pr-review.yml` can deny the raw `gh` API subcommand
# session-wide (the official `code-review` plugin prompt runs in that session
# over attacker-controlled PR content). It was extracted verbatim out of
# `skills/review-orchestrator.md`, so what is asserted here is that the
# extraction did not lose a guard:
#
#   * the "no screenshots → exit 0" early return (the common case is a review
#     with strategy=skip; it must be a silent no-op, not a failed API call);
#   * the `file -b --mime-type` PNG guard (a capture that failed mid-write embeds
#     a broken image in the review);
#   * the stdin `--input -` blob form — the argv form (`-f content=`) SILENTLY
#     DROPS blobs over ~200 KB, so a large screenshot would upload "successfully"
#     and render as a broken image;
#   * the review-assets create-vs-update split (PATCH an existing ref, POST a new
#     one) — a first review on a fresh repo has no branch to patch.

cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/upload-screenshots.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── gh mock (PATH shim) ──────────────────────────────────────────────────────
# Logs every invocation to $GH_LOG and captures POSTed stdin payloads into
# $GH_CAPTURE_DIR. GH_NO_BRANCH=1 makes the review-assets ref lookup fail, which
# selects the create arm.
MOCK_BIN="$WORK/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
# GH_SLEEP simulates a hung GitHub call — the whole point of the time budget.
[ "${GH_SLEEP:-0}" != "0" ] && sleep "$GH_SLEEP"
args="$*"
INPUT=""
prev=""
for a in "$@"; do
  [ "$prev" = "--input" ] && INPUT="$a"
  prev="$a"
done
capture() { # capture <name>
  local dest="$GH_CAPTURE_DIR/$1-$(date +%s%N).json"
  if [ "$INPUT" = "-" ]; then cat > "$dest"; else : > "$dest"; fi
}
case "$args" in
  *"git/refs/heads/review-assets"*"--method PATCH"*)
    echo '{}' ;;
  *"git/refs/heads/review-assets"*)
    [ "${GH_NO_BRANCH:-0}" = "1" ] && exit 1
    echo "basesha111" ;;
  *"git/commits/basesha111"*)
    echo "basetree222" ;;
  *"git/blobs"*)
    capture blob
    echo "blobsha333" ;;
  *"git/trees"*)
    capture tree
    echo "treesha444" ;;
  *"git/commits"*"--method POST"*)
    echo "commitsha555" ;;
  *"git/refs"*"--method POST"*)
    echo '{}' ;;
  *)
    echo '{}' ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

# run <shots-dir> — runs the script with mocks; sets OUT and RC.
run() {
  local dir="$1"
  : > "$WORK/gh.log"
  rm -rf "$WORK/capture"; mkdir -p "$WORK/capture"
  OUT=$(PATH="$MOCK_BIN:$PATH" \
    GH_LOG="$WORK/gh.log" GH_CAPTURE_DIR="$WORK/capture" \
    GH_NO_BRANCH="${NO_BRANCH:-0}" \
    GITHUB_REPOSITORY="${REPO_OVERRIDE-o/r}" PR_NUMBER="${PR_OVERRIDE-7}" \
    GITHUB_REPO_TOKEN=tok SCREENSHOT_DIR="$dir" \
    bash "$SCRIPT" 2>&1)
  RC=$?
}

# run2 <shots-dir> — like run(), but keeps stdout (OUT) and stderr (ERR) APART.
# The stdout contract ("every line is an https:// URL and nothing else") is not
# assertable through run()'s `2>&1`. Extra knobs, all inert at their defaults:
# OUT_DIR_OVERRIDE (the dry-run seam), GHA_OVERRIDE (GITHUB_ACTIONS),
# BUDGET_OVERRIDE (seconds), GH_SLEEP (hang every mocked call),
# FORCE_WATCHDOG=1 (hide `timeout`, exercising the pure-bash fallback).
run2() {
  local dir="$1"
  local -a envv
  : > "$WORK/gh.log"
  rm -rf "$WORK/capture"; mkdir -p "$WORK/capture"
  envv=(PATH="$MOCK_BIN:$PATH"
        GH_LOG="$WORK/gh.log" GH_CAPTURE_DIR="$WORK/capture"
        GH_NO_BRANCH="${NO_BRANCH:-0}" GH_SLEEP="${GH_SLEEP:-0}"
        GITHUB_REPOSITORY="${REPO_OVERRIDE-o/r}" PR_NUMBER="${PR_OVERRIDE-7}"
        GITHUB_REPO_TOKEN=tok SCREENSHOT_DIR="$dir"
        REVIEW_OUT_DIR="${OUT_DIR_OVERRIDE-}" GITHUB_ACTIONS="${GHA_OVERRIDE-}"
        SCREENSHOT_UPLOAD_TIMEOUT_SECONDS="${BUDGET_OVERRIDE-60}")
  [ "${FORCE_WATCHDOG:-0}" = "1" ] && envv+=(UPLOAD_TIMEOUT_BIN=)
  OUT=$(env "${envv[@]}" bash "$SCRIPT" 2>"$WORK/err.txt")
  RC=$?
  ERR=$(cat "$WORK/err.txt")
}

# A real 1x1 PNG — `file -b --mime-type` keys off the \x89PNG magic, so the bytes
# have to be genuine for the guard under test to mean anything.
png() { # png <path> [padding-bytes]
  python3 - "$1" "${2:-0}" <<'PY'
import base64, sys
data = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
pad = int(sys.argv[2])
open(sys.argv[1], "wb").write(data + b"\0" * pad)
PY
}

# ── 1. nothing to publish → silent no-op ────────────────────────────────────
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
run "$EMPTY"
assert_eq "no screenshots exits 0" "0" "$RC"
assert_eq "no screenshots prints nothing" "" "$OUT"
assert_eq "no screenshots makes no API call" "0" "$(wc -l < "$WORK/gh.log" | tr -d ' ')"

# A directory that does not exist at all is the same no-op (the tester never ran).
run "$WORK/does-not-exist"
assert_eq "missing screenshot dir exits 0" "0" "$RC"
assert_eq "missing screenshot dir prints nothing" "" "$OUT"

# ── 2. required inputs ──────────────────────────────────────────────────────
SHOTS="$WORK/shots"; mkdir -p "$SHOTS"
png "$SHOTS/01-list.png"
REPO_OVERRIDE="" run "$SHOTS"
assert_eq "missing GITHUB_REPOSITORY exits 2" "2" "$RC"
PR_OVERRIDE="" run "$SHOTS"
assert_eq "missing PR_NUMBER exits 2" "2" "$RC"

# ── 3. the PNG guard, and the URL shape ─────────────────────────────────────
# A truncated capture leaves a file that is not a PNG. Publishing it embeds a
# broken image in the review, so it must be dropped, not uploaded.
printf 'not a png at all' > "$SHOTS/02-truncated.png"
run "$SHOTS"
assert_eq "upload exits 0" "0" "$RC"
assert_contains "prints the embed URL for the real PNG" \
  "https://github.com/o/r/raw/review-assets/pr-7/01-list.png" "$OUT"
assert_not_contains "does NOT publish the non-PNG file" "02-truncated.png" "$OUT"
assert_eq "exactly one URL printed" "1" "$(printf '%s\n' "$OUT" | grep -c 'raw/review-assets')"
assert_eq "exactly one blob POSTed" "1" "$(grep -c 'git/blobs' "$WORK/gh.log")"
assert_not_contains "never uses raw.githubusercontent.com (breaks on private repos)" \
  "raw.githubusercontent.com" "$OUT"

# ── 4. the >200 KB stdin form ───────────────────────────────────────────────
# `-f content=…` puts the blob in argv and silently drops large ones. Assert the
# stdin form is used AND that a 300 KB image round-trips byte-for-byte.
assert_contains "blob POST uses the stdin --input form" "--input -" \
  "$(grep 'git/blobs' "$WORK/gh.log")"
assert_not_contains "blob POST never uses the argv -f content= form" "-f content=" \
  "$(grep 'git/blobs' "$WORK/gh.log")"

BIG="$WORK/big"; mkdir -p "$BIG"
png "$BIG/03-big.png" 307200
run "$BIG"
BLOB=$(ls "$WORK"/capture/blob-* 2>/dev/null | head -1)
assert_eq "large blob payload was captured from stdin" "yes" "$([ -s "$BLOB" ] && echo yes || echo no)"
assert_eq "payload declares base64 encoding" "base64" "$(jq -r '.encoding' "$BLOB" 2>/dev/null)"
assert_eq "300 KB PNG round-trips byte-for-byte" "match" \
  "$(python3 - "$BLOB" "$BIG/03-big.png" <<'PY'
import base64, json, sys
p = json.load(open(sys.argv[1]))["content"]
print("match" if base64.b64decode(p) == open(sys.argv[2], "rb").read() else "MISMATCH")
PY
)"

# ── 5. create-vs-update split on the review-assets branch ───────────────────
run "$SHOTS"
assert_contains "existing branch is force-PATCHed" "git/refs/heads/review-assets --method PATCH" \
  "$(cat "$WORK/gh.log")"
assert_contains "the PATCH is a force update (asset store, history worthless)" "-F force=true" \
  "$(cat "$WORK/gh.log")"
TREE=$(ls "$WORK"/capture/tree-* 2>/dev/null | head -1)
assert_eq "tree payload keeps the existing base_tree" "basetree222" \
  "$(jq -r '.base_tree' "$TREE" 2>/dev/null)"

NO_BRANCH=1 run "$SHOTS"
assert_contains "absent branch is CREATED, not patched" "refs/heads/review-assets" \
  "$(grep 'git/refs --method POST' "$WORK/gh.log")"
assert_eq "absent branch is never PATCHed" "0" \
  "$(grep -c 'git/refs/heads/review-assets --method PATCH' "$WORK/gh.log")"
TREE=$(ls "$WORK"/capture/tree-* 2>/dev/null | head -1)
assert_eq "tree payload omits base_tree on a fresh branch" "null" \
  "$(jq -r '.base_tree // "null"' "$TREE" 2>/dev/null)"

# ── 6. the dry-run seam (REVIEW_OUT_DIR) ────────────────────────────────────
# post-review.sh documents REVIEW_OUT_DIR as "set it and every GitHub WRITE
# becomes an artifact", and it invokes THIS script unguarded — so a local dry run
# with screenshots on disk used to POST blobs/trees/commits and PATCH a ref
# against the live target repo. An audit had to stub this script out to keep from
# writing to a real customer repo.
SEAM="$WORK/seam"; mkdir -p "$SEAM"
printf 'PRE-EXISTING LINE\n' > "$SEAM/actions.log"
OUT_DIR_OVERRIDE="$SEAM" run2 "$SHOTS"
SEAM_LOG=$(cat "$SEAM/actions.log")
assert_eq "dry run exits 0" "0" "$RC"
assert_eq "dry run makes NO write call" "0" \
  "$(grep -c -e '--method POST' -e '--method PATCH' "$WORK/gh.log")"
assert_contains "dry run still READS the review-assets ref" "git/refs/heads/review-assets" \
  "$(cat "$WORK/gh.log")"
assert_contains "dry run logs the suppressed blob POST" "POST git/blobs pr-7/01-list.png" "$SEAM_LOG"
assert_contains "dry run logs the suppressed tree POST" "POST git/trees" "$SEAM_LOG"
assert_contains "dry run logs the suppressed commit POST" "POST git/commits" "$SEAM_LOG"
assert_contains "dry run logs the suppressed ref PATCH" "PATCH git/refs/heads/review-assets" "$SEAM_LOG"
# post-review.sh created and already wrote to this log before calling us.
assert_contains "dry run APPENDS to actions.log, never truncates it" "PRE-EXISTING LINE" "$SEAM_LOG"
# The caller's rendering path must still be exercised by a dry run.
assert_eq "dry run still prints the URL it would have produced" \
  "https://github.com/o/r/raw/review-assets/pr-7/01-list.png" "$OUT"

# The create arm is the other thing a dry run has to be able to report.
NO_BRANCH=1 OUT_DIR_OVERRIDE="$SEAM" run2 "$SHOTS"
assert_contains "dry run logs the CREATE arm when the branch is absent" \
  "POST git/refs refs/heads/review-assets" "$(cat "$SEAM/actions.log")"

# Same refusal as post-review.sh: a dry run that silently swallowed a real review
# is the only failure mode that matters, so this one is loud.
GHA_OVERRIDE=true OUT_DIR_OVERRIDE="$SEAM" run2 "$SHOTS"
assert_eq "REVIEW_OUT_DIR under GITHUB_ACTIONS fails loudly" "1" "$RC"
assert_contains "…with post-review.sh's wording" \
  "::error::REVIEW_OUT_DIR is a local-eval seam and must never be set in CI" "$ERR"
assert_eq "…and prints nothing on stdout" "" "$OUT"

# ── 7. the total time budget ────────────────────────────────────────────────
# post-review.sh invokes this bare and posts the review AFTERWARDS, so a hung
# `gh api` here does not cost a gallery, it costs the whole review: the job burns
# to the workflow timeout and the PR gets NO review at all.
START=$(date +%s)
GH_SLEEP=20 BUDGET_OVERRIDE=1 run2 "$SHOTS"
ELAPSED=$(( $(date +%s) - START ))
assert_eq "a hung upload still exits 0 (non-fatal by contract)" "0" "$RC"
assert_eq "a hung upload prints nothing" "" "$OUT"
assert_contains "a hung upload warns on stderr" "::warning::" "$ERR"
assert_contains "…naming the budget it blew" "1s budget" "$ERR"
assert_eq "the budget is actually enforced (returned in <10s, not 20s)" "yes" \
  "$([ "$ELAPSED" -lt 10 ] && echo yes || echo "no (${ELAPSED}s)")"

# macOS has no GNU `timeout` unless coreutils is installed; the CI runner does.
# FORCE_WATCHDOG hides it so the pure-bash fallback is exercised on both.
START=$(date +%s)
FORCE_WATCHDOG=1 GH_SLEEP=20 BUDGET_OVERRIDE=1 run2 "$SHOTS"
ELAPSED=$(( $(date +%s) - START ))
assert_eq "the no-coreutils fallback also exits 0" "0" "$RC"
assert_eq "the no-coreutils fallback prints nothing" "" "$OUT"
assert_contains "the no-coreutils fallback warns" "::warning::" "$ERR"
assert_eq "the no-coreutils fallback enforces the budget too" "yes" \
  "$([ "$ELAPSED" -lt 10 ] && echo yes || echo "no (${ELAPSED}s)")"

# The watchdog must not change the happy path.
FORCE_WATCHDOG=1 run2 "$SHOTS"
assert_eq "the fallback path still publishes normally" \
  "https://github.com/o/r/raw/review-assets/pr-7/01-list.png" "$OUT"

# ── 8. stdout is URLs or nothing ────────────────────────────────────────────
# post-review.sh builds `![](<line>)` straight from these lines. Anything else on
# stdout renders a BROKEN IMAGE in a public review and leaks an internal path;
# a basename with a space or `)` breaks the markdown itself.
NAMES="$WORK/names"; mkdir -p "$NAMES"
png "$NAMES/01-list.png"
png "$NAMES/01 my shot.png"
png "$NAMES/02(evil).png"
run2 "$NAMES"
assert_eq "unsafe basenames do not stop the safe one" "0" "$RC"
assert_eq "only the URL-safe capture is published" \
  "https://github.com/o/r/raw/review-assets/pr-7/01-list.png" "$OUT"
assert_eq "one blob POSTed, not three" "1" "$(grep -c 'git/blobs' "$WORK/gh.log")"
assert_not_contains "a space never reaches stdout" " " "$OUT"
assert_not_contains "a paren never reaches stdout (it would close the link early)" ")" "$OUT"
assert_contains "the skipped space-named file is named in a warning" "01 my shot.png" "$ERR"
assert_contains "the skipped paren-named file is named in a warning" "02(evil).png" "$ERR"
assert_contains "…as a ::warning::, on stderr" "::warning::" "$ERR"
assert_eq "every stdout line is a bare https:// URL" "0" \
  "$(printf '%s\n' "$OUT" | grep -cvE '^https://[A-Za-z0-9._~:/-]+$')"

# The last gate: whatever produced it, a line that is not a clean URL is dropped
# rather than handed to the caller as an image source.
REPO_OVERRIDE="o r/x" run2 "$SHOTS"
assert_eq "a malformed URL is suppressed, not printed" "" "$OUT"
assert_contains "…and reported on stderr" "::warning::" "$ERR"
assert_eq "suppressing it is still non-fatal" "0" "$RC"

# ── 9. house rules ──────────────────────────────────────────────────────────
assert_eq "script does not use set -e (bugbot.md)" "yes" \
  "$(grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$SCRIPT" && echo no || echo yes)"
assert_eq "action.yml verifies the script is installed" "yes" \
  "$(grep -q 'upload-screenshots.sh' action.yml && echo yes || echo no)"
# The poster invokes it, not the review session. That is the whole point: the
# session then needs no raw GitHub API at all, and the upload happens whether or
# not the review produced a finding to hang a screenshot on.
assert_eq "the poster invokes it" "yes" \
  "$(grep -q 'UPLOAD_SCREENSHOTS_SH' scripts/post-review.sh && echo yes || echo no)"
assert_eq "the orchestrator skill does NOT invoke it" "yes" \
  "$(grep -q 'Run .*upload-screenshots.sh' skills/review-orchestrator.md && echo no || echo yes)"

# `.review-scripts/` lived in the worktree as untracked files; a judge's
# `git stash -u` swallowed it mid-run and the poster died with exit 127.
# Comments still name the old path to explain the history; only INVOCATIONS matter.
assert_eq "no caller resolves the scripts through the git workspace" "yes" \
  "$(grep -rh '\.review-scripts/[a-z-]*\.sh' action.yml .github/workflows/pr-review.yml skills/ \
     | grep -qv '^[[:space:]]*#' && echo no || echo yes)"
assert_eq "action.yml installs the scripts outside the workspace" "yes" \
  "$(grep -q 'RUNNER_TEMP' action.yml && grep -q 'CLAUDE_REVIEW_SCRIPTS=' action.yml && echo yes || echo no)"

exit $((fail > 0))
