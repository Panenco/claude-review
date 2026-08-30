#!/usr/bin/env bash
# guard.sh — the only deterministic short-circuit before a model call.
#
# Replaces review-plan.sh's seven-tier classifier: review-scan self-scales its
# own depth, so the only decisions left are the four a model must never be paid
# to make. Pure function of its inputs — unit-tested in tests/guard_test.sh.
#
# Output — GITHUB_OUTPUT-shaped lines on stdout, appendable verbatim:
#   proceed=true|false · gate=ok|label|unchanged|oversized|empty · reason=<one line>
#   docs_only=true|false — proceed path only; nothing but documents changed.
#   depth_scale=3..8 + comment_limit=6..16 — proceed path only; how deep the
#   review is allowed to go, derived from diff size. See section 5.
#   verdict=REQUEST_CHANGES + body<<GUARD_BODY…GUARD_BODY — oversized only; that
#   split request is posted as-is, with no model call.
#
# Env (all optional): GATE_FILES_TSV ("path<TAB>additions<TAB>deletions" per
# changed file), GATE_LABELS (newline-separated), GATE_SKIP_LABEL (skip-review),
# GATE_FORCE_LABEL (deep-review) and GATE_FORCE_DEEP ("true" from `/review deep`)
# — either one overrides the size ceiling, GATE_TRIGGER (/review, for the split
# request's wording), GATE_SIZE_CEILING (3000), GATE_FILE_CEILING (60),
# GATE_PRIOR_HEAD_SHA + GATE_DELTA_FILES (round-2 scope, see docs/adr/0003),
# GATE_HUMAN_REQUESTED (true when a person typed the command — `unchanged` gate).

set -uo pipefail # No `set -e` (repo rule, bugbot.md).

SKIP_LABEL="${GATE_SKIP_LABEL:-skip-review}"
FORCE_LABEL="${GATE_FORCE_LABEL:-deep-review}"
TRIGGER="${GATE_TRIGGER:-/review}"
SIZE_CEILING="${GATE_SIZE_CEILING:-3000}"
FILE_CEILING="${GATE_FILE_CEILING:-60}"

emit() { printf 'proceed=%s\ngate=%s\nverdict=%s\nreason=%s\n' "$1" "$2" "$3" "$4"; }

