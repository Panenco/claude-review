#!/usr/bin/env bash
set -u
# No `set -e` (repo rule, bugbot.md): explicit exits on every path instead.
#
# `pipefail` is deliberately OFF. Two pipelines below depend on its absence:
#   * `grep -oE … | head -1` — `head` closes the pipe on the FIRST match, `grep`
#     dies of SIGPIPE, and under pipefail the whole pipeline would report failure
#     on the SUCCESS path, printing the "none" fallback for a review that DID
#     carry a functional verdict.
#   * `gh api --paginate … | jq -s 'add // []'` — a failed fetch must degrade to
#     `[]` (which `add // []` yields for empty input), not abort the block.

# fetch-pr-threads.sh — every READ this pipeline makes against the GitHub REST /
# GraphQL API that `gh pr view/diff/list` and `gh issue view` cannot express.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE BLOCK IN skills/review-context-builder.md.
# The review session runs the OFFICIAL `code-review` plugin prompt
# (`review-native`) over ATTACKER-CONTROLLED PR content, in a job that holds
# `contents: write` / `pull-requests: write` / `issues: write`. Session-wide
# `--disallowedTools` is the only lever that binds that plugin's ~10 subagents,
# and it cannot deny `gh api` selectively — so while ANY of our own agents needed
# `gh api`, `gh api -X POST …/issues/N/comments`, `gh api --method PATCH …` and
# every other raw write stayed reachable by the plugin. Collecting these five
# reads here (and the writes in `upload-screenshots.sh`) is what lets
# `pr-review.yml` deny `Bash(gh api:*)` outright.
#
# Behaviour is a VERBATIM extraction of the two blocks that used to live in
# `skills/review-context-builder.md` Turn 1. The jq shaping is a CONTRACT:
# downstream skills read these files by exact field name. Do not rename a key,
# do not "improve" a filter, do not change a truncation width.
#
# Usage:
#   fetch-pr-threads.sh [threads]           # inline/issue comments, threads, reviews
#   fetch-pr-threads.sh issue-candidates    # linked-issue resolution
#
# Inputs (env):
#   PR / PR_NUMBER        PR number (required)
#   REPO / GITHUB_REPOSITORY   owner/repo (required)
#   BOT_USER / REVIEW_BOT_USER our review identity (default github-actions[bot])
#   PRIOR_HEAD_SHA        non-empty selects the round-2 extras (prior review,
#                         human review bodies, author rebuttals)
#   OUT_DIR               where the JSON files land (default /tmp)

MODE="${1:-threads}"
PR="${PR:-${PR_NUMBER:-}}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
BOT_USER="${BOT_USER:-${REVIEW_BOT_USER:-github-actions[bot]}}"
OUT="${OUT_DIR:-/tmp}"

if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "fetch-pr-threads: PR (or PR_NUMBER) and REPO (or GITHUB_REPOSITORY) are required" >&2
  exit 2
fi
mkdir -p "$OUT"

