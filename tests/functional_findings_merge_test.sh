#!/usr/bin/env bash
set -uo pipefail

# functional_findings_merge_test.sh — fixture test for the
# functional-tester defensive merge in build-review.sh.
#
# Background. Each functional-tester finding can carry a `screenshot:
# /tmp/screenshots/NN-name.png` field. The inline-comment builder at
# the bottom of build-review.sh embeds `![screenshot](url)` only for
# entries that reach `/tmp/all-findings.json` — so functional findings
# that don't merge into ALL_FINDINGS lose their at-the-line image
# evidence and survive only in the body's "Functional Validation"
# gallery (no diff-line anchor, no inline thread).
#
# This test exercises the merge expression in three regimes:
#   - net-new functional finding folds in with its screenshot intact
#   - functional finding the orchestrator already folded is deduped
#   - both empty → merge is a no-op (defence-in-depth path stays sane)

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

merge() {
  local primary_file="$1" functional_file="$2"
  jq -n \
    --argjson primary "$(cat "$primary_file")" \
    --slurpfile fn "$functional_file" \
    '($primary | map(.id)) as $seen
     | ($primary | map((.path // "") + "|" + (.title // ""))) as $seen_content
     | $primary + (($fn[0] // []) | map(select(
         (.id as $id | $seen | index($id) | not)
         and (((.title // "") == "") or (((.path // "") + "|" + (.title // "")) as $k | $seen_content | index($k) | not))
       )))'
}

# ── Block 1: net-new functional finding folds in, screenshot preserved ──
cat > "$TMP/all-findings-1.json" <<'JSON'
[
  {"id":"j1","severity":"major","path":"src/a.ts","line_start":10,"title":"Judge finding","evidence":"x","reasoning":"y","expected":"z","type":"finding"}
]
JSON
cat > "$TMP/functional-1.json" <<'JSON'
[
  {"id":"f1","severity":"major","path":"src/c.ts","line_start":30,"title":"Submit button missing","evidence":"button[type=submit] not in DOM","reasoning":"y","expected":"z","type":"finding","screenshot":"/tmp/screenshots/02-form.png"}
]
JSON
M1=$(merge "$TMP/all-findings-1.json" "$TMP/functional-1.json")
assert_eq "net-new: merged length" "2" "$(echo "$M1" | jq 'length')"
assert_eq "net-new: f1 present"    "1" "$(echo "$M1" | jq '[.[] | select(.id == "f1")] | length')"
assert_eq "net-new: screenshot kept" "/tmp/screenshots/02-form.png" \
  "$(echo "$M1" | jq -r '[.[] | select(.id == "f1")] | .[0].screenshot')"

# ── Block 2: orchestrator already folded — dedup by id ──
cat > "$TMP/all-findings-2.json" <<'JSON'
[
  {"id":"j1","severity":"major","path":"src/a.ts","line_start":10,"title":"Judge finding","evidence":"x","reasoning":"y","expected":"z","type":"finding"},
  {"id":"f1","severity":"major","path":"src/c.ts","line_start":30,"title":"Submit button missing","evidence":"orchestrator copy","reasoning":"y","expected":"z","type":"finding","screenshot":"/tmp/screenshots/02-form.png"}
]
JSON
cat > "$TMP/functional-2.json" <<'JSON'
[
  {"id":"f1","severity":"major","path":"src/c.ts","line_start":30,"title":"Submit button missing","evidence":"functional copy","reasoning":"y","expected":"z","type":"finding","screenshot":"/tmp/screenshots/02-form.png"}
]
JSON
M2=$(merge "$TMP/all-findings-2.json" "$TMP/functional-2.json")
assert_eq "dedup: total length unchanged" "2" "$(echo "$M2" | jq 'length')"
assert_eq "dedup: f1 appears once"        "1" "$(echo "$M2" | jq '[.[] | select(.id == "f1")] | length')"
# Orchestrator's already-folded copy wins (its evidence was "orchestrator copy").
assert_eq "dedup: orchestrator copy wins" "orchestrator copy" \
  "$(echo "$M2" | jq -r '[.[] | select(.id == "f1")] | .[0].evidence')"

# ── Block 2b: orchestrator folded under a re-id'd `j*` id — dedup by content ──
# Phase 4 re-ids merged findings to j1..jN, so the functional copy arrives
# under its original f-id. Id-only dedup re-appended it (byte-identical
# duplicate inline comments, observed at up to a third of comments on
# busy PRs); content (path+title) dedup must catch it.
cat > "$TMP/all-findings-2b.json" <<'JSON'
[
  {"id":"j1","severity":"major","path":"src/a.ts","line_start":10,"title":"Judge finding","evidence":"x","reasoning":"y","expected":"z","type":"finding"},
  {"id":"j2","severity":"major","path":"src/c.ts","line_start":30,"title":"Submit button missing","evidence":"orchestrator copy","reasoning":"y","expected":"z","type":"finding","screenshot":"/tmp/screenshots/02-form.png"}
]
JSON
M2B=$(merge "$TMP/all-findings-2b.json" "$TMP/functional-2.json")
assert_eq "content-dedup: total length unchanged" "2" "$(echo "$M2B" | jq 'length')"
assert_eq "content-dedup: no f1 re-append"        "0" "$(echo "$M2B" | jq '[.[] | select(.id == "f1")] | length')"

# Untitled findings never content-collide (two distinct untitled findings on one path).
cat > "$TMP/all-findings-2c.json" <<'JSON'
[{"id":"j1","severity":"major","path":"src/c.ts","line_start":10,"title":"","evidence":"a","reasoning":"y","expected":"z","type":"finding"}]
JSON
cat > "$TMP/functional-2c.json" <<'JSON'
[{"id":"f9","severity":"minor","path":"src/c.ts","line_start":80,"title":"","evidence":"b","reasoning":"y","expected":"z","type":"finding"}]
JSON
M2C=$(merge "$TMP/all-findings-2c.json" "$TMP/functional-2c.json")
assert_eq "untitled: both kept" "2" "$(echo "$M2C" | jq 'length')"

# ── Block 3: both empty → no-op ──
echo '[]' > "$TMP/all-findings-3.json"
echo '[]' > "$TMP/functional-3.json"
M3=$(merge "$TMP/all-findings-3.json" "$TMP/functional-3.json")
assert_eq "empty+empty: stays []" "0" "$(echo "$M3" | jq 'length')"

# ── Block 4: judges had findings, functional empty → no-op ──
cat > "$TMP/all-findings-4.json" <<'JSON'
[{"id":"j1","severity":"minor","path":"src/a.ts","line_start":1,"title":"x","evidence":"x","reasoning":"x","expected":"x","type":"finding"}]
JSON
echo '[]' > "$TMP/functional-4.json"
M4=$(merge "$TMP/all-findings-4.json" "$TMP/functional-4.json")
assert_eq "judges-only: length unchanged" "1" "$(echo "$M4" | jq 'length')"
assert_eq "judges-only: j1 preserved"     "j1" "$(echo "$M4" | jq -r '.[0].id')"

if [ "$fail" -eq 0 ]; then
  echo
  echo "All functional-findings merge tests passed."
  exit 0
else
  echo
  echo "$fail functional-findings merge test assertion(s) failed."
  exit 1
fi
