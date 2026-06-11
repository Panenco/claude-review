#!/usr/bin/env bash
set -euo pipefail

# verdict-gate.sh — Final verdict gate: check review result and set exit code.
#
# Checks if the poster crashed, validates review-result.json, extracts verdict
# and metadata, writes the GitHub step summary, posts a PR comment if the
# result is missing, and exits with the appropriate code.
#
# Exit semantics: the check is GREEN whenever a review was successfully
# posted — including REQUEST_CHANGES, which lives on the PR review itself
# (and blocks via branch protection when required reviews are enforced).
# A red check means the PIPELINE failed: no review produced, or a verdict
# was computed but the POST to GitHub failed. Conflating "bot wants
# changes" with "bot broke" made fleet failure rates unreadable and
# trained authors to re-run perfectly good reviews.
#
# Required env vars:
#   ANALYZER_OUTCOME      — outcome of the analyzer step (success/failure/etc.)
#   POSTER_OUTCOME        — outcome of the poster step (success/failure/etc.)
#   GITHUB_REPOSITORY     — owner/repo
#   GH_TOKEN              — GitHub token for API calls
#   PR_NUMBER             — pull request number
#   GITHUB_STEP_SUMMARY   — path to the step summary file

# If poster crashed after analyzer succeeded, the review wasn't posted.
# Inject posting_error so the gate surfaces it.
if [ "$ANALYZER_OUTCOME" = "success" ] && [ "$POSTER_OUTCOME" != "success" ]; then
  if [ -f review-result.json ]; then
    jq --arg outcome "$POSTER_OUTCOME" '.posting_error = "poster agent failed (outcome: \($outcome))"' review-result.json > /tmp/r.json && mv /tmp/r.json review-result.json
    echo "::warning::Poster agent failed — review-result.json exists but the review may not have been posted to the PR."
  fi
fi

