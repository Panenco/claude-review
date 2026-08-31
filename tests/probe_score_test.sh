#!/usr/bin/env bash
set -uo pipefail

# probe_score_test.sh — scripts/probe-score.sh: the label contract, the outcome
# reader, and the scorecard arithmetic.
#
# No model runs and no network. Every case builds a corpus and a results tree by
# hand, so the four labels and both error rates are exercised against outcomes
# whose shape is copied from real artifacts (`claude-review-<pr>` and
# review-local.sh's `posted/`).
#
# THE CASE THAT MATTERS MOST is `simple` + APPROVE + one check comment. That is
# the owner's complaint stated exactly — "should not get any check comments and
# those should be approved without findings" — and a scorer that called it a
# pass because the verdict was APPROVE would measure nothing.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCORE="$ROOT/scripts/probe-score.sh"
EXAMPLE="$ROOT/tests/fixtures/probe-corpus.example.json"
for f in "$SCORE" "$EXAMPLE"; do
  [ -f "$f" ] || { echo "FAIL: $f not found"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want '$2', got '$3'"; fi; }
assert_contains() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — expected to find '$2' in output" ;; esac
}
assert_not_contains() {
  case "$3" in *"$2"*) bad "$1 — did NOT expect '$2' in output" ;; *) ok "$1" ;; esac
}
# The scorecard is column-aligned with printf field widths, so asserting on
# literal runs of spaces breaks on any width tweak while testing nothing. These
# squeeze runs of spaces first: the numbers are the contract, the padding is not.
squeeze() { printf '%s' "$1" | tr -s ' '; }
assert_row() { assert_contains "$1" "$2" "$(squeeze "$3")"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── helpers that build the two outcome shapes ────────────────────────────────

# ci_outcome <dir> <verdict> <n-findings> <n-checks>
# The CI artifact shape: /tmp/review.json, verdict + meta counts.
ci_outcome() {
  local d="$1" v="$2" nf="$3" nc="$4"
  mkdir -p "$d"
  jq -n --arg v "$v" --argjson nf "$nf" --argjson nc "$nc" '{
    verdict: $v,
    body: "a body",
    comments: [],
    meta: {
      findings:     [range($nf)   | {id: "f\(.)", path: "src/a.ts", line: 1, title: "t\(.)", severity: "minor"}],
      human_review: [range($nc)   | {path: "src/a.ts", line: 1, what_to_check: "q\(.)", why_unresolved: "w"}],
      refuted: [], resolved_prior: [], depth_used: "full", review_effort: 3,
      approve_blocked_by: "none", prompt_injection_detected: false
    }}' > "$d/review.json"
}

# posted_outcome <dir> <verdict> <n-findings> <n-checks>
# review-local.sh's shape: posted/verdict + posted/meta.json + posted/comments.json.
posted_outcome() {
  local d="$1" v="$2" nf="$3" nc="$4"
  mkdir -p "$d/posted"
  printf '%s\n' "$v" > "$d/posted/verdict"
  jq -n --argjson nf "$nf" --argjson nc "$nc" '{
    findings:     [range($nf) | {id: "f\(.)", path: "src/a.ts", line: 1, title: "t\(.)"}],
    human_review: [range($nc) | {path: "src/a.ts", line: 1, what_to_check: "q\(.)"}],
    refuted: []}' > "$d/posted/meta.json"
  echo '[]' > "$d/posted/comments.json"
}

# corpus_of <path> <repo#pr:label> ...
corpus_of() {
  local out="$1"; shift
  local n=0
  : > "$WORK/.rows"
  for spec in "$@"; do
    n=$((n + 1))
    local rp="${spec%%:*}" lbl="${spec##*:}"
    jq -cn --arg r "${rp%%#*}" --argjson p "${rp##*#}" --arg l "$lbl" \
      '{repo:$r, number:$p, title:"t", additions:1, deletions:0, changed_files:1,
        docs_only:false, label:$l, head_sha:"a", base_sha:"b", merge_commit:"c",
        reason:"r", borderline:false}' >> "$WORK/.rows"
  done
  jq -s '.' "$WORK/.rows" > "$out"
}

# ── 1. the shipped example fixture is valid and fully labelled ───────────────
assert_eq "example fixture parses as a JSON array" "true" \
  "$(jq -r 'type == "array"' "$EXAMPLE")"
assert_eq "example fixture uses only known labels" "0" \
  "$(jq -r '[.[] | select((.label | IN("simple","needs-eyes","docs-slice","docs-baseline")) | not)] | length' "$EXAMPLE")"
assert_eq "example fixture covers all four labels" "4" \
  "$(jq -r '[.[].label] | unique | length' "$EXAMPLE")"