# Excluded from the size count: their presence never makes a PR "big".
is_generated() {
  case "$1" in
    *.lock|package-lock.json|pnpm-lock.yaml|*.snap) return 0 ;;
    dist/*|*/dist/*|build/*|*/build/*|*.min.js|*.min.css|*.generated.*|*.pb.go|*_pb2.py) return 0 ;;
    *) return 1 ;;
  esac
}

# 1) Human opted out.
if [ -n "${GATE_LABELS:-}" ] && printf '%s\n' "$GATE_LABELS" | grep -Fxq "$SKIP_LABEL"; then
  emit false label "" "Skipped — '$SKIP_LABEL' label present (reviewed elsewhere / opted out)."
  exit 0
fi

# 2) Round 2+ with nothing new. GATE_DELTA_FILES is `git diff --name-only
#    <prior>..HEAD` from the caller, so this stays a pure function. An empty
#    prior SHA is round 1 and never skips.
#
#    It suppresses AUTOMATIC re-runs only. `/review code` then `/review
#    functional` on one commit used to give the second request a 👀 and then
#    total silence — no comment, no tester, green check. See
#    prior-review-state.sh:120: silence is a worse answer than a repeat.
if [ -n "${GATE_PRIOR_HEAD_SHA:-}" ] && [ "${GATE_HUMAN_REQUESTED:-false}" != "true" ]; then
  delta=0
  while IFS= read -r dpath; do
    [ -z "$dpath" ] && continue
    is_generated "$dpath" || delta=$(( delta + 1 ))
  done <<< "${GATE_DELTA_FILES:-}"
  if [ "$delta" -eq 0 ]; then
    emit false unchanged "" "Skipped — nothing non-generated changed since the last review (${GATE_PRIOR_HEAD_SHA})."
    exit 0
  fi
fi

ng_lines=0; ng_files=0; docs_only=true
while IFS=$'\t' read -r path adds dels; do
  [ -z "$path" ] && continue
  is_generated "$path" && continue
  ng_files=$(( ng_files + 1 ))
  case "$path" in *.md|LICENSE) ;; *) docs_only=false ;; esac
  [[ "${adds:-}" =~ ^[0-9]+$ ]] && ng_lines=$(( ng_lines + adds ))
  [[ "${dels:-}" =~ ^[0-9]+$ ]] && ng_lines=$(( ng_lines + dels ))
done <<< "${GATE_FILES_TSV:-}"

# 3) Too big to review well — block with a split request, no model call.
#    Two equivalent overrides: `$TRIGGER deep` for the run it starts, the
#    `$FORCE_LABEL` label for every push. A large PR that genuinely cannot be
#    split is worse off unreviewed than reviewed imperfectly (PR #106, a
#    6692-line rewrite of credential handling, merged with no review at all).
forced=false
if [ "${GATE_FORCE_DEEP:-}" = "true" ] ||
   { [ -n "${GATE_LABELS:-}" ] && printf '%s\n' "$GATE_LABELS" | grep -Fxq "$FORCE_LABEL"; }; then
  forced=true
fi
if [ "$forced" != "true" ] && { [ "$ng_lines" -gt "$SIZE_CEILING" ] || [ "$ng_files" -gt "$FILE_CEILING" ]; }; then
  emit false oversized REQUEST_CHANGES \
    "Too large to review well: ${ng_files} files / ${ng_lines} non-generated lines (ceiling ${FILE_CEILING} / ${SIZE_CEILING})."
  cat <<GUARD_OUTPUT
body<<GUARD_BODY
<!-- claude-review-oversized -->

## Claude review — REQUEST_CHANGES

Too large to review well: ${ng_files} files, ${ng_lines} non-generated lines (ceiling ${FILE_CEILING} files / ${SIZE_CEILING} lines). No code was read.

Split it into focused PRs (team limit: 400 lines). If it genuinely cannot be split, comment \`${TRIGGER} deep\` to review it anyway, or add the \`${FORCE_LABEL}\` label to keep doing that on every push. \`${SKIP_LABEL}\` skips it entirely.
GUARD_BODY
GUARD_OUTPUT
  exit 0
fi

# 4) Nothing reviewable left once generated files are excluded.
if [ "$ng_files" -eq 0 ]; then
  emit false empty "" "Skipped — no non-generated files changed."
  exit 0
fi

# 5) Depth scale — how many judgement calls this diff is worth. Full rationale
#    and the band table: docs/adr/0004, Amendment 3. In one sentence: every 250
#    units of diff weight buys one more judgement slot, from 3 up to 8, and the
#    inline-comment cap is twice that.
#
#      weight = ng_lines + 25*ng_files (a file costs about what 25 lines cost)
#      depth_scale   = min(3 + weight/250, 8)  → the human_review / check ceiling
#      comment_limit = 2 * depth_scale         → post-review.sh REVIEW_COMMENT_LIMIT
#
#    Not a tier ladder: one continuous step function with two clamps, replacing
#    three flat constants (0-5 items, carry 5, cap 10) that gave a typo fix and a
#    2500-line refactor identical depth. A 400-line PR (the team limit) lands on
#    5/10 — exactly the old constants — so the common case does not move.
#    review_effort is unknown until scan has run; review-verify moves this by one
#    on it. Emitted on the proceed path only, so a short-circuited run sets no
#    step output and post-review.sh falls back to its own default.
weight=$(( ng_lines + 25 * ng_files ))
depth_scale=$(( 3 + weight / 250 ))
[ "$depth_scale" -gt 8 ] && depth_scale=8
printf 'depth_scale=%s\ncomment_limit=%s\n' "$depth_scale" "$(( depth_scale * 2 ))"

# No code to break, so review-scan's failure_scenario bar alone would silence it.
printf 'docs_only=%s\n' "$docs_only"
emit true ok "" "Reviewing ${ng_files} files / ${ng_lines} non-generated lines (depth ${depth_scale})."
