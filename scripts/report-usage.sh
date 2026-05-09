#!/usr/bin/env bash
# report-usage.sh — Emit /tmp/usage.json with a tiny per-run record.
#
# Reads review-result.json + /tmp/functional-meta.json + /tmp/phase-summary.txt
# and a handful of env vars, writes /tmp/usage.json. The workflow uploads
# this file as the `claude-review-usage` artifact; scripts/usage-report.sh
# (run locally by the maintainer with their own `gh` auth) discovers consumer
# repos via code search and aggregates these artifacts across them.
#
# This script is BEST-EFFORT BY DESIGN. Every input is optional, every field
# falls back to null/empty rather than failing, and the script always exits 0.
# The workflow step that runs it is also `continue-on-error: true` and
# `if: always()` — usage tracking must never block a review.
#
# Env vars (all optional):
#   GITHUB_REPOSITORY        — owner/repo
#   GITHUB_RUN_ID            — Actions run id
#   GITHUB_RUN_ATTEMPT       — Actions run attempt
#   PR_NUMBER                — PR number
#   HEAD_SHA                 — PR head SHA
#   ANALYZER_OUTCOME         — outcome of the analyzer step (success/failure/…)
#   POSTER_OUTCOME           — outcome of the poster step
#   PRIOR_STATE_AVAILABLE    — "true" iff this is round 2+

set +e

# Coerce review-result.json + functional-meta.json to a stable {} so jq's
# input always has the same shape. Either file may be missing (analyzer
# crashed) or malformed (rare, but build-review.sh has seen it on PRs with
# unescaped quotes in evidence).
RR_TMP=$(mktemp 2>/dev/null) || RR_TMP=/tmp/usage-rr.$$.json
FM_TMP=$(mktemp 2>/dev/null) || FM_TMP=/tmp/usage-fm.$$.json
echo '{}' > "$RR_TMP"
echo '{}' > "$FM_TMP"
if [ -f review-result.json ] && jq -e 'type=="object"' review-result.json >/dev/null 2>&1; then
  cp review-result.json "$RR_TMP" 2>/dev/null || true
fi
if [ -f /tmp/functional-meta.json ] && jq -e 'type=="object"' /tmp/functional-meta.json >/dev/null 2>&1; then
  cp /tmp/functional-meta.json "$FM_TMP" 2>/dev/null || true
fi

# Round inference. PRIOR_STATE_AVAILABLE is set by the workflow's prior_state
# step output ("true" if a state artifact for this PR was downloaded).
ROUND=1
if [ "${PRIOR_STATE_AVAILABLE:-false}" = "true" ]; then
  ROUND=2
fi

# Phase timings — flatten /tmp/phase-summary.txt (`name=Ns` per line) into a
# JSON object so the aggregator can chart context-builder vs analyzer vs
# dev-env if it ever wants to. No-op when the file is absent.
PHASES_JSON='{}'
if [ -f /tmp/phase-summary.txt ]; then
  PHASES_JSON=$(awk -F= '
    BEGIN { printf "{" }
    NF==2 {
      n = $1; v = $2; sub(/s$/, "", v)
      if (v ~ /^[0-9]+$/) {
        if (count++) printf ","
        printf "\"%s\":%s", n, v
      }
    }
    END { printf "}" }
  ' /tmp/phase-summary.txt 2>/dev/null)
  # Fall back if awk produced something jq can't parse.
  if ! echo "$PHASES_JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
    PHASES_JSON='{}'
  fi
fi

RECORDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

OUT=/tmp/usage.json
jq -n \
  --arg repo "${GITHUB_REPOSITORY:-}" \
  --arg pr "${PR_NUMBER:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg head_sha "${HEAD_SHA:-}" \
  --arg recorded_at "$RECORDED_AT" \
  --arg analyzer_outcome "${ANALYZER_OUTCOME:-}" \
  --arg poster_outcome "${POSTER_OUTCOME:-}" \
  --argjson round "$ROUND" \
  --argjson phases "$PHASES_JSON" \
  --slurpfile rr "$RR_TMP" \
  --slurpfile fm "$FM_TMP" \
  '
    ($rr[0] // {}) as $r |
    ($fm[0] // {}) as $f |
    {
      schema_version: 1,
      repo: $repo,
      pr_number: ($pr | tonumber? // null),
      run_id: $run_id,
      run_attempt: ($run_attempt | tonumber? // 1),
      head_sha: $head_sha,
      recorded_at: $recorded_at,
      round: $round,
      verdict: ($r.verdict // null),
      findings_count: (($r.findings // []) | length),
      posting_error: ($r.posting_error // null),
      requires_human_review: ($r.requires_human_review // false),
      technical_change: ($r.technical_change // false),
      functional_strategy: ($r.functional_validation.strategy // $f.strategy // null),
      functional_overall:  ($r.functional_validation.overall  // $f.overall  // null),
      screenshot_count:    ($r.functional_validation.screenshot_count
                            // (($f.screenshots // []) | length)),
      analyzer_outcome: $analyzer_outcome,
      poster_outcome:   $poster_outcome,
      phases: $phases
    }
  ' > "$OUT" 2>/dev/null

# Fallback if jq itself failed (very unusual — corrupt jq, OOM). Emit a
# minimal record so the artifact upload still surfaces "this run happened"
# in the aggregator.
if ! jq empty "$OUT" >/dev/null 2>&1; then
  printf '{"schema_version":1,"repo":"%s","run_id":"%s","recorded_at":"%s","error":"jq_failed"}\n' \
    "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}" "$RECORDED_AT" > "$OUT"
fi

rm -f "$RR_TMP" "$FM_TMP" 2>/dev/null || true

echo "Wrote $OUT:"
cat "$OUT"
exit 0
