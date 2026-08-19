#!/usr/bin/env bash
set -uo pipefail

# fetch_pr_threads_test.sh — fixture test for scripts/fetch-pr-threads.sh with a
# mocked `gh` (PATH shim).
#
# The script holds every raw GitHub REST/GraphQL READ this pipeline makes. It was
# extracted verbatim out of `skills/review-context-builder.md` so that
# `pr-review.yml` can deny the raw `gh` API subcommand session-wide — the review
# session also runs the official `code-review` plugin's prompt over
# attacker-controlled PR content, and `--disallowedTools` cannot be scoped to one
# subagent.
#
# What is asserted here is the OUTPUT CONTRACT, because that is what the
# extraction could silently break: the file names and the exact jq field names
# that `review-context-builder.md`, `review-judge.md` and `post-review.sh`
# downstream read by name. A renamed key is invisible until a round-2 review
# quietly reconstructs zero prior findings and forgives the previous round's
# blockers.

cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/fetch-pr-threads.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "OK:   $label"; else echo "FAIL: $label — want '$want', got '$got'"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"; mkdir -p "$OUT"

# ── fixtures ────────────────────────────────────────────────────────────────
# One inline-comment set covering every branch of the four-view split: our bot's
# top-level comment, another bot's, a human's, replies of each kind, and a
# comment by the PR author (which must be excluded from human-inline-comments).
cat > "$WORK/pulls-comments.json" <<'EOF'
[
  {"id": 1, "node_id": "PRRC_1", "path": "src/a.ts", "line": 10, "in_reply_to_id": null,
   "user": {"login": "claude-bot[bot]", "type": "Bot"}, "body": "ours"},
  {"id": 2, "node_id": "PRRC_2", "path": "src/b.ts", "line": 20, "in_reply_to_id": null,
   "user": {"login": "cursor[bot]", "type": "Bot"}, "body": "other bot"},
  {"id": 3, "node_id": "PRRC_3", "path": "src/c.ts", "line": 30, "in_reply_to_id": null,
   "user": {"login": "alice", "type": "User"}, "body": "human top-level"},
  {"id": 4, "node_id": "PRRC_4", "path": "src/d.ts", "line": 40, "in_reply_to_id": null,
   "user": {"login": "prauthor", "type": "User"}, "body": "author top-level"},
  {"id": 5, "node_id": "PRRC_5", "path": "src/a.ts", "line": 10, "in_reply_to_id": 1,
   "user": {"login": "prauthor", "type": "User"}, "body": "reply on ours"},
  {"id": 6, "node_id": "PRRC_6", "path": "src/b.ts", "line": 20, "in_reply_to_id": 2,
   "user": {"login": "prauthor", "type": "User"}, "body": "reply on other bot"},
  {"id": 7, "node_id": "PRRC_7", "path": "src/c.ts", "line": 30, "in_reply_to_id": 3,
   "user": {"login": "prauthor", "type": "User"}, "body": "reply on human"},
  {"id": 8, "node_id": "PRRC_8", "path": "src/b.ts", "line": 20, "in_reply_to_id": 2,
   "user": {"login": "claude-bot[bot]", "type": "Bot"}, "body": "our reply on theirs"}
]
EOF
cat > "$WORK/issue-comments.json" <<'EOF'
[
  {"id": 100, "created_at": "2026-01-01T00:00:00Z", "user": {"login": "alice", "type": "User"}, "body": "general human"},
  {"id": 101, "created_at": "2026-01-02T00:00:00Z", "user": {"login": "cursor[bot]", "type": "Bot"}, "body": "bot noise"}
]
EOF
cat > "$WORK/graphql.json" <<'EOF'
{"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
  {"id": "PRRT_open", "isResolved": false, "isOutdated": false,
   "comments": {"nodes": [{"databaseId": 1, "author": {"login": "claude-bot[bot]"}, "path": "src/a.ts", "line": 10}]}},
  {"id": "PRRT_done", "isResolved": true, "isOutdated": false,
   "comments": {"nodes": [{"databaseId": 3, "author": {"login": "alice"}, "path": "src/c.ts", "line": 30}]}}
]}}}}}
EOF
# Reviews: a crash banner, a skipped marker, and two real judged reviews — one at
# the prior head SHA, one older. The prior-review pick MUST land on the one
# pinned to PRIOR_HEAD_SHA and MUST ignore every marker-stamped body.
cat > "$WORK/reviews.json" <<'EOF'
[
  {"user": {"login": "claude-bot[bot]", "type": "Bot"}, "state": "COMMENTED", "commit_id": "oldsha",
   "submitted_at": "2026-01-01T00:00:00Z", "body": "## Claude PR Review — COMMENT\n\nolder judged"},
  {"user": {"login": "claude-bot[bot]", "type": "Bot"}, "state": "CHANGES_REQUESTED", "commit_id": "headsha",
   "submitted_at": "2026-01-02T00:00:00Z", "body": "## Claude PR Review\n\nFunctional Validation — WARN\n\njudged at head"},
  {"user": {"login": "claude-bot[bot]", "type": "Bot"}, "state": "COMMENTED", "commit_id": "headsha",
   "submitted_at": "2026-01-03T00:00:00Z", "body": "<!-- claude-review-crash -->\n\ncrash banner"},
  {"user": {"login": "claude-bot[bot]", "type": "Bot"}, "state": "COMMENTED", "commit_id": "headsha",
   "submitted_at": "2026-01-04T00:00:00Z", "body": "<!-- claude-review-skipped -->\n\nskipped"},
  {"user": {"login": "alice", "type": "User"}, "state": "APPROVED", "commit_id": "headsha",
   "submitted_at": "2026-01-05T00:00:00Z", "body": "lgtm from a human"}
]
EOF
printf '{"author": {"login": "prauthor"}, "title": "Fix #42", "body": "closes #43 and mentions #44", "closingIssuesReferences": [{"number": 41}]}\n' > "$OUT/pr.json"

