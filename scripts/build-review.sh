#!/usr/bin/env bash
set -euo pipefail

# build-review.sh — Build review artifacts from the orchestrator's output.
#
# Runs AFTER the orchestrator (and, in round 2, the thread classifier) have
# completed. Reads the pre-deduped findings + meta the orchestrator wrote,
# collects screenshots from the functional tester, applies the round-2
# verdict ladder, and builds review-result.json + review body + inline
# comments. No multi-source merge or LLM dedup runs here — the judge debate
# inside the orchestrator already produced a single, deduped findings array.
#
# Required env vars:
#   GH_TOKEN            — GitHub token for API calls (review identity)
#   GITHUB_REPO_TOKEN   — GitHub token with contents:write (for screenshot upload)
#   GITHUB_REPOSITORY   — owner/repo
#   GITHUB_RUN_ID       — Actions run ID (for logs link)
#   PR_NUMBER           — pull request number
#   FUNCTIONAL_OK       — 1 if the functional tester succeeded (or was correctly skipped)
#
# Orchestrator-step outcome is intentionally NOT plumbed in as a flag.
# We gate on the artifact (`/tmp/all-findings.json` parses as an array)
# instead, so a max-turns-killed orchestrator that still wrote partial
# output gets used; only a missing/malformed file fails the build step.
#
# Expected files (from agents):
#   /tmp/all-findings.json        — orchestrator's final findings (REQUIRED)
#   /tmp/review-meta.json         — orchestrator's verdict + meta (REQUIRED)
#   /tmp/functional-findings.json — functional tester findings (optional)
#   /tmp/functional-meta.json     — functional tester metadata (optional)
#   /tmp/thread-resolution.json   — round-2 thread classifier output (round 2 only)
#   /tmp/resolution-findings.json — round-2 net-new findings (round 2 only, rare)
#
# Output files:
#   review-result.json            — full review result
#   /tmp/review-body.md           — PR review body markdown
#   /tmp/review-comments.json     — inline comments array
#   findings.draft.json           — all findings for artifact upload

# Pick the more-severe of two verdicts. Order: REQUEST_CHANGES > COMMENT > APPROVE.
# Used by the round-2 degraded branch to fail-closed when resolution status is
# unknown — never silently downgrade a prior REQUEST_CHANGES.
#
# Both inputs must be in {REQUEST_CHANGES, COMMENT, APPROVE}. Anything else
# (typo, corrupted prior-state, future enum we don't know about) is treated
# as REQUEST_CHANGES — fail-closed. The previous default of APPROVE was
# fail-open: a corrupted PRIOR_VERDICT would silently downgrade.
verdict_max() {
  local a="${1:-REQUEST_CHANGES}"
  local b="${2:-REQUEST_CHANGES}"
  case "$a" in REQUEST_CHANGES|COMMENT|APPROVE) ;; *) a="REQUEST_CHANGES" ;; esac
  case "$b" in REQUEST_CHANGES|COMMENT|APPROVE) ;; *) b="REQUEST_CHANGES" ;; esac
  case "$a:$b" in
    REQUEST_CHANGES:*|*:REQUEST_CHANGES) echo "REQUEST_CHANGES" ;;
    COMMENT:*|*:COMMENT)                 echo "COMMENT" ;;
    *)                                   echo "APPROVE" ;;
  esac
}

echo "::group::Build review"

# The orchestrator (review-orchestrator skill, run as a Claude Code agent
# with the Task tool) ran two judges (Opus + Haiku), reconciled them via
# a debate loop, and wrote two artifacts directly:
#
#   /tmp/all-findings.json — the final, deduped findings array (drop-in
#                            replacement for the legacy multi-source merge
#                            + Haiku dedup output).
#   /tmp/review-meta.json  — verdict, verdict_summary, manual_spec_present,
#                            spec_compliance, requires_human_review,
#                            uncertain_observations, prompt_injection_detected,
#                            spec_sources, judge_health.
#
# Both files are required. If either is missing or malformed, the orchestrator
# either crashed mid-run or hit a quota wall before writing its STOP-anchor
# fallback. We bail with a clear error and let verdict-gate.sh post the
# "Claude Review — incomplete" notification.

if [ ! -f /tmp/all-findings.json ] || ! jq -e 'type == "array"' /tmp/all-findings.json >/dev/null 2>&1; then
  # Distinguish OAuth-quota exhaustion from a generic crash so the error
  # annotation says what actually happened. The orchestrator's stdout log
  # (text mode, /tmp/orchestrator-output.txt) carries the same `hit your
  # limit · resets …` / `"error":"rate_limit"` signals the legacy multi-
  # agent fan did. Same grep, narrowed to the single log file.
  if [ -f /tmp/all-findings.json ]; then
    cp /tmp/all-findings.json /tmp/all-findings.invalid.json 2>/dev/null || true
  fi
  QUOTA_HIT=false
  RESET_PHRASE=""
  if [ -f /tmp/orchestrator-output.txt ] && grep -qE 'hit your limit · resets|"error": *"rate_limit"' /tmp/orchestrator-output.txt 2>/dev/null; then
    QUOTA_HIT=true
    RESET_PHRASE=$(grep -oE 'resets [^"\\]+' /tmp/orchestrator-output.txt 2>/dev/null | head -1 || true)
  fi
  if [ "$QUOTA_HIT" = "true" ]; then
    if [ -n "$RESET_PHRASE" ]; then
      echo "::error::Orchestrator failed: Claude OAuth quota exhausted ($RESET_PHRASE)."
    else
      echo "::error::Orchestrator failed: Claude OAuth quota exhausted (rate_limit returned, no reset window in the log)."
    fi
    echo "::error::Re-run after the quota resets, or rotate CLAUDE_CODE_OAUTH_TOKEN to a token with available quota."
  else
    echo "::error::Orchestrator did not produce a valid /tmp/all-findings.json — cannot generate a verdict."
    echo "::error::Investigate /tmp/orchestrator-output.txt (and /tmp/judge-opus*.json / /tmp/judge-haiku*.json if present)."
  fi
  exit 1
fi

if [ ! -f /tmp/review-meta.json ] || ! jq -e 'type == "object"' /tmp/review-meta.json >/dev/null 2>&1; then
  if [ -f /tmp/review-meta.json ]; then
    cp /tmp/review-meta.json /tmp/review-meta.invalid.json 2>/dev/null || true
  fi
  echo "::error::Orchestrator did not produce a valid /tmp/review-meta.json — cannot read verdict / spec_compliance."
  echo "::error::Investigate /tmp/orchestrator-output.txt."
  exit 1
fi

ALL_FINDINGS=$(cat /tmp/all-findings.json)
CORE_META=$(cat /tmp/review-meta.json)

