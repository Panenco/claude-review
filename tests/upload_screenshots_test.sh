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

# ── 6. house rules ──────────────────────────────────────────────────────────
assert_eq "script does not use set -e (bugbot.md)" "yes" \
  "$(grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$SCRIPT" && echo no || echo yes)"
assert_eq "action.yml verifies the script is installed" "yes" \
  "$(grep -q 'upload-screenshots.sh' action.yml && echo yes || echo no)"
assert_eq "the orchestrator skill invokes it instead of inlining the API calls" "yes" \
  "$(grep -q 'CLAUDE_REVIEW_SCRIPTS/upload-screenshots.sh' skills/review-orchestrator.md && echo yes || echo no)"

# `.review-scripts/` lived in the worktree as untracked files; a judge's
# `git stash -u` swallowed it mid-run and the poster died with exit 127.
# Comments still name the old path to explain the history; only INVOCATIONS matter.
assert_eq "no caller resolves the scripts through the git workspace" "yes" \
  "$(grep -rh '\.review-scripts/[a-z-]*\.sh' action.yml .github/workflows/pr-review.yml skills/ \
     | grep -qv '^[[:space:]]*#' && echo no || echo yes)"
assert_eq "action.yml installs the scripts outside the workspace" "yes" \
  "$(grep -q 'RUNNER_TEMP' action.yml && grep -q 'CLAUDE_REVIEW_SCRIPTS=' action.yml && echo yes || echo no)"

exit $((fail > 0))
