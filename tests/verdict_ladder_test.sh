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

# decide_degraded <PRIOR_VERDICT> <PER_PR_VERDICT> <SINCE_LAST_EXISTS> <THREAD_RES_EXISTS>
# Echoes "<FINAL_VERDICT>|<OVERRIDE_REASON>". Mirrors build-review.sh's
# RESOLUTION_VALID=false branch after the shallow-clone-fallback split:
#
#   since-last.diff absent      → trust per-PR (judges saw full diff)
#   since-last.diff present     → classifier was supposed to run; pin via
#                                  verdict_max because resolution is unknown
decide_degraded() {
  local PRIOR_VERDICT="$1"
  local PER_PR_VERDICT="$2"
  local SINCE_LAST_EXISTS="$3"
  local THREAD_RES_EXISTS="$4"

  local VERDICT="$PER_PR_VERDICT"
  local LADDER_OVERRIDE_REASON=""

  if [ "$SINCE_LAST_EXISTS" = "false" ]; then
    :  # shallow-clone fallback — no pin, no override reason
  else
    local DEGRADED_REASON="missing"
    [ "$THREAD_RES_EXISTS" = "true" ] && DEGRADED_REASON="malformed"
    VERDICT=$(verdict_max "$PRIOR_VERDICT" "$PER_PR_VERDICT")
    if [ "$VERDICT" != "$PER_PR_VERDICT" ]; then
      LADDER_OVERRIDE_REASON="prior verdict was $PRIOR_VERDICT and the round-2 thread-resolution was $DEGRADED_REASON; pinned to the more severe of (prior, per-PR) so we never silently downgrade"
    fi
  fi

  echo "${VERDICT}|${LADDER_OVERRIDE_REASON}"
}

echo ""
echo "── degraded round-2 branch split (shallow-clone vs real failure) ──"

# Headline case: qiv#350 (PRIOR_HEAD_SHA outside shallow clone). Prior was
# REQUEST_CHANGES, judges reviewed the full diff in round-1 fallback mode
# and landed APPROVE. Old behaviour pinned to REQUEST_CHANGES; new
# behaviour trusts the per-PR verdict.
got=$(decide_degraded REQUEST_CHANGES APPROVE false false)
assert_eq "shallow-clone: prior=REQUEST_CHANGES, per-PR=APPROVE → APPROVE (no pin)" "APPROVE|" "$got"

# Same fallback, per-PR landed COMMENT (minor finding in the full re-review).
got=$(decide_degraded REQUEST_CHANGES COMMENT false false)
assert_eq "shallow-clone: prior=REQUEST_CHANGES, per-PR=COMMENT → COMMENT (no pin)" "COMMENT|" "$got"

# Fallback with a benign prior: no behaviour change expected.
got=$(decide_degraded APPROVE APPROVE false false)
assert_eq "shallow-clone: prior=APPROVE, per-PR=APPROVE → APPROVE (no pin)" "APPROVE|" "$got"

# Real degraded round-2: since-last.diff existed, classifier should have run
# but its output is missing — pin must still fire (this is the protection
# against the classifier crashing).
got=$(decide_degraded REQUEST_CHANGES APPROVE true false)
assert_eq "degraded: prior=REQUEST_CHANGES, per-PR=APPROVE, thread-res missing → REQUEST_CHANGES (pin)" \
  "REQUEST_CHANGES|prior verdict was REQUEST_CHANGES and the round-2 thread-resolution was missing; pinned to the more severe of (prior, per-PR) so we never silently downgrade" "$got"

# Real degraded with a malformed thread-resolution.json (classifier crashed
# mid-write). Different DEGRADED_REASON in the override message.
got=$(decide_degraded REQUEST_CHANGES APPROVE true true)
assert_eq "degraded: prior=REQUEST_CHANGES, per-PR=APPROVE, thread-res malformed → REQUEST_CHANGES (pin)" \
  "REQUEST_CHANGES|prior verdict was REQUEST_CHANGES and the round-2 thread-resolution was malformed; pinned to the more severe of (prior, per-PR) so we never silently downgrade" "$got"

# Real degraded but prior was benign and per-PR matched it — pin is a no-op
# and we must not capture an override reason (it'd misleadingly narrate
# a non-existent override).
got=$(decide_degraded APPROVE APPROVE true false)
assert_eq "degraded: prior=APPROVE, per-PR=APPROVE → APPROVE (pin no-op, no override)" "APPROVE|" "$got"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All verdict-ladder tests passed."
  exit 0
else
  echo "$fail verdict-ladder test(s) failed."
  exit 1
fi