# Defensive merge of round-2 net-new findings from the thread classifier.
# The orchestrator skill (Phase 4) instructs the LLM to fold
# `/tmp/resolution-findings.json` into `/tmp/all-findings.json` before
# exiting; this safety net catches the rare case where the LLM forgot or
# crashed mid-write, ensuring a major/critical net-new from the
# classifier still lands in the verdict gate. Dedup by id so an entry
# already merged by the orchestrator isn't double-counted.
if [ -f /tmp/resolution-findings.json ] && jq -e 'type == "array" and length > 0' /tmp/resolution-findings.json >/dev/null 2>&1; then
  MERGED=$(jq -s '
    (.[0] // []) as $primary |
    ($primary | map(.id)) as $seen |
    $primary + ((.[1] // []) | map(select(.id as $id | $seen | index($id) | not)))
  ' /tmp/all-findings.json /tmp/resolution-findings.json)
  ADDED=$(( $(echo "$MERGED" | jq 'length') - $(echo "$ALL_FINDINGS" | jq 'length') ))
  if [ "$ADDED" -gt 0 ]; then
    echo "::notice::Defensive-merged $ADDED resolution-finding(s) the orchestrator hadn't already folded into /tmp/all-findings.json."
  fi
  ALL_FINDINGS="$MERGED"
fi

# Defensive merge of functional-tester findings. Same pattern + reason
# as the resolution-findings merge above — the orchestrator skill folds
# `/tmp/functional-findings.json` into `/tmp/all-findings.json` so that
# (a) the verdict gate counts UI/contract findings as blockers and
# (b) findings carrying a `screenshot` path reach the inline-comment
# builder at the bottom of this script (the `![screenshot](url)` embed
# only fires for entries in $ALL_FINDINGS). Without this safety net a
# functional finding lands only in the body's "Issues found" list and
# the developer never sees the screenshot at the offending diff line.
# Dedup by id is mandatory: judges sometimes re-discover the same UI
# bug with a different id, and the orchestrator may have already folded
# the functional entry, in which case its id wins.
if [ -f /tmp/functional-findings.json ] && jq -e 'type == "array" and length > 0' /tmp/functional-findings.json >/dev/null 2>&1; then
  PREV_LEN=$(echo "$ALL_FINDINGS" | jq 'length')
  MERGED=$(jq -n --argjson primary "$ALL_FINDINGS" --slurpfile fn /tmp/functional-findings.json '
    ($primary | map(.id)) as $seen |
    $primary + (($fn[0] // []) | map(select(.id as $id | $seen | index($id) | not)))
  ')
  ADDED=$(( $(echo "$MERGED" | jq 'length') - PREV_LEN ))
  if [ "$ADDED" -gt 0 ]; then
    echo "::notice::Defensive-merged $ADDED functional-finding(s) the orchestrator hadn't already folded into /tmp/all-findings.json."
  fi
  ALL_FINDINGS="$MERGED"
fi

TOTAL=$(echo "$ALL_FINDINGS" | jq 'length')
echo "Orchestrator findings: total=$TOTAL (judge_health: $(echo "$CORE_META" | jq -c '.judge_health // {}'))"

# Functional tester output is still produced by a separate agent — gate it
# independently. Coerce malformed JSON to {}; if findings file is missing
# default to []. Both downstream verdict gates and body builders read
# FUNCTIONAL_HAS_OUTPUT to decide whether to render the functional section.
FUNCTIONAL_HAS_OUTPUT=false
if [ -f /tmp/functional-findings.json ] && jq -e 'type == "array"' /tmp/functional-findings.json >/dev/null 2>&1; then
  FUNCTIONAL_HAS_OUTPUT=true
fi
if [ -f /tmp/functional-meta.json ] && ! jq -e 'type == "object"' /tmp/functional-meta.json >/dev/null 2>&1; then
  echo "::warning::/tmp/functional-meta.json is not a JSON object — falling back to {}."
  cp /tmp/functional-meta.json /tmp/functional-meta.invalid.json 2>/dev/null || true
  echo '{}' > /tmp/functional-meta.json
fi
# Distinguish "tester ran and crashed" from "tester correctly skipped".
# Docs-only / no-dev-env / round-2 since-last-with-no-user-surface PRs
# legitimately skip functional dispatch — the orchestrator writes a
# synthetic /tmp/functional-meta.json with strategy="skip" and never emits
# /tmp/functional-findings.json in some paths, which would otherwise fire
# the "failed" warning every time. Read the meta's strategy first; only
# flag "failed" when the planner asked for a smoke run that never landed.
if [ "$FUNCTIONAL_HAS_OUTPUT" = "false" ]; then
  FUNCTIONAL_STRATEGY_TMP="skip"
  if [ -f /tmp/functional-meta.json ]; then
    FUNCTIONAL_STRATEGY_TMP=$(jq -r '.strategy // "skip"' /tmp/functional-meta.json 2>/dev/null || echo "skip")
  fi
  if [ "$FUNCTIONAL_STRATEGY_TMP" != "skip" ]; then
    echo "::warning::Functional tester failed — strategy=$FUNCTIONAL_STRATEGY_TMP but no findings file produced."
  fi
fi

# Load functional test metadata (strategy, screenshots, overall verdict)
FUNCTIONAL_META='{}'
[ -f /tmp/functional-meta.json ] && FUNCTIONAL_META=$(cat /tmp/functional-meta.json)
FUNCTIONAL_STRATEGY=$(echo "$FUNCTIONAL_META" | jq -r '.strategy // "skip"')
FUNCTIONAL_OVERALL=$(echo "$FUNCTIONAL_META" | jq -r '.overall // "N/A"')
echo "Functional tester: strategy=$FUNCTIONAL_STRATEGY, overall=$FUNCTIONAL_OVERALL"

# Prior round's smoke result (round 2+ only). When the round-2 planner picks
# strategy=skip because since-last has no user-observable surface, the
# Technical-change smoke gate below inherits PRIOR_FUNCTIONAL_OVERALL so a
# small follow-up commit doesn't drop APPROVE → COMMENT just because the
# tester didn't re-run. Inheritance only kicks in for PASS/WARN — a prior
# FAIL or N/A doesn't satisfy the gate.
PRIOR_FUNCTIONAL_OVERALL=""
PRIOR_FUNCTIONAL_STRATEGY=""
PRIOR_DISMISSED=false
if [ -f /tmp/prior-state/review-state.json ]; then
  PRIOR_FUNCTIONAL_OVERALL=$(jq -r '.functional_overall // empty' /tmp/prior-state/review-state.json 2>/dev/null || echo "")
  PRIOR_FUNCTIONAL_STRATEGY=$(jq -r '.functional_strategy // empty' /tmp/prior-state/review-state.json 2>/dev/null || echo "")
  # jq's `//` treats explicit `false` as missing — `false // <default>`
  # always returns the default, regardless of intent. Coincidentally
  # correct here because the field's default IS false, but if the
  # default ever changes the bug becomes real. Use the project's
  # `if has() then ... else default end` pattern (see line ~485).
  PRIOR_DISMISSED=$(jq -r 'if (type == "object" and has("dismissed_by_author")) then .dismissed_by_author else false end' /tmp/prior-state/review-state.json 2>/dev/null || echo "false")
fi

# ── Screenshot collection and upload ──
# We collect ONLY the basenames the functional tester named in
# functional-meta.screenshots[].file (and functional-findings[].screenshot).
# Earlier versions scanned the consumer repo's CWD with `find . -name '*.png'`
# and a `-mmin -60` mtime filter, but `actions/checkout` rewrites all
# checked-in file mtimes to ~now — so the filter cannot distinguish a
# checked-in product asset (e.g. seaters' `screenshots/wl_logo.png`) from
# a freshly captured tester screenshot. Cursor caught this on PR #30;
# the only safe rule is to upload exactly what the tester says it wrote.
SCREENSHOT_URLS='{}'
mkdir -p /tmp/all-screenshots
# Short-circuit when the functional tester didn't run or didn't produce
# any image-typed screenshots[] entries. This both saves the upload work
# and guarantees a docs-only / strategy=skip review on a repo with any
# pre-existing PNG never commits those PNGs to review-assets/pr-N/.
EXPECTED_IMAGE_SHOTS=$(echo "$FUNCTIONAL_META" | jq '[(.screenshots // [])[] | select((.file // "") | test("\\.(png|jpg|jpeg|webp)$"; "i"))] | length')
if [ "$FUNCTIONAL_STRATEGY" = "skip" ] || [ "${EXPECTED_IMAGE_SHOTS:-0}" -eq 0 ]; then
  echo "Skipping screenshot collection + upload (strategy=$FUNCTIONAL_STRATEGY, expected_image_screenshots=${EXPECTED_IMAGE_SHOTS:-0})."
else
  # Build the allowlist: every `file` field across screenshots[] and
  # findings[].screenshot. Resolve to absolute paths first (the tester
  # is contract-bound to write under /tmp/screenshots/ but legacy
  # plain-filename paths get expanded relative to ., the tester's CWD).
  FN_INPUT="[]"
  [ -f /tmp/functional-findings.json ] && jq -e 'type == "array"' /tmp/functional-findings.json >/dev/null 2>&1 \
    && FN_INPUT=$(cat /tmp/functional-findings.json)
  EXPECTED_FILES=$(jq -n \
    --argjson meta "$FUNCTIONAL_META" \
    --argjson fn "$FN_INPUT" \
    'def img_paths: map(select(type == "string" and (test("\\.(png|jpg|jpeg|webp)$"; "i")))) | unique;
     (($meta.screenshots // []) | map(.file // ""))
     + (($fn // []) | map(.screenshot // ""))
     | img_paths')
  echo "Functional tester named $(echo "$EXPECTED_FILES" | jq 'length') screenshot path(s); resolving each."
  while read -r expected; do
    [ -z "$expected" ] && continue
    base=$(basename "$expected")
    # 1) Absolute path the tester wrote (preferred — /tmp/screenshots/...).
    if [ -f "$expected" ]; then
      cp -n "$expected" "/tmp/all-screenshots/$base"
      continue
    fi
    # 2) Plain-filename fallback: the tester used a relative path that
    #    Playwright MCP expanded against its CWD. Check the agent-only
    #    output dirs first, then the repo root as a last resort —
    #    bound to a basename match so we never pick up unrelated PNGs.
    found=""
    for d in /tmp/screenshots /tmp/playwright-mcp-output .playwright-mcp .playwright-mcp/screenshots screenshots .; do
      [ -f "$d/$base" ] && { found="$d/$base"; break; }
    done
    if [ -n "$found" ]; then
      cp -n "$found" "/tmp/all-screenshots/$base"
    else
      echo "::notice::Functional tester referenced screenshot '$expected' but the file was not produced on disk (basename '$base' not found in /tmp/screenshots, /tmp/playwright-mcp-output, .playwright-mcp{,/screenshots}, screenshots, or repo root)."
    fi
  done < <(echo "$EXPECTED_FILES" | jq -r '.[]')
fi
SCREENSHOT_DIR=""
if ls /tmp/all-screenshots/*.png >/dev/null 2>&1; then
  SCREENSHOT_DIR="/tmp/all-screenshots"
  echo "Found $(ls /tmp/all-screenshots/*.png | wc -l) screenshot(s):"
  ls -la /tmp/all-screenshots/*.png
else
  echo "No screenshots found in any path. Searched: ., /tmp/screenshots, /tmp/playwright-mcp-output, .playwright-mcp, screenshots, .playwright-mcp/screenshots, plus recursive /tmp scan"
  echo "All recent PNGs anywhere on disk (debug):"
  find / -name '*.png' -mmin -60 2>/dev/null | grep -v node_modules | head -20 || true
fi

if [ -n "$SCREENSHOT_DIR" ]; then
  echo "Uploading screenshots to review-assets branch..."
  mkdir -p screenshots
  cp "$SCREENSHOT_DIR"/*.png screenshots/ 2>/dev/null || true

  # Upload via Git Trees API to review-assets branch.
  # Single orphan commit (no parent) with base_tree from previous commit
  # to preserve old PR screenshots. Always exactly 1 commit — no history.
  BASE_TREE=""
  BASE_SHA=""
  if GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/refs/heads/review-assets" >/dev/null 2>&1; then
    BASE_SHA=$(GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/refs/heads/review-assets" --jq '.object.sha')
    BASE_TREE=$(GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/commits/$BASE_SHA" --jq '.tree.sha')
  fi

  TREE_ENTRIES="[]"
  UPLOAD_COUNT=0
  FAILED_COUNT=0
  TOTAL_COUNT=$(ls "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l)
  for img in "$SCREENSHOT_DIR"/*.png; do
    BASENAME=$(basename "$img")
    UPLOAD_PATH="pr-${PR_NUMBER}/${BASENAME}"
    # Pipe the base64 payload via stdin + --input rather than `-f content=`.
    # The argv-form field silently fails for blobs above ~200 KB on GitHub
    # runners (form-encoded body outgrows some internal buffer), leaving
    # `BLOB_SHA` empty and the image silently dropped. argenx-argo-map#227
    # run 24578947702 uploaded 4/9 screenshots exactly along the 26 KB
    # boundary — every larger PNG (map view, user menu, SAML redirect)
    # was dropped and only survived as a "see build artifacts" link. A
    # JSON body through stdin sidesteps the form-encoding path entirely.
    BLOB_SHA=$(base64 -w0 < "$img" 2>/dev/null | \
      jq -Rs '{content: ., encoding: "base64"}' | \
      GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/blobs" \
        --method POST --input - --jq '.sha' 2>/tmp/blob-err.log) || true
    if [ -n "$BLOB_SHA" ]; then
      TREE_ENTRIES=$(echo "$TREE_ENTRIES" | jq --arg p "$UPLOAD_PATH" --arg s "$BLOB_SHA" \
        '. + [{"path": $p, "mode": "100644", "type": "blob", "sha": $s}]')
      URL="https://github.com/$GITHUB_REPOSITORY/raw/review-assets/$UPLOAD_PATH"
      SCREENSHOT_URLS=$(echo "$SCREENSHOT_URLS" | jq --arg k "$BASENAME" --arg v "$URL" '. + {($k): $v}')
      echo "  $BASENAME -> $URL"
      UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
    else
      FAILED_COUNT=$((FAILED_COUNT + 1))
      SIZE=$(wc -c < "$img" | tr -d ' ')
      ERR_TAIL=$(tail -c 200 /tmp/blob-err.log 2>/dev/null | tr '\n' ' ')
      echo "::warning::Blob upload failed for $BASENAME ($SIZE bytes) — will render as fallback link. API err: ${ERR_TAIL:-<empty>}"
    fi
  done
  if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "::warning::Screenshot upload: $UPLOAD_COUNT/$TOTAL_COUNT succeeded ($FAILED_COUNT failed). Failed images fall back to 'see build artifacts' text in the review body."
  fi

  if [ "$UPLOAD_COUNT" -gt 0 ]; then
    echo "$TREE_ENTRIES" > /tmp/tree-entries.json
    # Use base_tree to preserve existing pr-NNN/ dirs from other PRs
    if [ -n "$BASE_TREE" ]; then
      TREE=$(GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/trees" --method POST \
        --input <(jq -n --arg bt "$BASE_TREE" --slurpfile t /tmp/tree-entries.json '{"base_tree":$bt,"tree":$t[0]}') \
        --jq '.sha' 2>/dev/null) || true
    else
      TREE=$(GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/trees" --method POST \
        --input <(jq -n --slurpfile t /tmp/tree-entries.json '{"tree":$t[0]}') \
        --jq '.sha' 2>/dev/null) || true
    fi
    # Orphan commit (no parent) — always 1 commit, force-replaced
    COMMIT=$(GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/commits" --method POST \
      -f "message=Review screenshots (auto-replaced)" -f "tree=$TREE" --jq '.sha' 2>/dev/null) || true
    if [ -n "$COMMIT" ]; then
      if [ -n "$BASE_SHA" ]; then
        GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/refs/heads/review-assets" \
          --method PATCH -f sha="$COMMIT" -F force=true >/dev/null 2>&1
      else
        GH_TOKEN="$GITHUB_REPO_TOKEN" gh api "repos/$GITHUB_REPOSITORY/git/refs" \
          --method POST -f ref="refs/heads/review-assets" -f sha="$COMMIT" >/dev/null 2>&1
      fi
      echo "Uploaded $UPLOAD_COUNT/$TOTAL_COUNT screenshots (1 orphan commit, old URLs preserved)"
    fi
  fi
fi

# ── Round-2 body inputs ──
# The thread classifier (review-thread-classifier skill) wrote a single
# unified file at /tmp/thread-resolution.json with entries for prior
# findings AND open inline threads (own bot + other bots + humans),
# distinguished by the `source` field. The body composition below renders
# only `source: "prior_finding"` entries in the "Since previous review"
# section — inline-thread RESOLVED entries drive the poster's per-comment
# reply, not the body.
RESOLVED_LIST="[]"
STILL_PRESENT_LIST="[]"
if [ -f /tmp/thread-resolution.json ] && jq -e 'type == "array"' /tmp/thread-resolution.json >/dev/null 2>&1; then
  RESOLVED_LIST=$(jq '[.[] | select(.source == "prior_finding" and .status == "RESOLVED")]' /tmp/thread-resolution.json)
  STILL_PRESENT_LIST=$(jq '[.[] | select(.source == "prior_finding" and .status == "STILL_PRESENT")]' /tmp/thread-resolution.json)
  TOTAL_RESOLVED=$(jq '[.[] | select(.status == "RESOLVED")] | length' /tmp/thread-resolution.json)
  TOTAL_STILL=$(jq '[.[] | select(.status == "STILL_PRESENT")] | length' /tmp/thread-resolution.json)
  TOTAL_NEW_CTX=$(jq '[.[] | select(.status == "NEW_CONTEXT")] | length' /tmp/thread-resolution.json)
  echo "Thread resolution: total=$TOTAL_RESOLVED RESOLVED / $TOTAL_STILL STILL_PRESENT / $TOTAL_NEW_CTX NEW_CONTEXT (prior_finding subset: $(echo "$RESOLVED_LIST" | jq 'length') / $(echo "$STILL_PRESENT_LIST" | jq 'length') / -)"
fi

# ── Determine verdict ──
HAS_BLOCKING=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "critical" or .severity == "major")] | length > 0')
HAS_ANY=$(echo "$ALL_FINDINGS" | jq 'length > 0')
HUMAN_REVIEW=$(echo "$CORE_META" | jq -r '.requires_human_review // false')

# Spec-presence gate. The core reviewer judges whether a human-authored spec
# source is available (linked issue, PRD, external tracker, or substantive
# manual PR body) and sets manual_spec_present in core-meta.json. Without a
# spec we cannot validate "code matches requirements" — auto-generated PR
# descriptions (Cursor/Bugbot/CodeRabbit/Gemini/Claude Code) summarise the
# diff, they don't define it. `// true`-style defaults are wrong here because
# jq's `//` treats explicit `false` as missing — `false // true` is `true`.
# Use `if has() then ... else` instead, but type-guard with `type == "object"`
# because `has()` crashes on non-object JSON (null, arrays) and our
# `is_valid_json` check only verifies parseability, not shape.
MANUAL_SPEC_PRESENT=$(echo "$CORE_META" | jq -r 'if (type == "object" and has("manual_spec_present")) then .manual_spec_present else true end')

# Smoke-test gate. The test planner flags PRs whose stated intent is "no
# user-visible behavior change" (refactor, upgrade, library swap, perf
# rewrite, build/config change) by emitting `## Technical change: true` in
# test-plan.md. These PRs have no acceptance criteria to validate against —
# specs by design say "nothing should change" — so the only regression-
# catching path is to actually run the app. APPROVE is withheld unless the
# smoke run came back PASS or WARN. This fires both when the smoke run
# failed AND when it couldn't run at all (no dev-start.sh in the consumer
# repo, or tester crashed).
#
# Read directly from test-plan.md, NOT functional-meta.json. The planner
# always writes test-plan.md to completion before the tester runs, so the
# flag survives tester crashes. Reading from functional-meta.json would be
# defeated by the workflow's synthetic `{strategy:"skip",overall:"PASS"}`
# crash placeholder, which would silently bypass exactly the case the gate
# needs to catch (tester didn't actually run). The tester ALSO copies the
# flag into functional-meta.json for the JSON artifact record, but that's
# a secondary record — this is the source of truth.
TECHNICAL_CHANGE=false
if [ -f test-plan.md ] && grep -qiE '^## *Technical change: *true *$' test-plan.md; then
  TECHNICAL_CHANGE=true
fi

# Planner's intended strategy, read directly from test-plan.md so the
# inheritance branch below can distinguish "planner deliberately chose
# skip" (round-2 since-last is non-user-observable) from "planner wanted a
# smoke but the workflow couldn't launch one" (degraded mode: no
# dev-start.sh, web not ready, no functional-prompt). Both end up with
# the same synthetic `{strategy:"skip",overall:"PASS"}` placeholder in
# functional-meta.json, so FUNCTIONAL_STRATEGY alone can't tell them
# apart. The same parser as in pr-review.yml's strategy resolution.
PLANNED_STRATEGY=""
if [ -f test-plan.md ]; then
  PLANNED_STRATEGY=$(grep -m1 -iE '^## Strategy:' test-plan.md 2>/dev/null \
    | sed -E 's/.*Strategy:[[:space:]]*//' \
    | sed -E 's/[^a-zA-Z-]//g' \
    | tr '[:upper:]' '[:lower:]' || true)
fi

# Did the smoke test actually pass? Three failure modes to disqualify:
#
#   1. Tester crashed (FUNCTIONAL_OK != 1).
#   2. Tester was never launched — the WEB_READY=false / no-dev-start.sh
#      path in pr-review.yml short-circuits before launching the agent and
#      sets FUNCTIONAL_OK=1 ("skipped = OK"), then writes the synthetic
#      `{strategy:"skip",overall:"PASS"}` placeholder. STRATEGY="skip" is
#      the reliable signal that the tester didn't actually run, since the
#      planner sets strategy="functional" or "quick" for any tech PR.
#   3. Tester ran but reported FAIL.
#
# Without (2), a technical PR in a repo without dev-start.sh would silently
# bypass the gate via the synthetic PASS placeholder — exactly the case
# Cursor flagged on the previous commit.
#
# Round-2 inheritance: when the planner deliberately picks strategy=skip
# because since-last has no user-observable surface (comments / log strings /
# types / internal helpers), the prior round's PASS/WARN smoke result still
# applies — observable behavior didn't change. We inherit it so a one-line
# follow-up doesn't drop APPROVE → COMMENT just to re-prove the same flow.
# Inheritance only kicks in when the PLANNER chose skip (PLANNED_STRATEGY
# from test-plan.md), AND on prior PASS/WARN. Degraded-mode runs (planner
# wanted functional, workflow couldn't launch) fall through to no inherit
# even when prior is PASS/WARN — those have no current smoke evidence.
SMOKE_OK=false
SMOKE_INHERITED=false
if [ "${FUNCTIONAL_OK:-1}" -ne 1 ]; then
  :  # tester crashed
elif [ "$FUNCTIONAL_STRATEGY" = "skip" ]; then
  if [ "$PLANNED_STRATEGY" = "skip" ] && { [ "$PRIOR_FUNCTIONAL_OVERALL" = "PASS" ] || [ "$PRIOR_FUNCTIONAL_OVERALL" = "WARN" ]; }; then
    SMOKE_OK=true
    SMOKE_INHERITED=true
    echo "::notice::Smoke gate inherited from prior round (functional_overall=$PRIOR_FUNCTIONAL_OVERALL, strategy=$PRIOR_FUNCTIONAL_STRATEGY) — current planner chose strategy=skip because since-last has no user-observable surface."
  fi
  # else: tester never launched (degraded mode), planner wanted a smoke but couldn't get one,
  # OR no prior to inherit — no smoke evidence either way.
elif [ "$FUNCTIONAL_OVERALL" = "PASS" ] || [ "$FUNCTIONAL_OVERALL" = "WARN" ]; then
  SMOKE_OK=true
fi

# Judge-health safety gate. The orchestrator's degraded paths (both
# judges crashed, or context-builder crashed) write `/tmp/all-findings.json
# = []` and a meta with `judge_health.{opus,haiku,cb}` set to "failed"
# / `*_failed: true`. With an empty findings array, the per-PR ladder
# below would otherwise reach APPROVE — contradicting the "Both judges
# failed" banner the body renders. Force COMMENT here so the verdict
# matches the banner. Single-judge failure is NOT downgraded — the
# orchestrator already proceeded with the surviving judge's output, and
# that's a legitimate review.
JUDGES_BOTH_FAILED=$(echo "$CORE_META" | jq -r '
  # Strict-equality predicates throughout. jq treats any non-false/non-null
  # value as truthy in `or`, so an LLM emitting `"both_failed": "false"`
  # (string instead of boolean) under `// false` would resolve to the
  # truthy string and false-trigger the gate. Compare against the literal
  # boolean / string instead.
  def is_failed_str(field): if has(field) then (.[field] == "failed") else false end;
  def is_true_bool(field): if has(field) then (.[field] == true) else false end;
  if (type == "object" and (.judge_health // null | type == "object")) then
    (.judge_health |
      is_true_bool("both_failed")
      or is_true_bool("cb_failed")
      or (is_failed_str("opus") and is_failed_str("haiku"))
    )
  else false end')

# Functional MCP gate. The functional-tester subagent's first turn is a
# smoke check that calls mcp__playwright__browser_navigate to about:blank;
# on failure it writes overall=CRASH and exits before running scenarios.
# Even with that loud-fail in place, a defence-in-depth string match here
# catches the historical silent-fallback string in uncertain_observations
# ("Playwright MCP tools were not available...") in case a future skill
# regression re-introduces the curl-only path. Either signal forces COMMENT
# + requires_human_review because we have NO UI evidence on a run that the
# planner said needed UI testing.
FUNCTIONAL_MCP_BROKEN=false
FUNCTIONAL_MCP_BROKEN_REASON=""
if [ "$FUNCTIONAL_OVERALL" = "CRASH" ] && echo "$FUNCTIONAL_META" | jq -e '(.summary // "") | test("Playwright MCP unavailable"; "i")' >/dev/null 2>&1; then
  FUNCTIONAL_MCP_BROKEN=true
  FUNCTIONAL_MCP_BROKEN_REASON="Playwright MCP smoke check failed — UI scenarios were not exercised. The .claude/agents/review-functional-tester.md subagent's inline mcpServers definition could not start the @playwright/mcp stdio server. Check the runner has network + npx access; check the 'Install Playwright + MCP' workflow step output."
elif { [ "$FUNCTIONAL_STRATEGY" = "functional" ] || [ "$FUNCTIONAL_STRATEGY" = "quick" ]; } \
     && echo "$FUNCTIONAL_META" | jq -e '[(.uncertain_observations // [])[] | select(test("Playwright MCP.*not.*avail|MCP.*unavailable|fall.*back to curl|all testing was done via curl"; "i"))] | length > 0' >/dev/null 2>&1; then
  # Both `functional` and `quick` strategies dispatch the Playwright-bound
  # functional tester; only `skip` and `pipeline-self-test` are MCP-free.
  # Earlier the gate checked only `functional` and would have let a quick
  # smoke run silent-fall-back to curl without flagging it.
  FUNCTIONAL_MCP_BROKEN=true
  FUNCTIONAL_MCP_BROKEN_REASON="Functional tester admitted in uncertain_observations that Playwright MCP was unavailable and tests fell back to curl/psql (strategy=$FUNCTIONAL_STRATEGY). UI-touching changes need UI evidence; the smoke-check loud-fail in skills/review-functional-tester.md should have caught this — investigate why it was bypassed."
fi

if [ "$HAS_BLOCKING" = "true" ]; then
  VERDICT="REQUEST_CHANGES"
elif [ "$HUMAN_REVIEW" = "true" ]; then
  VERDICT="COMMENT"
elif [ "$JUDGES_BOTH_FAILED" = "true" ]; then
  VERDICT="COMMENT"
  echo "::warning::Both judges (or context builder) failed — downgrading APPROVE to COMMENT. Body banner explains."
elif [ "$MANUAL_SPEC_PRESENT" = "false" ]; then
  VERDICT="COMMENT"
  echo "::warning::No manual spec available — downgrading APPROVE to COMMENT (core reviewer set manual_spec_present=false)"
elif [ "$FUNCTIONAL_MCP_BROKEN" = "true" ]; then
  VERDICT="COMMENT"
  HUMAN_REVIEW="true"
  CORE_META=$(echo "$CORE_META" | jq --arg r "$FUNCTIONAL_MCP_BROKEN_REASON" '. + {requires_human_review: true, requires_human_review_reason: $r}')
  echo "::warning::Playwright MCP unavailable — downgrading APPROVE to COMMENT and flagging for human review. Reason: $FUNCTIONAL_MCP_BROKEN_REASON"
elif [ "$TECHNICAL_CHANGE" = "true" ] && [ "$SMOKE_OK" = "false" ]; then
  VERDICT="COMMENT"
  echo "::warning::Technical change without successful smoke test (overall=$FUNCTIONAL_OVERALL, ok=${FUNCTIONAL_OK:-1}) — downgrading APPROVE to COMMENT"
elif [ "$HAS_ANY" = "true" ]; then
  VERDICT="COMMENT"
else
  VERDICT="APPROVE"
fi

# ── Round-2 verdict adjustment ──
# Validate prior state and resolution status by parsing, not by file
# existence. A file that's present but malformed used to satisfy the gate
# and silently let REQUEST_CHANGES → APPROVE downgrades through.
#
#   ROUND2_VALID=true     prior state file parses + has the expected shape
#                         AND the workflow signalled PRIOR_STATE_AVAILABLE.
#   RESOLUTION_VALID=true /tmp/thread-resolution.json parses as a JSON array
#                         (matches the resolution-checker output contract).
#
# When ROUND2_VALID + RESOLUTION_VALID are both true, run the case statement
# (the same spec as before). When ROUND2_VALID alone is true, we're in
# degraded round-2: pin VERDICT = max(PRIOR_VERDICT, current VERDICT) so we
# never silently downgrade. New blockers still escalate via the per-PR
# ladder above (HAS_BLOCKING=true → VERDICT=REQUEST_CHANGES already).
ROUND2_PRESENT=false
ROUND2_VALID=false
if [ "${PRIOR_STATE_AVAILABLE:-false}" = "true" ]; then
  ROUND2_PRESENT=true
  if jq -e 'type == "object" and has("verdict") and has("findings")' \
       /tmp/prior-state/review-state.json >/dev/null 2>&1; then
    ROUND2_VALID=true
  fi
fi

# Capture the per-PR ladder's verdict BEFORE any round-2 logic touches it
# so we can detect ladder overrides below and surface a one-line rationale
# in the review body. Without this the body's narrative ("Would APPROVE on
# this round") can disagree with the header — exactly the contradiction
# observed on Panenco/qiv#292. Initialised here (above the malformed-state
# branch) so EVERY round-2 path uses the same baseline.
PER_PR_VERDICT="$VERDICT"
LADDER_OVERRIDE_REASON=""

# When the workflow signalled prior state is present but the file fails
# the schema check (truncated upload, schema drift, agent crashed
# mid-write), treat it as fail-closed degraded round-2: pin via
# verdict_max with the best-effort prior verdict we can extract. Without
# this, a malformed state file used to skip the entire round-2 block
# and silently fall through to the per-PR ladder — REQUEST_CHANGES could
# downgrade to APPROVE just because the state file was corrupt.
if [ "$ROUND2_PRESENT" = "true" ] && [ "$ROUND2_VALID" = "false" ]; then
  BEST_EFFORT_PRIOR=$(jq -r '.verdict // empty' /tmp/prior-state/review-state.json 2>/dev/null || echo "")
  VERDICT=$(verdict_max "${BEST_EFFORT_PRIOR:-REQUEST_CHANGES}" "$PER_PR_VERDICT")
  echo "::warning::Round-2 state file failed schema check (prior_state_available=true but jq parse rejected /tmp/prior-state/review-state.json) — pinning verdict to max(best_effort_prior='${BEST_EFFORT_PRIOR:-REQUEST_CHANGES}', current=$PER_PR_VERDICT)=$VERDICT. Investigate the upload step + state-artifact integrity."
  if [ "$VERDICT" != "$PER_PR_VERDICT" ]; then
    LADDER_OVERRIDE_REASON="prior state file failed schema check; pinned to the more severe of (best-effort prior='${BEST_EFFORT_PRIOR:-REQUEST_CHANGES}', per-PR='$PER_PR_VERDICT')"
  fi
fi

RESOLUTION_VALID=false
# Validate shape: must be a JSON array AND every entry must have the .id,
# .source, and .status fields the verdict gate's id-join needs. A
# `type == "array"` check alone allowed entries missing .id to silently
# slip through — `map(.id)` would yield [null,null,...], `index($id)`
# would never match, and STILL_PRESENT_BLOCKERS would be 0 even when prior
# blockers persisted, letting REQUEST_CHANGES → APPROVE through the gate.
#
# Cross-check: when prior-state.findings has N entries the thread classifier
# MUST produce at least N entries with `source: "prior_finding"` (one per
# prior finding — inline-thread entries from streams 2/3/4 are extra).
# A shorter prior_finding subset means the agent crashed mid-write and the
# verdict gate would treat un-listed priors as zero-still-present —
# fail-open. We require prior_finding-subset length >= prior-findings
# length OR prior had no findings (length 0 is a legitimate "nothing to
# classify"). `jq -e all(...)` on an empty array returns true (vacuous
# truth) — the length cross-check below catches a crashed `[]` write.
if [ "$ROUND2_VALID" = "true" ] \
   && jq -e 'type == "array" and all(type == "object" and has("id") and has("source") and has("status"))' \
        /tmp/thread-resolution.json >/dev/null 2>&1; then
  PRIOR_FINDINGS_LEN=$(jq '.findings | length' /tmp/prior-state/review-state.json 2>/dev/null || echo 0)
  RESOLUTION_LEN=$(jq '[.[] | select(.source == "prior_finding")] | length' /tmp/thread-resolution.json 2>/dev/null || echo 0)
  if [ "$RESOLUTION_LEN" -ge "$PRIOR_FINDINGS_LEN" ]; then
    RESOLUTION_VALID=true
  else
    echo "::warning::Round-2: thread-resolution.json has $RESOLUTION_LEN prior_finding entries but prior-state.findings has $PRIOR_FINDINGS_LEN — classifier likely crashed mid-write. Treating resolution as unknown (degraded round-2)."
  fi
fi

if [ "$ROUND2_VALID" = "true" ]; then
  PRIOR_VERDICT=$(jq -r '.verdict // "MISSING"' /tmp/prior-state/review-state.json)
  PRIOR_BLOCKERS=$(jq -r '[.findings[]? | select(.severity == "critical" or .severity == "major")] | length' /tmp/prior-state/review-state.json)

  if [ "$RESOLUTION_VALID" = "true" ]; then
    # Derive the still-present blocker count by id-joining STILL_PRESENT
    # entries against prior-state.findings, instead of trusting the
    # resolution checker's `prior_severity` field. The verdict gate must
    # not ride on LLM compliance: if the agent forgets or mistypes
    # `prior_severity`, an approve-via-zero-blockers slips through.
    STILL_PRESENT_BLOCKERS=$(jq -n \
      --slurpfile state /tmp/prior-state/review-state.json \
      --argjson still "$STILL_PRESENT_LIST" \
      '($still | map(.id)) as $ids
       | ($state[0].findings // [])
       | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
       | length')
    echo "Round-2 verdict input: prior_verdict=$PRIOR_VERDICT prior_blockers=$PRIOR_BLOCKERS still_present_blockers=$STILL_PRESENT_BLOCKERS new_blocking=$HAS_BLOCKING current_verdict=$VERDICT"
    case "$PRIOR_VERDICT" in
      REQUEST_CHANGES)
        if [ "$STILL_PRESENT_BLOCKERS" -gt 0 ]; then
          VERDICT="REQUEST_CHANGES"
          echo "::notice::Round-2: $STILL_PRESENT_BLOCKERS prior blocking finding(s) still present — keeping REQUEST_CHANGES."
          # Only call this an override if the per-PR ladder hadn't
          # already landed on REQUEST_CHANGES — otherwise it's a
          # confirmation, not an override, and the body shouldn't
          # narrate it as one.
          if [ "$PER_PR_VERDICT" != "REQUEST_CHANGES" ]; then
            LADDER_OVERRIDE_REASON="$STILL_PRESENT_BLOCKERS prior blocking finding(s) from the previous review are still present in the diff"
          fi
        else
          # No new blockers and all prior blockers resolved (or there
          # never were any). Locked decision: per-PR ladder unconditionally
          # — APPROVE if no new findings, COMMENT if any minor remain.
          echo "::notice::Round-2: prior REQUEST_CHANGES, all blockers resolved (still_present=0, prior_blockers=$PRIOR_BLOCKERS) — using per-PR verdict '$VERDICT'."
        fi
        ;;
      COMMENT)
        # Anti-downgrade is moot here: prior=COMMENT had no blockers to
        # preserve. The per-PR verdict stands. If the LLM keeps flagging
        # the same minor finding it stays COMMENT; if it stops, APPROVE.
        # The previous behavior pinned APPROVE → COMMENT to avoid "auto-
        # approving on a follow-up", but the bot's verdict has no notion
        # of human approval — pinning was the source of the contradiction
        # observed on Panenco/qiv#292.
        :
        ;;
      APPROVE)
        # Per-PR verdict already escalates to REQUEST_CHANGES via the
        # primary ladder when HAS_BLOCKING=true, so no override is needed.
        :
        ;;
      *)
        # Unrecognized verdict (state file parses as object with `.verdict`
        # but the value is not a known enum). Fail closed via verdict_max.
        echo "::warning::Round-2: unrecognized prior_verdict='$PRIOR_VERDICT'. Pinning to max(prior,current)."
        VERDICT=$(verdict_max "$PRIOR_VERDICT" "$VERDICT")
        if [ "$VERDICT" != "$PER_PR_VERDICT" ]; then
          LADDER_OVERRIDE_REASON="prior verdict '$PRIOR_VERDICT' was not a recognized value; failed closed to the more severe of (prior, per-PR)"
        fi
        ;;
    esac
  else
    # Degraded round-2: prior state is valid but thread-resolution.json
    # is missing or malformed (thread classifier didn't run, since-last.diff
    # couldn't be computed, or the agent crashed). Pin VERDICT to the
    # more-severe of (PRIOR_VERDICT, current per-PR VERDICT) — never
    # silently downgrade REQUEST_CHANGES.
    DEGRADED_REASON="missing"
    [ -f /tmp/thread-resolution.json ] && DEGRADED_REASON="malformed"
    VERDICT=$(verdict_max "$PRIOR_VERDICT" "$PER_PR_VERDICT")
    echo "::warning::Round-2 degraded: thread-resolution.json $DEGRADED_REASON — pinned verdict to max(prior=$PRIOR_VERDICT, current=$PER_PR_VERDICT)=$VERDICT."
    if [ "$VERDICT" != "$PER_PR_VERDICT" ]; then
      LADDER_OVERRIDE_REASON="prior verdict was $PRIOR_VERDICT and the round-2 thread-resolution was $DEGRADED_REASON; pinned to the more severe of (prior, per-PR) so we never silently downgrade"
    fi
  fi
fi

echo "Verdict: $VERDICT (blocking=$HAS_BLOCKING, any=$HAS_ANY, human=$HUMAN_REVIEW, manual_spec=$MANUAL_SPEC_PRESENT, technical_change=$TECHNICAL_CHANGE, smoke_ok=$SMOKE_OK, functional=$FUNCTIONAL_OVERALL)"

# ── Build review-result.json ──
# The previous architecture wrote a synthetic `{strategy:"skip",overall:"PASS"}`
# placeholder when the functional tester crashed without writing meta,
# and an override here flipped that to `strategy:"crashed",overall:"CRASH"`
# for the JSON artifact. The single-orchestrator architecture writes the
# crashed sentinel directly (see review-orchestrator.md "Per-subagent
# failure handling"), so the override branch is no longer reachable.
# Cursor flagged it as dead code on PR #29 commit 8ffb593.
JSON_FUNCTIONAL_META="$FUNCTIONAL_META"

SPEC_COMPLIANCE=$(echo "$CORE_META" | jq -r '.spec_compliance // ""')
VERDICT_SUMMARY=$(echo "$CORE_META" | jq -r '.verdict_summary // ""')
FUNCTIONAL_SUMMARY_TEXT=$(echo "$FUNCTIONAL_META" | jq -r '.summary // ""')
if [ "$(echo "$ALL_FINDINGS" | jq 'length')" -eq 0 ]; then
  SUMMARY="${SPEC_COMPLIANCE:-No issues found. Code reviewed for correctness, spec compliance, security, consistency, and performance.}"
else
  SUMMARY=$(echo "$ALL_FINDINGS" | jq -r '[.[] | "\(.severity): \(.title)"] | join("; ")' | head -c 200)
fi

jq -n \
  --arg pr "$PR_NUMBER" \
  --arg verdict "$VERDICT" \
  --arg summary "$SUMMARY" \
  --arg spec_compliance "$SPEC_COMPLIANCE" \
  --arg verdict_summary "$VERDICT_SUMMARY" \
  --arg technical_change "$TECHNICAL_CHANGE" \
  --arg smoke_ok "$SMOKE_OK" \
  --argjson findings "$ALL_FINDINGS" \
  --argjson meta "$CORE_META" \
  --argjson functional_meta "$JSON_FUNCTIONAL_META" \
  '{
    pr_number: ($pr | tonumber),
    verdict: $verdict,
    summary: $summary,
    spec_compliance: $spec_compliance,
    verdict_summary: $verdict_summary,
    spec_sources: ($meta.spec_sources // {linked_issue: null, external_issue: null, prd_path: null, convention_rules: []}),
    manual_spec_present: (if ($meta | type == "object" and has("manual_spec_present")) then $meta.manual_spec_present else true end),
    technical_change: ($technical_change == "true"),
    smoke_ok: ($smoke_ok == "true"),
    findings: $findings,
    requires_human_review: ($meta.requires_human_review // false),
    requires_human_review_reason: ($meta.requires_human_review_reason // null),
    uncertain_observations: (($meta.uncertain_observations // []) + ($functional_meta.uncertain_observations // [])),
    prompt_injection_detected: ($meta.prompt_injection_detected // false),
    reviewer_self_modification: ($meta.reviewer_self_modification // false),
    functional_validation: {
      strategy: ($functional_meta.strategy // "skip"),
      overall: ($functional_meta.overall // "N/A"),
      areas_tested: ($functional_meta.areas_tested // []),
      screenshot_count: (($functional_meta.screenshots // []) | map(select((.file // "") | test("\\.(png|jpg|jpeg|webp)$"; "i"))) | length)
    }
  }' > review-result.json

# ── Build /tmp/review-body.md ──
# `linked_issue` is the GitHub-native issue number (from closingIssuesReferences).
# `external_issue` is the tracker identifier (e.g. ABC-123) surfaced by the
# consumer's optional fetch-issue.sh hook. Show #N when present, otherwise the
# external identifier, falling back to "none found" only when neither exists.
ISSUE=$(jq -r '.spec_sources.linked_issue // "none found"' review-result.json)
EXTERNAL=$(jq -r '.spec_sources.external_issue // empty' review-result.json)
{
  echo "## Claude PR Review — $VERDICT"
  echo ""
  echo "### Spec sources"
  echo ""
  if [ "$ISSUE" != "null" ] && [ "$ISSUE" != "none found" ]; then
    if [ -n "$EXTERNAL" ] && [ "$EXTERNAL" != "null" ]; then
      echo "- Linked issue: #$ISSUE (external tracker: $EXTERNAL)"
    else
      echo "- Linked issue: #$ISSUE"
    fi
  elif [ -n "$EXTERNAL" ] && [ "$EXTERNAL" != "null" ]; then
    echo "- Linked issue: $EXTERNAL (external tracker)"
  else
    echo "- Linked issue: none found"
  fi
  RULES=$(jq -r '.spec_sources.convention_rules // [] | map("`\(.)`") | join(", ")' review-result.json)
  echo "- Convention rules: ${RULES:-none identified}"
  echo ""
  # Verdict summary — the human-assist field. The reviewer's verdict_summary
  # explains in 3-4 sentences what the PR does + why this verdict + (when
  # COMMENT-due-to-no-spec) what the hypothetical APPROVE/REQUEST_CHANGES
  # would have been. Falls back to spec_compliance for older runs that
  # didn't fill verdict_summary, then to a generic line for clean APPROVEs.
  if [ -n "$VERDICT_SUMMARY" ] && [ "$VERDICT_SUMMARY" != "null" ]; then
    echo "$VERDICT_SUMMARY"
    echo ""
  elif [ -n "$SPEC_COMPLIANCE" ] && [ "$SPEC_COMPLIANCE" != "null" ]; then
    echo "$SPEC_COMPLIANCE"
    echo ""
  elif [ "$VERDICT" = "APPROVE" ]; then
    echo "No issues found. Code reviewed for correctness, spec compliance, security, consistency, test quality, and performance."
    echo ""
  fi
  # Single-line state banners — the verdict_summary above carries the why.
  # Round-2 ladder override (when set): explain why the verdict differs
  # from the bot's per-PR judgement so body and header never disagree.
  if [ -n "$LADDER_OVERRIDE_REASON" ] && [ "$VERDICT" != "$PER_PR_VERDICT" ]; then
    echo "> :information_source: **Verdict pinned to \`$VERDICT\`** by the round-2 ladder (per-PR judgement was \`$PER_PR_VERDICT\`; $LADDER_OVERRIDE_REASON)."
    echo ""
  fi
  # Dismissal acknowledgement: the prior round's review was dismissed by
  # the author, so the round-2 ladder is treating prior=APPROVE. Surface
  # this so the reader knows the bot saw the dismissal.
  if [ "$PRIOR_DISMISSED" = "true" ]; then
    echo "> :wave: **Prior review dismissed by author** — treating earlier findings as accepted/false-positive for ladder purposes. New findings on this round are evaluated independently."
    echo ""
  fi
  if [ "$MANUAL_SPEC_PRESENT" = "false" ]; then
    echo "> :no_entry: **APPROVE withheld — no spec.** Link an issue, paste acceptance criteria into the PR body, or wire up the external tracker."
    echo ""
  fi
  if [ "$TECHNICAL_CHANGE" = "true" ] && [ "$SMOKE_OK" = "false" ]; then
    echo "> :no_entry: **APPROVE withheld — smoke test did not pass** (overall=\`$FUNCTIONAL_OVERALL\`). Configure \`.github/claude-review/dev-start.sh\` or fix the smoke run."
    echo ""
  fi
  if [ "$(jq -r '.requires_human_review' review-result.json)" = "true" ]; then
    echo "> :stop_sign: **Human review required** — $(jq -r '.requires_human_review_reason // ""' review-result.json)"
    echo ""
  fi
  # Surface judge-debate health in the body so a reader can see at a glance
  # whether one of the two judges failed (the orchestrator proceeded with
  # the survivor) and how many rebuttal rounds it took to converge.
  JUDGE_HEALTH_RAW=$(echo "$CORE_META" | jq -c '.judge_health // {}' 2>/dev/null || echo '{}')
  OPUS_OK=$(echo "$JUDGE_HEALTH_RAW" | jq -r '.opus // "unknown"')
  HAIKU_OK=$(echo "$JUDGE_HEALTH_RAW" | jq -r '.haiku // "unknown"')
  REBUTTAL_ROUNDS=$(echo "$JUDGE_HEALTH_RAW" | jq -r '.rebuttal_rounds // 0')
  AGREED_AT=$(echo "$JUDGE_HEALTH_RAW" | jq -r '.agreed_at // "unknown"')
  if [ "$OPUS_OK" = "failed" ] && [ "$HAIKU_OK" = "failed" ]; then
    echo "> :warning: **Both judges failed** — review is empty or partial. Re-run the workflow."
    echo ""
  elif [ "$OPUS_OK" = "failed" ]; then
    echo "> :warning: **Opus judge failed** — review consolidated from the Haiku judge alone. Recall on subtle reasoning may be incomplete."
    echo ""
  elif [ "$HAIKU_OK" = "failed" ]; then
    echo "> :warning: **Haiku judge failed** — review consolidated from the Opus judge alone. Mechanical-find recall (lints, obvious misses) may be incomplete."
    echo ""
  elif [ "$REBUTTAL_ROUNDS" != "0" ] && [ "$AGREED_AT" = "none" ]; then
    echo "> :scales: **Judges did not converge** after $REBUTTAL_ROUNDS rebuttal round(s) — final findings are the union, verdict is the more severe of the two."
    echo ""
  fi
  # Round-2 only: surface what the resolution checker found.
  # The body lists each prior finding by id + its original title so the
  # reader can recognise the issue at a glance. The full evidence (and
  # diff-hunk references) lives on the auto-resolved source thread, not
  # here — keeps the body scannable instead of pasting diff syntax.
  RESOLVED_N=$(echo "$RESOLVED_LIST" | jq 'length')
  STILL_N=$(echo "$STILL_PRESENT_LIST" | jq 'length')
  if [ "$RESOLVED_N" -gt 0 ] || [ "$STILL_N" -gt 0 ]; then
    PRIOR_FINDINGS_JSON='[]'
    [ -f /tmp/prior-state/review-state.json ] \
      && PRIOR_FINDINGS_JSON=$(jq '.findings // []' /tmp/prior-state/review-state.json 2>/dev/null || echo '[]')
    echo "### Since previous review"
    echo ""
    # Helper jq: join an entry against prior findings on .id, return the
    # prior title (or fall back to a 100-char clipped evidence if the
    # title is missing). Defensive against malformed prior state.
    JOIN_TITLE='
      . as $entry
      | ($prior // []) as $p
      | ($p | map(select(.id == $entry.id)) | .[0]) as $f
      | ($f.title // ($entry.evidence // ""))
      | (if length > 120 then .[:117] + "..." else . end)
    '
    if [ "$RESOLVED_N" -gt 0 ]; then
      echo "**Resolved (${RESOLVED_N}):**"
      echo "$RESOLVED_LIST" | jq -r --argjson prior "$PRIOR_FINDINGS_JSON" \
        '.[] | "- `\(.id)` — " + ('"$JOIN_TITLE"')'
      echo ""
    fi
    if [ "$STILL_N" -gt 0 ]; then
      echo "**Still present (${STILL_N}):**"
      echo "$STILL_PRESENT_LIST" | jq -r --argjson prior "$PRIOR_FINDINGS_JSON" \
        '.[] as $e
         | ($prior | map(select(.id == $e.id)) | .[0]) as $f
         | "- `\($e.id)` (\($e.prior_severity // ($f.severity // "?"))) — " + (
             ($f.title // ($e.evidence // ""))
             | (if length > 120 then .[:117] + "..." else . end)
           )'
      echo ""
    fi
  fi
} > /tmp/review-body.md

# ── Append functional validation section ──
TEST_PLAN_EXISTS="false"
[ -f test-plan.md ] && TEST_PLAN_EXISTS="true"

# Count only image-typed entries — see review-result.json's
# screenshot_count above for the rationale.
FUNCTIONAL_SCREENSHOT_COUNT=$(echo "$FUNCTIONAL_META" | jq '(.screenshots // []) | map(select((.file // "") | test("\\.(png|jpg|jpeg|webp)$"; "i"))) | length')
FUNCTIONAL_OK="${FUNCTIONAL_OK:-1}"
if [ "$FUNCTIONAL_OVERALL" != "N/A" ] && [ "$FUNCTIONAL_STRATEGY" != "skip" ]; then
  # CRASH gets the ❌ marker — the orchestrator now writes
  # `strategy:"crashed",overall:"CRASH"` directly when the functional
  # subagent fails (review-orchestrator.md "Per-subagent failure
  # handling"), so this branch must render the failure clearly instead
  # of falling through to the default ✅. Without the explicit case a
  # crashed run got the green checkmark.
  EMOJI="✅"
  [ "$FUNCTIONAL_OVERALL" = "FAIL" ] && EMOJI="❌"
  [ "$FUNCTIONAL_OVERALL" = "CRASH" ] && EMOJI="❌"
  [ "$FUNCTIONAL_OVERALL" = "WARN" ] && EMOJI="⚠️"
  # Label depends on strategy: pipeline-self-test runs bash scripts (no
  # screenshots), Playwright runs are "Functional Validation" with shots.
  if [ "$FUNCTIONAL_STRATEGY" = "pipeline-self-test" ]; then
    PASS_COUNT=$(echo "$FUNCTIONAL_META" | jq -r '.pass // 0')
    TOTAL_COUNT=$(echo "$FUNCTIONAL_META" | jq -r '.total // 0')
    SECTION_HEADER="$EMOJI <b>Pipeline Self-Test — $FUNCTIONAL_OVERALL</b> (${PASS_COUNT}/${TOTAL_COUNT} bash test script(s) passed)"
  else
    SECTION_HEADER="$EMOJI <b>Functional Validation — $FUNCTIONAL_OVERALL</b> ($FUNCTIONAL_SCREENSHOT_COUNT screenshots)"
  fi
  {
    echo ""
    echo "<details>"
    echo "<summary>$SECTION_HEADER</summary>"
    echo ""
    if [ -n "$FUNCTIONAL_SUMMARY_TEXT" ] && [ "$FUNCTIONAL_SUMMARY_TEXT" != "null" ]; then
      echo "#### Summary"
      echo ""
      echo "$FUNCTIONAL_SUMMARY_TEXT"
      echo ""
    fi
    # Findings
    if [ -f /tmp/functional-findings.json ] && [ "$(jq 'length' /tmp/functional-findings.json)" -gt 0 ]; then
      echo "#### Issues found"
      echo ""
      jq -r '.[] |
        "- **[\(.severity | ascii_upcase)]** \(.title)\n" +
        "  <br/>_Evidence:_ " + (.evidence | gsub("\n"; " ") | .[:240]) + (if (.evidence | length) > 240 then "..." else "" end)
      ' /tmp/functional-findings.json
      echo ""
    fi
    # Screenshot gallery — render each as caption + inline image so the
    # whole gallery is visible at a glance once the parent Functional
    # Validation section is expanded. The previous form wrapped each shot
    # in its own <details>, which forced the reader to expand twice (once
    # for the section, once per screenshot) before seeing anything.
    # Skip non-image entries up front: the functional tester sometimes
    # records API-response JSON dumps as "screenshots" for API-only
    # scenarios; we only render actual image files so the body never
    # claims a screenshot exists when there is nothing to embed.
    if [ "$FUNCTIONAL_SCREENSHOT_COUNT" -gt 0 ]; then
      echo "#### Screenshots"
      echo ""
      echo "$FUNCTIONAL_META" | jq -r --argjson urls "$SCREENSHOT_URLS" \
        --arg repo "$GITHUB_REPOSITORY" --arg run "${GITHUB_RUN_ID:-}" '
        .screenshots[] |
        select((.file // "") | test("\\.(png|jpg|jpeg|webp)$"; "i")) |
        .file as $file |
        ($file | split("/") | last) as $basename |
        ($urls[$basename] // null) as $url |
        if $url then
          "**\(.description)**\n\n![\(.description)](\($url))\n"
        else
          "- **\(.description)** — *see [build artifacts](https://github.com/\($repo)/actions/runs/\($run))*\n"
        end
      '
    fi
    echo "</details>"
  } >> /tmp/review-body.md
elif [ "${FUNCTIONAL_OK:-1}" -eq 0 ] && [ "$TEST_PLAN_EXISTS" = "true" ]; then
  # Functional tester crashed but may have partial evidence
  FUNCTIONAL_ERROR=""
  [ -f /tmp/functional-output.txt ] && FUNCTIONAL_ERROR=$(tail -20 /tmp/functional-output.txt | head -c 500)
  CRASH_SHOT_COUNT=$(echo "$SCREENSHOT_URLS" | jq 'length')
  CRASH_FINDING_COUNT=0
  [ -f /tmp/functional-findings.json ] && CRASH_FINDING_COUNT=$(jq 'length' /tmp/functional-findings.json)
  {
    echo ""
    echo "<details>"
    echo "<summary>❌ Functional Validation — CRASHED ($CRASH_SHOT_COUNT screenshots, $CRASH_FINDING_COUNT partial findings)</summary>"
    echo ""
    echo "The functional tester agent did not complete (likely hit its turn budget). Partial evidence below."
    if [ "$CRASH_FINDING_COUNT" -gt 0 ]; then
      echo ""
      echo "**Partial findings:**"
      jq -r '.[] | "- **\(.title)**: \(.evidence[:200])"' /tmp/functional-findings.json
    fi
    if [ "$CRASH_SHOT_COUNT" -gt 0 ]; then
      echo ""
      echo "**Screenshots captured before crash:**"
      echo ""
      echo "$SCREENSHOT_URLS" | jq -r 'to_entries[] | "**\(.key)**\n\n![\(.key)](\(.value))\n"'
    fi
    if [ -n "$FUNCTIONAL_ERROR" ]; then
      echo ""
      echo "**Crash log (tail):**"
      echo ""
      echo '```'
      echo "$FUNCTIONAL_ERROR"
      echo '```'
    fi
    echo "</details>"
  } >> /tmp/review-body.md
fi

# Append run logs link
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  echo "" >> /tmp/review-body.md
  echo "[Run logs](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)" >> /tmp/review-body.md
fi

# ── Build /tmp/review-comments.json — inline comments ──
# Include reasoning and support multi-line comments.
# For test findings with screenshots, embed the image in the comment.
# Cap multi-line ranges at 10 lines.
echo "$ALL_FINDINGS" > /tmp/all-findings.json
echo "$SCREENSHOT_URLS" > /tmp/screenshot-urls.json
jq --slurpfile urls /tmp/screenshot-urls.json '[.[] |
  ($urls[0] // {}) as $url_map |
  (.screenshot // null) as $shot |
  (if $shot then ($shot | split("/") | last) else null end) as $basename |
  (if $basename then ($url_map[$basename] // null) else null end) as $shot_url |
  (((.line_end // .line_start // 0) - (.line_start // 0)) <= 10 and .line_start != .line_end) as $use_range |
  # Default to RIGHT (the new file). Reviewer skills set side:"LEFT" for
  # findings on deleted lines so the comment can anchor on the LEFT-side
  # of the diff hunk; without this, deleted-line findings get dropped at
  # the post-review.sh hunk-validation step.
  ((.side // "RIGHT") | ascii_upcase) as $side |
  (if $side == "LEFT" or $side == "RIGHT" then $side else "RIGHT" end) as $side |
  {
    path: .path,
    line: (.line_end // .line_start // 1),
    side: $side,
    body: (
      "**[\((.type // "finding") | ascii_upcase)]** \(.title // "Untitled")\n\n\(.reasoning // "")\n\n_Expected:_ \(.expected // "")"
      + (if .prd_quote then "\n\n_PRD:_ \(.prd_quote)" else "" end)
      + (if $shot_url then "\n\n![screenshot](\($shot_url))" else "" end)
      | if length > 65000 then .[:64997] + "..." else . end
    )
  } + (if $use_range then {start_line: .line_start, start_side: $side} else {} end)
]' /tmp/all-findings.json > /tmp/review-comments.json

# Also write findings.draft.json for artifact upload
cp /tmp/all-findings.json findings.draft.json

echo "review-result.json: $VERDICT, $(echo "$ALL_FINDINGS" | jq 'length') findings"
echo "review-comments.json: $(jq 'length' /tmp/review-comments.json) inline comments"

# ── Persist round-state for the next follow-up review ──
# The Upload review state workflow step packages this for cross-run pickup.
# Schema is documented in pr-review.yml (round-2 read step) and in
# skills/review-thread-classifier.md.
CURRENT_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
CURRENT_BASE_SHA=$(git merge-base HEAD "${GITHUB_BASE_REF:+origin/$GITHUB_BASE_REF}" 2>/dev/null || echo "")
PRIOR_HEAD_SHA_FROM_STATE=""
PRIOR_ROUND=1
if [ -f /tmp/prior-state/review-state.json ]; then
  PRIOR_HEAD_SHA_FROM_STATE=$(jq -r '.prior_head_sha // empty' /tmp/prior-state/review-state.json 2>/dev/null || echo "")
  PRIOR_ROUND=$(jq -r '.round // 1' /tmp/prior-state/review-state.json 2>/dev/null || echo "1")
fi
NEXT_ROUND=$((PRIOR_ROUND + 1))
[ -z "$PRIOR_HEAD_SHA_FROM_STATE" ] && NEXT_ROUND=1

# Decide what to persist for the NEXT round's inheritance check. Three cases:
#
#   1. SMOKE_INHERITED=true (planner picked skip + prior PASS/WARN inherited)
#      → carry the inherited values forward so a chain of internal-only
#        follow-ups keeps the smoke signal alive.
#   2. Tester actually ran (FUNCTIONAL_OK=1 AND FUNCTIONAL_STRATEGY != "skip")
#      → persist the real result.
#   3. Anything else (crashed, degraded mode, planner-chose-skip with no prior)
#      → persist empty so the next round CAN'T inherit. The synthetic
#        `{strategy:"skip",overall:"PASS"}` placeholder used by the workflow
#        when the tester didn't run would otherwise look like a legitimate
#        pass to the next round's inheritance check (Cursor #26 + Aikido
#        flagged this exact leak).
PERSISTED_FUNCTIONAL_OVERALL=""
PERSISTED_FUNCTIONAL_STRATEGY=""
if [ "$SMOKE_INHERITED" = "true" ]; then
  PERSISTED_FUNCTIONAL_OVERALL="$PRIOR_FUNCTIONAL_OVERALL"
  PERSISTED_FUNCTIONAL_STRATEGY="$PRIOR_FUNCTIONAL_STRATEGY"
elif [ "${FUNCTIONAL_OK:-1}" -eq 1 ] && [ "$FUNCTIONAL_STRATEGY" != "skip" ]; then
  PERSISTED_FUNCTIONAL_OVERALL="$FUNCTIONAL_OVERALL"
  PERSISTED_FUNCTIONAL_STRATEGY="$FUNCTIONAL_STRATEGY"
fi

jq -n \
  --arg head "$CURRENT_HEAD_SHA" \
  --arg base "$CURRENT_BASE_SHA" \
  --argjson round "$NEXT_ROUND" \
  --argjson findings "$ALL_FINDINGS" \
  --arg verdict "$VERDICT" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg functional_overall "$PERSISTED_FUNCTIONAL_OVERALL" \
  --arg functional_strategy "$PERSISTED_FUNCTIONAL_STRATEGY" \
  '{
    schema_version: 1,
    prior_head_sha: $head,
    prior_base_sha: $base,
    round: $round,
    findings: $findings,
    verdict: $verdict,
    functional_overall: $functional_overall,
    functional_strategy: $functional_strategy,
    reviewed_at: $ts
  }' > /tmp/review-state.json
INHERITED_TAG=""
[ "$SMOKE_INHERITED" = "true" ] && INHERITED_TAG=" (inherited)"
echo "review-state.json: head=$CURRENT_HEAD_SHA round=$NEXT_ROUND findings=$(echo "$ALL_FINDINGS" | jq 'length') functional=$PERSISTED_FUNCTIONAL_OVERALL/$PERSISTED_FUNCTIONAL_STRATEGY${INHERITED_TAG}"
echo "::endgroup::"