# ── gh mock (PATH shim) ─────────────────────────────────────────────────────
# Serves the fixtures above. Issue 44 is a PULL REQUEST (.pull_request non-null),
# which the candidate loop must reject — PRs are a subclass of issues in the API
# and a PR body pulled in as a "spec" is the failure that check exists for.
MOCK_BIN="$WORK/bin"; mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  *"pulls/7/comments"*) cat "$FX/pulls-comments.json" ;;
  *"issues/7/comments"*) cat "$FX/issue-comments.json" ;;
  *"pulls/7/reviews"*)  cat "$FX/reviews.json" ;;
  *graphql*)            cat "$FX/graphql.json" ;;
  *"api repos/o/r/issues/44"*) echo '{"number": 44, "pull_request": {"url": "x"}}' ;;
  *"api repos/o/r/issues/"*)
    n=${args##*issues/}; echo "{\"number\": $n, \"pull_request\": null}" ;;
  "issue view "*)
    n=$3; echo "{\"number\": $n, \"title\": \"issue $n\", \"body\": \"b\", \"labels\": [], \"state\": \"OPEN\"}" ;;
  *) echo '{}' ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

run() { # run <mode> [PRIOR_HEAD_SHA]
  : > "$WORK/gh.log"
  STDOUT=$(PATH="$MOCK_BIN:$PATH" GH_LOG="$WORK/gh.log" FX="$WORK" \
    PR=7 REPO=o/r BOT_USER="claude-bot[bot]" OUT_DIR="$OUT" \
    PRIOR_HEAD_SHA="${2:-}" bash "$SCRIPT" "$1" 2>&1)
  RC=$?
}

# ── 1. required inputs ──────────────────────────────────────────────────────
RC=0
PATH="$MOCK_BIN:$PATH" GH_LOG="$WORK/gh.log" FX="$WORK" OUT_DIR="$OUT" \
  PR= REPO= bash "$SCRIPT" threads >/dev/null 2>&1 || RC=$?
assert_eq "missing PR/REPO exits 2" "2" "$RC"

RC=0
PATH="$MOCK_BIN:$PATH" GH_LOG="$WORK/gh.log" FX="$WORK" OUT_DIR="$OUT" \
  PR=7 REPO=o/r bash "$SCRIPT" bogus-mode >/dev/null 2>&1 || RC=$?
assert_eq "unknown mode exits 2" "2" "$RC"

# ── 2. threads mode, round 1 ────────────────────────────────────────────────
run threads
assert_eq "threads mode exits 0" "0" "$RC"

assert_eq "all-raw-comments keeps every comment" "8" "$(jq 'length' "$OUT/all-raw-comments.json")"
assert_eq "prior-bot-comments = our top-level only" "1" "$(jq 'length' "$OUT/prior-bot-comments.json")"
assert_eq "prior-bot-comments keeps node_id (the poster resolves by it)" "PRRC_1" \
  "$(jq -r '.[0].node_id' "$OUT/prior-bot-comments.json")"
assert_eq "other-bot-comments excludes our own bot" "cursor[bot]" \
  "$(jq -r '.[0].user' "$OUT/other-bot-comments.json")"
assert_eq "other-bot-comments has exactly one entry" "1" "$(jq 'length' "$OUT/other-bot-comments.json")"