assert_eq "example fixture names no real repo" "0" \
  "$(jq -r '[.[] | select(.repo | test("^owner/") | not)] | length' "$EXAMPLE")"
assert_eq "every example entry carries a reason" "0" \
  "$(jq -r '[.[] | select((.reason // "") == "")] | length' "$EXAMPLE")"
assert_eq "every example entry carries head/base sha" "0" \
  "$(jq -r '[.[] | select((.head_sha // "") == "" or (.base_sha // "") == "")] | length' "$EXAMPLE")"

# ── 2. repo rule: no `set -e` ────────────────────────────────────────────────
if grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$SCORE"; then
  bad "probe-score.sh must not use set -e (bugbot.md)"
else
  ok "probe-score.sh does not use set -e"
fi
assert_eq "probe-score.sh sets -uo pipefail" "1" \
  "$(grep -cE '^set -uo pipefail$' "$SCORE")"

# ── 3. the label contract: approvable vs needs-a-human ───────────────────────
C="$WORK/c1.json"; R="$WORK/r1"
corpus_of "$C" \
  "owner/repo-a#1:simple" "owner/repo-a#2:needs-eyes" \
  "owner/repo-b#3:docs-slice" "owner/repo-b#4:docs-baseline"
ci_outcome "$R/repo-a-1" APPROVE 0 0          # simple, clean       -> pass
ci_outcome "$R/repo-a-2" REQUEST_CHANGES 2 1  # needs-eyes, flagged -> pass
ci_outcome "$R/repo-b-3" APPROVE 0 0          # docs-slice, clean   -> pass
ci_outcome "$R/repo-b-4" COMMENT 0 3          # docs-baseline, asks -> pass
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "all-four-correct exits 0" "0" "$RC"
assert_row "simple scored 1/1" " simple 1/1 100%" "$OUT"
assert_row "needs-eyes scored 1/1" " needs-eyes 1/1 100%" "$OUT"
assert_row "docs-slice scored 1/1" " docs-slice 1/1 100%" "$OUT"
assert_row "docs-baseline scored 1/1" " docs-baseline 1/1 100%" "$OUT"
assert_contains "overall accuracy is 100%" "overall accuracy    100%" "$OUT"
assert_contains "APPROVE rate is 50%" "APPROVE rate        50%" "$OUT"
assert_contains "no false alarms" "false alarms        0" "$OUT"
assert_contains "no misses" "misses              0" "$OUT"

# ── 4. THE CASE: a simple PR approved but carrying a check comment ───────────
# APPROVE alone is not the target. "zero findings, zero check comments" is.
C="$WORK/c2.json"; R="$WORK/r2"
corpus_of "$C" "owner/repo-a#1:simple"
ci_outcome "$R/repo-a-1" APPROVE 0 1
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "simple + APPROVE + one check exits non-zero" "1" "$RC"
assert_contains "it is a false alarm, not a pass" "false alarms        1" "$OUT"
assert_contains "the row reads fail" "fail" "$OUT"
assert_contains "the APPROVE rate still counts it approved" "APPROVE rate        100%" "$OUT"

# a simple PR approved with a body finding is likewise a false alarm
C="$WORK/c2b.json"; R="$WORK/r2b"
corpus_of "$C" "owner/repo-a#1:simple"
ci_outcome "$R/repo-a-1" COMMENT 1 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1)
assert_contains "simple + COMMENT + a finding is a false alarm" "false alarms        1" "$OUT"

# ── 5. the dangerous direction: a needs-eyes PR silently approved ────────────
C="$WORK/c3.json"; R="$WORK/r3"
corpus_of "$C" "owner/repo-a#9:needs-eyes"
ci_outcome "$R/repo-a-9" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "needs-eyes silently approved exits non-zero" "1" "$RC"
assert_contains "it is counted as a miss" "misses              1" "$OUT"
assert_not_contains "and not as a false alarm" "false alarms        1" "$OUT"

# an APPROVE that still carried a check is NOT a miss — a human was asked
C="$WORK/c3b.json"; R="$WORK/r3b"
corpus_of "$C" "owner/repo-a#9:needs-eyes"
ci_outcome "$R/repo-a-9" APPROVE 0 2
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "needs-eyes approved WITH checks passes" "0" "$RC"
assert_contains "no miss recorded" "misses              0" "$OUT"

# ── 6. posted/ beats review.json, and both are readable ──────────────────────
C="$WORK/c4.json"; R="$WORK/r4"
corpus_of "$C" "owner/repo-a#1:simple"
ci_outcome     "$R/repo-a-1" COMMENT 3 3   # pre-poster: 3 and 3
posted_outcome "$R/repo-a-1" APPROVE 0 0   # post-poster: clean
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "posted/ is preferred over review.json" "0" "$RC"
assert_contains "and the source says so" "(posted)" "$OUT"

