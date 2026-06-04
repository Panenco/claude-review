#!/usr/bin/env bash
# review-plan.sh — Deterministic PR-shape classifier (the "review-plan resolver").
#
# Decides, from a PR's changed files + branch refs + labels, HOW MUCH review the PR
# warrants — BEFORE any LLM agent runs. Pure function of its inputs (no network, no
# LLM) so it is unit-testable in isolation (see tests/review_plan_test.sh).
#
# Output (KEY=value lines on stdout, ready to append to $GITHUB_OUTPUT):
#   review_level=full|light|skip
#   run_functional=true|false
#   gate=normal|nonruntime|oversized|promotion|label|small
#   reason=<human-readable, single line>
#
# review_level (consumed by review-orchestrator.md):
#   full   — dual-judge debate (+ rebuttal); functional per run_functional
#   light  — single judge, no rebuttal, no functional (cheap pass)
#   skip   — early-return: no judges; post the reason as a note
# run_functional — drive the app via the functional tester (only meaningful at `full`)
# gate           — the classification that produced the decision (stable, for banners)
#
# Mapping:
#   label       → skip  / functional off   (human opted out — respect it; beats deep-review if both)
#   deep-review → full  / functional on    (label; forces full — suppresses promotion/oversized/small.
#                                           Does NOT turn functional on for an all-nonruntime PR.)
#   promotion   → light / functional off   (source already reviewed; cheap insurance)
#   oversized   → light / functional off   (too big for full; a single judge catches the worst)
#   nonruntime  → full  / functional off   (tests/docs/CI/locks — judges yes, no app-driving)
#   small       → light / functional off   (<= GATE_SMALL_CEILING non-gen lines, no sensitive paths)
#   normal      → full  / functional on    (substantial, OR touches a sensitive path)
#
# Inputs (env; all optional — safe, review-biased defaults):
#   GATE_FILES_TSV       one "path<TAB>additions<TAB>deletions" line per changed file
#   GATE_BASE_REF        PR base branch (e.g. main)
#   GATE_HEAD_REF        PR head branch (e.g. staging)
#   GATE_LABELS          newline-separated PR label names
#   GATE_SKIP_LABEL      label that forces a skip (default: skip-review)
#   GATE_DEEP_LABEL      label that forces a full review (default: deep-review)
#   GATE_SIZE_CEILING    non-generated changed lines → oversized (default 1500)
#   GATE_FILE_CEILING    non-generated changed files → oversized (default 40)
#   GATE_SMALL_CEILING   non-gen lines at/under which a runtime PR → small/light (default 300)
#   GATE_SENSITIVE_GLOBS space-separated path globs that force full even when small
#                        (default: auth.* / oauth / authentication / authorization /
#                        security / payments / migrations. A bare "auth/" dir is NOT
#                        sensitive by default — frontends use views/auth/ as the signed-in
#                        route group; add "*/auth/*" per-repo if yours holds auth logic.)
#   GATE_PROMOTION_BASES space-separated release targets (default: main master production prod)
#   GATE_PROMOTION_HEADS space-separated promotion sources, exact or "<name>/*" prefix
#                        (default: staging develop dev release hotfix)
#
# Design bias: a false-downgrade (miss a bug) is worse than a false-full-review
# (waste), so anything ambiguous (tsconfig, build/app config, source) counts as
# RUNTIME and gets a full review. The bot only downgrades when confident.

set -uo pipefail

BASE_REF="${GATE_BASE_REF:-}"
HEAD_REF="${GATE_HEAD_REF:-}"
SKIP_LABEL="${GATE_SKIP_LABEL:-skip-review}"
DEEP_LABEL="${GATE_DEEP_LABEL:-deep-review}"
SIZE_CEILING="${GATE_SIZE_CEILING:-1500}"
FILE_CEILING="${GATE_FILE_CEILING:-40}"
SMALL_CEILING="${GATE_SMALL_CEILING:-300}"
PROMO_BASES="${GATE_PROMOTION_BASES:-main master production prod}"
PROMO_HEADS="${GATE_PROMOTION_HEADS:-staging develop dev release hotfix}"
SENSITIVE_GLOBS="${GATE_SENSITIVE_GLOBS:-*auth.* */oauth/* oauth.* */authentication/* authentication/* */authorization/* authorization/* */security/* security/* */payments/* payments/* */payment/* payment/* */migrations/* migrations/* */migration/* migration/*}"

emit() {
  # $1 review_level, $2 run_functional, $3 gate, $4 reason
  printf 'review_level=%s\nrun_functional=%s\ngate=%s\nreason=%s\n' "$1" "$2" "$3" "$4"
}
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── 1) Explicit human override: skip label present? (highest precedence) ──
if [ -n "${GATE_LABELS:-}" ] && printf '%s\n' "$GATE_LABELS" | grep -Fxq "$SKIP_LABEL"; then
  emit "skip" "false" "label" "Skipping detailed review — '$SKIP_LABEL' label present (reviewed elsewhere / opted out)."
  exit 0
fi

# ── 1b) deep-review label → force a full review (suppresses the light downgrades
#        below). skip-review (above) wins if both labels are present. ──
FORCE_FULL=false
if [ -n "${GATE_LABELS:-}" ] && printf '%s\n' "$GATE_LABELS" | grep -Fxq "$DEEP_LABEL"; then
  FORCE_FULL=true
fi