assert_eq "user replies are classified into three channels" "human-thread other-bot-thread own-thread" \
  "$(jq -r '[.[].channel] | sort | join(" ")' "$OUT/user-replies-on-ours.json")"
assert_eq "user replies carry the PARENT's path, not their own" "src/a.ts" \
  "$(jq -r '.[] | select(.channel=="own-thread") | .path' "$OUT/user-replies-on-ours.json")"
assert_eq "our replies on other bots' threads are collected separately" "2" \
  "$(jq -r '.[0].parent_id' "$OUT/our-replies-on-others.json")"

assert_eq "human-inline-comments excludes the PR author" "alice" \
  "$(jq -r '[.[].user] | join(",")' "$OUT/human-inline-comments.json")"
assert_eq "general-comments drops bot noise" "general human" \
  "$(jq -r '[.[].body] | join(",")' "$OUT/general-comments.json")"

assert_eq "review-threads keeps only UNRESOLVED threads" "PRRT_open" \
  "$(jq -r '[.[].thread_id] | join(",")' "$OUT/review-threads.json")"
assert_eq "review-threads maps thread → first comment databaseId" "1" \
  "$(jq -r '.[0].comment_id' "$OUT/review-threads.json")"

assert_eq "round 1 writes no prior-review file" "no" \
  "$([ -f "$OUT/prior-review.json" ] && echo yes || echo no)"

# ── 3. threads mode, round 2 ────────────────────────────────────────────────
run threads headsha
assert_eq "round 2 exits 0" "0" "$RC"
assert_eq "prior review is pinned to PRIOR_HEAD_SHA" "headsha" \
  "$(jq -r '.commit_id' "$OUT/prior-review.json")"
assert_eq "prior review skips crash/skipped marker bodies" "CHANGES_REQUESTED" \
  "$(jq -r '.state' "$OUT/prior-review.json")"
assert_eq "prior functional verdict is echoed for the log" "Functional Validation — WARN" \
  "$(printf '%s\n' "$STDOUT" | grep -o 'Functional Validation — WARN')"
assert_eq "human review bodies exclude bots" "alice" \
  "$(jq -r '[.[].user] | join(",")' "$OUT/human-review-bodies.json")"
assert_eq "author-rebuttals merges all three channels" "general-comment human-review-body human-thread other-bot-thread own-thread" \
  "$(jq -r '[.[].channel] | sort | unique | join(" ")' "$OUT/author-rebuttals.json")"
assert_eq "author-rebuttals renames body → text (downstream field name)" "yes" \
  "$(jq -e 'all(.[]; has("text"))' "$OUT/author-rebuttals.json" >/dev/null && echo yes || echo no)"

# ── 4. issue-candidates mode ────────────────────────────────────────────────
run issue-candidates
assert_eq "issue-candidates exits 0" "0" "$RC"
assert_eq "issue.json is an array" "array" "$(jq -r 'type' "$OUT/issue.json")"
assert_eq "closing reference ranks first" "41" "$(jq -r '.[0].number' "$OUT/issue.json")"
assert_eq "plain #refs are candidates too" "41,42,43" \
  "$(jq -r '[.[].number] | sort | join(",")' "$OUT/issue.json")"
assert_eq "a PULL REQUEST masquerading as an issue ref is rejected" "0" \
  "$(jq '[.[] | select(.number == 44)] | length' "$OUT/issue.json")"

# ── 5. house rules + wiring ─────────────────────────────────────────────────
assert_eq "script does not use set -e (bugbot.md)" "yes" \
  "$(grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$SCRIPT" && echo no || echo yes)"
assert_eq "action.yml verifies the script is installed" "yes" \
  "$(grep -q 'fetch-pr-threads.sh' action.yml && echo yes || echo no)"
assert_eq "the context-builder skill invokes it instead of inlining the API calls" "yes" \
  "$(grep -q 'fetch-pr-threads.sh' skills/review-context-builder.md && echo yes || echo no)"
# The whole point of the extraction: no skill may reach for the raw API verb, or
# the session-wide deny rule in pr-review.yml would break our own agents.
assert_eq "no skill still calls the raw gh API subcommand" "0" \
  "$(grep -l 'gh api' skills/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "the review session denies that subcommand" "yes" \
  "$(grep -q 'Bash(gh api:\*)' .github/workflows/pr-review.yml && echo yes || echo no)"
# Reads the plugin's own prompt relies on must stay reachable.
for verb in 'Bash(gh pr view' 'Bash(gh pr diff' 'Bash(gh issue view' 'Bash(git log'; do
  assert_eq "deny list does not catch ${verb#Bash(}" "0" \
    "$(grep -c -- "$verb" .github/workflows/pr-review.yml)"
done

exit $((fail > 0))