C="$WORK/c4b.json"; R="$WORK/r4b"
corpus_of "$C" "owner/repo-a#1:simple"
ci_outcome "$R/repo-a-1" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1)
assert_contains "a CI artifact alone is read, and named" "(review.json)" "$OUT"

# ── 7. no meta -> counted from the comment list, and SAID so ─────────────────
# A degraded run writes verdict + comments and no meta. Counting must not
# silently report zero findings, which would manufacture a pass for `simple`.
C="$WORK/c5.json"; R="$WORK/r5"
corpus_of "$C" "owner/repo-a#1:simple"
mkdir -p "$R/repo-a-1"
cat > "$R/repo-a-1/review.json" <<'EOF'
{"verdict": "APPROVE", "body": "b",
 "comments": [
   {"path": "src/a.ts", "line": 3, "body": "**minor** a real finding"},
   {"path": "src/a.ts", "line": 9, "body": "**worth a look** Should this refuse a stale id?"}
 ]}
EOF
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "a meta-less outcome is still scored" "1" "$RC"
assert_contains "the approximation is disclosed" "+approx" "$OUT"
assert_row "one finding and one check counted from the comments" "APPROVE 1 1 fail" "$OUT"

# ── 8. an outcome that cannot be read is no-result, never a pass ─────────────
C="$WORK/c6.json"; R="$WORK/r6"
corpus_of "$C" "owner/repo-a#1:simple" "owner/repo-a#2:simple"
ci_outcome "$R/repo-a-1" APPROVE 0 0
mkdir -p "$R/repo-a-2"
echo 'not json at all' > "$R/repo-a-2/review.json"
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "an unreadable outcome fails the sweep" "1" "$RC"
assert_contains "it is reported as no-result" "no-result" "$OUT"
assert_contains "and excluded from the scored denominator" "scored              1   (no result yet: 1)" "$OUT"
assert_contains "so accuracy is over the scored entries only" "overall accuracy    100%  (1/1)" "$OUT"

# a review.json with a verdict the pipeline never emits is also no-result
C="$WORK/c6b.json"; R="$WORK/r6b"
corpus_of "$C" "owner/repo-a#1:simple"
mkdir -p "$R/repo-a-1"
echo '{"verdict":"LGTM","comments":[]}' > "$R/repo-a-1/review.json"
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1)
assert_contains "an unknown verdict is not scored as a pass" "no-result" "$OUT"

# an entry with no directory at all
C="$WORK/c6c.json"; R="$WORK/r6c"
corpus_of "$C" "owner/repo-a#1:simple" "owner/repo-a#2:needs-eyes"
ci_outcome "$R/repo-a-1" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1)
assert_contains "a missing entry is no-result" "no result yet: 1" "$OUT"

# ── 9. a loose outcome at the results root serves ONE entry, never many ──────
# Without this, a stray review.json at the root would be handed to every entry
# that has no directory — scoring one PR's label against another PR's review.
C="$WORK/c7.json"; R="$WORK/r7"
corpus_of "$C" "owner/repo-a#1:simple"
ci_outcome "$R" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "a single-entry corpus reads the results root" "0" "$RC"

C="$WORK/c7b.json"; R="$WORK/r7b"
corpus_of "$C" "owner/repo-a#1:simple" "owner/repo-a#2:needs-eyes"
ci_outcome "$R" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" 2>&1)
assert_contains "a multi-entry corpus refuses to share the root" "no result yet: 2" "$OUT"

# ── 10. --label filters the sweep ────────────────────────────────────────────
C="$WORK/c8.json"; R="$WORK/r8"
corpus_of "$C" "owner/repo-a#1:simple" "owner/repo-a#2:needs-eyes"
ci_outcome "$R/repo-a-1" APPROVE 0 0
ci_outcome "$R/repo-a-2" APPROVE 0 0
OUT=$(bash "$SCORE" score --corpus "$C" --results "$R" --label simple 2>&1); RC=$?
assert_eq "--label simple scores only the simple entry" "0" "$RC"
assert_contains "one entry in the corpus line" "corpus entries      1" "$OUT"
assert_not_contains "needs-eyes is absent" "repo-a#2" "$OUT"

# ── 11. a bad label in the corpus is refused, never silently dropped ─────────
C="$WORK/c9.json"
jq -n '[{repo:"owner/repo-a", number:1, label:"trivial"}]' > "$C"
OUT=$(bash "$SCORE" score --corpus "$C" --results "$WORK" 2>&1); RC=$?
assert_eq "an unknown label exits non-zero" "1" "$RC"
assert_contains "and names the offending entry" "label=trivial" "$OUT"

jq -n '[{repo:"owner/repo-a", label:"simple"}]' > "$C"
OUT=$(bash "$SCORE" score --corpus "$C" --results "$WORK" 2>&1); RC=$?
assert_eq "a missing PR number exits non-zero" "1" "$RC"
assert_contains "and says which index" "index 0" "$OUT"

