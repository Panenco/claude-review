#!/usr/bin/env bash
set -uo pipefail

# post-review.sh — Post review results to the PR.
#
# Dismisses stale reviews, deduplicates against existing comments,
# validates comment lines against diff hunks, and posts the atomic review.
#
# Required env vars:
#   GH_TOKEN            — GitHub token for API calls
#   GITHUB_REPOSITORY   — owner/repo
#   PR_NUMBER           — pull request number
#   BOT_USER            — bot username for review identity (e.g. "github-actions[bot]")

REPO="$GITHUB_REPOSITORY"
PR="$PR_NUMBER"

echo "::group::Post review — dismiss stale"
# Dismiss prior APPROVED and CHANGES_REQUESTED reviews from this bot.
# Best-effort: a 401 or missing permission must not abort the poster.
(
  gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
    --jq ".[] | select(.user.login == \"$BOT_USER\" and (.state == \"CHANGES_REQUESTED\" or .state == \"APPROVED\")) | .id" \
    2>/dev/null | while read -r id; do
        echo "Dismissing review $id"
        gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
          -f message="Superseded by new Claude review on updated commit." || true
      done
) || echo "::warning::Could not dismiss stale reviews (non-fatal)"
echo "::endgroup::"

echo "::group::Post review — dedupe + reply to existing comments"
# Fetch ALL inline comments. We need `in_reply_to_id` to avoid
# re-replying on subsequent runs to the same parent comment.
# Only line-anchored comments participate in line-based dedup.
if ! gh api --paginate "repos/$REPO/pulls/$PR/comments" \
  --jq "[.[] | select(.line != null) | {id, path, line, user: .user.login, in_reply_to_id, body: .body[:80]}]" \
  2>/dev/null | jq -s 'add // []' > /tmp/all-comments.json; then
  echo "::warning::Could not fetch existing comments — skipping dedup"
  echo '[]' > /tmp/all-comments.json
fi
# Top-level (non-reply) comments from other authors — candidates for cross-bot dedup.
jq --arg bot "$BOT_USER" '[.[] | select(.user != $bot and .in_reply_to_id == null)]' /tmp/all-comments.json > /tmp/other-comments.json
# Our own comments, incl. replies — used for self-dedup and "already-replied" checks.
jq --arg bot "$BOT_USER" '[.[] | select(.user == $bot)]' /tmp/all-comments.json > /tmp/own-comments.json
# Parent IDs we've already replied to in a previous run — dedup cross-bot replies.
jq --arg bot "$BOT_USER" '[.[] | select(.user == $bot and .in_reply_to_id != null) | .in_reply_to_id]' /tmp/all-comments.json > /tmp/own-reply-parents.json
echo "Existing inline comments: $(jq 'length' /tmp/all-comments.json) total ($(jq 'length' /tmp/own-comments.json) own, $(jq 'length' /tmp/other-comments.json) other top-level, $(jq 'length' /tmp/own-reply-parents.json) parents we've already replied to)"

