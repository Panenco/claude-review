#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): critical steps carry explicit guards instead.

# post-review.sh — validate /tmp/review.json, post the review, set the check.
#
# Exit semantics: 0 = a review reached the PR (REQUEST_CHANGES included — the
# blocking signal is the PR review, not the check color). 1 = pipeline failure
# (no usable orchestrator output, or the POST to GitHub failed).
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, REVIEW_BOT_USER
# Optional env: ANALYZER_OUTCOME, HEAD_SHA, GITHUB_STEP_SUMMARY

REPO="$GITHUB_REPOSITORY"
PR="$PR_NUMBER"
BOT="${REVIEW_BOT_USER:-github-actions[bot]}"
REVIEW_JSON="${REVIEW_JSON:-/tmp/review.json}"
ORCH_LOG="${ORCH_LOG:-/tmp/orchestrator-output.txt}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK=$(mktemp -d) || { echo "::error::mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Crash banners can't be deleted (no review-delete API); PATCH them to a
# benign superseded form. The superseded marker shares no substring with the
# crash marker, so a superseded review is never re-matched.
supersede_crash_banners() {
  local ids body
  ids=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT" '
        (add // [])
        | [.[] | select(.user.login == $bot and ((.body // "") | contains("<!-- claude-review-crash -->"))) | .id]
        | .[]' 2>/dev/null || true)
  [ -z "$ids" ] && { echo "No prior crash banners to supersede."; return 0; }
  body=$'<!-- claude-review-superseded -->\n\n_Superseded by a newer Claude review run on this PR._'
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id" -f body="$body" >/dev/null 2>&1; then
      echo "Superseded prior crash review #$id"
    else
      echo "::warning::Could not supersede crash review #$id"
    fi
  done <<< "$ids"
}

# crash_exit <context-message> — quota-aware crash banner + exit 1.
crash_exit() {
  local context="$1" quota_hit=false reset_phrase="" crash_msg payload
  if [ -f "$ORCH_LOG" ] && grep -qE 'hit your limit · resets|"error": *"rate_limit"' "$ORCH_LOG" 2>/dev/null; then
    quota_hit=true
    reset_phrase=$(grep -oE 'resets [^"\\]+' "$ORCH_LOG" 2>/dev/null | head -1 || true)
  fi

  if [ "$quota_hit" = "true" ]; then
    if [ -n "$reset_phrase" ]; then
      echo "::error::Claude OAuth quota exhausted ($reset_phrase) — review agent returned rate_limit before producing output."
    else
      echo "::error::Claude OAuth quota exhausted (rate_limit returned, no reset window in the agent log) — review agent could not produce output."
    fi
    echo "::error::Re-run after the quota resets, or rotate CLAUDE_CODE_OAUTH_TOKEN to a token with available quota."
  elif [ "${ANALYZER_OUTCOME:-}" = "failure" ]; then
    echo "::error::Analyzer agent crashed before completing the review ($context)."
    echo "::error::Check the 'Review: orchestrate' step log — common causes: OAuth quota exhausted, OAuth token expired, network failure, max-turns limit hit, runner OOM."
  else
    echo "::error::$context"
  fi

  if [ -n "${PR:-}" ] && [ -n "${REPO:-}" ]; then
    supersede_crash_banners
    if [ "$quota_hit" = "true" ]; then
      crash_msg="<!-- claude-review-crash -->"
      crash_msg+=$'\n\n'"> **Claude Review — quota exhausted** :hourglass:"
      crash_msg+=$'\n'">"
      if [ -n "$reset_phrase" ]; then
        crash_msg+=$'\n'"> The Claude OAuth token hit its limit ($reset_phrase)."
      else
        crash_msg+=$'\n'"> The Claude OAuth token returned rate_limit (the agent log did not include a reset window)."
      fi
      crash_msg+=$'\n'">"
      crash_msg+=$'\n'"> **Action required:** re-run the workflow after the quota resets, or rotate \`CLAUDE_CODE_OAUTH_TOKEN\` to a token with available quota. No code review was produced for this push."
    else
      crash_msg="<!-- claude-review-crash -->"
      crash_msg+=$'\n\n'"> **Claude Review — incomplete** :warning:"
      crash_msg+=$'\n'">"
      crash_msg+=$'\n'"> The automated review agent crashed before producing results."
      crash_msg+=$'\n'"> Common causes: OAuth quota exhausted, max-turns budget exhausted, runner OOM."
      crash_msg+=$'\n'">"
      crash_msg+=$'\n'"> **Action required:** a human reviewer should check this PR. Re-running the workflow may also help if the cause was transient."
    fi
    payload=$(jq -n --arg body "$crash_msg" '{event: "COMMENT", body: $body}')
    gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - <<<"$payload" >/dev/null \
      || echo "::warning::Failed to post crash notification review"
  fi
  exit 1
}

# ── 1. Validate the orchestrator's single artifact ──────────────────────────
if [ ! -f "$REVIEW_JSON" ]; then
  crash_exit "$REVIEW_JSON not found — orchestrator did not write output."
fi
if ! jq -e 'type == "object"' "$REVIEW_JSON" >/dev/null 2>&1; then
  crash_exit "$REVIEW_JSON is not valid JSON."
fi
VERDICT=$(jq -r '.verdict // empty' "$REVIEW_JSON")
case "$VERDICT" in
  APPROVE|COMMENT|REQUEST_CHANGES) ;;
  *) crash_exit "$REVIEW_JSON has unknown verdict '${VERDICT:-<missing>}'." ;;
esac
jq -r '.body // ""' "$REVIEW_JSON" > "$WORK/body.md" || crash_exit "could not extract review body from $REVIEW_JSON."
jq '(.comments // []) | map(select(type == "object"))' "$REVIEW_JSON" > "$WORK/comments.json" || crash_exit "could not extract comments from $REVIEW_JSON."

# ── 2. Hunk validation ───────────────────────────────────────────────────────
# GitHub 422s the whole atomic POST if any comment line is outside a diff
# hunk. Build the valid (path:line:side) set from the pulls/files patches and
# move out-of-hunk comments into the body instead of losing the review.
echo "::group::Hunk validation"
if ! gh api --paginate "repos/$REPO/pulls/$PR/files" 2>/dev/null | jq -s 'add // []' > "$WORK/pr-files.json"; then
  echo '[]' > "$WORK/pr-files.json"
fi
# The FILE-tab sentinel is unambiguous: patch lines only start with @@/+/-/space/backslash.
jq -r '.[] | "FILE\t" + .filename, (.patch // "")' "$WORK/pr-files.json" > "$WORK/patches.txt"
awk '
  /^FILE\t/ { file=substr($0, index($0, "\t")+1); next }
  /^@@ / {
    lspec = $2; rspec = $3
    sub(/^-/, "", lspec); sub(/^\+/, "", rspec)
    n = split(lspec, lp, ","); lstart = lp[1] + 0; lcount = (n >= 2 ? lp[2] + 0 : 1)
    n = split(rspec, rp, ","); rstart = rp[1] + 0; rcount = (n >= 2 ? rp[2] + 0 : 1)
    for (i = lstart; i < lstart + lcount; i++) print file ":" i ":LEFT"
    for (i = rstart; i < rstart + rcount; i++) print file ":" i ":RIGHT"
  }
' "$WORK/patches.txt" | sort -u > "$WORK/valid-lines.txt"

if [ -s "$WORK/valid-lines.txt" ]; then
  jq --rawfile valid "$WORK/valid-lines.txt" '
    ($valid | split("\n") | map(select(length > 0))) as $lines |
    [.[] | . as $c | ($c.path + ":" + ($c.line | tostring) + ":" + ($c.side // "RIGHT")) as $key |
      $c + {_in_diff: ($lines | any(. == $key))}
    ] as $tagged |
    {
      kept:    [$tagged[] | select(._in_diff) | del(._in_diff)],
      dropped: [$tagged[] | select(._in_diff | not) | del(._in_diff)]
    }
  ' "$WORK/comments.json" > "$WORK/split.json"
  # start_line must also anchor inside a hunk or GitHub 422s the whole POST;
  # demote an invalid range to a single-line comment rather than losing it.
  # Null-valued keys (start_line: null) are stripped for the same reason.
  jq --rawfile valid "$WORK/valid-lines.txt" '
    ($valid | split("\n") | map(select(length > 0))) as $lines |
    [.kept[]
      | . as $c
      | if ($c.start_line != null)
          and (($lines | index($c.path + ":" + ($c.start_line | tostring) + ":" + ($c.side // "RIGHT"))) == null)
        then $c | .start_line = null else $c end
      | with_entries(select(.value != null))]
  ' "$WORK/split.json" > "$WORK/comments.json"
  DROPPED=$(jq '.dropped | length' "$WORK/split.json")
  if [ "$DROPPED" -gt 0 ]; then
    echo "Moved $DROPPED comment(s) outside diff hunks into the review body."
    {
      printf '\n### Findings outside diff hunks (%s)\n\n' "$DROPPED"
      printf '_These findings reference lines outside the PR diff hunks, so inline comments cannot anchor there._\n\n'
      jq -r '.dropped[] | "- **`" + .path + ":" + (.line | tostring) + "`** — " + (.body | split("\n")[0]) + "\n"' "$WORK/split.json"
    } >> "$WORK/body.md"
  fi
else
  echo "::warning::Could not derive diff hunks from pulls/files — posting comments unvalidated."
fi
echo "Inline comments: $(jq 'length' "$WORK/comments.json")"
echo "::endgroup::"

# ── 3. Dismiss own stale blocking reviews (keep COMMENTED for audit trail) ──
echo "::group::Dismiss stale reviews"
STALE_IDS=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
  | jq -s --arg bot "$BOT" '
      (add // [])
      | [.[] | select(.user.login == $bot and (.state == "CHANGES_REQUESTED" or .state == "APPROVED")) | .id]
      | .[]' 2>/dev/null || true)
while IFS= read -r id; do
  [ -z "$id" ] && continue
  echo "Dismissing review $id"
  gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
    -f message="Superseded by new Claude review on updated commit." >/dev/null 2>&1 \
    || echo "::warning::Could not dismiss review $id (non-fatal)"
done <<< "$STALE_IDS"
echo "::endgroup::"

# ── 4. Supersede prior crash banners ─────────────────────────────────────────
echo "::group::Supersede prior crash banners"
supersede_crash_banners
echo "::endgroup::"

# ── 5. Atomic POST ───────────────────────────────────────────────────────────
echo "::group::Post review"
# Last-line dedup guard: identical (path, line, body) tuples that survive the
# orchestrator's merge must not reach GitHub twice.
jq 'unique_by([.path, (.line | tostring), .body])' "$WORK/comments.json" > "$WORK/comments-dedup.json" \
  && mv "$WORK/comments-dedup.json" "$WORK/comments.json"
jq -n \
  --arg event "$VERDICT" \
  --rawfile body "$WORK/body.md" \
  --slurpfile comments "$WORK/comments.json" \
  '{event: $event, body: $body, comments: $comments[0]}' > "$WORK/payload.json" || crash_exit "could not build review payload."
echo "Posting $VERDICT review with $(jq '.comments | length' "$WORK/payload.json") inline comments"
if ! POST_RESPONSE=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input "$WORK/payload.json" 2>&1); then
  echo "::endgroup::"
  crash_exit "Review POST failed — verdict is $VERDICT but no PR review was created: $(echo "$POST_RESPONSE" | head -c 400)"
fi
REVIEW_ID=$(echo "$POST_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
echo "Posted review${REVIEW_ID:+ #$REVIEW_ID}"
echo "::endgroup::"

# ── 6. Best-effort: replies to other-bot threads + resolve fixed threads ────
REPLY_COUNT=$(jq '(.bot_replies // []) | length' "$REVIEW_JSON")
if [ "$REPLY_COUNT" -gt 0 ]; then
  echo "::group::Bot replies ($REPLY_COUNT)"
  while IFS= read -r reply; do
    CID=$(echo "$reply" | jq -r '.comment_id')
    if OUT=$(echo "$reply" | jq '{body: .body}' \
        | gh api --method POST "repos/$REPO/pulls/$PR/comments/$CID/replies" --input - 2>&1); then
      echo "Replied to comment $CID"
    else
      echo "::warning::Reply to comment $CID failed — $(echo "$OUT" | head -c 300)"
    fi
  done < <(jq -c '(.bot_replies // [])[]' "$REVIEW_JSON")
  echo "::endgroup::"
fi

RESOLVE_COUNT=$(jq '(.resolve_threads // []) | length' "$REVIEW_JSON")
if [ "$RESOLVE_COUNT" -gt 0 ]; then
  echo "::group::Resolve threads ($RESOLVE_COUNT)"
  OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
  # Map thread id → first comment's databaseId: audit replies go through the
  # REST /replies endpoint because the GraphQL reply mutation auto-creates an
  # empty review container.
  THREADS=$(gh api graphql -f query='
    query($owner:String!, $repo:String!, $pr:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes { id isResolved comments(first:1) { nodes { databaseId } } }
          }
        }
      }
    }' -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes' 2>&1 || true)
  if ! echo "$THREADS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "::warning::Could not fetch review threads — skipping thread resolution. Response: $(echo "$THREADS" | head -c 300)"
    THREADS='[]'
  fi
  while IFS= read -r entry; do
    TID=$(echo "$entry" | jq -r '.thread_id // empty')
    [ -z "$TID" ] && continue
    NODE=$(echo "$THREADS" | jq -c --arg tid "$TID" '.[] | select(.id == $tid)' | head -n1 || true)
    if [ -z "$NODE" ]; then
      echo "::warning::Thread $TID not found among open review threads — skipping."
      continue
    fi
    CID=$(echo "$NODE" | jq -r '.comments.nodes[0].databaseId // empty')
    if [ -n "$CID" ]; then
      echo "$entry" | jq '{body: (.reply // "✅ Resolved by Claude review")}' \
        | gh api --method POST "repos/$REPO/pulls/$PR/comments/$CID/replies" --input - >/dev/null 2>&1 \
        || echo "::warning::Audit reply on thread $TID failed (still resolving)."
    fi
    if gh api graphql -f query='
      mutation($threadId:ID!) {
        resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } }
      }' -f threadId="$TID" >/dev/null 2>&1; then
      echo "Resolved thread $TID"
    else
      echo "::warning::resolveReviewThread failed for $TID"
    fi
  done < <(jq -c '(.resolve_threads // [])[]' "$REVIEW_JSON")
  echo "::endgroup::"
fi

# ── 7. Step summary ──────────────────────────────────────────────────────────
FINDING_COUNT=$(jq '(.meta.findings // []) | length' "$REVIEW_JSON")
HUMAN_REVIEW=$(jq -r '.meta.requires_human_review // false' "$REVIEW_JSON")
HUMAN_REASON=$(jq -r '.meta.requires_human_review_reason // empty' "$REVIEW_JSON")
MANUAL_SPEC=$(jq -r 'if (.meta | type == "object" and has("manual_spec_present")) then .meta.manual_spec_present else true end' "$REVIEW_JSON")
SPEC_WAIVED=$(jq -r '.meta.spec_gate_waived // false' "$REVIEW_JSON")
TECHNICAL_CHANGE=$(jq -r '.meta.technical_change // false' "$REVIEW_JSON")
SMOKE_OK=$(jq -r 'if (.meta | type == "object" and has("smoke_ok")) then .meta.smoke_ok else true end' "$REVIEW_JSON")
FN_STRATEGY=$(jq -r '.meta.functional_validation.strategy // "skip"' "$REVIEW_JSON")
FN_OVERALL=$(jq -r '.meta.functional_validation.overall // "N/A"' "$REVIEW_JSON")
FN_SHOTS=$(jq -r '.meta.functional_validation.screenshot_count // 0' "$REVIEW_JSON")
{
  echo "## Claude Review: $VERDICT"
  echo ""
  jq -r '.meta.verdict_summary // .meta.functional_validation.summary // "(see the PR review for details)"' "$REVIEW_JSON"
  echo ""
  echo "### Confirmed findings ($FINDING_COUNT)"
  jq -r '(.meta.findings // [])[] | "- **\((.severity // "?") | ascii_upcase)** [\(.type // "?")] `\(.path // "?"):\(.line_start // "?")` — \(.title // "Untitled")"' "$REVIEW_JSON"
  if [ "$HUMAN_REVIEW" = "true" ]; then
    echo ""
    echo "> :stop_sign: **Human review required.** $HUMAN_REASON"
  fi
  if [ "$MANUAL_SPEC" = "false" ] && [ "$SPEC_WAIVED" != "true" ]; then
    echo ""
    echo "> :no_entry: **No manual spec available — APPROVE withheld.** Link an issue, paste acceptance criteria, or wire up an external tracker to enable APPROVE."
  fi
  if [ "$TECHNICAL_CHANGE" = "true" ] && [ "$SMOKE_OK" = "false" ]; then
    echo ""
    echo "> :no_entry: **Technical change — APPROVE withheld until smoke-tested** (overall=\`$FN_OVERALL\`). Refactors/upgrades have no acceptance criteria, so a passing smoke run is required. Configure \`.github/claude-review/dev-start.sh\` to bring up the app, or fix the issues that caused the smoke run to fail."
  fi
  if [ "$FN_STRATEGY" != "skip" ]; then
    echo ""
    echo "### Functional validation: $FN_OVERALL"
    echo "Strategy: $FN_STRATEGY | Screenshots: $FN_SHOTS | Areas: $(jq -r '.meta.functional_validation.areas_tested // [] | join(", ")' "$REVIEW_JSON")"
  fi
  echo ""
  echo "Review posted${REVIEW_ID:+ (review #$REVIEW_ID)} on \`${HEAD_SHA:-HEAD}\`."
} >> "$SUMMARY"

# ── 8. Exit code ─────────────────────────────────────────────────────────────
case "$VERDICT" in
  APPROVE)
    exit 0 ;;
  COMMENT)
    if [ "$HUMAN_REVIEW" = "true" ]; then
      echo "::warning::Claude requires human review: $HUMAN_REASON"
    else
      echo "::warning::Claude posted $FINDING_COUNT non-blocking finding(s). See the PR review for details."
    fi
    exit 0 ;;
  REQUEST_CHANGES)
    echo "::warning::Claude review: REQUEST_CHANGES — $FINDING_COUNT blocking finding(s). See the PR review and the run summary for details."
    exit 0 ;;
esac
