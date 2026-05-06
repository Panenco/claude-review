#!/usr/bin/env bash
set -uo pipefail

# verdict_ladder_test.sh — fixture test for the round-2 verdict ladder in
# build-review.sh. Mirrors the case statement at lines ~676-710 with the
# same shape, then asserts behavior across the cases the rework on
# Panenco/qiv#292 surfaced:
#
#   - prior=COMMENT + per-PR=APPROVE + no still-present  → APPROVE   (was COMMENT before fix)
#   - prior=COMMENT + per-PR=COMMENT (minor)             → COMMENT
#   - prior=COMMENT + new blocker (per-PR=REQUEST_CHANGES)→ REQUEST_CHANGES
#   - prior=REQUEST_CHANGES + still-present blocker      → REQUEST_CHANGES (override of per-PR=APPROVE)
#   - prior=REQUEST_CHANGES + still-present=0 + per-PR=APPROVE → APPROVE
#   - prior=APPROVE + per-PR=APPROVE                     → APPROVE
#   - prior=APPROVE + new blocker (per-PR=REQUEST_CHANGES)→ REQUEST_CHANGES
#
# Plus override-reason capture: only set when per-PR != final verdict.
#
# No LLM key required; pure decision-table.

cd "$(dirname "$0")/.."

fail=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — want '$want', got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# decide_ladder <PRIOR_VERDICT> <PER_PR_VERDICT> <HAS_BLOCKING> <STILL_PRESENT_BLOCKERS>
# Echoes "<FINAL_VERDICT>|<OVERRIDE_REASON>". Mirrors build-review.sh round-2
# case statement after the rework. PER_PR_VERDICT is the verdict the per-PR
# ladder produced (REQUEST_CHANGES if HAS_BLOCKING=true; otherwise COMMENT
# or APPROVE depending on whether any non-blocking findings remain).
decide_ladder() {
  local PRIOR_VERDICT="$1"
  local PER_PR_VERDICT="$2"
  local HAS_BLOCKING="$3"
  local STILL_PRESENT_BLOCKERS="$4"

  local VERDICT="$PER_PR_VERDICT"
  local LADDER_OVERRIDE_REASON=""

  case "$PRIOR_VERDICT" in
    REQUEST_CHANGES)
      if [ "$STILL_PRESENT_BLOCKERS" -gt 0 ]; then
        VERDICT="REQUEST_CHANGES"
        if [ "$PER_PR_VERDICT" != "REQUEST_CHANGES" ]; then
          LADDER_OVERRIDE_REASON="prior blockers still present"
        fi
      fi
      ;;
    COMMENT)
      :  # let per-PR stand
      ;;
    APPROVE)
      :  # let per-PR stand (HAS_BLOCKING already escalated upstream)
      ;;
  esac

  echo "${VERDICT}|${LADDER_OVERRIDE_REASON}"
}

echo "── Round-2 verdict ladder ──"

# Headline case: PR #292. Prior round flagged a doc-only nit (COMMENT).
# Round 2 fixed it; per-PR has zero findings. Old behaviour: COMMENT.
# New behaviour: APPROVE.
got=$(decide_ladder COMMENT APPROVE false 0)
assert_eq "prior=COMMENT, all resolved, per-PR=APPROVE → APPROVE" "APPROVE|" "$got"

# Round 2 still has minor findings: stays COMMENT.
got=$(decide_ladder COMMENT COMMENT false 0)
assert_eq "prior=COMMENT, minor still flagged, per-PR=COMMENT → COMMENT" "COMMENT|" "$got"

# Round 2 introduces a new blocker: per-PR ladder set REQUEST_CHANGES; ladder
# does not override that. No reason should be captured (it's not an override).
got=$(decide_ladder COMMENT REQUEST_CHANGES true 0)
assert_eq "prior=COMMENT, new blocker, per-PR=REQUEST_CHANGES → REQUEST_CHANGES (no override)" "REQUEST_CHANGES|" "$got"

# Prior REQUEST_CHANGES with the blocker still present, but new commit is
# clean enough that per-PR landed APPROVE. Ladder must override.
got=$(decide_ladder REQUEST_CHANGES APPROVE false 1)
assert_eq "prior=REQUEST_CHANGES, still-present>0, per-PR=APPROVE → REQUEST_CHANGES (overridden)" "REQUEST_CHANGES|prior blockers still present" "$got"

# Same prior REQUEST_CHANGES, but the prior blocker is now resolved AND no
# new findings — APPROVE.
got=$(decide_ladder REQUEST_CHANGES APPROVE false 0)
assert_eq "prior=REQUEST_CHANGES, all resolved, per-PR=APPROVE → APPROVE" "APPROVE|" "$got"

# Prior REQUEST_CHANGES, prior blocker resolved, but per-PR has new minors:
# COMMENT.
got=$(decide_ladder REQUEST_CHANGES COMMENT false 0)
assert_eq "prior=REQUEST_CHANGES, all resolved, per-PR=COMMENT → COMMENT" "COMMENT|" "$got"

# Prior REQUEST_CHANGES + still-present=1 + per-PR also REQUEST_CHANGES (new
# blocker too). The ladder confirms REQUEST_CHANGES but that's NOT an
# override — both inputs already say REQUEST_CHANGES.
got=$(decide_ladder REQUEST_CHANGES REQUEST_CHANGES true 1)
assert_eq "prior=REQUEST_CHANGES, still-present>0, per-PR=REQUEST_CHANGES → REQUEST_CHANGES (confirmation, no override reason)" "REQUEST_CHANGES|" "$got"

# Prior APPROVE, new push has no findings: APPROVE.
got=$(decide_ladder APPROVE APPROVE false 0)
assert_eq "prior=APPROVE, per-PR=APPROVE → APPROVE" "APPROVE|" "$got"

# Prior APPROVE, new push has a blocker: per-PR is REQUEST_CHANGES; ladder
# lets it stand.
got=$(decide_ladder APPROVE REQUEST_CHANGES true 0)
assert_eq "prior=APPROVE, new blocker, per-PR=REQUEST_CHANGES → REQUEST_CHANGES" "REQUEST_CHANGES|" "$got"

# Round-2 verdict_max degraded path: not exercised by decide_ladder above
# because that path runs when RESOLUTION_VALID=false. Validate the
# verdict_max contract directly instead.
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

echo ""
echo "── verdict_max (degraded round-2) ──"
assert_eq "max(REQUEST_CHANGES, APPROVE)"     "REQUEST_CHANGES" "$(verdict_max REQUEST_CHANGES APPROVE)"
assert_eq "max(COMMENT, APPROVE)"             "COMMENT"         "$(verdict_max COMMENT APPROVE)"
assert_eq "max(APPROVE, APPROVE)"             "APPROVE"         "$(verdict_max APPROVE APPROVE)"
assert_eq "max(REQUEST_CHANGES, COMMENT)"     "REQUEST_CHANGES" "$(verdict_max REQUEST_CHANGES COMMENT)"
# Unknown enum fails closed.
assert_eq "max(UNKNOWN, APPROVE)"             "REQUEST_CHANGES" "$(verdict_max UNKNOWN APPROVE)"
assert_eq "max(empty, APPROVE)"               "REQUEST_CHANGES" "$(verdict_max '' APPROVE)"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All verdict-ladder tests passed."
  exit 0
else
  echo "$fail verdict-ladder test(s) failed."
  exit 1
fi