if [ -f /tmp/review-comments.json ]; then
  BEFORE=$(jq 'length' /tmp/review-comments.json)

  # 1. Self-dedup: drop our new comments that duplicate our own previous comments (same path + line +/-5).
  OWN_COUNT=$(jq 'length' /tmp/own-comments.json)
  if [ "$OWN_COUNT" -gt 0 ]; then
    jq --slurpfile own /tmp/own-comments.json '
      [.[] | . as $c |
        if ($own[0] | any(.path == $c.path and (((.line // -999) - ($c.line // -999)) | fabs) <= 5))
        then empty else . end
      ]' /tmp/review-comments.json > /tmp/review-comments-selfdedup.json
    SELF_DEDUP=$((BEFORE - $(jq 'length' /tmp/review-comments-selfdedup.json)))
    [ "$SELF_DEDUP" -gt 0 ] && echo "Self-dedup: dropped $SELF_DEDUP comments already posted in prior review"
    mv /tmp/review-comments-selfdedup.json /tmp/review-comments.json
  fi

  # 2. Cross-bot dedup: find new comments that overlap other bots' comments — reply instead of posting new.
  OTHER_COUNT=$(jq 'length' /tmp/other-comments.json)
  if [ "$OTHER_COUNT" -gt 0 ]; then
    AFTER_SELF=$(jq 'length' /tmp/review-comments.json)

    # Match against other bots' top-level comments, BUT skip parents
    # we've already replied to (prevents stacking replies every run).
    jq --slurpfile existing /tmp/other-comments.json \
       --slurpfile replied /tmp/own-reply-parents.json '
      ($replied[0] // []) as $skip |
      [.[] | . as $c |
        ($existing[0] | map(select(.path == $c.path and (((.line // -999) - ($c.line // -999)) | fabs) <= 5 and (.id as $id | $skip | index($id) | not))) | .[0]) as $match |
        if $match then {comment_id: $match.id, body: $c.body} else empty end
      ]' /tmp/review-comments.json > /tmp/reply-comments.json

    # Drop new comments only when they overlap an other-bot comment
    # that WE HAVE NOT already replied to.
    jq --slurpfile existing /tmp/other-comments.json \
       --slurpfile replied /tmp/own-reply-parents.json '
      ($replied[0] // []) as $skip |
      [.[] | . as $c |
        if ($existing[0] | any(.path == $c.path and (((.line // -999) - ($c.line // -999)) | fabs) <= 5 and (.id as $id | $skip | index($id) | not)))
        then empty else . end
      ]' /tmp/review-comments.json > /tmp/review-comments-deduped.json

    AFTER=$(jq 'length' /tmp/review-comments-deduped.json)
    REPLIES=$(jq 'length' /tmp/reply-comments.json)
    echo "Cross-bot dedup: $AFTER_SELF -> $AFTER new, $REPLIES will reply to existing"
    mv /tmp/review-comments-deduped.json /tmp/review-comments.json

    # Post replies to other bots' comments we agree with.
    if [ "$REPLIES" -gt 0 ]; then
      jq -c '.[]' /tmp/reply-comments.json | while read -r reply; do
        CID=$(echo "$reply" | jq -r '.comment_id')
        TITLE=$(echo "$reply" | jq -r '.body' | head -n 1 | head -c 200)
        # Extract screenshot URL from body if present
        SHOT_URL=$(echo "$reply" | jq -r '.body' | grep -oE '!\[screenshot\]\([^)]+\)' | head -1 || true)
        REPLY_BODY="✅ Confirmed by Claude review — same finding: $TITLE"
        [ -n "$SHOT_URL" ] && REPLY_BODY="$REPLY_BODY"$'\n\n'"$SHOT_URL"
        gh api --method POST "repos/$REPO/pulls/$PR/comments/$CID/replies" \
          -f body="$REPLY_BODY" 2>/dev/null || true
      done
      echo "Posted $REPLIES reply confirmations"
    fi
  fi

  echo "Final inline comments: $(jq 'length' /tmp/review-comments.json) (from $BEFORE)"
fi
echo "::endgroup::"

echo "::group::Post review — validate comment lines against diff"
# Filter out comments targeting lines outside PR diff hunks.
# GitHub returns 422 if any comment has an unresolvable line.
gh pr diff "$PR" > /tmp/pr.diff 2>/dev/null || true
if [ -f /tmp/pr.diff ] && [ -f /tmp/review-comments.json ]; then
  # Build a map of valid line ranges per file from diff hunk headers
  awk '
    /^--- a\// { next }
    /^\+\+\+ b\// { file=substr($0,7) }
    /^@@ / {
      # Parse "+start,count" from hunk header
      match($0, /\+([0-9]+)(,([0-9]+))?/, m)
      start = m[1]+0
      count = m[3]+0
      if (count == 0) count = 1
      for (i = start; i < start + count; i++)
        print file ":" i
    }
  ' /tmp/pr.diff | sort -u > /tmp/valid-lines.txt

  BEFORE=$(jq 'length' /tmp/review-comments.json)
  jq --rawfile valid /tmp/valid-lines.txt '
    ($valid | split("\n") | map(select(length > 0))) as $lines |
    [.[] | select((.path + ":" + (.line | tostring)) as $key | $lines | any(. == $key))]
  ' /tmp/review-comments.json > /tmp/review-comments-validated.json
  AFTER=$(jq 'length' /tmp/review-comments-validated.json)
  if [ "$AFTER" -lt "$BEFORE" ]; then
    echo "Filtered $((BEFORE - AFTER)) comments with lines outside diff hunks ($BEFORE -> $AFTER)"
  fi
  mv /tmp/review-comments-validated.json /tmp/review-comments.json
fi
echo "::endgroup::"

echo "::group::Post review — submit"
# Validate pre-built files exist
if [ ! -f /tmp/review-body.md ]; then
  echo "::error::/tmp/review-body.md not found — analyzer didn't build it"
  jq '.posting_error = "review-body.md missing"' review-result.json > /tmp/r.json && mv /tmp/r.json review-result.json
  exit 1
fi
if [ ! -f /tmp/review-comments.json ]; then
  echo "No inline comments file — posting body-only review"
  echo '[]' > /tmp/review-comments.json
fi
jq -e 'type == "array"' /tmp/review-comments.json > /dev/null || echo '[]' > /tmp/review-comments.json

# Append a phase-timing footer if any timing was captured.
# Format: *Pipeline: context Xs, dev-env Ys, analyze Zs, dedup Ws, total Ts*
if [ -s /tmp/phase-summary.txt ]; then
  TOTAL=0
  PARTS=""
  while IFS='=' read -r name dur; do
    [ -z "$name" ] && continue
    secs="${dur%s}"
    case "$secs" in *[!0-9]*|"") continue ;; esac
    TOTAL=$(( TOTAL + secs ))
    [ -n "$PARTS" ] && PARTS="$PARTS, "
    PARTS="$PARTS$name ${secs}s"
  done < /tmp/phase-summary.txt
  if [ -n "$PARTS" ]; then
    printf '\n\n---\n*Pipeline: %s, total %ss*\n' "$PARTS" "$TOTAL" >> /tmp/review-body.md
  fi
fi

# Build and POST atomic review
VERDICT=$(jq -r '.verdict' review-result.json)

# GitHub policy blocks `github-actions[bot]` from posting APPROVE reviews
# (422 Unprocessable Entity: "GitHub Actions is not permitted to approve
# pull requests"). When the App-token path falls back to github-actions
# (e.g. CLAUDE_REVIEW_APP_CLIENT_ID secret missing or renamed), an APPROVE
# verdict goes through a 422 + retry + final ::warning::, leaving the PR
# without any visible review at all. Detect this combo before the POST,
# downgrade to COMMENT, and prepend a banner so the user knows why the
# verdict was attenuated and how to restore APPROVE capability.
if [ "$VERDICT" = "APPROVE" ] && [ "${BOT_USER:-}" = "github-actions[bot]" ]; then
  echo "::warning::Verdict APPROVE downgraded to COMMENT — github-actions[bot] cannot post APPROVE reviews. Configure CLAUDE_REVIEW_APP_CLIENT_ID + CLAUDE_REVIEW_APP_PRIVATE_KEY + CLAUDE_REVIEW_APP_SLUG repo secrets and install the App on this repo to restore APPROVE capability (see prompts/setup-review.md)."
  VERDICT=COMMENT
  BANNER="> :information_source: **Verdict downgraded APPROVE → COMMENT** — \`github-actions[bot]\` cannot post APPROVE reviews per GitHub policy. The pipeline determined APPROVE on merit; configure a custom GitHub App (\`CLAUDE_REVIEW_APP_CLIENT_ID\` / \`_PRIVATE_KEY\` / \`_SLUG\` repo secrets + App installed on this repo) to restore APPROVE capability. See [setup guide](https://github.com/Panenco/claude-review/blob/main/prompts/setup-review.md#step-6-verify-secrets-and-app-install)."
  printf '%s\n\n%s' "$BANNER" "$(cat /tmp/review-body.md)" > /tmp/review-body.md.new && mv /tmp/review-body.md.new /tmp/review-body.md
  # Also write the downgrade flag into review-result.json so verdict-gate
  # and downstream artifact consumers can see it.
  jq '.posting_downgrade = "APPROVE→COMMENT (github-actions identity)"' review-result.json > /tmp/r.json && mv /tmp/r.json review-result.json
fi

jq -n \
  --arg event "$VERDICT" \
  --rawfile body /tmp/review-body.md \
  --slurpfile comments /tmp/review-comments.json \
  '{event: $event, body: $body, comments: $comments[0]}' \
  > /tmp/review-payload.json

echo "Posting $VERDICT review with $(jq '.comments | length' /tmp/review-payload.json) inline comments"
if ! gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input /tmp/review-payload.json; then
  sleep 2
  if ! gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input /tmp/review-payload.json; then
    jq '.posting_error = "POST failed after 1 retry"' review-result.json > /tmp/r.json && mv /tmp/r.json review-result.json
  fi
fi
echo "::endgroup::"

# ── Round-2: resolve threads for findings the resolution checker classified
#    as RESOLVED. Closes the loop so the PR UI shows fixed issues as resolved
#    instead of leaving every prior thread open forever.
#
# Inputs: /tmp/resolution-status.json (round-2 only, classifier output) +
#         /tmp/prior-state/review-state.json (round-1 findings with path/line).
# For each RESOLVED entry, find our own bot's review thread at that path+line
# and call GraphQL `resolveReviewThread` after a short reply for the audit
# trail. Best-effort: any GraphQL failure is logged but does not abort the
# poster — the review itself is already committed at this point.
if [ -f /tmp/resolution-status.json ] && [ -f /tmp/prior-state/review-state.json ]; then
  echo "::group::Post review — resolve fixed threads (round-2)"
  RESOLVED_IDS=$(jq -r '[.[] | select(.status == "RESOLVED") | .id] | .[]' /tmp/resolution-status.json 2>/dev/null || true)
  if [ -z "$RESOLVED_IDS" ]; then
    echo "No RESOLVED prior findings — nothing to resolve."
  else
    OWNER="${REPO%%/*}"
    NAME="${REPO##*/}"
    HEAD_SHA=$(git rev-parse --short=12 HEAD 2>/dev/null || echo "current")
    # Page through review threads. 100/page is typically enough; if a PR
    # accumulates more we'd need cursor-based pagination, but at that point
    # the review-thread sprawl is already a separate problem.
    THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!, $repo:String!, $pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:100) {
              nodes {
                id
                isResolved
                path
                line
                originalLine
                comments(first:1) { nodes { author { login } body } }
              }
            }
          }
        }
      }' -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>/dev/null || echo "[]")
    if [ "$(echo "$THREADS_JSON" | jq 'length')" = "0" ]; then
      echo "::warning::Could not fetch review threads via GraphQL — skipping resolution."
    else
      RESOLVED_COUNT=0
      SKIPPED_COUNT=0
      while IFS= read -r rid; do
        [ -z "$rid" ] && continue
        # Look up the prior finding's path + line_start by id.
        FINDING=$(jq -c --arg id "$rid" '.findings[]? | select(.id == $id)' /tmp/prior-state/review-state.json 2>/dev/null || echo "")
        if [ -z "$FINDING" ]; then
          echo "  $rid: prior finding not found in review-state.json, skipping"
          continue
        fi
        FPATH=$(echo "$FINDING" | jq -r '.path')
        FLINE_END=$(echo "$FINDING" | jq -r '.line_end // .line_start')
        # Match thread by path + line (line OR originalLine — GitHub reports
        # the comment's line on the latest commit OR the original commit
        # depending on whether the line still exists). Author must be us.
        # `|| true` on the head pipe: under pipefail, multiple matches close
        # the pipe early and SIGPIPE jq, returning a non-zero pipeline exit.
        # We only want the first match — closing the producer is fine.
        THREAD=$(echo "$THREADS_JSON" | jq -c --arg path "$FPATH" --argjson line "$FLINE_END" --arg bot "$BOT_USER" '
          .[] | select(
            .path == $path
            and ((.line == $line) or (.originalLine == $line))
            and (.comments.nodes[0].author.login == $bot)
            and (.isResolved == false)
          )' | head -n1 || true)
        if [ -z "$THREAD" ]; then
          SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
          continue
        fi
        TID=$(echo "$THREAD" | jq -r '.id')
        # Add a reply for the audit trail (visible in the thread), then
        # resolve. Two GraphQL calls; failure of either is non-fatal.
        gh api graphql -f query='
          mutation($threadId:ID!, $body:String!) {
            addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}) {
              comment { id }
            }
          }' -f threadId="$TID" -f body="✅ Resolved as of \`$HEAD_SHA\` (Claude review round-2 classifier confirmed the flagged issue is no longer present in the diff)." >/dev/null 2>&1 \
          || echo "  $rid: reply post failed (continuing to resolve)"
        if gh api graphql -f query='
          mutation($threadId:ID!) {
            resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
          }' -f threadId="$TID" >/dev/null 2>&1; then
          RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
          echo "  $rid: resolved thread on $FPATH:$FLINE_END"
        else
          echo "::warning::  $rid: resolveReviewThread mutation failed for $FPATH:$FLINE_END"
        fi
      done <<< "$RESOLVED_IDS"
      echo "Resolved $RESOLVED_COUNT thread(s); skipped $SKIPPED_COUNT (no matching open thread)."
    fi
  fi
  echo "::endgroup::"
fi

# ── Round-2: resolve OTHER-bot threads (cursor, aikido, etc.) that the
#    bot-comment resolver classified as RESOLVED. Mirror of own-thread
#    resolution above, but matches by comment_id (not path+author) because
#    the resolver outputs the GitHub REST id directly. We re-fetch threads
#    via GraphQL and find the one whose first comment's databaseId matches.
if [ -f /tmp/bot-resolution-status.json ]; then
  echo "::group::Post review — resolve fixed other-bot threads (round-2)"
  RESOLVED_BOT=$(jq -c '[.[] | select(.status == "RESOLVED")]' /tmp/bot-resolution-status.json 2>/dev/null || echo "[]")
  RESOLVED_BOT_N=$(echo "$RESOLVED_BOT" | jq 'length' 2>/dev/null || echo 0)
  if [ "$RESOLVED_BOT_N" = "0" ]; then
    echo "No RESOLVED other-bot comments — nothing to acknowledge."
  else
    OWNER="${REPO%%/*}"
    NAME="${REPO##*/}"
    HEAD_SHA=$(git rev-parse --short=12 HEAD 2>/dev/null || echo "current")
    # databaseId on a comment is the REST `id`; we use it to map
    # resolver output (which carries REST ids) to GraphQL thread nodes.
    THREADS_JSON=$(gh api graphql -f query='
      query($owner:String!, $repo:String!, $pr:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$pr) {
            reviewThreads(first:100) {
              nodes {
                id
                isResolved
                comments(first:1) { nodes { databaseId author { login } } }
              }
            }
          }
        }
      }' -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>/dev/null || echo "[]")
    if [ "$(echo "$THREADS_JSON" | jq 'length')" = "0" ]; then
      echo "::warning::Could not fetch review threads via GraphQL — skipping other-bot resolution."
    else
      RESOLVED_COUNT=0
      SKIPPED_COUNT=0
      # Process substitution rather than `| while`: the latter runs the loop
      # in a subshell, so RESOLVED_COUNT / SKIPPED_COUNT increments are lost
      # by the time the summary line below runs (always reports 0).
      while IFS= read -r entry; do
        CID=$(echo "$entry" | jq -r '.comment_id')
        BOT=$(echo "$entry" | jq -r '.bot_user')
        FPATH=$(echo "$entry" | jq -r '.path')
        FLINE=$(echo "$entry" | jq -r '.line')
        EVIDENCE=$(echo "$entry" | jq -r '.evidence // ""' | head -c 400)
        # Match thread whose first comment's databaseId == CID AND not already resolved.
        THREAD=$(echo "$THREADS_JSON" | jq -c --argjson cid "$CID" '
          .[] | select(.comments.nodes[0].databaseId == $cid and .isResolved == false)' | head -n1 || true)
        if [ -z "$THREAD" ]; then
          SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
          continue
        fi
        TID=$(echo "$THREAD" | jq -r '.id')
        REPLY_BODY="✅ Resolved as of \`$HEAD_SHA\` per Claude review round-2 classifier"
        [ -n "$EVIDENCE" ] && REPLY_BODY="$REPLY_BODY"$'\n\n'"$EVIDENCE"
        gh api graphql -f query='
          mutation($threadId:ID!, $body:String!) {
            addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}) {
              comment { id }
            }
          }' -f threadId="$TID" -f body="$REPLY_BODY" >/dev/null 2>&1 \
          || echo "  $BOT $CID: reply post failed (continuing to resolve)"
        if gh api graphql -f query='
          mutation($threadId:ID!) {
            resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
          }' -f threadId="$TID" >/dev/null 2>&1; then
          RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
          echo "  $BOT $CID: resolved thread on $FPATH:$FLINE"
        else
          echo "::warning::  $BOT $CID: resolveReviewThread mutation failed for $FPATH:$FLINE"
        fi
      done < <(echo "$RESOLVED_BOT" | jq -c '.[]')
      echo "Resolved $RESOLVED_COUNT other-bot thread(s); skipped $SKIPPED_COUNT (already resolved or thread not found)."
    fi
  fi
  echo "::endgroup::"
fi
