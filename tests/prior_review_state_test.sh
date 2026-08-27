#!/usr/bin/env bash
set -uo pipefail

# prior_review_state_test.sh — fixture test for scripts/prior-review-state.sh.
#
# The script turns a PR's review list into (round, prior_head_sha, prior_verdict).
# Reviews come from a fixture file via REVIEWS_JSON, so no gh and
# no network. The SHA-reachability check is real git, so the fixtures run inside a
# scratch repo with two real commits.
#
# The regression this file exists for (PR Panenco/qit#7534): an oversized
# "split this PR" block is a REVIEW_LEVEL=skip early-return — no judge ever read
# the diff. Counting it as round 1 made the next push scope itself to the
# since-last diff and APPROVE 4251 unreviewed lines on the strength of a 7-line
# generated-schema delta. Rounds count reviews that JUDGED, not reviews POSTED.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/prior-review-state.sh"
GUARD="$ROOT/scripts/guard.sh"
POSTER="$ROOT/scripts/post-review.sh"
fail=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Scratch repo: SHA_OLD and SHA_NEW resolve, SHA_GONE does not.
git init -q "$WORK/repo"
cd "$WORK/repo" || exit 1
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
SHA_OLD=$(git rev-parse HEAD)
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
SHA_NEW=$(git rev-parse HEAD)
SHA_GONE=0000000000000000000000000000000000000000

BOT=panenco-claude-reviewer[bot]

# review <state> <submitted_at> <sha> <body> → one review object
review() {
  jq -nc --arg bot "$BOT" --arg state "$1" --arg at "$2" --arg sha "$3" --arg body "$4" \
    '{user: {login: $bot}, state: $state, submitted_at: $at, commit_id: $sha, body: $body}'
}

OVERSIZED_BODY='<!-- claude-review-oversized -->

## Claude PR Review — REQUEST_CHANGES

PR too large to review well (30 files, 4587 non-generated lines).'
SKIPPED_BODY='<!-- claude-review-skipped -->

## Claude PR Review — COMMENT

Skipping detailed review — skip-review label present.'
CRASH_BODY='<!-- claude-review-crash -->

> **Claude Review — incomplete**'
JUDGED_BODY='## Claude PR Review — REQUEST_CHANGES

### Blocking findings
- **[major]** `src/a.ts:10` — unchecked null.'
JUDGED_APPROVE_BODY='## Claude PR Review — APPROVE

No blocking findings.'
# A real review of THIS repo: the marker appears in a finding, not as the stamp.
# Anything matching markers with contains() reads this as "never judged".
QUOTING_BODY='## Claude PR Review — REQUEST_CHANGES

### Blocking findings
- **[major]** `skills/review-orchestrator.md:53` — the skip branch documents its
  body as `<!-- claude-review-skipped -->` but the oversized branch stamps
  `<!-- claude-review-oversized -->`; the two specs disagree.'

# assert_state <label> <fixture-json-array> <want "round sha verdict"> [EXTRA_ENV=...]
assert_state() {
  local label="$1" fixture="$2" want="$3"; shift 3
  printf '%s' "$fixture" > "$WORK/reviews.json"
  local got
  got=$(env REVIEWS_JSON="$WORK/reviews.json" REVIEW_BOT_USER="$BOT" OUT_DIR="$WORK/out" \
          "$@" bash "$SCRIPT" \
        | awk -F= '
            /^round=/         {r=$2}
            /^prior_head_sha=/{s=$2}
            /^prior_verdict=/ {v=$2}
            END {print r, (s == "" ? "-" : s), (v == "" ? "-" : v)}')
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

echo "── round derivation ──"

assert_state "no reviews → round 1" \
  "[]" "1 - -"

# THE REGRESSION. An oversized block judged nothing, so the next run must start
# from scratch — full scope, no prior head to diff against.
assert_state "oversized block only → round 1 (never judged)" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$OVERSIZED_BODY")]" \
  "1 - -"

assert_state "skip-label note only → round 1 (never judged)" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$SKIPPED_BODY")]" \
  "1 - -"

assert_state "crash banner only → round 1" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$CRASH_BODY")]" \
  "1 - -"

assert_state "one judged review → round 2 with its head + verdict" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES"

# A judged round followed by a block (PR grew past the ceiling) still anchors on
# the judged round — the block contributes no state at all.
assert_state "judged then oversized → round 2 anchored on the judged review" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_NEW" "$OVERSIZED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES"

assert_state "two judged reviews → round 3, latest head" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review APPROVED 2026-08-07T08:00:00Z "$SHA_NEW" "$JUDGED_BODY")]" \
  "3 $SHA_NEW APPROVE"

# A dismissal is not an approval. It says nothing about what the review found, so
# the verdict is recovered from the body header. Nothing gates on it now (ADR 0003
# recomputes the verdict fresh each round), but it lands in the usage record.
assert_state "dismissed judged RC → verdict recovered from the body" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES"

assert_state "dismissed judged APPROVE → APPROVE" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_APPROVE_BODY")]" \
  "2 $SHA_OLD APPROVE"

# v4 renamed the header from "## Claude PR Review" to "## Claude review". Both must
# parse: a long-lived PR carries reviews written by both versions of the poster, and
# a header the regex misses silently fails closed to REQUEST_CHANGES.
assert_state "dismissed v4-header review → verdict recovered" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" '## Claude review — APPROVE

Looks fine.')]" \
  "2 $SHA_OLD APPROVE"