if [ ! -f review-result.json ]; then
  # Detect Claude OAuth-quota exhaustion in the orchestrator's JSONL stream.
  # The single-orchestrator architecture writes one execution_file per run
  # (claude-code-action's --output-file), copied by the workflow to
  # /tmp/orchestrator-output.txt. /tmp/functional-output.txt may also exist
  # if a separate functional dispatch was wired in legacy form, so we still
  # scan it when present. build-review.sh has the same scan when reachable;
  # this duplicate covers the path where the orchestrator hits quota before
  # writing /tmp/all-findings.json — build-review.sh is never invoked then,
  # so this gate is the only place the quota signal can surface.
  #
  # Track QUOTA_HIT independently from RESET_PHRASE so a rate_limit without
  # an accompanying `resets …` phrase (older agent versions, truncated
  # logs, future format changes) still emits the quota-specific message
  # instead of silently falling back to the generic catch-all.
  QUOTA_HIT=false
  RESET_PHRASE=""
  for f in /tmp/orchestrator-output.txt \
           /tmp/functional-output.txt \
           /tmp/thread-classifier-output.txt \
           /tmp/build-context-execution.jsonl; do
    [ -f "$f" ] || continue
    if grep -qE 'hit your limit · resets|"error": *"rate_limit"' "$f" 2>/dev/null; then
      QUOTA_HIT=true
      RESET_PHRASE=$(grep -oE 'resets [^"\\]+' "$f" 2>/dev/null | head -1 || true)
      break
    fi
  done

  if [ "$QUOTA_HIT" = "true" ]; then
    if [ -n "$RESET_PHRASE" ]; then
      echo "::error::Claude OAuth quota exhausted ($RESET_PHRASE) — review agent returned rate_limit before producing output."
    else
      echo "::error::Claude OAuth quota exhausted (rate_limit returned, no reset window in the agent log) — review agent could not produce output."
    fi
    echo "::error::Re-run after the quota resets, or rotate CLAUDE_CODE_OAUTH_TOKEN to a token with available quota."
  elif [ "$ANALYZER_OUTCOME" = "failure" ]; then
    echo "::error::Analyzer agent crashed before completing the review."
    echo "::error::Check the 'Review: analyze code' step log — common causes:"
    echo "::error::OAuth quota exhausted, OAuth token expired, network failure, max-turns limit hit, runner OOM."
  else
    echo "::error::review-result.json not found — analyzer did not write output."
  fi

  # Post a visible notice to the PR so the author knows the review
  # didn't happen (Actions log alone is easy to miss).
  #
  # Posted as a *review* (not an issue comment) carrying a stable HTML
  # marker so the next successful run can find and supersede it via
  # post-review.sh's PUT /reviews/{id} step. Without supersession the red
  # banner survives every retry — observed on Panenco/qiv#292.
  if [ -n "$PR_NUMBER" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    if [ "$QUOTA_HIT" = "true" ]; then
      CRASH_MSG="<!-- claude-review-crash -->"
      CRASH_MSG+=$'\n\n'"> **Claude Review — quota exhausted** :hourglass:"
      CRASH_MSG+=$'\n'">"
      if [ -n "$RESET_PHRASE" ]; then
        CRASH_MSG+=$'\n'"> The Claude OAuth token hit its limit ($RESET_PHRASE)."
      else
        CRASH_MSG+=$'\n'"> The Claude OAuth token returned rate_limit (the agent log did not include a reset window)."
      fi
      CRASH_MSG+=$'\n'">"
      CRASH_MSG+=$'\n'"> **Action required:** re-run the workflow after the quota resets, or rotate \`CLAUDE_CODE_OAUTH_TOKEN\` to a token with available quota. No code review was produced for this push."
    else
      CRASH_MSG="<!-- claude-review-crash -->"
      CRASH_MSG+=$'\n\n'"> **Claude Review — incomplete** :warning:"
      CRASH_MSG+=$'\n'">"
      CRASH_MSG+=$'\n'"> The automated review agent crashed before producing results."
      CRASH_MSG+=$'\n'"> Common causes: OAuth quota exhausted, max-turns budget exhausted, runner OOM."
      CRASH_MSG+=$'\n'">"
      CRASH_MSG+=$'\n'"> **Action required:** a human reviewer should check this PR. Re-running the workflow may also help if the cause was transient."
    fi
    # event=COMMENT keeps the notice non-blocking (we already exit 1 below
    # to fail the workflow). Using a review instead of an issue comment
    # gives us a single editable surface that the next successful run can
    # supersede in post-review.sh.
    # Supersede prior crash banners first. post-review.sh only cleans them
    # on the next SUCCESSFUL run — PRs that crash on every push (quota walls,
    # bot PRs) otherwise stack a new red banner per night, 10+ observed.
    PRIOR_CRASH_IDS=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" 2>/dev/null \
      | jq -s '(add // []) | [.[] | select((.body // "") | contains("<!-- claude-review-crash -->")) | .id] | .[]' 2>/dev/null || true)
    if [ -n "$PRIOR_CRASH_IDS" ]; then
      SUPERSEDE_BODY=$'<!-- claude-review-superseded -->\n\n_Superseded by a newer Claude review run on this PR._'
      while IFS= read -r CRID; do
        [ -z "$CRID" ] && continue
        gh api --method PUT "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$CRID" -f body="$SUPERSEDE_BODY" >/dev/null 2>&1 \
          || echo "::warning::Could not supersede prior crash review #$CRID"
      done <<< "$PRIOR_CRASH_IDS"
    fi
    CRASH_PAYLOAD=$(jq -n --arg body "$CRASH_MSG" '{event: "COMMENT", body: $body}')
    if ! gh api --method POST "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" --input - <<<"$CRASH_PAYLOAD" >/dev/null; then
      echo "::warning::Failed to post crash notification review"
    fi
  fi
  exit 1
fi

if ! jq empty review-result.json 2>/dev/null; then
  echo "::error::review-result.json is not valid JSON"
  exit 1
fi

VERDICT=$(jq -r '.verdict // "MISSING"' review-result.json)
FINDING_COUNT=$(jq '(.findings // []) | length' review-result.json)
POSTING_ERROR=$(jq -r '.posting_error // empty' review-result.json)
HUMAN_REVIEW=$(jq -r '.requires_human_review // false' review-result.json)
HUMAN_REASON=$(jq -r '.requires_human_review_reason // empty' review-result.json)
MANUAL_SPEC=$(jq -r 'if (type == "object" and has("manual_spec_present")) then .manual_spec_present else true end' review-result.json)
SPEC_WAIVED=$(jq -r '.spec_gate_waived // false' review-result.json)
TECHNICAL_CHANGE=$(jq -r 'if (type == "object" and has("technical_change")) then .technical_change else false end' review-result.json)
# Read smoke_ok directly — it captures both the FUNCTIONAL_OK crash flag and
# the FUNCTIONAL_OVERALL value as build-review.sh saw them. Reading
# functional_validation.overall here would diverge from the gate condition
# in the partial-crash scenario where the tester wrote
# `{strategy: "functional", overall: "PASS"}` and then crashed: the
# JSON_FUNCTIONAL_META override only fires for the {skip,PASS} synthetic, so
# overall would still read "PASS" and the banner would silently disappear
# even though the verdict was correctly downgraded to COMMENT.
SMOKE_OK=$(jq -r 'if (type == "object" and has("smoke_ok")) then .smoke_ok else true end' review-result.json)
FUNCTIONAL_OVERALL=$(jq -r '.functional_validation.overall // "N/A"' review-result.json)

# Step summary for the Actions UI.
{
  echo "## Claude Review: $VERDICT"
  echo ""
  jq -r '.summary // "(no summary)"' review-result.json
  echo ""
  echo "### Confirmed findings ($FINDING_COUNT)"
  jq -r '(.findings // [])[] | "- **\(.severity | ascii_upcase)** [\(.type)] `\(.path):\(.line_start)` — \(.title // "Untitled")"' review-result.json
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
    echo "> :no_entry: **Technical change — APPROVE withheld until smoke-tested** (overall=\`$FUNCTIONAL_OVERALL\`). Refactors/upgrades have no acceptance criteria, so a passing smoke run is required. Configure \`.github/claude-review/dev-start.sh\` to bring up the app, or fix the issues that caused the smoke run to fail."
  fi
  # Functional validation summary
  FN_STRATEGY=$(jq -r '.functional_validation.strategy // "skip"' review-result.json)
  FN_OVERALL=$(jq -r '.functional_validation.overall // "N/A"' review-result.json)
  FN_SHOTS=$(jq -r '.functional_validation.screenshot_count // 0' review-result.json)
  if [ "$FN_STRATEGY" != "skip" ]; then
    echo ""
    echo "### Functional validation: $FN_OVERALL"
    echo "Strategy: $FN_STRATEGY | Screenshots: $FN_SHOTS | Areas: $(jq -r '.functional_validation.areas_tested // [] | join(", ")' review-result.json)"
  fi
  if [ -n "$POSTING_ERROR" ]; then
    echo ""
    echo "> :warning: **Posting error:** $POSTING_ERROR. The verdict is recorded above but the GitHub review comment was not posted to this PR."
  fi
} >> "$GITHUB_STEP_SUMMARY"

# A verdict that never reached the PR is a pipeline failure — the author
# sees nothing, so the check must go red (observed: REQUEST_CHANGES computed,
# POST failed, author saw a bare red check with no findings anywhere).
if [ -n "$POSTING_ERROR" ]; then
  echo "::error::Claude review posting failed ($POSTING_ERROR) — verdict is $VERDICT but no PR review was created. Re-run the workflow."
  exit 1
fi

case "$VERDICT" in
  APPROVE)
    exit 0
    ;;
  COMMENT)
    # CI passes (concerns are not blocking) but emit a warning so the
    # check is visually distinguishable from APPROVE in the PR UI.
    if [ "$HUMAN_REVIEW" = "true" ]; then
      echo "::warning::Claude requires human review: $HUMAN_REASON"
    else
      echo "::warning::Claude posted $FINDING_COUNT non-blocking finding(s). See the PR review for details."
    fi
    exit 0
    ;;
  REQUEST_CHANGES)
    # Green: the review posted successfully. The blocking signal is the
    # REQUEST_CHANGES review on the PR, not this check's color.
    echo "::warning::Claude review: REQUEST_CHANGES — $FINDING_COUNT blocking finding(s). See the PR review and the run summary for details."
    exit 0
    ;;
  *)
    echo "::error::Unknown or missing verdict: $VERDICT"
    exit 1
    ;;
esac