# ── 2) Promotion / release PR? base is a release target AND head is a promotion source ──
is_promotion() {
  local base head h b ok=1
  local -a bases heads
  base=$(lc "$BASE_REF"); head=$(lc "$HEAD_REF")
  [ -z "$base" ] && return 1
  read -ra bases <<< "$PROMO_BASES"
  read -ra heads <<< "$PROMO_HEADS"
  for b in "${bases[@]}"; do [ "$base" = "$(lc "$b")" ] && ok=0 && break; done
  [ "$ok" -ne 0 ] && return 1
  for h in "${heads[@]}"; do
    h=$(lc "$h")
    [ "$head" = "$h" ] && return 0
    case "$head" in "$h"/*) return 0 ;; esac
  done
  return 1
}
if [ "$FORCE_FULL" = false ] && is_promotion; then
  emit "light" "false" "promotion" "Release/promotion PR ($HEAD_REF → $BASE_REF): source changes were reviewed on their own PRs — lightweight pass only (single judge, no functional)."
  exit 0
fi

# ── File classification ──
# Excluded from the SIZE count (presence doesn't make a PR "big"):
is_generated() {
  case "$1" in
    *.lock|package-lock.json|pnpm-lock.yaml|*.snap) return 0 ;;
    dist/*|*/dist/*|build/*|*/build/*|*.min.js|*.min.css|*.generated.*|*.pb.go|*_pb2.py) return 0 ;;
    *) return 1 ;;
  esac
}
# Non-runtime: a file that cannot change app behavior → functional testing pointless.
# Conservative: only clearly-non-runtime paths. Ambiguous (tsconfig, *.config.*, app
# yaml/json, source) is treated as runtime.
is_nonruntime() {
  case "$1" in
    *.spec.*|*.test.*|*_test.*|*.cy.*|*/e2e/*|e2e/*|*/cypress/*|cypress/*|*/__tests__/*|*/tests/*|tests/*|*/test/*|test/*) return 0 ;;
    *.md|*.mdx|*.txt|docs/*|*/docs/*|LICENSE) return 0 ;;
    .github/*) return 0 ;;
    *.lock|package-lock.json|pnpm-lock.yaml|*.snap) return 0 ;;
    *) return 1 ;;
  esac
}
# Sensitive: high-risk runtime areas where a single judge isn't enough — these force
# a full review even when the diff is small. Configurable via GATE_SENSITIVE_GLOBS.
is_sensitive() {
  [ -n "$SENSITIVE_GLOBS" ] || return 1
  local p g; local -a globs
  p=$(lc "$1")
  read -ra globs <<< "$SENSITIVE_GLOBS"
  for g in "${globs[@]}"; do
    # shellcheck disable=SC2254  # $g is intentionally a glob pattern, not a literal
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}

ng_lines=0; ng_files=0; total_files=0; all_nonruntime=true; has_sensitive=false
while IFS=$'\t' read -r path adds dels; do
  [ -z "$path" ] && continue
  total_files=$(( total_files + 1 ))
  is_nonruntime "$path" || all_nonruntime=false
  # Sensitivity is a property of the path (generated or not): a touch under a
  # sensitive glob forces a full review even if it doesn't count toward size.
  is_sensitive "$path" && has_sensitive=true
  if ! is_generated "$path"; then
    ng_files=$(( ng_files + 1 ))
    [[ "${adds:-}" =~ ^[0-9]+$ ]] && ng_lines=$(( ng_lines + adds ))
    [[ "${dels:-}" =~ ^[0-9]+$ ]] && ng_lines=$(( ng_lines + dels ))
  fi
done <<< "${GATE_FILES_TSV:-}"

# Size verdict, precomputed so the guard below stays a simple check.
oversized=false
if [ "$ng_lines" -gt "$SIZE_CEILING" ] || [ "$ng_files" -gt "$FILE_CEILING" ]; then
  oversized=true
fi

# ── 3) Oversized (non-promotion)? Lightweight pass + a "split / label" note.
#       deep-review (FORCE_FULL) suppresses this downgrade. ──
if [ "$FORCE_FULL" = false ] && [ "$oversized" = true ]; then
  emit "light" "false" "oversized" "PR too large for a full review (${ng_files} files, ${ng_lines} non-generated lines; ceiling ${FILE_CEILING} files / ${SIZE_CEILING} lines) — lightweight single-judge pass. Consider splitting (team limit: 400 lines), or add the '$SKIP_LABEL' label if this bundles already-reviewed work."
  exit 0
fi

# ── 4) All changed files non-runtime? Full review, but don't drive the app ──
if [ "$total_files" -gt 0 ] && [ "$all_nonruntime" = true ]; then
  emit "full" "false" "nonruntime" "All ${total_files} changed files are non-runtime (tests / docs / CI / lockfiles); running the judges but skipping functional app-testing."
  exit 0
fi

# ── 5) Small, non-sensitive runtime change with real (non-generated) source? One
#       judge is enough — skip the debate and functional. All-generated diffs,
#       sensitive paths, and the deep-review label fall through to full. ──
if [ "$ng_files" -gt 0 ] && [ "$FORCE_FULL" = false ] && [ "$has_sensitive" = false ] && [ "$ng_lines" -le "$SMALL_CEILING" ]; then
  emit "light" "false" "small" "Small runtime change (${ng_files} files, ${ng_lines} non-generated lines, at/under the ${SMALL_CEILING}-line small-PR ceiling; no sensitive paths) — lightweight single-judge pass. Add the '$DEEP_LABEL' label to force a full review."
  exit 0
fi

# ── 6) Normal — full review, functional eligible (substantial, or sensitive paths) ──
emit "full" "true" "normal" "Eligible for full review (${ng_files} runtime-relevant files, ${ng_lines} non-generated lines)."
