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
#
# Output files:
#   review-result.json            — full review result
#   /tmp/review-body.md           — PR review body markdown
#   /tmp/review-comments.json     — inline comments array
#   findings.draft.json           — all findings for artifact upload

echo "::group::Merge findings + build review"

# Guard: check which agents produced VALID output. An agent's findings
# file being present but not JSON (e.g. an invalid escape in a free-text
# `evidence` field) used to crash the whole step with `jq: parse error`
# on the slurpfile below. Now we validate up front, warn, and preserve
# the malformed file for artifact upload so the agent output can be
# inspected without re-running.
is_valid_findings() {
  # Accept only a JSON array — agents are required to write `[]` at minimum.
  [ -f "$1" ] && jq -e 'type == "array"' "$1" >/dev/null 2>&1
}
is_valid_json() {
  [ -f "$1" ] && jq empty "$1" >/dev/null 2>&1
}
preserve_invalid() {
  local src="$1"
  [ -f "$src" ] || return 0
  cp "$src" "${src%.json}.invalid.json" 2>/dev/null || true
  # Show the first parse error in logs for immediate diagnosis
  jq empty "$src" 2>&1 | head -3 || true
}

CORE_HAS_OUTPUT=false; SWEEP_HAS_OUTPUT=false; SPEC_HAS_OUTPUT=false; FUNCTIONAL_HAS_OUTPUT=false
if [ -f /tmp/core-findings.json ]; then
  if is_valid_findings /tmp/core-findings.json; then
    CORE_HAS_OUTPUT=true
  else
    echo "::warning::Core reviewer findings are not a valid JSON array — treating as failed."
    preserve_invalid /tmp/core-findings.json
  fi
fi
if [ -f /tmp/sweep-findings.json ]; then
  if is_valid_findings /tmp/sweep-findings.json; then
    SWEEP_HAS_OUTPUT=true
  else
    echo "::warning::Sweep reviewer findings are not a valid JSON array — treating as failed."
    preserve_invalid /tmp/sweep-findings.json
  fi
fi
if [ -f /tmp/spec-findings.json ]; then
  if is_valid_findings /tmp/spec-findings.json; then
    SPEC_HAS_OUTPUT=true
  else
    echo "::warning::Spec-compliance findings are not a valid JSON array — treating as failed."
    preserve_invalid /tmp/spec-findings.json
  fi
fi
if [ -f /tmp/functional-findings.json ]; then
  if is_valid_findings /tmp/functional-findings.json; then
    FUNCTIONAL_HAS_OUTPUT=true
  else
    echo "::warning::Functional tester findings are not a valid JSON array — treating as failed."
    preserve_invalid /tmp/functional-findings.json
  fi
fi
# Meta files are also agent-written JSON — fall back to empty if malformed.
if [ -f /tmp/core-meta.json ] && ! is_valid_json /tmp/core-meta.json; then
  echo "::warning::Core reviewer meta is not valid JSON — falling back to {}."
  preserve_invalid /tmp/core-meta.json
  echo '{}' > /tmp/core-meta.json
fi
if [ -f /tmp/functional-meta.json ] && ! is_valid_json /tmp/functional-meta.json; then
  echo "::warning::Functional tester meta is not valid JSON — falling back to {}."
  preserve_invalid /tmp/functional-meta.json
  echo '{}' > /tmp/functional-meta.json
fi

if [ "$CORE_HAS_OUTPUT" = "false" ] && [ "$SWEEP_HAS_OUTPUT" = "false" ]; then
  echo "::error::Both code reviewers failed to produce output — cannot generate a verdict."
  echo "::error::Check rate limits and OAuth token."
  exit 1
fi

if [ "$CORE_HAS_OUTPUT" = "false" ]; then
  echo "::warning::Core reviewer (Opus) failed — proceeding with sweep-only findings. Correctness/spec review may be incomplete."
fi
if [ "$SWEEP_HAS_OUTPUT" = "false" ]; then
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

