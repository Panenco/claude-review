#!/usr/bin/env bash
set -uo pipefail
# shard_plan_test.sh — fixture test for scripts/shard-plan.sh: a pure function
# from a changed-file TSV to N contiguous, path-sorted shards of about equal
# weight, or exactly one shard below the size threshold.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/shard-plan.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }
fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
run() { OUT=$(env OUT_DIR="$W" "$@" bash "$SCRIPT"); N=$(sed -n 's/^shards=//p' <<<"$OUT"); }

# 200 files x 20 lines = 4000 lines, weight 9000 → 4 shards at the cap
big=$(for i in $(seq -w 1 50); do for d in apps/api/src infra packages/contracts apps/web; do printf '%s/f%s.ts\t15\t5\n' "$d" "$i"; done; done)
run SHARD_FILES_TSV="$big"
assert_eq "a large diff is cut into the maximum number of shards" "4" "$N"
assert_eq "every file lands in exactly one shard" "200" "$(cat "$W"/shard-[1-4].txt | sort -u | wc -l | tr -d ' ')"
assert_eq "…and nothing is duplicated" "200" "$(cat "$W"/shard-[1-4].txt | wc -l | tr -d ' ')"
if [ "$(cat "$W"/shard-[1-4].txt)" = "$(printf '%s\n' "$big" | cut -f1 | LC_ALL=C sort)" ]; then ok "shards are contiguous in sorted path order"
else bad "shards are not contiguous path-sorted chunks"; fi
minw=$(for i in 1 2 3 4; do wc -l < "$W/shard-$i.txt"; done | sort -n | head -1); maxw=$(for i in 1 2 3 4; do wc -l < "$W/shard-$i.txt"; done | sort -n | tail -1)
if [ $(( maxw - minw )) -le 2 ]; then ok "shards carry about equal weight ($minw..$maxw files)"; else bad "shards are unbalanced: $minw..$maxw files"; fi
case "$OUT" in *"shard_1="*"shard_4="*) ok "per-shard sizes are reported" ;; *) bad "per-shard sizes missing from: $OUT" ;; esac

run SHARD_FILES_TSV=$'src/a.ts\t300\t100\nsrc/b.ts\t200\t50'
assert_eq "a small diff is one shard" "1" "$N"
[ -e "$W/shard-1.txt" ] && bad "one shard writes no shard file" || ok "one shard writes no shard file"

run SHARD_FILES_TSV=$'src/a.ts\t900\t300\nsrc/b.ts\t200\t50'
assert_eq "1200 non-generated lines is the line threshold" "2" "$N"

many=$(for i in $(seq -w 1 30); do printf 'src/f%s.ts\t2\t1\n' "$i"; done)
run SHARD_FILES_TSV="$many"
[ "$N" -ge 1 ] && ok "30 files reach the file threshold (shards=$N, weight decides how many)" || bad "30 files: shards=$N"

gen=$(printf 'pnpm-lock.yaml\t5000\t5000\nsrc/a.ts\t10\t0')
run SHARD_FILES_TSV="$gen"
assert_eq "generated churn does not make a diff large" "1" "$N"

run SHARD_FILES_TSV="$big" SHARD_MAX=2
assert_eq "SHARD_MAX caps the count" "2" "$N"

printf '{"files":[{"path":"src/a.ts","additions":900,"deletions":300},{"path":"src/b.ts","additions":200,"deletions":50}]}' > "$W/pr.json"
run PR_JSON="$W/pr.json"
assert_eq "falls back to pr.json's files when no TSV is given" "2" "$N"

run SHARD_FILES_TSV=""
[ "$N" = "1" ] && ok "no input at all → one shard, never a crash" || bad "no input: shards='$N'"

echo ""
if [ "$fail" -eq 0 ]; then echo "All shard-plan tests passed."; exit 0; fi
echo "$fail shard-plan test(s) failed."; exit 1
