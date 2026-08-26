#!/usr/bin/env bash
# prior-review-state.sh — Derive the round-2 review state from GitHub's review list.
#
# GitHub is the state store (see docs/adr/0002): the round number, the SHA the
# last review actually judged, and that review's verdict all come straight from
# the PR's review list. No cross-run artifacts.
#
# Output (KEY=value lines on stdout, ready to append to $GITHUB_OUTPUT):
#   round=<int>              1 on a first (or unreconstructable) round, else N+1
#   prior_head_sha=<sha>     head SHA of the last JUDGED review ("" on round 1)
#   prior_verdict=<verdict>  APPROVE|COMMENT|REQUEST_CHANGES ("" on round 1)
#
# THE TWO LISTS ARE NOT THE SAME LIST — this is the whole point of the script:
#
#   bot-reviews.json    every bot review that is not a crash/superseded banner.
#                       Read by the review-context builder, which shows the reviewer
#                       what is currently standing on the PR — blocks included.
#   prior-reviews.json  the above MINUS the reviews that never judged the diff
#                       (the REVIEW_LEVEL=skip early-returns: the oversized block
#                       and the skip-label note). Feeds round/prior_head_sha/
#                       prior_verdict.
#
# Why: `round` drives since-last SCOPING downstream — the context builder indexes
# only /tmp/since-last-chunks/ and the orchestrator may take its trivial-delta
# shortcut, both on the premise "round 1 already read the whole PR". A skip
# early-return read nothing. Counting one as a round makes the next push review
# only the delta and approve a PR nobody ever looked at. So `round` counts rounds
# that JUDGED, not reviews that were POSTED.
#
# Inputs (env):
#   GITHUB_REPOSITORY, PR_NUMBER   the PR to read (unused when REVIEWS_JSON is set)
#   REVIEW_BOT_USER                login whose reviews count as ours
#   REVIEWS_JSON                   test hook: read this file instead of calling gh
#   OUT_DIR                        where the two lists land (default /tmp)
#
# Failure bias matches review-plan.sh: when a filter cannot be evaluated we fall
# back to the EMPTY list, i.e. round 1 / full-scope re-review. A wasted full
# review is cheaper than a silently-narrowed one.

set -uo pipefail

OUT_DIR="${OUT_DIR:-/tmp}"
BOT_REVIEWS="$OUT_DIR/bot-reviews.json"
PRIOR_REVIEWS="$OUT_DIR/prior-reviews.json"

# Hidden body markers stamped by the orchestrator's REVIEW_LEVEL=skip branch.
# Any new skip gate MUST stamp one of these and list it here — tests/prior_review_state_test.sh
# fails the build if review-plan.sh grows a skip gate that isn't covered.
SKIP_MARKERS=('<!-- claude-review-oversized -->' '<!-- claude-review-skipped -->')

# Every pipeline marker is stamped as the body's FIRST LINE (see the `body` =
# specs in skills/review-orchestrator.md and the crash/superseded bodies in
# post-review.sh), so match it there rather than with contains(). An unanchored
# match reads a review that merely QUOTES a marker as one that never judged —
# live on this repo, which reviews itself: a finding quoting
# `<!-- claude-review-skipped -->` out of review-orchestrator.md would drop a
# real round from the judged list, resetting `round` to 1 and un-pinning that
# round's blockers from the anti-downgrade ladder. Trailing \s absorbs the \r
# GitHub bodies carry when they are CRLF.
JQ_FIRST_LINE='def first_line: ((. // "") | split("\n") | (.[0] // "") | sub("\\s+$"; ""));'

mkdir -p "$OUT_DIR" 2>/dev/null || true

