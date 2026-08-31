#!/usr/bin/env bash
set -uo pipefail

# prior_findings_test.sh — fixture test for scripts/prior-findings.sh.
#
# The regression it exists for: post-review.sh gives the highest-severity
# findings an inline slot and then DELETES their bullets from the review body
# (the inline-XOR rule), and the truncator deletes whatever overflows the
# 1200-byte budget. The body was the only thing round 2 read, so round 2 could
# see everything EXCEPT the criticals and the overflow. R1 files a critical, R2's
# delta looks clean, APPROVE, and the standing block is dismissed.
#
# Everything here is fixtures: no gh, no network, no model. The three carriers
# are fed from files through COMMENTS_JSON / PR_FILES_JSON and a hand-written
# prior-reviews.json.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/prior-findings.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
fail=0

ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label — want '$want', got '$got'"; fi
}
assert_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) ok "$label" ;; *) bad "$label — expected to find '$needle'" ;; esac
}
assert_not_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) bad "$label — did NOT expect '$needle'" ;; *) ok "$label" ;; esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BOT="claude-bot[bot]"

# A `gh` that always fails, so a carrier with no fixture degrades exactly as it
# would on a runner whose API call 404s — never by reaching the real network.
MOCK_BIN="$WORK/bin"
mkdir -p "$MOCK_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_BIN/gh"
chmod +x "$MOCK_BIN/gh"

# reset <round> — a fresh OUT_DIR with an empty review list and the default hooks.
reset() {
  rm -rf "$WORK/out"
  mkdir -p "$WORK/out"
  echo '[]' > "$WORK/out/prior-reviews.json"
  echo '[]' > "$WORK/comments.json"
  jq -n '[{filename: "src/foo.ts"}, {filename: "src/bar.ts"}]' > "$WORK/files.json"
  ROUND_N="${1:-2}"
}

# run_pf [EXTRA_ENV=...] — runs the script; sets OUT, RC and reads back the JSON.
run_pf() {
  OUT=$(env PATH="$MOCK_BIN:$PATH" OUT_DIR="$WORK/out" REVIEW_BOT_USER="$BOT" \
            ROUND="$ROUND_N" COMMENTS_JSON="$WORK/comments.json" \
            PR_FILES_JSON="$WORK/files.json" "$@" bash "$SCRIPT" 2>&1)
  RC=$?
  FJSON=$(cat "$WORK/out/prior-findings.json" 2>/dev/null || echo 'MISSING')
  FMD=$(cat "$WORK/out/prior-findings.md" 2>/dev/null || echo 'MISSING')
  COUNT=$(printf '%s\n' "$OUT" | sed -n 's/^prior_finding_count=//p')
}

# review <submitted_at> <body> → one review object for prior-reviews.json
review() {
  jq -nc --arg bot "$BOT" --arg at "$1" --arg body "$2" \
    '{user: {login: $bot}, state: "CHANGES_REQUESTED", submitted_at: $at, body: $body}'
}
# comment <path> <line> <body> → one inline review comment
comment() {
  jq -nc --arg bot "$BOT" --arg p "$1" --argjson l "$2" --arg body "$3" \
    '{user: {login: $bot}, path: $p, line: $l, in_reply_to_id: null, body: $body}'
}

STATE_ONE='<!-- claude-review-state
{"v":1,"round":1,"truncated":false,"findings":[{"id":"aaaaaaa1","p":"src/foo.ts","l":11,"sev":"critical","t":"alpha loops forever","fs":"a 401 spins the refresh forever and pins a core","r":1},{"id":"aaaaaaa2","p":"src/foo.ts","l":12,"sev":"major","t":"beta returns another tenant","fs":"the warm cache serves tenant A rows to tenant B","r":1},{"id":"aaaaaaa3","p":"src/bar.ts","l":7,"sev":"minor","t":"gamma logs the token","fs":"the bearer lands in stdout","r":2}]}
-->'

echo "── nothing to recover ──"
reset 2
run_pf
assert_eq "exit 0" "0" "$RC"
assert_eq "count is 0" "0" "$COUNT"
assert_eq "the array is empty" "0" "$(echo "$FJSON" | jq 'length')"
assert_contains "the file is written anyway" "# Prior findings on this PR" "$FMD"
assert_contains "…and says the carry-over is unproven, not clean" "None recovered" "$FMD"
assert_contains "…and says what that means for the review" "unvetted rather than as" "$FMD"

echo ""
echo "── carrier 1: the state block ──"
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z "## Claude review — REQUEST_CHANGES

Two blocking findings.

