#!/usr/bin/env bash
set -euo pipefail

# build-review.sh — Merge findings from all agents and build review artifacts.
#
# Runs AFTER the parallel agents (core + sweep + functional + spec) have completed.
# Checks which agents produced output, collects screenshots, deduplicates findings,
# determines verdict, and builds review-result.json + review body + inline comments.
#
# Required env vars:
#   GH_TOKEN            — GitHub token for API calls (review identity)
#   GITHUB_REPO_TOKEN   — GitHub token with contents:write (for screenshot upload)
#   GITHUB_REPOSITORY   — owner/repo
#   GITHUB_RUN_ID       — Actions run ID (for logs link)
#   PR_NUMBER           — pull request number
#
# Expected files (from agents):
#   /tmp/core-findings.json       — core reviewer findings (optional)
#   /tmp/sweep-findings.json      — sweep reviewer findings (optional)
#   /tmp/spec-findings.json       — spec-compliance findings (optional)
#   /tmp/functional-findings.json — functional tester findings (optional)
#   /tmp/functional-meta.json     — functional tester metadata (optional)
#   /tmp/core-meta.json           — core reviewer metadata (optional)
#   /tmp/core-findings-2.json     — round-1 redundancy: core pass-2 findings (optional)
#   /tmp/sweep-findings-2.json    — round-1 redundancy: sweep pass-2 findings (optional)
#
# Output files:
#   review-result.json            — full review result
#   /tmp/review-body.md           — PR review body markdown
#   /tmp/review-comments.json     — inline comments array
#   findings.draft.json           — all findings for artifact upload

echo "::group::Merge findings + build review"

# Validate every reviewer's findings file in one loop. If a file is present
# but malformed (e.g. unescaped quotes in free-text evidence), preserve it
# under .invalid.json for the artifact upload, log the first parse error,
# and treat that source as "no output" for the failure gate downstream.
declare -A HAS_OUTPUT=(
  [core]=false [sweep]=false [spec]=false [functional]=false
  [core2]=false [sweep2]=false [resolution]=false
)
declare -A FINDINGS_FILE=(
  [core]=/tmp/core-findings.json
  [sweep]=/tmp/sweep-findings.json
  [spec]=/tmp/spec-findings.json
  [functional]=/tmp/functional-findings.json
  [core2]=/tmp/core-findings-2.json
  [sweep2]=/tmp/sweep-findings-2.json
  # Round-2 resolution checker may surface high-severity net-new findings
  # alongside its classification output (see review-resolution-checker.md).
  # Most runs leave this as []; when populated, the entries flow through
  # the same Haiku dedup as every other reviewer's output.
  [resolution]=/tmp/resolution-findings.json
)
for key in "${!FINDINGS_FILE[@]}"; do
  f="${FINDINGS_FILE[$key]}"
  [ -f "$f" ] || continue
  if jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    HAS_OUTPUT[$key]=true
  else
    echo "::warning::${key} findings ($f) are not a valid JSON array — treating as failed."
    cp "$f" "${f%.json}.invalid.json" 2>/dev/null \
      || echo "::warning::Failed to preserve $f to ${f%.json}.invalid.json (filesystem permissions or disk space?). Original kept in place."
    jq empty "$f" 2>&1 | head -3 || true
  fi
done

CORE_HAS_OUTPUT="${HAS_OUTPUT[core]}"
SWEEP_HAS_OUTPUT="${HAS_OUTPUT[sweep]}"
SPEC_HAS_OUTPUT="${HAS_OUTPUT[spec]}"
FUNCTIONAL_HAS_OUTPUT="${HAS_OUTPUT[functional]}"
CORE2_HAS_OUTPUT="${HAS_OUTPUT[core2]}"
SWEEP2_HAS_OUTPUT="${HAS_OUTPUT[sweep2]}"

# Aggregate flags: pass-2 substitutes for pass-1 if pass-1 failed but pass-2
# succeeded. Used for the failure gate, the warnings below, and the verdict
# downgrade logic — any successful pass means we have those findings.
# Explicit form (not `$(... && echo … || echo …)`) — the && / || precedence
# trick produces the right truth table here but is one restructure away
# from breaking silently.
if [ "$CORE_HAS_OUTPUT" = "true" ] || [ "$CORE2_HAS_OUTPUT" = "true" ]; then
  CORE_ANY_OUTPUT=true
else
  CORE_ANY_OUTPUT=false