echo '{"not": "an array"}' > "$C"
OUT=$(bash "$SCORE" score --corpus "$C" --results "$WORK" 2>&1); RC=$?
assert_eq "a non-array corpus exits non-zero" "1" "$RC"

OUT=$(bash "$SCORE" score --corpus "$WORK/nope.json" --results "$WORK" 2>&1); RC=$?
assert_eq "a missing corpus exits non-zero" "1" "$RC"
assert_contains "and points at the example" "probe-corpus.example.json" "$OUT"

# ── 12. --json is machine-readable and carries the same arithmetic ───────────
C="$WORK/c10.json"; R="$WORK/r10"
corpus_of "$C" \
  "owner/repo-a#1:simple" "owner/repo-a#2:simple" "owner/repo-a#3:needs-eyes"
ci_outcome "$R/repo-a-1" APPROVE 0 0
ci_outcome "$R/repo-a-2" COMMENT 0 2
ci_outcome "$R/repo-a-3" REQUEST_CHANGES 1 0
J=$(bash "$SCORE" score --corpus "$C" --results "$R" --json 2>/dev/null)
assert_eq "--json emits valid JSON" "true" "$(printf '%s' "$J" | jq -e 'type == "object"' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "--json totals.scored" "3" "$(printf '%s' "$J" | jq -r '.totals.scored')"
assert_eq "--json totals.false_alarm" "1" "$(printf '%s' "$J" | jq -r '.totals.false_alarm')"
assert_eq "--json totals.miss" "0" "$(printf '%s' "$J" | jq -r '.totals.miss')"
assert_eq "--json approve_rate_pct" "33" "$(printf '%s' "$J" | jq -r '.rates.approve_rate_pct')"
assert_eq "--json accuracy_pct" "66" "$(printf '%s' "$J" | jq -r '.rates.accuracy_pct')"
assert_eq "--json by_label simple pass" "1" \
  "$(printf '%s' "$J" | jq -r '.by_label[] | select(.label == "simple") | .pass')"
assert_eq "--json entries carries every corpus row" "3" "$(printf '%s' "$J" | jq -r '.entries | length')"

# ── 13. plan prints the cost of a live sweep, and runs no model ──────────────
OUT=$(bash "$SCORE" plan --corpus "$EXAMPLE" 2>&1); RC=$?
assert_eq "plan exits 0" "0" "$RC"
assert_contains "plan counts the corpus" "entries: 5" "$OUT"
assert_contains "plan prices a live sweep" "cost  \$10 - \$30" "$OUT"
assert_contains "plan states the offline alternative is free" "costs \$0" "$OUT"
assert_contains "plan breaks the corpus down by label" "docs-baseline" "$OUT"

# ── 14. run refuses a malformed or unknown entry BEFORE spending money ───────
OUT=$(bash "$SCORE" run --corpus "$EXAMPLE" --results "$WORK/r11" --entry "owner/repo-a" 2>&1); RC=$?
assert_eq "run refuses an entry without a #" "2" "$RC"
OUT=$(bash "$SCORE" run --corpus "$EXAMPLE" --results "$WORK/r11" --entry "owner/repo-a#xyz" 2>&1); RC=$?
assert_eq "run refuses a non-numeric PR number" "2" "$RC"
OUT=$(bash "$SCORE" run --corpus "$EXAMPLE" --results "$WORK/r11" --entry "owner/repo-a#999" 2>&1); RC=$?
assert_eq "run refuses a PR that is not in the corpus" "1" "$RC"
assert_contains "and says so" "is not in" "$OUT"
OUT=$(bash "$SCORE" run --corpus "$EXAMPLE" --entry "owner/repo-a#101" 2>&1); RC=$?
assert_eq "run refuses without --results" "2" "$RC"

# ── 15. fetch reports what is missing without a run map, and spends nothing ──
C="$WORK/c12.json"; R="$WORK/r12"
corpus_of "$C" "owner/repo-a#1:simple" "owner/repo-a#2:needs-eyes"
ci_outcome "$R/repo-a-1" APPROVE 0 0
OUT=$(bash "$SCORE" fetch --corpus "$C" --results "$R" 2>&1); RC=$?
assert_eq "fetch exits non-zero while something is missing" "1" "$RC"
assert_contains "fetch names the entry it already has" "have    owner/repo-a#1" "$OUT"
assert_contains "fetch names the entry it lacks" "MISSING owner/repo-a#2" "$OUT"

if [ "$fail" -eq 0 ]; then
  echo "PASS — probe_score_test.sh"
  exit 0
fi
echo "FAILED: $fail assertion(s)"
exit 1
