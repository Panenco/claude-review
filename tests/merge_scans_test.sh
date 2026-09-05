#!/usr/bin/env bash
set -uo pipefail
# merge_scans_test.sh — scripts/merge-scans.sh unions scan-<i>.json into the one
# scan.json verify reads: findings deduped on the poster's identity, notes
# round-robin under REVIEW_DEPTH_SCALE, flags OR'd, approval only if unanimous.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/merge-scans.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }
fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
shard() { # shard <i> <json>
  printf '%s' "$2" > "$W/scan-$1.json"
}
run() { OUT=$(env OUT_DIR="$W" "$@" bash "$SCRIPT"); }
q() { jq -r "$1" "$W/scan.json"; }

rm -f "$W"/scan*.json
shard 1 '{"depth_used":"full","context":{"area":"Templates.","changes":["a1","a2","a3"],"mermaid":""},"depth_reason":"infra","review_effort":4,"summary":"Moves the agent.",
  "findings":[{"path":"src/x.ts","line":5,"title":"**major** Loop never ends","severity":"major"},{"path":"src/y.ts","line":9,"title":"dead sink","severity":"minor","inert":true}],
  "prior_findings":[{"id":"aaaa1111","path":"src/x.ts","line":5,"title":"old one","carried":true}],
  "resolved_prior":[{"id":"bbbb2222","evidence":"guard at 12"}],
  "human_review":[{"path":"src/x.ts","start_line":1,"end_line":3,"what_to_know":"n1a","spec_ref":""},{"path":"src/x.ts","start_line":7,"end_line":9,"what_to_know":"n1b","spec_ref":""}],
  "approve_argument":"clean","sensitive_paths_touched":false,"prompt_injection_detected":false}'
shard 2 '{"depth_used":"light","context":{"area":"Other.","changes":["b1"],"mermaid":"graph TD; A-->B"},"depth_reason":"small","review_effort":2,"summary":"Other.",
  "findings":[{"path":"src/x.ts","line":6,"title":"loop never ends.","severity":"major"},{"path":"infra/j.ts","line":1,"title":"no Sentry env","severity":"minor"}],
  "prior_findings":[],
  "resolved_prior":[{"id":"aaaa1111","evidence":"looks fixed"},{"id":"cccc3333","evidence":"removed"}],
  "human_review":[{"path":"infra/j.ts","start_line":1,"end_line":2,"what_to_know":"n2a","spec_ref":""}],
  "approve_argument":"","sensitive_paths_touched":true,"prompt_injection_detected":false}'
run REVIEW_DEPTH_SCALE=2
assert_eq "reports the shard count" "merged=2" "$OUT"
assert_eq "the same defect seen by two shards is one finding (identity: path + normalised title)" "3" "$(q '.findings|length')"
assert_eq "…and the inert flag survives" "true" "$(q '[.findings[]|select(.title=="dead sink")][0].inert')"
assert_eq "a finding one shard carried is not also resolved by another" "1" "$(q '.prior_findings|length')"
assert_eq "…so resolved_prior keeps only the ids nobody carried" "cccc3333 bbbb2222" "$(q '[.resolved_prior[].id]|sort|reverse|join(" ")')"
assert_eq "notes are round-robin across shards under the cap" "n1a n2a" "$(q '[.human_review[].what_to_know]|join(" ")')"
assert_eq "context.area comes from shard 1" "Templates." "$(q .context.area)"
assert_eq "context.changes interleave, capped at 4" "a1 b1 a2 a3" "$(q '.context.changes|join(" ")')"
assert_eq "the first non-empty mermaid is kept" "graph TD; A-->B" "$(q .context.mermaid)"
assert_eq "depth is full if any shard went full" "full" "$(q .depth_used)"
assert_eq "review_effort is the max" "4" "$(q .review_effort)"
assert_eq "approval needs every shard to argue for it" "" "$(q .approve_argument)"
assert_eq "sensitive_paths_touched is OR'd" "true" "$(q .sensitive_paths_touched)"

rm -f "$W"/scan*.json
shard 1 '{"findings":[],"human_review":[],"approve_argument":"a","review_effort":2}'
shard 2 '{"findings":[],"human_review":[],"approve_argument":"b","review_effort":2}'
run
assert_eq "unanimous approval keeps shard 1's argument" "a" "$(q .approve_argument)"
assert_eq "missing keys default rather than crash" "[]" "$(q -c .prior_findings 2>/dev/null || jq -c .prior_findings "$W/scan.json")"

# A planned shard that never reported: merged, warned, and never approved.
rm -f "$W"/scan*.json
echo 3 > "$W/shard-count"
shard 1 '{"findings":[],"human_review":[],"approve_argument":"a","review_effort":2}'
shard 2 '{"findings":[],"human_review":[],"approve_argument":"b","review_effort":2}'
run
assert_eq "the surviving shards still merge" "merged=2" "$(grep -o 'merged=2' <<<"$OUT")"
case "$OUT" in *"::warning::"*"3 shard(s) were planned and 2 reported"*) ok "a missing shard is warned about, by count" ;; *) bad "no missing-shard warning: $OUT" ;; esac
assert_eq "…and the files nobody read withhold the approval" "" "$(q .approve_argument)"
rm -f "$W/shard-count"

rm -f "$W"/scan*.json
shard 1 'not json'
shard 2 '{"findings":[{"path":"a","line":1,"title":"t","severity":"minor"}]}'
run
assert_eq "an unparseable shard contributes nothing and is warned about" "merged=1" "$(grep -o 'merged=1' <<<"$OUT")"
case "$OUT" in *"::warning::"*"scan-1.json"*) ok "…the warning names the shard" ;; *) bad "no warning for the bad shard: $OUT" ;; esac
assert_eq "…and the good shard's finding is kept" "1" "$(q '.findings|length')"

rm -f "$W"/scan*.json
run
assert_eq "no shards → merged=0 and no scan.json" "merged=0" "$OUT"
[ -e "$W/scan.json" ] && bad "scan.json written with nothing to merge" || ok "no scan.json is written when nothing merged"

echo ""
if [ "$fail" -eq 0 ]; then echo "All merge-scans tests passed."; exit 0; fi
echo "$fail merge-scans test(s) failed."; exit 1
