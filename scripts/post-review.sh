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
  # Initialise REPLIES so the post-step summary line below doesn't trip
  # `set -u` when there's no other-bot overlap (OTHER_COUNT=0 path skips
  # the assignment inside the cross-bot dedup block).
  REPLIES=0

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
    echo "Cross-bot dedup: $AFTER_SELF -> $AFTER new, $REPLIES will reply to existing (replies posted after submit)"
    mv /tmp/review-comments-deduped.json /tmp/review-comments.json
    # Reply POSTing is intentionally deferred until AFTER the substantive
    # review is submitted (see "Post review — submit" below). The REST
    # `/comments/<id>/replies` endpoint silently auto-creates an empty
    # COMMENTED review wrapper when the bot has no review on this SHA;
    # if we posted replies first, the substantive POST's idempotency
    # guard would mistake that empty wrapper for a prior substantive
    # review and skip the real POST. Observed on Panenco/seaters#470
    # (run 25456226383) — verdict was REQUEST_CHANGES with 4 findings,
    # but only the empty reply wrapper landed on the PR.
  fi

  echo "Pre-submit inline comments: $(jq 'length' /tmp/review-comments.json) (from $BEFORE; $REPLIES queued as replies)"
fi
echo "::endgroup::"

echo "::group::Post review — validate comment lines against diff"
# Filter out comments targeting lines outside PR diff hunks.
# GitHub returns 422 if any comment has an unresolvable line.
# Comments that fall outside hunks get appended to the review body's
# "Findings outside diff hunks" section instead of being silently dropped
# — observed on Panenco/qiv#292 as "comments went to general section."
gh pr diff "$PR" > /tmp/pr.diff 2>/dev/null || true
if [ -f /tmp/pr.diff ] && [ -f /tmp/review-comments.json ]; then
  # Build a map of valid (path, line, side) tuples from diff hunk headers.
  # Hunk headers carry both `-old_start,old_count` (LEFT, deleted lines)
  # and `+new_start,new_count` (RIGHT, added/modified lines). We track
  # both so reviewers can comment on a deleted line by setting side="LEFT"
  # in the finding — without the LEFT axis the validation step silently
  # dropped every deleted-line comment.
  # Portable awk (works with BSD awk + gawk). Hunk header shape:
  #   @@ -lstart[,lcount] +rstart[,rcount] @@ ...
  # Field 2 is "-lstart,lcount"; field 3 is "+rstart,rcount". When the
  # `,count` part is omitted GitHub means "1 line"; when count is 0 the
  # range is empty (e.g. pure-addition hunks have `-0,0`).
  awk '
    /^--- a\// { next }
    /^\+\+\+ b\// { file=substr($0,7); next }
    /^@@ / {
      lspec = $2; rspec = $3
      sub(/^-/, "", lspec); sub(/^\+/, "", rspec)
      n = split(lspec, lp, ",")
      lstart = lp[1] + 0
      lcount = (n >= 2 ? lp[2] + 0 : 1)
      n = split(rspec, rp, ",")
      rstart = rp[1] + 0
      rcount = (n >= 2 ? rp[2] + 0 : 1)
      for (i = lstart; i < lstart + lcount; i++) print file ":" i ":LEFT"
      for (i = rstart; i < rstart + rcount; i++) print file ":" i ":RIGHT"
    }
  ' /tmp/pr.diff | sort -u > /tmp/valid-lines.txt

  BEFORE=$(jq 'length' /tmp/review-comments.json)
  # Split into kept (matching a valid hunk line) and dropped (outside).
  # Bind each comment to $c first — inside `any(...)` the `.` rebinds to
  # the array element, so `.path` would dereference a string.
  jq --rawfile valid /tmp/valid-lines.txt '
    ($valid | split("\n") | map(select(length > 0))) as $lines |
    [.[] | . as $c | ($c.path + ":" + ($c.line | tostring) + ":" + ($c.side // "RIGHT")) as $key |
      $c + {_in_diff: ($lines | any(. == $key))}
    ] as $tagged |
    {
      kept:    [$tagged[] | select(._in_diff) | del(._in_diff)],
      dropped: [$tagged[] | select(._in_diff | not) | del(._in_diff)]
    }
  ' /tmp/review-comments.json > /tmp/review-comments-split.json
  jq '.kept' /tmp/review-comments-split.json > /tmp/review-comments.json
  jq '.dropped' /tmp/review-comments-split.json > /tmp/dropped-comments.json
  AFTER=$(jq 'length' /tmp/review-comments.json)
  DROPPED=$(jq 'length' /tmp/dropped-comments.json)
  if [ "$DROPPED" -gt 0 ]; then
    echo "Moved $DROPPED comment(s) outside diff hunks to the review body's \"Findings outside diff hunks\" section ($BEFORE -> $AFTER inline)"
    {
      printf '\n### Findings outside diff hunks (%s)\n\n' "$DROPPED"
      printf '_These findings reference lines outside the PR'"'"'s diff hunks (often deleted lines, context just outside the change window, or near-but-imprecise line targets). Inline comments cannot anchor here — surfacing them in the body so they aren'"'"'t lost._\n\n'
      jq -r '.[] |
        "- **`" + .path + ":" + (.line | tostring) + "` (" + (.side // "RIGHT") + ")** — " +
        # First line of body is the bold "[TYPE] Title" header, which is
        # the most useful summary; trim the rest to keep the body scannable.
        (.body | split("\n") | .[0])' /tmp/dropped-comments.json
      printf '\n'
    } >> /tmp/review-body.md
  fi
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
jq -n \
  --arg event "$VERDICT" \
  --rawfile body /tmp/review-body.md \
  --slurpfile comments /tmp/review-comments.json \
  '{event: $event, body: $body, comments: $comments[0]}' \
  > /tmp/review-payload.json

# Idempotency guard: if the bot already posted a substantive review on
# this commit, don't post a second one. Two scenarios this protects:
#   1. A run gets manually re-triggered on the same SHA.
#   2. The previous retry-on-failure loop double-posted when the original
#      POST actually succeeded but its response was misinterpreted as
#      failure. We drop the retry below; this guard belt-and-braces against
#      a similar future regression.
# Crash-banner reviews carry the <!-- claude-review-crash --> marker and
# don't count as substantive — those are the ones we supersede later.
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
EXISTING_REVIEW_ID=""
EXISTING_REVIEW_NODE_ID=""
if [ -n "$HEAD_SHA" ]; then
  # `gh api --paginate --jq` runs the filter on EACH page independently, so
  # `.[0] // empty` would emit one match per page — a multi-object output
  # that breaks downstream `jq -r '.id'` parsing. Slurp all pages into a
  # single array first, then apply the filter once. (cursor#bugbot, PR #28.)
  #
  # The filter excludes:
  #   - crash-banner reviews (`<!-- claude-review-crash -->`) — those are
  #     placeholder banners that should be superseded, not treated as
  #     "already reviewed".
  #   - already-superseded crash banners (`<!-- claude-review-superseded -->`).
  #   - **empty-body reviews** — when GitHub auto-creates a review wrapper
  #     to host a `/comments/<id>/replies` POST (we use this to confirm
  #     other-bot findings via cross-bot dedup), the wrapper has body=""
  #     and state=COMMENTED. Without the empty-body filter, a cross-bot
  #     reply posted in the same run would create a wrapper that this
  #     guard then mistook for "we already reviewed", silently skipping
  #     the substantive POST. (Observed on Panenco/seaters#470.) The
  #     reply-post is now deferred until AFTER submit, but the guard
  #     keeps this filter as defense-in-depth.
  EXISTING_REVIEW=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT_USER" --arg sha "$HEAD_SHA" '
        (add // [])
        | [.[] | select(
            .user.login == $bot
            and .commit_id == $sha
            and ((.body // "") | length > 0)
            and (
              (
                (.body | contains("<!-- claude-review-crash -->"))
                or (.body | contains("<!-- claude-review-superseded -->"))
              ) | not
            )
          )]
        | .[0] // empty
      ' 2>/dev/null || echo "")
  if [ -n "$EXISTING_REVIEW" ]; then
    EXISTING_REVIEW_ID=$(echo "$EXISTING_REVIEW" | jq -r '.id // empty')
    EXISTING_REVIEW_NODE_ID=$(echo "$EXISTING_REVIEW" | jq -r '.node_id // empty')
    echo "::notice::Bot already posted a substantive review on $HEAD_SHA (review_id=$EXISTING_REVIEW_ID); skipping duplicate POST."
  fi
fi

REVIEW_ID=""
REVIEW_NODE_ID=""
if [ -n "$EXISTING_REVIEW_ID" ]; then
  REVIEW_ID="$EXISTING_REVIEW_ID"
  REVIEW_NODE_ID="$EXISTING_REVIEW_NODE_ID"
else
  echo "Posting $VERDICT review with $(jq '.comments | length' /tmp/review-payload.json) inline comments"
  # Single POST. The previous retry-on-failure loop traded a real-failure
  # signal for a duplicate-post risk; the gate now reports posting_error
  # cleanly and humans can re-run the workflow.
  if POST_RESPONSE=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input /tmp/review-payload.json 2>&1); then
    REVIEW_ID=$(echo "$POST_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
    REVIEW_NODE_ID=$(echo "$POST_RESPONSE" | jq -r '.node_id // empty' 2>/dev/null || echo "")
    if [ -z "$REVIEW_ID" ]; then
      echo "::warning::Review POST succeeded but response did not include a review id — round-2 dismissal lookup will degrade to path-line matching."
    fi
  else
    echo "::error::Review POST failed: $POST_RESPONSE"
    jq '.posting_error = "POST failed (see workflow log for response body)"' review-result.json > /tmp/r.json && mv /tmp/r.json review-result.json
  fi
fi

# Persist the review id back into review-state.json so the next round can
# fetch the prior review's GitHub state (e.g. detect author dismissal).
# Best-effort: missing review id just means round-2 falls back to current
# behaviour.
#
# IMPORTANT: do NOT use `$rnid | select(length > 0)` for the node-id field.
# When $rnid is empty, `select` returns an empty stream; placed inside an
# object literal that makes the entire `. + {...}` expression produce zero
# outputs, and the redirect below writes an empty file — destroying the
# whole round-state artifact (cursor#bugbot caught this on PR #28). Use an
# `if/then/else` so empty input maps to a literal null instead.
if [ -n "$REVIEW_ID" ] && [ -f /tmp/review-state.json ]; then
  jq --arg rid "$REVIEW_ID" --arg rnid "$REVIEW_NODE_ID" \
    '. + {
       review_id: ($rid | tonumber? // null),
       review_node_id: (if ($rnid | length) > 0 then $rnid else null end)
     }' \
    /tmp/review-state.json > /tmp/r.json && mv /tmp/r.json /tmp/review-state.json
fi
echo "::endgroup::"

# Cross-bot reply confirmations — deferred from the dedup step above.
# `/comments/<id>/replies` auto-creates a COMMENTED review wrapper when
# our bot doesn't already have a review on this SHA; we post these AFTER
# the substantive POST so the wrapper attaches to (or stacks alongside)
# our real review instead of pre-empting it. Fully best-effort — a
# wrapper-creation error doesn't roll back anything.
if [ -f /tmp/reply-comments.json ]; then
  REPLY_COUNT=$(jq 'length' /tmp/reply-comments.json 2>/dev/null || echo 0)
  if [ "$REPLY_COUNT" -gt 0 ]; then
    echo "::group::Post review — confirm other-bot findings (cross-bot replies)"
    POSTED_REPLIES=0
    while IFS= read -r reply; do
      CID=$(echo "$reply" | jq -r '.comment_id')
      TITLE=$(echo "$reply" | jq -r '.body' | head -n 1 | head -c 200)
      SHOT_URL=$(echo "$reply" | jq -r '.body' | grep -oE '!\[screenshot\]\([^)]+\)' | head -1 || true)
      REPLY_BODY="✅ Confirmed by Claude review — same finding: $TITLE"
      [ -n "$SHOT_URL" ] && REPLY_BODY="$REPLY_BODY"$'\n\n'"$SHOT_URL"
      if REPLY_OUT=$(gh api --method POST "repos/$REPO/pulls/$PR/comments/$CID/replies" \
        -f body="$REPLY_BODY" 2>&1); then
        POSTED_REPLIES=$((POSTED_REPLIES + 1))
      else
        echo "::warning::Cross-bot reply on comment $CID failed — $(echo "$REPLY_OUT" | head -c 400)"
      fi
    done < <(jq -c '.[]' /tmp/reply-comments.json)
    echo "Posted $POSTED_REPLIES/$REPLY_COUNT cross-bot reply confirmations."
    echo "::endgroup::"
  fi
fi

# After a successful POST: supersede any prior crash-banner reviews on this
# PR so the misleading red banner doesn't linger after the next push.
# Crash banners can't be deleted (no review-delete API) — we PATCH the body
# to a benign superseded form. The superseded marker is *distinct* from the
# crash marker (no shared substring), so the filter below cannot
# accidentally re-match a review we already superseded on a previous push.
if [ -n "$REVIEW_ID" ]; then
  echo "::group::Post review — supersede prior crash banners"
  # `gh api --paginate --jq` runs the filter on EACH page independently,
  # so a crash banner on a later page would emit correctly only because
  # the filter happens to be a flat select-and-emit. Slurp pages first
  # so the filter sees the full review list — matches the pattern at
  # `Post review — submit` above and prevents future breakage if the
  # filter ever needs cross-page aggregation.
  CRASH_REVIEWS=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT_USER" --argjson rid "$REVIEW_ID" '
        (add // [])
        | [.[] | select(
            .user.login == $bot
            and (.body | contains("<!-- claude-review-crash -->"))
            and (.id != $rid)
          ) | .id]
        | .[]' 2>/dev/null || true)
  if [ -n "$CRASH_REVIEWS" ]; then
    SUPERSEDE_BODY=$'<!-- claude-review-superseded -->\n\n_Superseded by a successful review run on `'"$HEAD_SHA"$'`._'
    while IFS= read -r CRID; do
      [ -z "$CRID" ] && continue
      if gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$CRID" -f body="$SUPERSEDE_BODY" >/dev/null 2>&1; then
        echo "Superseded prior crash review #$CRID"
      else
        echo "::warning::Could not supersede crash review #$CRID (PATCH failed)"
      fi
    done <<< "$CRASH_REVIEWS"
  else
    echo "No prior crash banners to supersede."
  fi
  echo "::endgroup::"
fi

# ── Round-2: resolve threads for findings the resolution checker classified
#    as RESOLVED. Closes the loop so the PR UI shows fixed issues as resolved
#    instead of leaving every prior thread open forever.
#
# Inputs: /tmp/thread-resolution.json (round-2 only, classifier output —
#         filtered to source=prior_finding for this block) +
#         /tmp/prior-state/review-state.json (round-1 findings with path/line).
# For each RESOLVED prior-finding entry, find our own bot's review thread at
# that path+line and call GraphQL `resolveReviewThread` after a short reply
# for the audit trail. The other sources (own_bot/other_bot/human) are
# handled by the comment_id-keyed block further down. Best-effort: any
# GraphQL failure is logged but does not abort the poster — the review
# itself is already committed at this point.
if [ -f /tmp/thread-resolution.json ] && [ -f /tmp/prior-state/review-state.json ]; then
  echo "::group::Post review — resolve fixed prior-finding threads (round-2)"
  RESOLVED_IDS=$(jq -r '[.[] | select(.source == "prior_finding" and .status == "RESOLVED") | .id] | .[]' /tmp/thread-resolution.json 2>/dev/null || true)
  if [ -z "$RESOLVED_IDS" ]; then
    echo "No RESOLVED prior findings — nothing to resolve."
  else
    OWNER="${REPO%%/*}"
    NAME="${REPO##*/}"
    HEAD_SHA=$(git rev-parse --short=12 HEAD 2>/dev/null || echo "current")
    # Page through review threads. 100/page is typically enough; if a PR
    # accumulates more we'd need cursor-based pagination, but at that point
    # the review-thread sprawl is already a separate problem.
    # `databaseId` is selected so we can post audit replies via the REST
    # `/replies` endpoint instead of GraphQL `addPullRequestReviewThreadReply`,
    # which auto-creates a new (empty) review container per call.
    THREADS_RAW=$(gh api graphql -f query='
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
                comments(first:1) { nodes { databaseId author { login } } }
              }
            }
          }
        }
      }' -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>&1 || true)
    if ! echo "$THREADS_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "::warning::Could not fetch review threads via GraphQL — skipping resolution. API response: $(echo "$THREADS_RAW" | head -c 400)"
      THREADS_JSON='[]'
    else
      THREADS_JSON="$THREADS_RAW"
    fi
    if [ "$(echo "$THREADS_JSON" | jq 'length')" = "0" ]; then
      :  # Already warned above; nothing to resolve.
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
        PARENT_CID=$(echo "$THREAD" | jq -r '.comments.nodes[0].databaseId // empty')
        # Audit reply via REST `/replies`. The previous implementation used
        # GraphQL `addPullRequestReviewThreadReply`, which silently creates
        # a new (empty) review container when the bot has no pending review
        # — observed on Panenco/qiv#292 as a 0-byte review posted seconds
        # after the substantive one.
        if [ -n "$PARENT_CID" ]; then
          REPLY_OUT=$(gh api --method POST "repos/$REPO/pulls/$PR/comments/$PARENT_CID/replies" \
            -f body="✅ Resolved as of \`$HEAD_SHA\` (Claude review round-2 classifier confirmed the flagged issue is no longer present in the diff)." 2>&1) \
            || echo "::warning::  $rid: reply post failed for $FPATH:$FLINE_END — $(echo "$REPLY_OUT" | head -c 400)"
        else
          echo "::warning::  $rid: thread had no databaseId on its first comment — skipping audit reply (still resolving)."
        fi
        # Resolve the thread. Mutation failure here is non-fatal but
        # diagnostically important — surface the error body.
        if RESOLVE_OUT=$(gh api graphql -f query='
          mutation($threadId:ID!) {
            resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
          }' -f threadId="$TID" 2>&1); then
          RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
          echo "  $rid: resolved thread on $FPATH:$FLINE_END"
        else
          echo "::warning::  $rid: resolveReviewThread mutation failed for $FPATH:$FLINE_END — $(echo "$RESOLVE_OUT" | head -c 400)"
        fi
      done <<< "$RESOLVED_IDS"
      echo "Resolved $RESOLVED_COUNT thread(s); skipped $SKIPPED_COUNT (no matching open thread)."
    fi
  fi
  echo "::endgroup::"
fi

# ── Round-2: resolve INLINE-COMMENT threads (own bot, other bots, humans)
#    that the thread classifier marked RESOLVED. Mirror of the prior-finding
#    block above, but matches by comment_id (not path+author) because each
#    entry's `id` is the GitHub REST comment id directly. Covers all three
#    inline-comment streams in one pass — `bot_user` is null for humans,
#    "panenco-claude-reviewer[bot]" (or similar) for own_bot, "cursor[bot]" /
#    "aikido-pr-checks[bot]" / etc. for other_bot.
# Round-2 guard: thread-resolution.json should only ever exist after a
# successful round-2 run, but a stale filesystem artifact left on the
# runner could otherwise let this block fire on round 1. Mirror the
# guard on the prior-finding block above so both flows share the same
# `prior-state present` precondition.
if [ -f /tmp/thread-resolution.json ] && [ -f /tmp/prior-state/review-state.json ]; then
  echo "::group::Post review — resolve fixed inline-comment threads (round-2)"
  RESOLVED_BOT=$(jq -c '[.[] | select((.source == "own_bot" or .source == "other_bot" or .source == "human") and .status == "RESOLVED")]' /tmp/thread-resolution.json 2>/dev/null || echo "[]")
  RESOLVED_BOT_N=$(echo "$RESOLVED_BOT" | jq 'length' 2>/dev/null || echo 0)
  if [ "$RESOLVED_BOT_N" = "0" ]; then
    echo "No RESOLVED inline-comment threads — nothing to acknowledge."
  else
    OWNER="${REPO%%/*}"
    NAME="${REPO##*/}"
    HEAD_SHA=$(git rev-parse --short=12 HEAD 2>/dev/null || echo "current")
    # databaseId on a comment is the REST `id`; we use it to map
    # resolver output (which carries REST ids) to GraphQL thread nodes.
    THREADS_RAW=$(gh api graphql -f query='
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
      }' -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>&1 || true)
    if ! echo "$THREADS_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "::warning::Could not fetch review threads via GraphQL — skipping other-bot resolution. API response: $(echo "$THREADS_RAW" | head -c 400)"
      THREADS_JSON='[]'
    else
      THREADS_JSON="$THREADS_RAW"
    fi
    if [ "$(echo "$THREADS_JSON" | jq 'length')" = "0" ]; then
      :  # Already warned above; nothing to resolve.
    else
      RESOLVED_COUNT=0
      SKIPPED_COUNT=0
      # Process substitution rather than `| while`: the latter runs the loop
      # in a subshell, so RESOLVED_COUNT / SKIPPED_COUNT increments are lost
      # by the time the summary line below runs (always reports 0).
      while IFS= read -r entry; do
        # In the unified thread-resolution.json schema, `id` is the numeric
        # GitHub REST comment id for inline-comment sources (own_bot /
        # other_bot / human). `path` and `line` mirror the comment.
        # `bot_user` is null for humans.
        CID=$(echo "$entry" | jq -r '.id')
        SRC=$(echo "$entry" | jq -r '.source')
        BOT=$(echo "$entry" | jq -r '.bot_user // empty')
        [ -z "$BOT" ] && BOT="$SRC"
        FPATH=$(echo "$entry" | jq -r '.path // empty')
        FLINE=$(echo "$entry" | jq -r '.line // empty')
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
        # Audit reply via REST `/replies`. CID here is already the parent
        # comment's databaseId (from the resolver's input), so no extra
        # GraphQL roundtrip is needed.
        REPLY_OUT=$(gh api --method POST "repos/$REPO/pulls/$PR/comments/$CID/replies" \
          -f body="$REPLY_BODY" 2>&1) \
          || echo "::warning::  $BOT $CID: reply post failed for $FPATH:$FLINE — $(echo "$REPLY_OUT" | head -c 400)"
        if RESOLVE_OUT=$(gh api graphql -f query='
          mutation($threadId:ID!) {
            resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
          }' -f threadId="$TID" 2>&1); then
          RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
          echo "  $BOT $CID: resolved thread on $FPATH:$FLINE"
        else
          echo "::warning::  $BOT $CID: resolveReviewThread mutation failed for $FPATH:$FLINE — $(echo "$RESOLVE_OUT" | head -c 400)"
        fi
      done < <(echo "$RESOLVED_BOT" | jq -c '.[]')
      echo "Resolved $RESOLVED_COUNT other-bot thread(s); skipped $SKIPPED_COUNT (already resolved or thread not found)."
    fi
  fi
  echo "::endgroup::"
fi
