#!/usr/bin/env bash
# shard-plan.sh — split a large diff into shards, one review-scan each.
#
# One agent reading a 61-file / 2.7k-line diff in ~15 turns does the
# investigative work and runs out of room to file: replayed twice on one audited client PR
# it found 3 and then 1 of the 19 defects a human found, while its transcript
# shows it had read the evidence for most of the rest. Each shard reads a
# fraction of the diff at the same depth; review-verify still runs once.
#
# Pure function of its inputs — unit-tested in tests/shard_plan_test.sh.
#
# In  (env): SHARD_FILES_TSV ("path<TAB>additions<TAB>deletions" per file) or,
#            when unset, the `files` of PR_JSON (default /tmp/pr.json).
#            SHARD_MIN_LINES (1200) / SHARD_MIN_FILES (30): below BOTH, one shard.
#            SHARD_TARGET (900): weight one shard should carry. SHARD_MAX (4).
#            GATE_GENERATED_GLOBS: the consumer's extra build-output globs, as guard.sh.
#            PRIOR_FINDINGS_JSON (OUT_DIR/prior-findings.json): on a delta round
#            the file list holds only what this push touched, but every carried
#            finding must still be owned by SOME shard — its path is added at
#            zero weight so the shard that gets it accounts for it.
#            UNREVIEWED_FILE (OUT_DIR/unreviewed-files.txt): files a shard of the
#            LAST round never reported on (prior-findings.sh reads them back out
#            of the review state); folded in the same way, so they get read.
#            OUT_DIR (/tmp): where shard-<i>.txt land (one path per line), plus
#            shard-count, which merge-scans.sh reads to notice a missing shard.
# Out (stdout): shards=<n>, then shard_<i>=<files>/<lines> per shard.
#
# Sorted by path, cut into contiguous chunks of about equal weight: siblings are
# adjacent in path order, so a cut lands between directories far more often than
# inside one, and no tree logic is needed. weight = lines + 25*files, as guard.sh.
set -uo pipefail # No `set -e` (repo rule, bugbot.md).

OUT_DIR="${OUT_DIR:-/tmp}"
MIN_LINES="${SHARD_MIN_LINES:-1200}"
MIN_FILES="${SHARD_MIN_FILES:-30}"
TARGET="${SHARD_TARGET:-900}"
MAX="${SHARD_MAX:-4}"

# Mirrors guard.sh is_generated — tests/pipeline_contract_test.sh asserts the
# two case lists are byte-identical, so edit both or neither. The repo-declared
# globs are walked with `read`, which never pathname-expands, so no `set -f`.
GENERATED_GLOBS="${GATE_GENERATED_GLOBS:-}"
is_generated() {
  case "$1" in
    *.lock|package-lock.json|pnpm-lock.yaml|*.snap) return 0 ;;
    dist/*|*/dist/*|build/*|*/build/*|*.min.js|*.min.css|*.generated.*|*.pb.go|*_pb2.py) return 0 ;;
    openapi*.json|openapi*.yaml|openapi*.yml|*/openapi*.json|*/openapi*.yaml|*/openapi*.yml) return 0 ;;
    swagger*.json|swagger*.yaml|swagger*.yml|*/swagger*.json|*/swagger*.yaml|*/swagger*.yml) return 0 ;;
    schema.graphql|*/schema.graphql|*.gen.*|__generated__/*|*/__generated__/*) return 0 ;;
  esac
  local glob
  while read -r glob; do
    [ -n "$glob" ] || continue
    case "$1" in $glob) return 0 ;; esac
  done <<< "${GENERATED_GLOBS// /$'\n'}"
  return 1
}

TSV="${SHARD_FILES_TSV:-}"
if [ -z "$TSV" ]; then
  TSV=$(jq -r '.files[]? | "\(.path)\t\(.additions // 0)\t\(.deletions // 0)"' "${PR_JSON:-/tmp/pr.json}" 2>/dev/null)
fi

# Carried findings whose file this push did not touch still need an owner, and
# so do the files a shard of the last round never reported on.
PF="${PRIOR_FINDINGS_JSON:-$OUT_DIR/prior-findings.json}"
UF="${UNREVIEWED_FILE:-$OUT_DIR/unreviewed-files.txt}"
carried=0
if [ -n "$TSV" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF -- "$p" <(cut -f1 <<< "$TSV") || { TSV+=$'\n'"$p"$'\t0\t0'; carried=$(( carried + 1 )); }
  done < <( { jq -e 'type == "array"' "$PF" >/dev/null 2>&1 && jq -r '.[] | .p // empty' "$PF" 2>/dev/null
              [ -s "$UF" ] && grep . "$UF"; } | sort -u)
fi

rm -f "$OUT_DIR"/shard-[0-9]*.txt "$OUT_DIR/shard-count" 2>/dev/null
total=0; files=0; rows=""
while IFS=$'\t' read -r path adds dels; do
  [ -z "$path" ] && continue
  is_generated "$path" && continue
  [[ "${adds:-}" =~ ^[0-9]+$ ]] || adds=0
  [[ "${dels:-}" =~ ^[0-9]+$ ]] || dels=0
  w=$(( adds + dels + 25 ))
  total=$(( total + w )); files=$(( files + 1 ))
  rows+="$path	$w"$'\n'
done <<< "$TSV"

lines=$(( total - 25 * files ))
n=1
if [ "$lines" -ge "$MIN_LINES" ] || [ "$files" -ge "$MIN_FILES" ]; then
  n=$(( (total + TARGET - 1) / TARGET ))
  [ "$n" -gt "$MAX" ] && n=$MAX
  [ "$n" -lt 1 ] && n=1
fi
# A carried file only reaches a scan through a shard list: the one-shard round
# names no files and reviews the since-last delta, which does not contain it.
# So a round that carries anything is sharded, however small its own diff.
[ "$carried" -gt 0 ] && [ "$n" -lt 2 ] && n=2
if [ "$n" -eq 1 ]; then echo 1 > "$OUT_DIR/shard-count"; echo "shards=1"; exit 0; fi

# Greedy contiguous fill: a shard closes once it reaches total/n, except the last,
# which takes everything left. Sorted first so the cuts fall between directories.
printf '%s' "$rows" | LC_ALL=C sort | awk -F'\t' -v n="$n" -v total="$total" -v out="$OUT_DIR" '
  BEGIN { per = total / n; i = 1; acc = 0; f = 0; l = 0 }
  {
    file = out "/shard-" i ".txt"
    print $1 >> file
    acc += $2; f++; l += $2 - 25
    if (i < n && acc >= per) { printf "shard_%d=%d/%d\n", i, f, l; close(file); i++; acc = 0; f = 0; l = 0 }
  }
  # The last row may itself have closed a shard, leaving i one past the files
  # written — report the shards that exist, never one the orchestrator would
  # dispatch a scan at and find missing.
  END { if (f > 0) { printf "shard_%d=%d/%d\n", i, f, l; print "shards=" i } else print "shards=" (i - 1) }
' | { out=$(cat); n=$(sed -n 's/^shards=//p' <<<"$out"); echo "$n" > "$OUT_DIR/shard-count"; echo "shards=$n"; echo "$out" | grep '^shard_'; }
