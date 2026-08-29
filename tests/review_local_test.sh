#!/usr/bin/env bash
set -uo pipefail

# review_local_test.sh — the REVIEW_OUT_DIR dry-run seam in scripts/post-review.sh,
# and the static contract of scripts/review-local.sh that drives it.
#
# A SEPARATE FILE FROM post_review_test.sh on purpose. That suite's `gh` mock
# happily SERVES writes, because every case in it is about what gets posted. The
# seam's entire claim is the opposite — that no write is attempted at all — so it
# needs a mock that FAILS on one, and post_review_test.sh keeps asserting the
# production path unchanged next to it.
#
# No model runs here. review-local.sh's own model call is not exercised by
# anything in tests/ and cannot be: it is a real `claude -p` session.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
POSTER="$ROOT/scripts/post-review.sh"
LOCAL="$ROOT/scripts/review-local.sh"
for f in "$POSTER" "$LOCAL"; do
  [ -f "$f" ] || { echo "FAIL: $f not found"; exit 1; }
done

fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
assert_contains() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — expected to find '$2'" ;; esac
}
assert_file_has() {
  if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 — no '$2' in ${3##*/}"; fi
}

WORKROOT=$(mktemp -d)
trap 'rm -rf "$WORKROOT" "$MOCK_BIN"' EXIT

# ── gh mock ──────────────────────────────────────────────────────────────────
# Reads are served from fixtures — the poster still needs the diff hunks to
# decide which comments go inline, and a dry run that skipped that would report a
# DIFFERENT review than the real one. Writes are the thing under test: every
# `--method` call is recorded in $GH_WRITE_LOG and fails loudly, so a seam that
# leaked one is a red test rather than a silent post.
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--method "*)
    echo "$args" >> "$GH_WRITE_LOG"
    echo "gh MOCK: a WRITE was attempted during a dry run: $args" >&2
    exit 1 ;;
  *"/pulls/"*"/files"*)
    cat "${GH_FIXTURE_FILES:-/dev/null}" 2>/dev/null || echo '[]' ;;
  *"/pulls/"*"/reviews"*)
    cat "${GH_FIXTURE_REVIEWS:-/dev/null}" 2>/dev/null || echo '[]' ;;
  *) echo '{}' ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

FILES_FIXTURE="$WORKROOT/files.json"
cat > "$FILES_FIXTURE" <<'EOF'
[{"filename": "src/foo.ts", "patch": "@@ -10,3 +10,4 @@\n line10\n-old\n+new11\n+new12\n ctx"}]
EOF

# One standing CHANGES_REQUESTED review by the bot: section 5 must want to
# dismiss it, which is what proves a suppressed dismissal reaches actions.log.
REVIEWS_FIXTURE="$WORKROOT/reviews.json"
cat > "$REVIEWS_FIXTURE" <<'EOF'
[{"id": 4242, "state": "CHANGES_REQUESTED", "user": {"login": "claude-bot[bot]"}, "body": "old review"}]
EOF

write_review_json() { # write_review_json <path>
  cat > "$1" <<'EOF'
{
  "verdict": "COMMENT",
  "body": "### Findings (1)\n- **minor** {{LINK:src/bar.ts:4}} — a body-only finding",
  "comments": [{"path": "src/foo.ts", "line": 11, "side": "RIGHT",
                "body": "**major** the inline one\n\nfails when the socket closes early"}],
  "meta": {"findings": [{"path": "src/foo.ts", "line": 11, "severity": "major",
                         "title": "the inline one", "failure_scenario": "socket closes early"}],
           "human_review": []}
}
EOF
}

# run_poster <label-dir> — sets OUT, RC and WORK. REVIEW_OUT_DIR is passed only
# when DRY is non-empty, GITHUB_ACTIONS only when CI_MODE is.
run_poster() {
  WORK="$WORKROOT/$1"
  mkdir -p "$WORK"
  write_review_json "$WORK/review.json"
  printf 'document\n' > "$WORK/spec-status"
  : > "$WORK/gh-writes.log"
  # `env` and not an assignment prefix: a prefix is parsed before expansion, so
  # a conditionally-expanded `VAR=...` word becomes the command name instead.
  local seam=() ci=()
  [ -n "${DRY:-}" ] && seam=(REVIEW_OUT_DIR="$WORK/posted")
  [ -n "${CI_MODE:-}" ] && ci=(GITHUB_ACTIONS=true)
  # `-u GITHUB_ACTIONS`: this suite RUNS in CI, where that variable is already
  # true in the ambient environment `env` inherits. Without the unset, every
  # case sees CI_MODE's value whether it asked for it or not — and the seam is
  # refused under GITHUB_ACTIONS, so the whole dry-run half failed in CI while
  # passing on a developer machine. CI_MODE stays the only thing that sets it.
  OUT=$(cd "$WORK" && env -u GITHUB_ACTIONS \
    PATH="$MOCK_BIN:$PATH" \
    GH_WRITE_LOG="$WORK/gh-writes.log" \
    GH_FIXTURE_FILES="$FILES_FIXTURE" GH_FIXTURE_REVIEWS="$REVIEWS_FIXTURE" \
    GH_TOKEN=x GITHUB_REPOSITORY=o/r PR_NUMBER=7 REVIEW_BOT_USER="claude-bot[bot]" \
    HEAD_SHA=abc123 \
    SPEC_STATUS="$WORK/spec-status" \
    REVIEW_JSON="$WORK/review.json" ORCH_LOG="$WORK/orchestrator-output.txt" \
    JOB_START="$WORK/no-job-start" \
    PRIOR_FINDINGS_JSON="$WORK/no-priors.json" \
    "${seam[@]+"${seam[@]}"}" "${ci[@]+"${ci[@]}"}" \
    bash "$POSTER" 2>&1)
  RC=$?
}