fi
if [ "$SWEEP_HAS_OUTPUT" = "true" ] || [ "$SWEEP2_HAS_OUTPUT" = "true" ]; then
  SWEEP_ANY_OUTPUT=true
else
  SWEEP_ANY_OUTPUT=false
fi

# Meta files are also agent-written JSON — coerce malformed/non-object to {}
# so the verdict gates and meta-merge below see a stable shape.
for mf in /tmp/core-meta.json /tmp/core-meta-2.json /tmp/functional-meta.json; do
  [ -f "$mf" ] || continue
  if ! jq -e 'type == "object"' "$mf" >/dev/null 2>&1; then
    echo "::warning::${mf} is not a JSON object — falling back to {}."
    cp "$mf" "${mf%.json}.invalid.json" 2>/dev/null \
      || echo "::warning::Failed to preserve $mf to ${mf%.json}.invalid.json (filesystem permissions or disk space?). Coercing to {} anyway."
    echo '{}' > "$mf"
  fi
done

if [ "$CORE_ANY_OUTPUT" = "false" ] && [ "$SWEEP_ANY_OUTPUT" = "false" ]; then
  echo "::error::All code reviewers failed to produce output (core+sweep, both passes if boost ran) — cannot generate a verdict."
  echo "::error::Check rate limits and OAuth token."
  exit 1
fi

if [ "$CORE_ANY_OUTPUT" = "false" ]; then
  echo "::warning::Core reviewer (Opus) failed — proceeding with sweep-only findings. Correctness/spec review may be incomplete."
fi
if [ "$SWEEP_ANY_OUTPUT" = "false" ]; then
  echo "::warning::Sweep reviewer (Sonnet) failed — proceeding with core-only findings. Consistency/performance review may be incomplete."
fi
if [ "$FUNCTIONAL_HAS_OUTPUT" = "false" ]; then
  echo "::warning::Functional tester failed — no functional validation results."
fi

# Load functional test metadata (strategy, screenshots, overall verdict)
FUNCTIONAL_META='{}'
[ -f /tmp/functional-meta.json ] && FUNCTIONAL_META=$(cat /tmp/functional-meta.json)
FUNCTIONAL_STRATEGY=$(echo "$FUNCTIONAL_META" | jq -r '.strategy // "skip"')
FUNCTIONAL_OVERALL=$(echo "$FUNCTIONAL_META" | jq -r '.overall // "N/A"')
echo "Functional tester: strategy=$FUNCTIONAL_STRATEGY, overall=$FUNCTIONAL_OVERALL"

# ── Screenshot collection and upload ──
# Playwright MCP saves screenshots to its CWD when the agent passes a
# plain filename (e.g. "01-name.png") — that resolves to the repo root
# in our setup. --output-dir doesn't override agent-chosen paths.
# So we scan: agent's likely cwd (.), /tmp/screenshots (if agent used
# an absolute path), and a few historical alternate paths.
SCREENSHOT_URLS='{}'
mkdir -p /tmp/all-screenshots
# maxdepth 2: catches files at repo root (./*.png) plus one level of
# subdir nesting (./screenshots/*.png), without scanning node_modules.
for src_dir in . /tmp/screenshots /tmp/playwright-mcp-output .playwright-mcp screenshots .playwright-mcp/screenshots; do
  if [ -d "$src_dir" ]; then
    find "$src_dir" -maxdepth 2 -name '*.png' -not -path '*/node_modules/*' -exec cp -n {} /tmp/all-screenshots/ \; 2>/dev/null || true
  fi