# ── Merge findings from all sources (core + sweep + spec + functional) ──
# Write safe defaults, then overwrite with actual findings if available.
# Using files + --slurpfile avoids bash variable expansion issues with
# large JSON payloads that can break --argjson on some runners.
echo '[]' > /tmp/merged-core.json
echo '[]' > /tmp/merged-sweep.json
echo '[]' > /tmp/merged-spec.json
echo '[]' > /tmp/merged-functional.json
[ "$CORE_HAS_OUTPUT" = "true" ] && cp /tmp/core-findings.json /tmp/merged-core.json
[ "$SWEEP_HAS_OUTPUT" = "true" ] && cp /tmp/sweep-findings.json /tmp/merged-sweep.json
[ "$SPEC_HAS_OUTPUT" = "true" ] && cp /tmp/spec-findings.json /tmp/merged-spec.json
[ "$FUNCTIONAL_HAS_OUTPUT" = "true" ] && cp /tmp/functional-findings.json /tmp/merged-functional.json
CORE_META='{}'
[ -f /tmp/core-meta.json ] && CORE_META=$(cat /tmp/core-meta.json)

CORE_COUNT=$(jq 'length' /tmp/merged-core.json)
SWEEP_COUNT=$(jq 'length' /tmp/merged-sweep.json)
SPEC_COUNT=$(jq 'length' /tmp/merged-spec.json)
FUNCTIONAL_COUNT=$(jq 'length' /tmp/merged-functional.json)
echo "Core: $CORE_COUNT, Sweep: $SWEEP_COUNT, Spec: $SPEC_COUNT, Functional: $FUNCTIONAL_COUNT findings"

# ── Deduplication ──
# Pass 1 (line-based): collapse findings at the same path+line_start.
# Pass 2 (content-based): collapse findings with the same normalized
#   title in the same file, even when reported on different lines.
# In both passes, highest severity wins (critical > major > minor > note).
cat > /tmp/dedup.jq <<'JQEOF'
def sev_rank:
  if .severity == "critical" then 0
  elif .severity == "major" then 1
  elif .severity == "minor" then 2
  else 3 end;
def norm_title: (.title // "") | ascii_downcase | gsub("[^a-z0-9]+"; " ") | gsub("^ +| +$"; "");
def pick_best:
  sort_by(sev_rank) |
  (.[0]) as $best |
  ([.[] | select(.screenshot != null)] | .[0] // null) as $shot_donor |
  if $best.screenshot == null and $shot_donor != null
  then $best + {screenshot: $shot_donor.screenshot}
  else $best end;

($c[0] + $s[0] + $p[0] + $f[0])
| group_by(.path + ":" + (.line_start | tostring))
| map(pick_best)
| group_by(.path + "|" + norm_title)
| map(pick_best)
JQEOF
ALL_FINDINGS=$(jq -n \
  --slurpfile c /tmp/merged-core.json \
  --slurpfile s /tmp/merged-sweep.json \
  --slurpfile p /tmp/merged-spec.json \
  --slurpfile f /tmp/merged-functional.json \
  -f /tmp/dedup.jq)
DEDUPED_COUNT=$(echo "$ALL_FINDINGS" | jq 'length')
TOTAL=$((CORE_COUNT + SWEEP_COUNT + SPEC_COUNT + FUNCTIONAL_COUNT))
if [ "$DEDUPED_COUNT" -lt "$TOTAL" ]; then
  echo "Within-run dedup (path+line then path+normalized-title, highest severity wins): $TOTAL -> $DEDUPED_COUNT (removed $((TOTAL - DEDUPED_COUNT)))"
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
elif [ "$CORE_HAS_OUTPUT" = "false" ]; then
  # Core reviewer (bugs/spec) failed — can't confidently approve without it
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
  if [ "$CORE_HAS_OUTPUT" = "false" ]; then
    echo "> :warning: **Core reviewer (Opus) failed** — correctness and spec compliance review may be incomplete."
    echo ""
  fi
  if [ "$SWEEP_HAS_OUTPUT" = "false" ]; then
    echo "> :warning: **Sweep reviewer (Sonnet) failed** — consistency and performance review may be incomplete."
    echo ""
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
echo "::endgroup::"