echo "── REVIEW_OUT_DIR set: artifacts, not GitHub writes ──"
DRY=1 CI_MODE="" run_poster dry
assert_eq "exit 0 — the exit contract is unchanged on the dry-run path" 0 "$RC"
if [ -s "$WORK/gh-writes.log" ]; then
  bad "no GitHub write is attempted — got: $(cat "$WORK/gh-writes.log")"
else
  ok "no GitHub write is attempted"
fi
POSTED="$WORK/posted"
for f in verdict body.md comments.json meta.json summary.md actions.log; do
  if [ -f "$POSTED/$f" ]; then ok "artifact $f exists"; else bad "artifact $f is missing"; fi
done
assert_eq "verdict is the event string the review would have posted" "COMMENT" "$(cat "$POSTED/verdict" 2>/dev/null)"
assert_file_has "body.md carries the expanded link, not the placeholder" "](https://github.com/o/r/pull/7/files#diff-" "$POSTED/body.md"
assert_file_has "…and the round-2 state block, which is appended last" "<!-- claude-review-state" "$POSTED/body.md"
assert_eq "comments.json holds the kept inline comments as posted" "1" "$(jq 'length' "$POSTED/comments.json" 2>/dev/null)"
assert_eq "…anchored where the model put it" "src/foo.ts:11" \
  "$(jq -r '.[0] | .path + ":" + (.line|tostring)' "$POSTED/comments.json" 2>/dev/null)"
assert_eq "meta.json is .meta from the review JSON" "1" "$(jq '.findings | length' "$POSTED/meta.json" 2>/dev/null)"
assert_file_has "summary.md is what would have gone to the step summary" "## Claude Review: COMMENT" "$POSTED/summary.md"
assert_file_has "actions.log records the suppressed post, with its shape" "POST review COMMENT 1 comments" "$POSTED/actions.log"
assert_file_has "…and the suppressed dismissal of the standing review" "DISMISS 4242" "$POSTED/actions.log"
assert_contains "the run says plainly that it wrote instead of posting" "instead of posting it" "$OUT"

echo ""
echo "── REVIEW_OUT_DIR under GITHUB_ACTIONS: refuse, loudly ──"
DRY=1 CI_MODE=1 run_poster ci
assert_eq "exit 1" 1 "$RC"
assert_contains "the error names the seam and the rule" \
  "::error::REVIEW_OUT_DIR is a local-eval seam and must never be set in CI" "$OUT"
if [ -d "$WORKROOT/ci/posted" ]; then
  bad "refusing must happen before any artifact directory is created"
else
  ok "no artifact directory is created on the refusal path"
fi

echo ""
echo "── REVIEW_OUT_DIR unset: the production path, unchanged ──"
DRY="" CI_MODE="" run_poster live
# The mock fails every write, so the POST fails and the poster crash-exits. That
# is the point: with the seam unset the writes are still ATTEMPTED, so nothing
# the seam added can suppress a real review by accident.
if [ -s "$WORKROOT/live/gh-writes.log" ]; then
  ok "GitHub writes are still attempted when the seam is unset"
else
  bad "the seam suppressed a write with REVIEW_OUT_DIR unset"
fi
assert_file_has "…including the review POST itself" "--method POST" "$WORKROOT/live/gh-writes.log"
for f in verdict body.md comments.json meta.json actions.log; do
  if [ -e "$WORKROOT/live/$f" ]; then bad "an artifact leaked into the CWD: $f"; fi
done
ok "no dry-run artifact leaks into the working directory"

echo ""
echo "── review-local.sh ──"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=error "$LOCAL" >/dev/null 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported an error"
    shellcheck --severity=error "$LOCAL"
  fi
else
  echo "SKIP: shellcheck not installed"
fi
if grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$LOCAL"; then
  bad "review-local.sh uses set -e (banned, bugbot.md)"
else
  ok "review-local.sh does not use set -e"