done
# Final fallback: scan /tmp recursively for any PNG produced in the last hour.
if ! ls /tmp/all-screenshots/*.png >/dev/null 2>&1; then
  echo "No screenshots in expected paths — scanning /tmp recursively for recent PNGs..."
  find /tmp -name '*.png' -mmin -60 -not -path '/tmp/all-screenshots/*' -exec cp -n {} /tmp/all-screenshots/ \; 2>/dev/null || true
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

# ── Merge findings from all sources ──
# Concatenate every valid reviewer output into a single array. The
# HAS_OUTPUT flags above tell us which files survived validation; we
# feed only those into jq -s 'add'. No intermediate per-source files.
SAFE_INPUTS=()
for key in core sweep spec functional core2 sweep2 resolution; do
  [ "${HAS_OUTPUT[$key]}" = "true" ] && SAFE_INPUTS+=("${FINDINGS_FILE[$key]}")
done
# Merge pass-1 + pass-2 core meta. OR-merge safety booleans (any signal
# wins), AND-merge `manual_spec_present` (either NO blocks APPROVE),
# pass-1-prefer for prose. The bash loop above already coerces non-object
# meta to {}, but the program rebinds $m1/$m2 with an in-jq type guard
# anyway so it stays self-contained — has() crashes on non-object types
# in jq 1.7+ (ubuntu-24.04 default), and a future refactor that drops
# the bash coercion shouldn't be able to re-introduce that crash.
META1='{}'; META2='{}'
[ -f /tmp/core-meta.json ] && META1=$(cat /tmp/core-meta.json)
[ -f /tmp/core-meta-2.json ] && META2=$(cat /tmp/core-meta-2.json)
CORE_META=$(jq -n --argjson m1 "$META1" --argjson m2 "$META2" '
  ($m1 | if type == "object" then . else {} end) as $m1
  | ($m2 | if type == "object" then . else {} end) as $m2
  | def or_bool(k): (($m1[k] // false) or ($m2[k] // false));
    # `has()` rather than `// true`: jq treats explicit false as missing,
    # so `false // true` is `true` — wrong direction here.
    def and_present:
      (if $m1 | has("manual_spec_present") then $m1.manual_spec_present else true end)
      and
      (if $m2 | has("manual_spec_present") then $m2.manual_spec_present else true end);
    {
      requires_human_review:        or_bool("requires_human_review"),
      requires_human_review_reason: ($m1.requires_human_review_reason // $m2.requires_human_review_reason // null),
      uncertain_observations:       (($m1.uncertain_observations // []) + ($m2.uncertain_observations // [])),
      prompt_injection_detected:    or_bool("prompt_injection_detected"),
      reviewer_self_modification:   or_bool("reviewer_self_modification"),
      build_unavailable:            or_bool("build_unavailable"),
      manual_spec_present:          and_present,
      spec_compliance:              ($m1.spec_compliance // $m2.spec_compliance // null),
      spec_sources:                 ($m1.spec_sources // $m2.spec_sources // null)
    }')

if [ "${#SAFE_INPUTS[@]}" -gt 0 ]; then
  jq -s 'add' "${SAFE_INPUTS[@]}" > /tmp/all-findings-merged.json
else
  echo '[]' > /tmp/all-findings-merged.json
fi
report_count() { jq 'length' "$1" 2>/dev/null || echo 0; }
echo "Findings: core=$(report_count /tmp/core-findings.json) sweep=$(report_count /tmp/sweep-findings.json) spec=$(report_count /tmp/spec-findings.json) functional=$(report_count /tmp/functional-findings.json) core2=$(report_count /tmp/core-findings-2.json) sweep2=$(report_count /tmp/sweep-findings-2.json) resolution=$(report_count /tmp/resolution-findings.json) — total=$(jq 'length' /tmp/all-findings-merged.json)"
TOTAL=$(jq 'length' /tmp/all-findings-merged.json)

# ── Deduplication ──
# One Haiku call groups by root cause across every reviewer's output.
# The previous two-pass jq dedup (path+line then path+title) missed
# semantic duplicates with different categories on adjacent lines.
# On Haiku failure (after one retry) we post the raw concatenated
# input with a visible ::error:: — no second dedup path to maintain.

run_haiku_dedup() {
  local out="$1"
  : > /tmp/dedup-output.txt
  rm -f "$out"
  ~/.local/bin/claude -p "=== review-dedup skill (follow exactly) ===

${DEDUP_SKILL}${BUGBOT_BLOCK:-}

You are the dedup reviewer. Read /tmp/all-findings-merged.json (the full reviewer output). When /tmp/resolution-status.json AND /tmp/prior-state/state.json exist, this is a round-2 follow-up — Read both and apply the STILL_PRESENT drop rule from the skill. OUTPUT_PATH=${out} — write the deduped JSON array to that exact path. Follow the skill above exactly." \
    --model "${MODEL_FAST:-claude-haiku-4-5}" \
    --permission-mode dontAsk \
    --setting-sources user \
    --allowedTools Read,Write \
    --disallowedTools Bash,Edit,Glob,Grep,WebFetch,WebSearch \
    --max-turns 4 > /tmp/dedup-output.txt 2>&1
}

# Validate dedup output: must be a JSON array; every element must be an
# object with severity/path/line_start/id; length must be ≤ input length
# but > 0 when input was non-empty; every output id must appear in the
# input. The non-empty check is critical: jq `all` on [] is vacuously
# true, so an LLM that silently writes [] for a non-empty input would
# pass shape + id-membership checks and produce a spurious APPROVE on a
# PR with real bugs. is_valid_json only verifies parseability — that's
# why the 412ac65 / 231722f hardening exists. Shape validation below is
# the regression guard.
validate_dedup_output() {
  local out="$1"
  [ -f "$out" ] || return 1
  jq -e 'type == "array"' "$out" >/dev/null 2>&1 || return 1
  jq -e 'all(type == "object" and has("severity") and has("path") and has("line_start") and has("id"))' "$out" >/dev/null 2>&1 || return 1
  local out_len in_len
  out_len=$(jq 'length' "$out")
  in_len=$(jq 'length' /tmp/all-findings-merged.json)
  [ "$out_len" -le "$in_len" ] || return 1
  # Drop-all is allowed: review-dedup.md authorizes it when every input
  # matches a bugbot-accepted trade-off, or (round 2) every new finding
  # overlaps a STILL_PRESENT prior. Rejecting drop-all here used to
  # cause a regression where the fallback re-posted the raw concatenated
  # findings — exactly the duplicates / exempt entries the dedup is
  # meant to filter. We log the drop-all case as a notice (so an
  # operator can audit) but treat it as valid output.
  if [ "$in_len" -gt 0 ] && [ "$out_len" -eq 0 ]; then
    echo "::notice::Dedup dropped all $in_len finding(s) — accepting (matches bugbot-exempt or round-2 STILL_PRESENT-overlap rules in review-dedup.md). Audit /tmp/all-findings-merged.json + /tmp/deduped-findings.json if this looks wrong."
  fi
  jq --slurpfile in /tmp/all-findings-merged.json \
     -e 'all(.id as $id | $in[0] | any(.id == $id))' \
     "$out" >/dev/null 2>&1 || return 1
  return 0
}

DEDUP_SKILL=""
if [ -n "${SKILLS_DIR:-}" ] && [ -f "$SKILLS_DIR/review-dedup.md" ]; then
  DEDUP_SKILL=$(cat "$SKILLS_DIR/review-dedup.md")
elif [ -f "${CLAUDE_REVIEW_PIPELINE_DIR:-}/skills/review-dedup.md" ]; then
  DEDUP_SKILL=$(cat "${CLAUDE_REVIEW_PIPELINE_DIR}/skills/review-dedup.md")
fi

ALL_FINDINGS=""
if [ -z "$DEDUP_SKILL" ] || [ -z "${MODEL_FAST:-}" ]; then
  echo "::warning::review-dedup.md or MODEL_FAST not available — skipping LLM dedup, posting raw concatenated findings"
  ALL_FINDINGS=$(cat /tmp/all-findings-merged.json)
else
  DEDUP_OK=false
  for attempt in 1 2; do
    echo "Haiku dedup attempt $attempt/2..."
    if run_haiku_dedup /tmp/deduped-findings.json && validate_dedup_output /tmp/deduped-findings.json; then
      DEDUP_OK=true
      break
    fi
    echo "::warning::Haiku dedup attempt $attempt failed (invalid output or non-zero exit). See /tmp/dedup-output.txt"
  done
  if [ "$DEDUP_OK" = "true" ]; then
    ALL_FINDINGS=$(cat /tmp/deduped-findings.json)
  else
    echo "::error::Haiku dedup failed twice; posting raw findings (may include duplicates). Investigate /tmp/dedup-output.txt and /tmp/all-findings-merged.json."
    ALL_FINDINGS=$(cat /tmp/all-findings-merged.json)
  fi
fi

DEDUPED_COUNT=$(echo "$ALL_FINDINGS" | jq 'length')
if [ "$DEDUPED_COUNT" -lt "$TOTAL" ]; then
  echo "Haiku dedup: $TOTAL -> $DEDUPED_COUNT (removed $((TOTAL - DEDUPED_COUNT)))"
fi

# Quality safeguard: dedup is allowed to merge duplicate criticals (highest
# severity wins within a group, per the skill), but it should never zero
# them out. Two criticals merging to one is fine; many criticals merging
# to zero means Haiku misclassified severity. Warn loudly so the operator
# can audit /tmp/deduped-findings.json without having to compare counts.
IN_CRITS=$(jq '[.[] | select(.severity == "critical")] | length' /tmp/all-findings-merged.json 2>/dev/null || echo 0)
OUT_CRITS=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo 0)
if [ "$IN_CRITS" -gt 0 ] && [ "$OUT_CRITS" -eq 0 ]; then
  echo "::warning::Dedup dropped every critical finding ($IN_CRITS in -> 0 out). Audit /tmp/deduped-findings.json — possible severity misclassification."
fi

# ── Round-2 body inputs ──
# Haiku dedup above already drops STILL_PRESENT-overlapping new findings
# semantically (it reads /tmp/resolution-status.json + prior-state). We
# only need the RESOLVED/STILL_PRESENT lists here so the body composition
# below can render the "Since previous review" section.
RESOLVED_LIST="[]"
STILL_PRESENT_LIST="[]"
if [ -f /tmp/resolution-status.json ] && jq -e 'type == "array"' /tmp/resolution-status.json >/dev/null 2>&1; then
  RESOLVED_LIST=$(jq '[.[] | select(.status == "RESOLVED")]' /tmp/resolution-status.json)
  STILL_PRESENT_LIST=$(jq '[.[] | select(.status == "STILL_PRESENT")]' /tmp/resolution-status.json)
  echo "Round-2 resolution status: $(echo "$RESOLVED_LIST" | jq 'length') RESOLVED, $(echo "$STILL_PRESENT_LIST" | jq 'length') STILL_PRESENT, $(jq '[.[] | select(.status == "NEW_CONTEXT")] | length' /tmp/resolution-status.json) NEW_CONTEXT"
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
SMOKE_OK=false
if [ "${FUNCTIONAL_OK:-1}" -ne 1 ]; then
  :  # tester crashed
elif [ "$FUNCTIONAL_STRATEGY" = "skip" ]; then
  :  # tester never launched (degraded mode) or planner skipped — no smoke evidence either way
elif [ "$FUNCTIONAL_OVERALL" = "PASS" ] || [ "$FUNCTIONAL_OVERALL" = "WARN" ]; then
  SMOKE_OK=true
fi

if [ "$HAS_BLOCKING" = "true" ]; then
  VERDICT="REQUEST_CHANGES"
elif [ "$HUMAN_REVIEW" = "true" ]; then
  VERDICT="COMMENT"
elif [ "$CORE_ANY_OUTPUT" = "false" ]; then
  # Core reviewer (bugs/spec) failed — can't confidently approve without it.
  # On first reviews this means BOTH core passes failed; on re-reviews this is
  # the single core run.
  VERDICT="COMMENT"
  echo "::warning::Core reviewer failed — downgrading from APPROVE to COMMENT (cannot verify correctness)"
elif [ "$MANUAL_SPEC_PRESENT" = "false" ]; then
  VERDICT="COMMENT"
  echo "::warning::No manual spec available — downgrading APPROVE to COMMENT (core reviewer set manual_spec_present=false)"
elif [ "$TECHNICAL_CHANGE" = "true" ] && [ "$SMOKE_OK" = "false" ]; then
  VERDICT="COMMENT"
  echo "::warning::Technical change without successful smoke test (overall=$FUNCTIONAL_OVERALL, ok=${FUNCTIONAL_OK:-1}) — downgrading APPROVE to COMMENT"
elif [ "$HAS_ANY" = "true" ]; then
  VERDICT="COMMENT"
else
  VERDICT="APPROVE"
fi

# ── Round-2 verdict adjustment ──
# When a prior state exists, blend the new-finding verdict above with the
# resolution-checker output. Spec from the plan §3 table:
#   - Prior REQUEST_CHANGES, no new criticals/majors, all prior blockers
#     RESOLVED   → APPROVE.
#   - Prior REQUEST_CHANGES, no new blockers, some prior blockers still
#     present     → REQUEST_CHANGES.
#   - Prior COMMENT, no new blockers → COMMENT (don't escalate to APPROVE).
#   - Any prior verdict + ≥1 new critical/major → REQUEST_CHANGES.
# The "no new blockers" branch is what makes this round-2 specific:
# round-1 with no findings would default to APPROVE here, but round-2
# preserves COMMENT/REQUEST_CHANGES until either the prior blockers are
# resolved OR the prior verdict was already non-blocking.
if [ -f /tmp/prior-state/state.json ]; then
  PRIOR_VERDICT=$(jq -r '.verdict // "MISSING"' /tmp/prior-state/state.json 2>/dev/null || echo "MISSING")
  PRIOR_BLOCKERS=$(jq -r '[.findings[]? | select(.severity == "critical" or .severity == "major")] | length' /tmp/prior-state/state.json 2>/dev/null || echo 0)
  # Derive the still-present blocker count by id-joining STILL_PRESENT
  # entries against prior-state.findings, instead of trusting the
  # resolution checker's `prior_severity` field. The verdict gate must
  # not ride on LLM compliance: if the agent forgets or mistypes
  # `prior_severity`, an approve-via-zero-blockers slips through.
  STILL_PRESENT_BLOCKERS=$(jq -n \
    --slurpfile state /tmp/prior-state/state.json \
    --argjson still "$STILL_PRESENT_LIST" \
    '($still | map(.id)) as $ids
     | ($state[0].findings // [])
     | map(select((.id as $id | $ids | index($id)) and (.severity == "critical" or .severity == "major")))
     | length')
  echo "Round-2 verdict input: prior_verdict=$PRIOR_VERDICT prior_blockers=$PRIOR_BLOCKERS still_present_blockers=$STILL_PRESENT_BLOCKERS new_blocking=$HAS_BLOCKING current_verdict=$VERDICT"
  case "$PRIOR_VERDICT" in
    REQUEST_CHANGES)
      if [ "$HAS_BLOCKING" = "true" ]; then
        VERDICT="REQUEST_CHANGES"
      elif [ "$STILL_PRESENT_BLOCKERS" -gt 0 ]; then
        VERDICT="REQUEST_CHANGES"
        echo "::notice::Round-2: $STILL_PRESENT_BLOCKERS prior blocking finding(s) still present — keeping REQUEST_CHANGES."
      fi
      # else: no new blockers AND all prior blockers resolved → keep
      # whatever the per-PR verdict computed above (APPROVE if clean).
      ;;
    COMMENT)
      if [ "$HAS_BLOCKING" = "true" ]; then
        VERDICT="REQUEST_CHANGES"
      elif [ "$VERDICT" = "APPROVE" ]; then
        # Don't escalate to APPROVE on a pure follow-up — prior verdict
        # was non-blocking but the user hadn't approved yet.
        VERDICT="COMMENT"
      fi
      ;;
    APPROVE)
      if [ "$HAS_BLOCKING" = "true" ]; then
        VERDICT="REQUEST_CHANGES"
      fi
      ;;
    *)
      # Unrecognized verdict (state file present but .verdict missing /
      # corrupted / unknown enum value) — leave the per-PR verdict alone
      # but emit a visible warning so the operator can audit.
      echo "::warning::Round-2 verdict adjustment skipped — unrecognized prior_verdict='$PRIOR_VERDICT'. Using per-PR verdict '$VERDICT' as-is."
      ;;
  esac
fi

echo "Verdict: $VERDICT (blocking=$HAS_BLOCKING, any=$HAS_ANY, human=$HUMAN_REVIEW, manual_spec=$MANUAL_SPEC_PRESENT, technical_change=$TECHNICAL_CHANGE, smoke_ok=$SMOKE_OK, functional=$FUNCTIONAL_OVERALL)"

# ── Build review-result.json ──
# Crash-aware functional_meta view, used ONLY for the JSON artifact. If
# the tester exited non-zero without writing /tmp/functional-meta.json,
# the workflow wrote a synthetic {strategy:"skip",overall:"PASS"} so
# downstream jq never sees a missing file. That placeholder is
# indistinguishable from an intentional skip — anyone reading
# review-result.json would see "skip / PASS" while the review body
# clearly renders a CRASHED section (that path reads FUNCTIONAL_OK
# directly). Override here so the JSON reflects the crash too. The
# FUNCTIONAL_STRATEGY / FUNCTIONAL_OVERALL shell vars that drive body
# rendering are deliberately left untouched — the existing
# `elif FUNCTIONAL_OK == 0` branch below still fires as before.
JSON_FUNCTIONAL_META="$FUNCTIONAL_META"
if [ "${FUNCTIONAL_OK:-1}" -eq 0 ] && [ "$FUNCTIONAL_STRATEGY" = "skip" ] && [ "$FUNCTIONAL_OVERALL" = "PASS" ]; then
  echo "::notice::functional tester exited non-zero without writing meta — review-result.json will record strategy=crashed"
  JSON_FUNCTIONAL_META=$(echo "$FUNCTIONAL_META" | jq '. + {strategy: "crashed", overall: "CRASH", summary: "Functional tester agent did not complete; see crash log in review body."}')
fi

SPEC_COMPLIANCE=$(echo "$CORE_META" | jq -r '.spec_compliance // ""')
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
    build_unavailable: ($meta.build_unavailable // false),
    functional_validation: {
      strategy: ($functional_meta.strategy // "skip"),
      overall: ($functional_meta.overall // "N/A"),
      areas_tested: ($functional_meta.areas_tested // []),
      screenshot_count: (($functional_meta.screenshots // []) | length)
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
  # Spec compliance summary
  if [ -n "$SPEC_COMPLIANCE" ] && [ "$SPEC_COMPLIANCE" != "null" ]; then
    echo "$SPEC_COMPLIANCE"
    echo ""
  elif [ "$VERDICT" = "APPROVE" ]; then
    echo "No issues found. Code reviewed for correctness, spec compliance, security, consistency, test quality, and performance."
    echo ""
  fi
  # Conditional banners
  if [ "$MANUAL_SPEC_PRESENT" = "false" ]; then
    echo "> :no_entry: **No manual spec available — APPROVE withheld.** Reviews can only validate code against a human-authored requirement source: a linked GitHub issue, a PRD, an external tracker spec, or a manually-written PR description. Auto-generated PR descriptions (Cursor, Cursor Bugbot, CodeRabbit, Gemini Code Assist, Claude Code) summarise the diff — they describe what the code does, not what it should do — so they aren't a basis for spec validation. Link an issue, paste acceptance criteria into the PR body, or wire up an external tracker to enable APPROVE."
    echo ""
  fi
  if [ "$TECHNICAL_CHANGE" = "true" ] && [ "$SMOKE_OK" = "false" ]; then
    echo "> :no_entry: **Technical change — APPROVE withheld until smoke-tested.** Refactors, library swaps, framework/runtime upgrades, and build-config changes claim no user-visible behavior change, so there are no acceptance criteria to validate against. The only way to catch regressions is to run the app and walk through a representative user flow. The smoke test did not pass here (overall=\`$FUNCTIONAL_OVERALL\`). To enable APPROVE: configure \`.github/claude-review/dev-start.sh\` so the reviewer can launch the app (see README), or fix the issues that caused the smoke run to fail."
    echo ""
  fi
  if [ "$(jq -r '.requires_human_review' review-result.json)" = "true" ]; then
    echo "> :stop_sign: **Human review required.** $(jq -r '.requires_human_review_reason // ""' review-result.json)"
    echo ""
  fi
  if [ "$(jq -r '.build_unavailable' review-result.json)" = "true" ]; then
    echo "> :gear: **Build verification was unavailable.**"
    echo ""
  fi
  if [ "$CORE_ANY_OUTPUT" = "false" ]; then
    echo "> :warning: **Core reviewer (Opus) failed** — correctness and spec compliance review may be incomplete."
    echo ""
  fi
  if [ "$SWEEP_ANY_OUTPUT" = "false" ]; then
    echo "> :warning: **Sweep reviewer (Sonnet) failed** — consistency and performance review may be incomplete."
    echo ""
  fi
  # Round-2 only: surface what the resolution checker found.
  RESOLVED_N=$(echo "$RESOLVED_LIST" | jq 'length')
  STILL_N=$(echo "$STILL_PRESENT_LIST" | jq 'length')
  if [ "$RESOLVED_N" -gt 0 ] || [ "$STILL_N" -gt 0 ]; then
    echo "### Since previous review"
    echo ""
    if [ "$RESOLVED_N" -gt 0 ]; then
      echo "**Resolved (${RESOLVED_N}):**"
      echo "$RESOLVED_LIST" | jq -r '.[] | "- `\(.id)` — \(.evidence)"'
      echo ""
    fi
    if [ "$STILL_N" -gt 0 ]; then
      echo "**Still present (${STILL_N}):**"
      echo "$STILL_PRESENT_LIST" | jq -r '.[] | "- `\(.id)` (\(.prior_severity // "?")) — \(.evidence)"'
      echo ""
    fi
  fi
} > /tmp/review-body.md

# ── Append functional validation section ──
TEST_PLAN_EXISTS="false"
[ -f test-plan.md ] && TEST_PLAN_EXISTS="true"

FUNCTIONAL_SCREENSHOT_COUNT=$(echo "$FUNCTIONAL_META" | jq '(.screenshots // []) | length')
FUNCTIONAL_OK="${FUNCTIONAL_OK:-1}"
if [ "$FUNCTIONAL_OVERALL" != "N/A" ] && [ "$FUNCTIONAL_STRATEGY" != "skip" ]; then
  EMOJI="✅"; [ "$FUNCTIONAL_OVERALL" = "FAIL" ] && EMOJI="❌"; [ "$FUNCTIONAL_OVERALL" = "WARN" ] && EMOJI="⚠️"
  {
    echo ""
    echo "<details>"
    echo "<summary>$EMOJI <b>Functional Validation — $FUNCTIONAL_OVERALL</b> ($FUNCTIONAL_SCREENSHOT_COUNT screenshots)</summary>"
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
    # Screenshot gallery
    if [ "$FUNCTIONAL_SCREENSHOT_COUNT" -gt 0 ]; then
      echo "#### Screenshots"
      echo ""
      echo "$FUNCTIONAL_META" | jq -r --argjson urls "$SCREENSHOT_URLS" \
        --arg repo "$GITHUB_REPOSITORY" --arg run "${GITHUB_RUN_ID:-}" '
        .screenshots[] |
        .file as $file |
        ($file | split("/") | last) as $basename |
        ($urls[$basename] // null) as $url |
        if $url then
          "<details><summary>\(.description)</summary>\n\n![\(.description)](\($url))\n\n</details>\n"
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
  {
    path: .path,
    line: (.line_end // .line_start // 1),
    side: "RIGHT",
    body: (
      "**[\((.type // "finding") | ascii_upcase)]** \(.title // "Untitled")\n\n\(.reasoning // "")\n\n_Expected:_ \(.expected // "")"
      + (if .prd_quote then "\n\n_PRD:_ \(.prd_quote)" else "" end)
      + (if $shot_url then "\n\n![screenshot](\($shot_url))" else "" end)
      | if length > 65000 then .[:64997] + "..." else . end
    )
  } + (if $use_range then {start_line: .line_start, start_side: "RIGHT"} else {} end)
]' /tmp/all-findings.json > /tmp/review-comments.json

# Also write findings.draft.json for artifact upload
cp /tmp/all-findings.json findings.draft.json

echo "review-result.json: $VERDICT, $(echo "$ALL_FINDINGS" | jq 'length') findings"
echo "review-comments.json: $(jq 'length' /tmp/review-comments.json) inline comments"

# ── Persist round-state for the next follow-up review ──
# The Upload review state workflow step packages this for cross-run pickup.
# Schema is documented in pr-review.yml (round-2 read step) and in
# skills/review-resolution-checker.md.
CURRENT_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
CURRENT_BASE_SHA=$(git merge-base HEAD "${GITHUB_BASE_REF:+origin/$GITHUB_BASE_REF}" 2>/dev/null || echo "")
PRIOR_HEAD_SHA_FROM_STATE=""
PRIOR_ROUND=1
if [ -f /tmp/prior-state/state.json ]; then
  PRIOR_HEAD_SHA_FROM_STATE=$(jq -r '.prior_head_sha // empty' /tmp/prior-state/state.json 2>/dev/null || echo "")
  PRIOR_ROUND=$(jq -r '.round // 1' /tmp/prior-state/state.json 2>/dev/null || echo "1")
fi
NEXT_ROUND=$((PRIOR_ROUND + 1))
[ -z "$PRIOR_HEAD_SHA_FROM_STATE" ] && NEXT_ROUND=1
jq -n \
  --arg head "$CURRENT_HEAD_SHA" \
  --arg base "$CURRENT_BASE_SHA" \
  --argjson round "$NEXT_ROUND" \
  --argjson findings "$ALL_FINDINGS" \
  --arg verdict "$VERDICT" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schema_version: 1,
    prior_head_sha: $head,
    prior_base_sha: $base,
    round: $round,
    findings: $findings,
    verdict: $verdict,
    reviewed_at: $ts
  }' > /tmp/review-state.json
echo "review-state.json: head=$CURRENT_HEAD_SHA round=$NEXT_ROUND findings=$(echo "$ALL_FINDINGS" | jq 'length')"
echo "::endgroup::"