assert_state "dismissed with unparseable body → REQUEST_CHANGES (fail closed)" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" 'some hand-edited body')]" \
  "2 $SHA_OLD REQUEST_CHANGES"

# Mirror of the oversized case: a skip note posted after a judged round adds no
# state, so the next push still resumes from the judged round — with its verdict.
assert_state "judged then skip note → round 2 anchored on the judged review" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review COMMENTED 2026-08-07T07:46:24Z "$SHA_NEW" "$SKIPPED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES"

# Markers are stamped on the body's FIRST LINE. This repo reviews itself, so a
# judged review that QUOTES a marker in a finding is a live case — matching with
# contains() would drop it from the judged list, resetting the round to 1 and
# un-pinning its blockers from the anti-downgrade ladder.
assert_state "judged review quoting a marker still counts as judged" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$QUOTING_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES"

# GitHub hands back CRLF bodies; the stamp is still the first line.
assert_state "CRLF skip body → still recognised as a skip" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$(printf '<!-- claude-review-skipped -->\r\n\r\n## Claude PR Review — COMMENT\r\n')")]" \
  "1 - -"

assert_state "unreachable prior head → reset to round 1" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_GONE" "$JUDGED_BODY")]" \
  "1 - -"

assert_state "another bot's review is not ours" \
  '[{"user":{"login":"aikido-pr-checks[bot]"},"state":"COMMENTED","submitted_at":"2026-08-06T15:00:14Z","commit_id":"'"$SHA_OLD"'","body":"something"}]' \
  "1 - -"

echo
echo "── guard: every skip gate that POSTS must carry a marker ──"

# guard.sh is the only producer of a review nobody judged. Sweep every branch and
# collect the ones that still post a body; each needs a marker, or the next push
# reviews only the delta on top of a review that read no code.
BIG_FILES=$(for i in $(seq 1 65); do printf 'src/f%d.ts\t10\t10\n' "$i"; done)
guard_body() {
  env "$@" bash "$GUARD" | awk '/^body<<GUARD_BODY$/{f=1;next} /^GUARD_BODY$/{f=0} f'
}
posting_gates=$(
  {
    env GATE_LABELS=$'skip-review' GATE_FILES_TSV=$'src/a.ts\t5\t5' bash "$GUARD"
    env GATE_FILES_TSV="$BIG_FILES" bash "$GUARD"
    env GATE_FILES_TSV=$'pnpm-lock.yaml\t9\t9' bash "$GUARD"
    env GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' GATE_FILES_TSV=$'src/a.ts\t5\t5' bash "$GUARD"
    env GATE_FILES_TSV=$'src/a.ts\t5\t5' bash "$GUARD"
  } | awk -F= '/^gate=/{g=$2} /^verdict=/{if ($2 != "") print g}' | sort -u
)
# Pin the sweep's own result first: a sweep that trips nothing would run zero
# assertions below and still print "All prior-review-state tests passed".
if [ "$posting_gates" != "oversized" ]; then
  echo "FAIL: posting-gate sweep found [$(echo "$posting_gates" | tr '\n' ' ')], expected [oversized]."
  echo "      Either guard.sh gained a gate that posts without a model call — give its body a"
  echo "      marker, add the marker to SKIP_MARKERS in prior-review-state.sh and to marker_for"
  echo "      below — or the sweep no longer trips the oversized ceilings and guards nothing."
  fail=$((fail + 1))
else
  echo "OK:   posting-gate sweep reached the oversized gate"
fi

# gate → the marker its review body must carry.
marker_for() {
  case "$1" in
    oversized) echo '<!-- claude-review-oversized -->' ;;
    *)         echo "" ;;
  esac
}
while IFS= read -r gate; do
  [ -z "$gate" ] && continue
  marker=$(marker_for "$gate")
  if [ -z "$marker" ]; then
    echo "FAIL: guard.sh gate '$gate' posts a review nobody judged but has no skip marker."
    fail=$((fail + 1))
    continue
  fi
  # The marker must be the body's FIRST line: every consumer anchors there.
  if [ "$(guard_body GATE_FILES_TSV="$BIG_FILES" | head -n1)" != "$marker" ]; then
    echo "FAIL: gate '$gate' does not stamp $marker as the first line of its body"
    fail=$((fail + 1))
  elif ! grep -qF "$marker" "$SCRIPT"; then
    echo "FAIL: gate '$gate' marker $marker is not in SKIP_MARKERS in prior-review-state.sh"
    fail=$((fail + 1))
  else
    echo "OK:   skip gate '$gate' → $marker (stamped first, excluded from the judged list)"
  fi
done <<< "$posting_gates"

# The poster must not dismiss a standing block when posting a skip-marked review
# (behaviour asserted in tests/post_review_test.sh) — that would un-block a PR
# nobody re-reviewed AND make the next round read its prior verdict off a
# DISMISSED review. Cheap structural canary so deleting the guard is loud here too.
if ! grep -q 'claude-review-(skipped|oversized)' "$POSTER"; then
  echo "FAIL: post-review.sh no longer skips stale-review dismissal for skip-marked bodies"
  fail=$((fail + 1))
else
  echo "OK:   post-review.sh leaves standing reviews alone on skip-marked posts"
fi

if [ "$fail" -eq 0 ]; then
  echo
  echo "All prior-review-state tests passed."
  exit 0
else
  echo
  echo "$fail prior-review-state test assertion(s) failed."
  exit 1
fi
