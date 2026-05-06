#!/usr/bin/env bash
set -uo pipefail

# diff_hunk_validation_test.sh — fixture test for the LEFT/RIGHT hunk
# parser and kept/dropped split in post-review.sh. Covers the
# regression on Panenco/qiv#292 where comments outside diff hunks
# (and comments on deleted lines, which need side=LEFT) silently
# disappeared.

cd "$(dirname "$0")/.."

fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label"
    echo "      want: $want"
    echo "      got:  $got"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# Sample diff with two files. src/foo.ts has lines 10-12 changed (one
# deleted at LEFT line 11, two added at RIGHT lines 11-12). src/bar.ts
# has a single hunk adding lines 5-7.
cat > "$TMP/pr.diff" <<'EOF'
diff --git a/src/foo.ts b/src/foo.ts
index abc..def 100644
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -10,3 +10,4 @@
 line10
-deleted line at LEFT 11
+new line at RIGHT 11
+new line at RIGHT 12
 trailing context
diff --git a/src/bar.ts b/src/bar.ts
index aaa..bbb 100644
--- a/src/bar.ts
+++ b/src/bar.ts
@@ -0,0 +5,3 @@
+bar 5
+bar 6
+bar 7
EOF

# Run the same portable awk parser as post-review.sh.
awk '
  /^--- a\// { next }
  /^\+\+\+ b\// { file=substr($0,7); next }
  /^@@ / {
    lspec = $2; rspec = $3
    sub(/^-/, "", lspec); sub(/^\+/, "", rspec)
    n = split(lspec, lp, ",")
    lstart = lp[1] + 0
    lcount = (n >= 2 ? lp[2] + 0 : 1)
    n = split(rspec, rp, ",")
    rstart = rp[1] + 0
    rcount = (n >= 2 ? rp[2] + 0 : 1)
    for (i = lstart; i < lstart + lcount; i++) print file ":" i ":LEFT"
    for (i = rstart; i < rstart + rcount; i++) print file ":" i ":RIGHT"
  }
' "$TMP/pr.diff" | sort -u > "$TMP/valid-lines.txt"

# foo.ts hunk: -10,3 +10,4 → LEFT 10,11,12; RIGHT 10,11,12,13.
# bar.ts hunk: -0,0 +5,3 → LEFT (empty range — 0,0 means no LEFT lines); RIGHT 5,6,7.
EXPECTED_LINES=$(cat <<'EOF' | sort -u
src/foo.ts:10:LEFT
src/foo.ts:10:RIGHT
src/foo.ts:11:LEFT
src/foo.ts:11:RIGHT
src/foo.ts:12:LEFT
src/foo.ts:12:RIGHT
src/foo.ts:13:RIGHT
src/bar.ts:5:RIGHT
src/bar.ts:6:RIGHT
src/bar.ts:7:RIGHT
EOF
)
# Some awks include "src/foo.ts:0:LEFT" / ":0:RIGHT" for -0,0; tolerate by
# filtering. The relevant assertion is presence of the lines we expect.
GOT_LINES=$(sort -u "$TMP/valid-lines.txt")

# Note: -0,0 in bar.ts produces no LEFT entries (lcount=0 means range is
# empty after the `< lstart + lcount` guard). The `,0` form keeps lcount=0
# rather than defaulting to 1.
echo "── Hunk parser ──"
for line in src/foo.ts:10:LEFT src/foo.ts:11:LEFT src/foo.ts:12:LEFT \
            src/foo.ts:10:RIGHT src/foo.ts:11:RIGHT src/foo.ts:12:RIGHT src/foo.ts:13:RIGHT \
            src/bar.ts:5:RIGHT src/bar.ts:6:RIGHT src/bar.ts:7:RIGHT; do
  if echo "$GOT_LINES" | grep -qx "$line"; then
    echo "OK:   parsed $line"
  else
    echo "FAIL: missing $line in valid-lines output"
    fail=$((fail + 1))
  fi
done
# bar.ts has no LEFT lines (it's a pure addition: -0,0 +5,3).
if echo "$GOT_LINES" | grep -q "^src/bar.ts:.*:LEFT$"; then
  echo "FAIL: pure-addition hunk should have no LEFT lines, got:"
  echo "$GOT_LINES" | grep "^src/bar.ts:.*:LEFT$"
  fail=$((fail + 1))
else
  echo "OK:   pure-addition hunk produced no LEFT lines"
fi

# Now exercise the kept/dropped split. Construct a fixture with:
#   - in-hunk RIGHT (kept)
#   - in-hunk LEFT (kept — deleted-line comment, the no-side default would drop)
#   - out-of-hunk RIGHT (dropped to body)
#   - missing side, in hunk (kept, defaults to RIGHT)
cat > "$TMP/comments.json" <<'EOF'
[
  {"path": "src/foo.ts", "line": 11, "side": "RIGHT", "body": "**[BUG]** new RIGHT line"},
  {"path": "src/foo.ts", "line": 11, "side": "LEFT",  "body": "**[NOTE]** deleted line"},
  {"path": "src/foo.ts", "line": 99, "side": "RIGHT", "body": "**[BUG]** out of hunk"},
  {"path": "src/bar.ts", "line": 5,                   "body": "**[STYLE]** missing side defaults to RIGHT"}
]
EOF

jq --rawfile valid "$TMP/valid-lines.txt" '
  ($valid | split("\n") | map(select(length > 0))) as $lines |
  [.[] | . as $c | ($c.path + ":" + ($c.line | tostring) + ":" + ($c.side // "RIGHT")) as $key |
    $c + {_in_diff: ($lines | any(. == $key))}
  ] as $tagged |
  {
    kept:    [$tagged[] | select(._in_diff) | del(._in_diff)],
    dropped: [$tagged[] | select(._in_diff | not) | del(._in_diff)]
  }
' "$TMP/comments.json" > "$TMP/split.json"

KEPT_COUNT=$(jq '.kept | length' "$TMP/split.json")
DROPPED_COUNT=$(jq '.dropped | length' "$TMP/split.json")

echo ""
echo "── Kept/dropped split ──"
assert_eq "kept count"    "3" "$KEPT_COUNT"
assert_eq "dropped count" "1" "$DROPPED_COUNT"

# Verify the kept set includes both the LEFT-side comment and the missing-side default.
KEPT_LEFT=$(jq -r '.kept[] | select(.side == "LEFT") | .body' "$TMP/split.json")
assert_eq "LEFT-side deleted-line kept" "**[NOTE]** deleted line" "$KEPT_LEFT"

KEPT_DEFAULT=$(jq -r '.kept[] | select(.path == "src/bar.ts") | .body' "$TMP/split.json")
assert_eq "missing-side defaults to RIGHT and is kept" "**[STYLE]** missing side defaults to RIGHT" "$KEPT_DEFAULT"

# Verify the dropped one is the out-of-hunk comment.
DROPPED_BODY=$(jq -r '.dropped[0].body' "$TMP/split.json")
assert_eq "out-of-hunk comment dropped" "**[BUG]** out of hunk" "$DROPPED_BODY"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All diff-hunk-validation tests passed."
  exit 0
else
  echo "$fail diff-hunk-validation test(s) failed."
  exit 1
fi