fi
if grep -qE '^set -uo pipefail' "$LOCAL"; then ok "…and does use set -uo pipefail"; else bad "no set -uo pipefail"; fi

OUT=$(bash "$LOCAL" 2>&1); RC=$?
assert_eq "no PR number → exit 2" 2 "$RC"
assert_contains "…with a usage line" "usage:" "$OUT"
OUT=$(bash "$LOCAL" 12 --post 2>&1); RC=$?
assert_eq "an unknown second argument → exit 2, never a run" 2 "$RC"

# The whole safety claim of the script: it drives the poster through the seam and
# owns no write verb of its own.
assert_file_has "it sets the seam when it invokes the poster" 'REVIEW_OUT_DIR="$OUT/posted"' "$LOCAL"
# The deny list itself names every write verb, so it is excluded by name — what
# is being asserted is that no LINE OF THE SCRIPT invokes one.
if grep -vE '^DENY=' "$LOCAL" \
   | grep -nE 'gh (api --method|pr (comment|review|edit|close|merge|ready)|issue (comment|edit|close)|release)|git push'; then
  bad "review-local.sh contains a GitHub write verb"
else
  ok "review-local.sh contains no GitHub write verb"
fi
assert_file_has "…and keeps the workflow's deny list verbatim" \
  "Bash(gh api:*),Bash(gh pr comment:*)" "$LOCAL"

echo ""
echo "── the local run must not be SHALLOWER than CI ──"
# CI installs the subagents from agents/*.md, whose frontmatter carries the
# effort. An --agents JSON that omits it runs them at the session's own
# --effort, so review-scan — the finding-producing stage — searched less hard
# than production and biased the only recall number this harness produces.
assert_file_has "the agents JSON carries an effort for review-scan" 'effort: $se' "$LOCAL"
assert_file_has "…and one for review-verify" 'effort: $ve' "$LOCAL"
assert_file_has "…read from the frontmatter, so the two cannot drift" 'agent_effort()' "$LOCAL"
for a in review-scan review-verify; do
  want=$(sed -n '/^---$/,/^---$/p' "$ROOT/agents/$a.md" | sed -n 's/^effort:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)
  case "$want" in
    low|medium|high) ok "agents/$a.md declares effort: $want" ;;
    *) bad "agents/$a.md has no readable 'effort:' — review-local.sh refuses to run without one" ;;
  esac
done

echo ""
echo "── concurrent runs must not share a base ref ──"
# `refs/remotes/*` is shared across worktrees (only HEAD and the index are
# per-worktree), so pinning origin/<base> in a worktree is a GLOBAL write: two
# runs in flight gave each other the wrong base, and with it the wrong diff
# scope and the wrong answer from review-verify's absence-claim lookup.
if grep -qE 'worktree add' "$LOCAL"; then
  bad "review-local.sh still checks out with 'git worktree add' — refs/remotes is shared"
else
  ok "the checkout is not a worktree"
fi
assert_file_has "…it is a per-run --shared clone" 'git clone -q --shared --no-checkout' "$LOCAL"
assert_file_has "…living inside the run directory" 'WT="$RUNDIR/repo"' "$LOCAL"
if grep -qE 'git -C "\$CLONE" update-ref' "$LOCAL"; then
  bad "the base ref is still pinned in the SHARED clone"
else
  ok "the base ref is pinned in the per-run clone, never the shared one"
fi

echo ""
echo "── .eval.env is read as data, not executed ──"
# The file has two readers with incompatible syntax: `make` needs EVAL_PRS
# unquoted and space-separated, which the shell reads as a command plus
# arguments. Sourcing it ran `102` and printed 'command not found' on every run.
if grep -qE '^[[:space:]]*\.[[:space:]]+"\$ROOT/\.eval\.env"' "$LOCAL"; then
  bad "review-local.sh still sources .eval.env"
else
  ok "review-local.sh does not source .eval.env"
fi
assert_file_has "…it parses the keys it uses" 'read_eval_env()' "$LOCAL"
# The shipped example must survive being read, whatever a `make` reader needs.
EXAMPLE="$ROOT/.eval.env.example"
if [ -f "$EXAMPLE" ]; then
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/scripts"
  cp "$LOCAL" "$SANDBOX/scripts/"
  cp "$EXAMPLE" "$SANDBOX/.eval.env"
  cp -R "$ROOT/agents" "$SANDBOX/" 2>/dev/null
  OUT=$(cd "$SANDBOX" && bash scripts/review-local.sh 2>&1)
  case "$OUT" in
    *"command not found"*) bad "the shipped .eval.env.example still executes when read" ;;
    *) ok "the shipped .eval.env.example is read without executing anything" ;;
  esac
  rm -rf "$SANDBOX"
else
  bad ".eval.env.example is missing — the template the docs point at"
fi

echo ""
if [ "$fail" -eq 0 ]; then echo "All review-local tests passed."; exit 0; fi
echo "$fail review-local test(s) failed."; exit 1
