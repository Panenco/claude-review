#!/usr/bin/env bash
# merge-scans.sh — union the shard scans (scan-<i>.json) into the one scan.json
# review-verify reads. Verify is unchanged; only its input is assembled here.
#
# Findings dedupe on the SAME identity prior-findings.sh and post-review.sh use
# (path + normalised title), so a defect two shards both saw is one finding.
# Notes are taken round-robin across shards and capped at REVIEW_DEPTH_SCALE, so
# every area keeps its top note under the cap. Scalars: `context.area`,
# `summary`, `depth_reason` from shard 1 (the heaviest — shard-plan.sh sorts by
# path, the orchestrator dispatches in order); flags OR; `review_effort` max;
# `approve_argument` only when EVERY shard argued for approval.
#
# A MISSING SHARD IS NEVER SILENT. shard-plan.sh writes shard-count; when fewer
# shards merged than were planned, the files nobody read cannot vouch for an
# approval, so `approve_argument` is blanked and the gap is warned about. The
# merge still happens — the shards that did report are real findings.
#
# Never fails the run: nothing parseable → nothing written, and the
# orchestrator's degraded path handles a missing scan.json as it does today.
set -uo pipefail

OUT_DIR="${OUT_DIR:-/tmp}"
N="${REVIEW_DEPTH_SCALE:-5}"; case "$N" in ''|*[!0-9]*) N=5 ;; esac

parts=()
for f in "$OUT_DIR"/scan-[0-9]*.json; do
  [ -f "$f" ] || continue
  if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then parts+=("$f")
  else echo "::warning::merge-scans: $f is not a JSON object — that shard contributes nothing."; fi
done
if [ "${#parts[@]}" -eq 0 ]; then echo "merged=0"; exit 0; fi
PLANNED=$(cat "$OUT_DIR/shard-count" 2>/dev/null || echo "${#parts[@]}")
case "$PLANNED" in ''|*[!0-9]*) PLANNED=${#parts[@]} ;; esac
COMPLETE=true
# The files of a shard that never reported are written out by name: the poster
# tells the reader, stamps them into the review state, and the next round's
# shard plan folds them back in — so a lost shard costs one round, not the files.
: > "$OUT_DIR/unreviewed-files.txt"
if [ "${#parts[@]}" -lt "$PLANNED" ]; then
  COMPLETE=false
  for i in $(seq 1 "$PLANNED"); do
    [ -f "$OUT_DIR/scan-$i.json" ] && jq -e 'type == "object"' "$OUT_DIR/scan-$i.json" >/dev/null 2>&1 && continue
    [ -f "$OUT_DIR/shard-$i.txt" ] && cat "$OUT_DIR/shard-$i.txt" >> "$OUT_DIR/unreviewed-files.txt"
  done
  echo "::warning::merge-scans: $PLANNED shard(s) were planned and ${#parts[@]} reported — $(grep -c . "$OUT_DIR/unreviewed-files.txt") file(s) were not reviewed this round (listed in unreviewed-files.txt), so this round cannot approve."
fi

JQ_NORM='def norm: gsub("[\r\n]+"; " ") | sub("^[ \t]*\\*\\*(critical|major|minor)\\*\\*[ \t]*"; ""; "i") | gsub("[`*]"; "") | gsub("[ \t]+"; " ") | sub("^ "; "") | sub(" $"; "") | ascii_downcase | sub("[.!?]+$"; "");'

jq -s --argjson n "$N" --argjson complete "$COMPLETE" "$JQ_NORM"'
  def rr(k): [ . as $lists | range(0; ($lists | map(length) | max) // 0) as $i
               | $lists[] | select(length > $i) | .[$i] ] | .[:k];
  . as $s
  | ($s | map(.findings // []) | add | unique_by([.path, (.title // "" | norm)])) as $f
  | ($s | map(.prior_findings // []) | add | unique_by(.id)) as $carried
  | ($carried | map(.id)) as $cids
  | {
      depth_used: (if any($s[]; .depth_used == "full") then "full" else ($s[0].depth_used // "light") end),
      context: {
        area: ($s[0].context.area // ""),
        changes: ($s | map(.context.changes // []) | rr(4)),
        mermaid: ([$s[] | .context.mermaid // "" | select(. != "")] | .[0] // "")
      },
      depth_reason: ($s[0].depth_reason // ""),
      review_effort: ([$s[] | .review_effort // 3] | max),
      summary: ($s[0].summary // ""),
      findings: $f,
      prior_findings: $carried,
      resolved_prior: ($s | map(.resolved_prior // []) | add | unique_by(.id) | map(select((.id | IN($cids[])) | not))),
      human_review: ($s | map(.human_review // []) | rr($n)),
      approve_argument: (if $complete and all($s[]; (.approve_argument // "") != "") then ($s[0].approve_argument) else "" end),
      sensitive_paths_touched: any($s[]; .sensitive_paths_touched == true),
      prompt_injection_detected: any($s[]; .prompt_injection_detected == true)
    }' "${parts[@]}" > "$OUT_DIR/scan.json.merged" 2>/dev/null \
  && mv "$OUT_DIR/scan.json.merged" "$OUT_DIR/scan.json" \
  || { echo "::warning::merge-scans: could not merge ${#parts[@]} shard(s) — no scan.json written."; rm -f "$OUT_DIR/scan.json.merged"; echo "merged=0"; exit 0; }
echo "merged=${#parts[@]}"