$STATE_ONE")" > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "exit 0" "0" "$RC"
assert_eq "all three findings recovered" "3" "$(echo "$FJSON" | jq 'length')"
assert_eq "the critical sorts first" "critical" "$(echo "$FJSON" | jq -r '.[0].sev')"
assert_eq "it keeps the id the poster assigned" "aaaaaaa1" "$(echo "$FJSON" | jq -r '.[0].id')"
assert_eq "…its line as of the round that filed it" "11" "$(echo "$FJSON" | jq '.[0].l')"
assert_eq "…and its first-seen round" "1" "$(echo "$FJSON" | jq '.[0].r')"
assert_contains "the failure scenario survives" "pins a core" "$FJSON"
assert_contains "the markdown names the id" "aaaaaaa1" "$FMD"
assert_contains "…tells the model the line may have moved" "re-anchor from your own Read" "$FMD"
assert_contains "…and renders the scenario in full" "pins a core" "$FMD"

echo ""
echo "── carrier priority: the state block outranks the inline comment ──"
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z "## Claude review — REQUEST_CHANGES

$STATE_ONE")" > "$WORK/out/prior-reviews.json"
printf '[%s]\n' "$(comment src/foo.ts 88 '**critical** alpha loops forever

a much shorter scenario')" > "$WORK/comments.json"
run_pf
assert_eq "the two carriers are one finding, not two" "3" "$(echo "$FJSON" | jq 'length')"
assert_contains "the state block's scenario is the one kept" "pins a core" "$FJSON"
assert_eq "…and its line, not the comment's" "11" \
  "$(echo "$FJSON" | jq '[.[] | select(.t == "alpha loops forever")][0].l')"

echo ""
echo "── carrier 2: the inline comments (a PR open before the state block shipped) ──"
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — REQUEST_CHANGES