# ── 1) Every bot review that still stands (crash banners and their supersede
#       notes are pipeline noise, never review state). ──
{
  if [ -n "${REVIEWS_JSON:-}" ]; then
    cat "$REVIEWS_JSON"
  else
    gh api --paginate "repos/${GITHUB_REPOSITORY:-}/pulls/${PR_NUMBER:-}/reviews" 2>/dev/null
  fi
} | jq -s --arg bot "${REVIEW_BOT_USER:-}" "$JQ_FIRST_LINE"'
      (add // [])
      | [.[] | select(
          .user.login == $bot
          and ((.body // "") | length > 0)
          and ((.body | first_line) != "<!-- claude-review-crash -->")
          and ((.body | first_line) != "<!-- claude-review-superseded -->")
        )]' > "$BOT_REVIEWS" 2>/dev/null || echo '[]' > "$BOT_REVIEWS"
jq -e 'type == "array"' "$BOT_REVIEWS" >/dev/null 2>&1 || echo '[]' > "$BOT_REVIEWS"

# ── 2) Of those, the ones that actually judged the diff. Filter is built from
#       SKIP_MARKERS so adding a marker above is the only edit a new gate needs. ──
JUDGED_FILTER="$JQ_FIRST_LINE"'[.[] | select(true'
for marker in "${SKIP_MARKERS[@]}"; do
  JUDGED_FILTER+=" and ((.body | first_line) != \"$marker\")"
done
JUDGED_FILTER+=')]'
jq "$JUDGED_FILTER" "$BOT_REVIEWS" > "$PRIOR_REVIEWS" 2>/dev/null || echo '[]' > "$PRIOR_REVIEWS"
jq -e 'type == "array"' "$PRIOR_REVIEWS" >/dev/null 2>&1 || echo '[]' > "$PRIOR_REVIEWS"

# ── 3) Round + prior state, from the JUDGED list. ──
COUNT=$(jq 'length' "$PRIOR_REVIEWS")
PRIOR_SHA=$(jq -r 'sort_by(.submitted_at) | last | .commit_id // empty' "$PRIOR_REVIEWS")
PRIOR_STATE=$(jq -r 'sort_by(.submitted_at) | last | .state // empty' "$PRIOR_REVIEWS")
case "$PRIOR_STATE" in
  APPROVED)          PRIOR_VERDICT=APPROVE ;;
  CHANGES_REQUESTED) PRIOR_VERDICT=REQUEST_CHANGES ;;
  COMMENTED)         PRIOR_VERDICT=COMMENT ;;
  # A dismissal does not change what the review CONCLUDED, so recover the
  # verdict from its body header and let the orchestrator's
  # `prior-dismiss-drops-low-sev` rung decide what the dismissal may drop (it
  # drops prior minor/note only and explicitly keeps critical/major). Mapping
  # straight to APPROVE here pre-empted that rung and un-pinned real blockers.
  # Unparseable header → REQUEST_CHANGES: fail closed, same bias as the filters.
  DISMISSED)
    PRIOR_VERDICT=$(jq -r 'sort_by(.submitted_at) | last | .body // ""' "$PRIOR_REVIEWS" 2>/dev/null \
                      | grep -m1 -oE '^## Claude PR Review — (APPROVE|COMMENT|REQUEST_CHANGES)')
    PRIOR_VERDICT="${PRIOR_VERDICT##* }"
    [ -n "$PRIOR_VERDICT" ] || PRIOR_VERDICT=REQUEST_CHANGES ;;
  *)                 PRIOR_VERDICT="" ;;
esac
ROUND=$(( COUNT + 1 ))
# A prior SHA we cannot resolve can't be diffed against — fall back to a full round 1.
if [ -z "$PRIOR_SHA" ] || ! git cat-file -e "${PRIOR_SHA}^{commit}" 2>/dev/null; then
  ROUND=1; PRIOR_SHA=""; PRIOR_VERDICT=""
fi

# The oversized re-run dedup is gone with the push trigger that made it necessary:
# a review now happens because someone asked, and answering that with silence is
# worse than answering it with the same block twice.

printf 'round=%s\nprior_head_sha=%s\nprior_verdict=%s\n' \
  "$ROUND" "$PRIOR_SHA" "$PRIOR_VERDICT"
