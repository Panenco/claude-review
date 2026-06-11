#!/usr/bin/env bash
# refine-review-plan.sh — Round-2 review-plan refinement.
#
# Most runs are follow-up rounds, and a small fix-up commit on a large PR
# doesn't need the full Opus+Haiku debate the full-PR shape resolves to —
# round-2 judges are already scoped to the since-last diff, the verdict
# ladder pins unresolved prior blockers, and the thread classifier runs
# regardless of judge count. So: re-resolve the plan (review-plan.sh)
# against the diff since the last reviewed commit, with guards that keep
# quality intact:
#
#   - round 1 / unreachable prior SHA      → keep the full-PR plan
#   - full-PR plan is `skip` or `light`    → keep it (already the floor)
#   - deep-review label                    → keep the full-PR plan
#   - empty since-last (same-SHA re-run)   → light, no functional
#   - otherwise                            → review-plan.sh on the
#     since-last shape (skip label, sensitive paths, ceilings re-apply)
#   - escalation: refined `light` while no prior round ran `full` → keep
#     the full-PR plan. A PR can't grow large through many small pushes
#     without ever getting the full debate.
#
# Inputs (env):
#   ORIG_LEVEL / ORIG_FUNCTIONAL / ORIG_GATE / ORIG_REASON
#                      the full-PR plan from review-plan.sh
#   ROUND2_AVAILABLE   "true" only when prior state loaded AND the prior
#                      head SHA is reachable in the clone (caller verifies)
#   PRIOR_LEVEL        review_level persisted by the prior round; empty
#                      means a pre-tiering state file → treat as "full"
#   PRIOR_HEAD_SHA     used in reason strings only
#   SINCE_FILES_TSV    "path<TAB>adds<TAB>dels" lines of the since-last diff
#   GATE_*             forwarded to review-plan.sh (labels, ceilings, globs)
#
# Output: same KEY=value contract as review-plan.sh.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

ORIG_LEVEL="${ORIG_LEVEL:-full}"
ORIG_FUNCTIONAL="${ORIG_FUNCTIONAL:-true}"
ORIG_GATE="${ORIG_GATE:-normal}"
ORIG_REASON="${ORIG_REASON:-}"

emit() {
  printf 'review_level=%s\nrun_functional=%s\ngate=%s\nreason=%s\n' "$1" "$2" "$3" "$4"
}
passthrough() {
  emit "$ORIG_LEVEL" "$ORIG_FUNCTIONAL" "$ORIG_GATE" "${1:-$ORIG_REASON}"
}

if [ "${ROUND2_AVAILABLE:-false}" != "true" ]; then
  passthrough; exit 0
fi
if [ "$ORIG_LEVEL" != "full" ]; then
  passthrough; exit 0
fi
if [ -n "${GATE_LABELS:-}" ] && printf '%s\n' "$GATE_LABELS" | grep -Fxq "${GATE_DEEP_LABEL:-deep-review}"; then
  passthrough; exit 0
fi

if [ -z "${SINCE_FILES_TSV:-}" ]; then
  emit "light" "false" "small" "No changes since the last reviewed commit (${PRIOR_HEAD_SHA:-prior head}) — lightweight re-check."
  exit 0
fi

REFINED=$(GATE_FILES_TSV="$SINCE_FILES_TSV" "$DIR/review-plan.sh")
R_LEVEL=$(grep '^review_level=' <<< "$REFINED" | cut -d= -f2)
R_FUNCTIONAL=$(grep '^run_functional=' <<< "$REFINED" | cut -d= -f2)
R_GATE=$(grep '^gate=' <<< "$REFINED" | cut -d= -f2)
R_REASON=$(grep '^reason=' <<< "$REFINED" | cut -d= -f2-)

if [ "$R_LEVEL" = "light" ] && [ "${PRIOR_LEVEL:-full}" != "full" ]; then
  passthrough "$ORIG_REASON (round-2 escalation: the full PR warrants a full review and no prior round ran one)"
  exit 0
fi

emit "$R_LEVEL" "$R_FUNCTIONAL" "$R_GATE" "Round 2, planned on the diff since the last review: $R_REASON"