fetch_threads() {
  # Inline comments → four views.
  gh api --paginate "repos/$REPO/pulls/$PR/comments" | jq -s 'add // []' > "$OUT/all-raw-comments.json"
  jq --arg bot "$BOT_USER" '[.[] | select(.user.login == $bot and .in_reply_to_id == null) | {id, node_id, path, line, body}]' \
    "$OUT/all-raw-comments.json" > "$OUT/prior-bot-comments.json"
  jq --arg bot "$BOT_USER" '[.[] | select(.user.type == "Bot" and .user.login != $bot and .in_reply_to_id == null) | {id, node_id, user: .user.login, path, line, body: (.body[:500])}]' \
    "$OUT/all-raw-comments.json" > "$OUT/other-bot-comments.json"
  jq --arg bot "$BOT_USER" '
    (reduce .[] as $c ({}; if $c.in_reply_to_id == null then .[$c.id|tostring] = $c else . end)) as $tops |
    [.[] | select(.user.type != "Bot" and .in_reply_to_id != null)
         | ($tops[.in_reply_to_id|tostring]) as $p
         | select($p != null)
         | {parent_id: .in_reply_to_id,
            channel: (if $p.user.login == $bot then "own-thread"
                      elif $p.user.type == "Bot" then "other-bot-thread"
                      else "human-thread" end),
            user: .user.login, path: $p.path, line: $p.line, body: (.body[:1000])}]' \
    "$OUT/all-raw-comments.json" > "$OUT/user-replies-on-ours.json"
  jq --arg bot "$BOT_USER" '[.[] | select(.user.login == $bot and .in_reply_to_id != null) | {parent_id: .in_reply_to_id, path, line, body: (.body[:1000])}]' \
    "$OUT/all-raw-comments.json" > "$OUT/our-replies-on-others.json"
  PR_AUTHOR=$(jq -r '.author.login // empty' "$OUT/pr.json" 2>/dev/null)
  jq --arg author "$PR_AUTHOR" '[.[] | select(.user.type != "Bot" and .in_reply_to_id == null and .path != null and .user.login != $author)
         | {id, node_id, user: .user.login, path, line, body: (.body[:500])}]' \
    "$OUT/all-raw-comments.json" > "$OUT/human-inline-comments.json"

  gh api --paginate "repos/$REPO/issues/$PR/comments" | jq -s 'add // []' > "$OUT/all-issue-comments.json"
  jq '[.[] | select(.user.type != "Bot") | {id, user: .user.login, created_at, body: (.body[:1000])}]' \
    "$OUT/all-issue-comments.json" > "$OUT/general-comments.json"

  # Review threads with GraphQL node ids (PRRT_…) — the poster resolves threads
  # by these ids. Map each thread's FIRST comment databaseId → thread id.
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved isOutdated comments(first:1){nodes{databaseId author{login} path line}}}}}}}' \
    -f o="${REPO%%/*}" -f r="${REPO##*/}" -F n="$PR" \
    | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)
           | {thread_id: .id, outdated: .isOutdated, comment_id: .comments.nodes[0].databaseId,
              author: .comments.nodes[0].author.login, path: .comments.nodes[0].path, line: .comments.nodes[0].line}]' \
    > "$OUT/review-threads.json"

  # Prior reviews (round 2): dismissal + prior functional result, from GitHub —
  # GitHub is the state store; there is no state artifact.
  # The filter MUST match scripts/prior-review-state.sh: same crash/superseded
  # exclusions AND the same skip markers, then pinned to $PRIOR_HEAD_SHA. That
  # script derived ROUND/PRIOR_HEAD_SHA/PRIOR_VERDICT from the JUDGED list; if this
  # resolves to a different review (e.g. an oversized block posted after the last
  # judged round) the round-2 ladder reconstructs the wrong prior findings — zero
  # of them — and silently forgives the prior round's blockers. Markers are matched
  # on the body's FIRST LINE, where they are stamped — contains() would also drop a
  # judged review that merely quotes one in a finding, with the same effect.
  # tests/prior_review_state_test.sh fails the build if a skip marker is missing here.
  if [ -n "${PRIOR_HEAD_SHA:-}" ]; then
    gh api --paginate "repos/$REPO/pulls/$PR/reviews" | jq -s 'add // []' > "$OUT/pr-reviews.json"
    jq --arg bot "$BOT_USER" --arg sha "$PRIOR_HEAD_SHA" '
      def first_line: ((. // "") | split("\n") | (.[0] // "") | sub("\\s+$"; ""));
      [.[] | select(.user.login == $bot) | select((.body // "") | length > 0)
           | select((.body | first_line) != "<!-- claude-review-crash -->")
           | select((.body | first_line) != "<!-- claude-review-superseded -->")
           | select((.body | first_line) != "<!-- claude-review-oversized -->")
           | select((.body | first_line) != "<!-- claude-review-skipped -->")]
      | sort_by(.submitted_at) as $judged
      | (($judged | map(select(.commit_id == $sha)) | last) // ($judged | last) // {})' \
      "$OUT/pr-reviews.json" > "$OUT/prior-review.json"
    echo "prior review: state=$(jq -r '.state // "none"' "$OUT/prior-review.json") commit=$(jq -r '.commit_id // ""' "$OUT/prior-review.json")"
    grep -oE 'Functional Validation — (PASS|WARN|FAIL|CRASH)' <(jq -r '.body // ""' "$OUT/prior-review.json") | head -1 || echo "prior functional: none"
    jq '[.[] | select(.user.type != "Bot") | select((.body // "") | length > 0) | select(.state=="CHANGES_REQUESTED" or .state=="COMMENTED" or .state=="APPROVED") | {user: .user.login, state, submitted_at, body: (.body[:1500])}] | sort_by(.submitted_at)' \
      "$OUT/pr-reviews.json" > "$OUT/human-review-bodies.json"

    jq -s '
      (.[0] | map({channel, user, path, line, text: .body}))
      + (.[1] | map({channel: "general-comment", user, path: null, line: null, text: .body}))
      + (.[2] | map({channel: "human-review-body", user, path: null, line: null, text: .body}))' \
      "$OUT/user-replies-on-ours.json" "$OUT/general-comments.json" "$OUT/human-review-bodies.json" > "$OUT/author-rebuttals.json"
    echo "author rebuttals: $(jq 'length' "$OUT/author-rebuttals.json")"
  fi
}

fetch_issue_candidates() {
  # Linked GitHub issue. Candidates: closingIssuesReferences rank first
  # (authoritative); plain refs in the PR title/body rank second — `Spec: #N`,
  # `Issue #N`, `Refs #N`, bare `#N` mentions, and full issue URLs, not only
  # closing keywords. Each is verified as a real issue, not a PR
  # (.pull_request is null only for real issues; PRs are a subclass of issues
  # in the API), then fetched via `gh issue view`.
  : > "$OUT/issue-candidates.jsonl"
  CANDS="$(jq -r '.closingIssuesReferences[]?.number' "$OUT/pr.json" 2>/dev/null)
$(jq -r '(.title // "") + " " + (.body // "")' "$OUT/pr.json" 2>/dev/null | grep -oE '(#|/issues/)[0-9]+' | grep -oE '[0-9]+')"
  for n in $(printf '%s\n' "$CANDS" | awk 'NF && !seen[$0]++' | head -6); do
    RESP=$(gh api "repos/$REPO/issues/$n" 2>/dev/null)
    printf '%s' "$RESP" | jq -e '.pull_request == null and (.number | type == "number")' >/dev/null 2>&1 || continue
    gh issue view "$n" --json number,title,body,labels,state >> "$OUT/issue-candidates.jsonl" 2>/dev/null || true
  done
  jq -s '.' "$OUT/issue-candidates.jsonl" > "$OUT/issue.json" 2>/dev/null || echo '[]' > "$OUT/issue.json"
}

case "$MODE" in
  threads)          fetch_threads ;;
  issue-candidates) fetch_issue_candidates ;;
  *)
    echo "fetch-pr-threads: unknown mode '$MODE' (expected 'threads' or 'issue-candidates')" >&2
    exit 2
    ;;
esac
exit 0
