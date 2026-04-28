#!/usr/bin/env bash
set -euo pipefail

# verdict-gate.sh — Final verdict gate: check review result and set exit code.
#
# Checks if the poster crashed, validates review-result.json, extracts verdict
# and metadata, writes the GitHub step summary, posts a PR comment if the
# result is missing, and exits with the appropriate code.
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
  if [ "$ANALYZER_OUTCOME" = "failure" ]; then
    echo "::error::Analyzer agent crashed before completing the review."
    echo "::error::Check the 'Review: analyze code' step log — common causes:"
    echo "::error::OAuth token expired, network failure, max-turns limit hit, runner OOM."
  else
    echo "::error::review-result.json not found — analyzer did not write output."
  fi

  # Post a visible comment to the PR so the author knows the review
  # didn't happen (Actions log alone is easy to miss).
  if [ -n "$PR_NUMBER" ]; then
    CRASH_MSG="> **Claude Review — incomplete** :warning:"
    CRASH_MSG+=$'\n'">"
    CRASH_MSG+=$'\n'"> The automated review agent crashed before producing results."
    CRASH_MSG+=$'\n'"> Common causes: OAuth token expiry, max-turns budget exhausted, runner OOM."
    CRASH_MSG+=$'\n'">"
    CRASH_MSG+=$'\n'"> **Action required:** a human reviewer should check this PR. Re-running the workflow may also help if the cause was transient."
    gh pr comment "$PR_NUMBER" --body "$CRASH_MSG" || echo "::warning::Failed to post crash notification comment"
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
BUILD_UNAVAILABLE=$(jq -r '.build_unavailable // false' review-result.json)
MANUAL_SPEC=$(jq -r 'if (type == "object" and has("manual_spec_present")) then .manual_spec_present else true end' review-result.json)

# Step summary for the Actions UI.
{
  echo "## Claude Review: $VERDICT"
  echo ""
  jq -r '.summary // "(no summary)"' review-result.json
  echo ""
  echo "### Confirmed findings ($FINDING_COUNT)"
  jq -r '(.findings // [])[] | "- **\(.severity | ascii_upcase)** [\(.type)] `\(.path):\(.line_start)` — \(.title)"' review-result.json
  if [ "$HUMAN_REVIEW" = "true" ]; then
    echo ""
    echo "> :stop_sign: **Human review required.** $HUMAN_REASON"
  fi
  if [ "$MANUAL_SPEC" = "false" ]; then
    echo ""
    echo "> :no_entry: **No manual spec available — APPROVE withheld.** Link an issue, paste acceptance criteria, or wire up an external tracker to enable APPROVE."
  fi
  if [ "$BUILD_UNAVAILABLE" = "true" ]; then
    echo ""
    echo "> :gear: **Build verification unavailable** — dependency install failed; findings are inferred from source reading without typecheck/lint corroboration."
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

# Surface posting failures as a workflow annotation.
if [ -n "$POSTING_ERROR" ]; then
  echo "::warning::Claude review posting failed ($POSTING_ERROR) — verdict is $VERDICT but no PR review comment was created."
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
    exit 1
    ;;
  *)
    echo "::error::Unknown or missing verdict: $VERDICT"
    exit 1
    ;;
esac
