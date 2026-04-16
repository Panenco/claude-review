#!/usr/bin/env bash
set -euo pipefail

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

# Build and POST atomic review
VERDICT=$(jq -r '.verdict' review-result.json)
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