Two blocking findings.')" > "$WORK/out/prior-reviews.json"
{ printf '[%s,\n' "$(comment src/foo.ts 11 '**critical** alpha loops forever

a 401 spins the refresh forever')"
  printf '%s]\n' "$(comment src/bar.ts 7 '**minor** gamma logs the token

the bearer lands in stdout')"; } > "$WORK/comments.json"
run_pf
assert_eq "both comments recovered" "2" "$(echo "$FJSON" | jq 'length')"
assert_eq "severity comes off the comment's first line" "critical" "$(echo "$FJSON" | jq -r '.[0].sev')"
assert_eq "the severity marker is not part of the title" "alpha loops forever" \
  "$(echo "$FJSON" | jq -r '.[0].t')"
assert_contains "the second paragraph becomes the scenario" "spins the refresh forever" "$FJSON"

echo ""
echo "── carrier 3: the bullets left in the review bodies ──"
# By the time GitHub hands the body back, {{LINK:}} is an EXPANDED markdown link.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — REQUEST_CHANGES

Two findings.

### Findings (1)
- **major** [src/foo.ts:11](https://github.com/o/r/pull/7/files#diff-abcR11) — delta drops the lock

### Also flagged (1)
- **minor** [src/bar.ts:7](https://github.com/o/r/pull/7/files#diff-defR7) — gamma logs the token')" \
  > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "both bullets recovered" "2" "$(echo "$FJSON" | jq 'length')"
assert_eq "…from the Findings section" "delta drops the lock" \
  "$(echo "$FJSON" | jq -r '[.[] | select(.sev == "major")][0].t')"
assert_eq "…and from Also flagged" "gamma logs the token" \
  "$(echo "$FJSON" | jq -r '[.[] | select(.sev == "minor")][0].t')"
assert_eq "the line is read out of the link label" "11" \
  "$(echo "$FJSON" | jq '[.[] | select(.sev == "major")][0].l')"
# The verdict sentence and the human-review checkboxes are not findings.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — COMMENT

Nothing blocking.

### What a human should review
- [ ] [src/foo.ts:11](https://x) — confirm the retry budget matches the gateway')" \
  > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "a human-review checkbox is not a finding" "0" "$(echo "$FJSON" | jq 'length')"

echo ""
echo "── THE REGRESSION: a critical the XOR rule deleted from the body ──"
# The body lists only the minor, because the critical got the inline slot and 4a
# deleted its bullet. Without carrier 2 the critical is invisible to round 2.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — REQUEST_CHANGES

Two blocking findings.

### Findings (1)
- **minor** [src/bar.ts:7](https://x) — gamma logs the token')" > "$WORK/out/prior-reviews.json"
printf '[%s]\n' "$(comment src/foo.ts 11 '**critical** alpha loops forever

a 401 spins the refresh forever and pins a core')" > "$WORK/comments.json"
run_pf
assert_eq "both the visible minor and the invisible critical are carried" "2" \
  "$(echo "$FJSON" | jq 'length')"
assert_eq "the critical is first" "critical" "$(echo "$FJSON" | jq -r '.[0].sev')"
assert_contains "…with its own words" "alpha loops forever" "$FJSON"

echo ""
echo "── a finding the truncator cut from the body is still in the state block ──"
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z "## Claude review — REQUEST_CHANGES

Two blocking findings.

_…truncated to fit the review budget._

$STATE_ONE")" > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "the truncated findings survive in the state block" "3" "$(echo "$FJSON" | jq 'length')"
assert_contains "including one that reached no other surface" "beta returns another tenant" "$FJSON"

echo ""
echo "── identity: path + title, never the line ──"
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — COMMENT

no findings here.')" > "$WORK/out/prior-reviews.json"
{ printf '[%s,\n' "$(comment src/foo.ts 42 '**major** cache key omits the tenant')"
  printf '%s]\n' "$(comment src/foo.ts 88 '**major** cache key omits the tenant')"; } > "$WORK/comments.json"
run_pf
assert_eq "the same finding at two lines is ONE finding" "1" "$(echo "$FJSON" | jq 'length')"

{ printf '[%s,\n' "$(comment src/foo.ts 42 '**major** cache key omits the tenant')"
  printf '%s]\n' "$(comment src/bar.ts 42 '**major** cache key omits the tenant')"; } > "$WORK/comments.json"
run_pf
assert_eq "the same title in another file is a DIFFERENT finding" "2" "$(echo "$FJSON" | jq 'length')"
assert_eq "…and they get different ids" "2" "$(echo "$FJSON" | jq '[.[].id] | unique | length')"

# Backticks, the severity marker, doubled spaces, a trailing period and a CR are
# all rendering noise. They must not fork one finding into four.
{ printf '[%s,\n' "$(comment src/foo.ts 42 '**major** `retry()` never caps.')"
  printf '%s,\n'  "$(comment src/foo.ts 43 '**major** retry() never  caps')"
  printf '%s,\n'  "$(comment src/foo.ts 44 "**major** retry() NEVER caps"$'\r')"
  printf '%s]\n'  "$(comment src/foo.ts 45 '**major** **retry()** never caps!')"; } > "$WORK/comments.json"
run_pf
assert_eq "rendering noise does not fork the identity" "1" "$(echo "$FJSON" | jq 'length')"

echo ""
echo "── a finding whose file left the PR is dropped ──"
reset 2
jq -n '[{filename: "src/bar.ts"}]' > "$WORK/files.json"
printf '[%s]\n' "$(comment src/foo.ts 11 '**critical** alpha loops forever')" > "$WORK/comments.json"
run_pf
assert_eq "the finding on the removed file is gone" "0" "$(echo "$FJSON" | jq 'length')"
assert_contains "…and the file still says so plainly" "None recovered" "$FMD"

echo ""
echo "── degradation: a carrier that cannot be read contributes nothing ──"
# An unparseable state block must not take carriers 2 and 3 down with it.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — REQUEST_CHANGES

### Findings (1)
- **minor** [src/bar.ts:7](https://x) — gamma logs the token

<!-- claude-review-state
{"v":1,"findings":[{"p": broken json here
-->')" > "$WORK/out/prior-reviews.json"
printf '[%s]\n' "$(comment src/foo.ts 11 '**critical** alpha loops forever')" > "$WORK/comments.json"
run_pf
assert_eq "exit 0" "0" "$RC"
assert_contains "the broken carrier is announced" "::warning::" "$OUT"
assert_eq "the other two carriers still deliver" "2" "$(echo "$FJSON" | jq 'length')"

# gh failing on pulls/N/comments is the same shape: warn, carry on, exit 0.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '## Claude review — REQUEST_CHANGES

### Findings (1)
- **major** [src/foo.ts:11](https://x) — delta drops the lock')" > "$WORK/out/prior-reviews.json"
OUT=$(env PATH="$MOCK_BIN:$PATH" OUT_DIR="$WORK/out" REVIEW_BOT_USER="$BOT" ROUND=2 \
          GITHUB_REPOSITORY=o/r PR_NUMBER=7 PR_FILES_JSON="$WORK/files.json" \
          bash "$SCRIPT" 2>&1)
RC=$?
assert_eq "exit 0 when the comments API fails" "0" "$RC"
assert_contains "…and it says which carrier it lost" "Could not read prior inline comments" "$OUT"
assert_eq "…while the body bullets still come through" "1" \
  "$(jq 'length' "$WORK/out/prior-findings.json")"
assert_contains "…and the file is written" "delta drops the lock" \
  "$(cat "$WORK/out/prior-findings.md")"

echo ""
echo "── the JUDGED list is the input, not the standing list ──"
# prior-reviews.json excludes reviews that judged nothing (guard.sh's oversized
# block). Reading bot-reviews.json instead would carry findings out of a review
# that read no code.
reset 2
printf '[%s]\n' "$(review 2026-06-02T00:00:00Z '## Claude review — REQUEST_CHANGES

### Findings (1)
- **major** [src/foo.ts:11](https://x) — a judged finding')" > "$WORK/out/prior-reviews.json"
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z '<!-- claude-review-oversized -->

## Claude review — REQUEST_CHANGES

### Findings (1)
- **critical** [src/bar.ts:7](https://x) — a finding nobody judged')" > "$WORK/out/bot-reviews.json"
run_pf
assert_eq "only the judged review contributes" "1" "$(echo "$FJSON" | jq 'length')"
assert_contains "…the judged finding" "a judged finding" "$FJSON"
assert_not_contains "…and nothing from the skip-marked one" "nobody judged" "$FJSON"
if grep -q 'prior-reviews\.json' "$SCRIPT" && ! grep -q 'bot-reviews\.json' "$SCRIPT"; then
  ok "the script reads prior-reviews.json and never bot-reviews.json"
else
  bad "prior-findings.sh must read prior-reviews.json (the JUDGED list), never bot-reviews.json"
fi

echo ""
echo "── an ABSENT state block is not a CORRUPT one ──"
# jq emits a bare newline when no review carries a block, so the file is 1 byte
# and `[ -s ]` was true — reporting corruption on every PR that predates the
# state block, which on release day is the entire round-2 population.
reset 2
printf '[%s]\n' "$(review 2026-06-01T00:00:00Z "## Claude review — COMMENT

A body from before the state block shipped.")" > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "exit 0" "0" "$RC"
assert_not_contains "no state block is not an unreadable one" \
  "state block is present but unreadable" "$OUT"

# …and a block that IS there but is malformed must still say so.
reset 2
printf '[%s]\n' "$(review 2026-06-02T00:00:00Z "## Claude review — COMMENT

<!-- claude-review-state
{ this is not json
-->")" > "$WORK/out/prior-reviews.json"
run_pf
assert_eq "exit 0" "0" "$RC"
assert_contains "a corrupt block still warns" \
  "state block is present but unreadable" "$OUT"

echo ""
echo "── a check comment is orientation, never a carried finding ──"
# spendfuse#373: round 1's checks came back to the model as prior findings with an
# empty severity. There is no bucket for a note — round 2 cannot resolve one — so
# it was re-emitted a line away and the author answered it twice in one morning.
# post-review.sh already excludes checks from the state block and kept-keys.txt;
# carrier 2 is the arm that reads the comments straight back off the API.
reset 2
printf '[%s,%s]\n' \
  "$(comment src/foo.ts 81 '**check** The basis rides on the opportunity detail, not the evidence response.

[spec](https://example.test/doc)')" \
  "$(comment src/bar.ts 10 '**major** delta drops the tenant filter

a staff read returns every tenants rows')" > "$WORK/comments.json"
run_pf
assert_eq "exit 0" "0" "$RC"
assert_eq "only the finding is carried" "1" "$(echo "$FJSON" | jq 'length')"
assert_eq "…and it is the major" "major" "$(echo "$FJSON" | jq -r '.[0].sev')"
assert_not_contains "the check does not reach the model" "basis rides on" "$FMD"
assert_not_contains "…nor does its spec link land in the scenario slot" "example.test" "$FMD"
assert_contains "the real finding still does" "drops the tenant filter" "$FMD"

echo ""
echo "── …whatever case the marker is written in ──"
reset 2
printf '[%s]\n' "$(comment src/foo.ts 81 '**Check** Mixed-case marker, still a note.')" \
  > "$WORK/comments.json"
run_pf
assert_eq "count is 0" "0" "$COUNT"
assert_not_contains "no sev-less row is rendered" "Mixed-case marker" "$FMD"

echo ""
echo "── a check sitting on a finding's own lines suppresses neither ──"
# A check may legitimately share path:line with a finding. Dropping the check must
# not drop the finding that happens to live there.
reset 2
printf '[%s,%s]\n' \
  "$(comment src/foo.ts 11 '**check** What this block is for.')" \
  "$(comment src/foo.ts 11 '**critical** alpha loops forever

a 401 spins the refresh forever')" > "$WORK/comments.json"
run_pf
assert_eq "the finding survives alone" "1" "$(echo "$FJSON" | jq 'length')"
assert_eq "…as a critical" "critical" "$(echo "$FJSON" | jq -r '.[0].sev')"

echo ""
echo "── house rules ──"
if grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$SCRIPT"; then
  bad "prior-findings.sh uses set -e (banned, bugbot.md)"
else
  ok "prior-findings.sh does not use set -e"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All prior-findings tests passed."
  exit 0
else
  echo "$fail prior-findings test(s) failed."
  exit 1
fi
