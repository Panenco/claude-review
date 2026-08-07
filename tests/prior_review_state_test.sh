#!/usr/bin/env bash
set -uo pipefail

# prior_review_state_test.sh — fixture test for scripts/prior-review-state.sh.
#
# The script turns a PR's review list into (round, prior_head_sha, prior_verdict,
# oversized_dup). Reviews come from a fixture file via REVIEWS_JSON, so no gh and
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
PLAN_SCRIPT="$ROOT/scripts/review-plan.sh"
ORCHESTRATOR="$ROOT/skills/review-orchestrator.md"
CONTEXT_BUILDER="$ROOT/skills/review-context-builder.md"
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

# assert_state <label> <fixture-json-array> <want "round sha verdict dup"> [EXTRA_ENV=...]
assert_state() {
  local label="$1" fixture="$2" want="$3"; shift 3
  printf '%s' "$fixture" > "$WORK/reviews.json"
  local got
  got=$(env REVIEWS_JSON="$WORK/reviews.json" REVIEW_BOT_USER="$BOT" OUT_DIR="$WORK/out" \
          GATE="" GITHUB_EVENT_NAME=pull_request "$@" bash "$SCRIPT" \
        | awk -F= '
            /^round=/         {r=$2}
            /^prior_head_sha=/{s=$2}
            /^prior_verdict=/ {v=$2}
            /^oversized_dup=/ {d=$2}
            END {print r, (s == "" ? "-" : s), (v == "" ? "-" : v), d}')
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

echo "── round derivation ──"

assert_state "no reviews → round 1" \
  "[]" "1 - - false"

# THE REGRESSION. An oversized block judged nothing, so the next run must start
# from scratch — full scope, no prior head to diff against.
assert_state "oversized block only → round 1 (never judged)" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$OVERSIZED_BODY")]" \
  "1 - - false"

assert_state "skip-label note only → round 1 (never judged)" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$SKIPPED_BODY")]" \
  "1 - - false"

assert_state "crash banner only → round 1" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$CRASH_BODY")]" \
  "1 - - false"

assert_state "one judged review → round 2 with its head + verdict" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

# A judged round followed by a block (PR grew past the ceiling) still anchors on
# the judged round — the block contributes no state at all.
assert_state "judged then oversized → round 2 anchored on the judged review" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_NEW" "$OVERSIZED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

assert_state "two judged reviews → round 3, latest head" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review APPROVED 2026-08-07T08:00:00Z "$SHA_NEW" "$JUDGED_BODY")]" \
  "3 $SHA_NEW APPROVE false"

# A dismissal is not an approval. It says nothing about what the review found,
# so the verdict comes from the body header and the orchestrator's
# `prior-dismiss-drops-low-sev` rung decides what dismissal may drop (minor/note
# only). Mapping DISMISSED→APPROVE here un-pinned the prior round's blockers.
assert_state "dismissed judged RC → verdict recovered from the body" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

assert_state "dismissed judged APPROVE → APPROVE" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_APPROVE_BODY")]" \
  "2 $SHA_OLD APPROVE false"

assert_state "dismissed with unparseable body → REQUEST_CHANGES (fail closed)" \
  "[$(review DISMISSED 2026-08-07T07:46:24Z "$SHA_OLD" 'some hand-edited body')]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

# Mirror of the oversized case: a skip note posted after a judged round adds no
# state, so the next push still resumes from the judged round — with its verdict.
assert_state "judged then skip note → round 2 anchored on the judged review" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:00:00Z "$SHA_OLD" "$JUDGED_BODY"),
    $(review COMMENTED 2026-08-07T07:46:24Z "$SHA_NEW" "$SKIPPED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

# Markers are stamped on the body's FIRST LINE. This repo reviews itself, so a
# judged review that QUOTES a marker in a finding is a live case — matching with
# contains() would drop it from the judged list, resetting the round to 1 and
# un-pinning its blockers from the anti-downgrade ladder.
assert_state "judged review quoting a marker still counts as judged" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$QUOTING_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false"

# Same anchoring, other direction: the dedup must not fire off a quoted marker,
# or a still-oversized PR silently skips the run that would have reviewed it.
assert_state "judged review quoting a marker → no oversized dedup" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$QUOTING_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false" GATE=oversized

# GitHub hands back CRLF bodies; the stamp is still the first line.
assert_state "CRLF skip body → still recognised as a skip" \
  "[$(review COMMENTED 2026-08-07T07:46:24Z "$SHA_OLD" "$(printf '<!-- claude-review-skipped -->\r\n\r\n## Claude PR Review — COMMENT\r\n')")]" \
  "1 - - false"

assert_state "unreachable prior head → reset to round 1" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_GONE" "$JUDGED_BODY")]" \
  "1 - - false"

assert_state "another bot's review is not ours" \
  '[{"user":{"login":"aikido-pr-checks[bot]"},"state":"COMMENTED","submitted_at":"2026-08-06T15:00:14Z","commit_id":"'"$SHA_OLD"'","body":"something"}]' \
  "1 - - false"

echo
echo "── oversized dedup (reads the FULL list, must survive the round filter) ──"

# The dedup asks "is the review standing on this PR my own block?" — if it read
# the judged-only list it would never see one, and every push to a still-oversized
# PR would re-post a byte-identical block.
assert_state "still oversized, block standing → dedup fires" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$OVERSIZED_BODY")]" \
  "1 - - true" GATE=oversized

assert_state "still oversized, judged review standing → no dedup" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$JUDGED_BODY")]" \
  "2 $SHA_OLD REQUEST_CHANGES false" GATE=oversized

assert_state "block standing but gate no longer oversized → no dedup" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$OVERSIZED_BODY")]" \
  "1 - - false" GATE=normal

assert_state "workflow_dispatch always re-runs" \
  "[$(review CHANGES_REQUESTED 2026-08-07T07:46:24Z "$SHA_OLD" "$OVERSIZED_BODY")]" \
  "1 - - false" GATE=oversized GITHUB_EVENT_NAME=workflow_dispatch

echo
echo "── guard: every skip gate must have a marker ──"

# review-plan.sh is the only producer of review_level=skip. Sweep a matrix wide
# enough to hit every branch and collect the gates that skip; each one needs a
# marker in prior-review-state.sh, or the next push reviews only the delta.
BIG_FILES=$(for i in $(seq 1 65); do printf 'src/f%d.ts\t10\t10\n' "$i"; done)
skip_gates=$(
  {
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'skip-review' GATE_FILES_TSV=$'src/a.ts\t5\t5' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV="$BIG_FILES" bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=staging GATE_FILES_TSV=$'src/a.ts\t5\t5' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'README.md\t5\t5' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t1\t1' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t50\t50' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t500\t500' bash "$PLAN_SCRIPT"
    env GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'deep-review' GATE_FILES_TSV="$BIG_FILES" bash "$PLAN_SCRIPT"
  } | awk -F= '/^review_level=/{lvl=$2} /^gate=/{if (lvl == "skip") print $2}' | sort -u
)
# Pin the sweep's own result first. Everything below loops over $skip_gates, so
# an empty sweep — review-plan.sh renamed a GATE_* input, or the FILE/SIZE
# ceilings moved past BIG_FILES — would run zero assertions and still print
# "All prior-review-state tests passed". The guard has to fail loudly when it
# stops guarding anything.
EXPECTED_SKIP_GATES=$'label\noversized'
if [ "$skip_gates" != "$EXPECTED_SKIP_GATES" ]; then
  echo "FAIL: skip-gate sweep found [$(echo "$skip_gates" | tr '\n' ' ')], expected [label oversized]."
  echo "      Either review-plan.sh changed which gates skip — add the new one to SKIP_MARKERS in"
  echo "      prior-review-state.sh, to marker_for below, and to EXPECTED_SKIP_GATES — or the sweep's"
  echo "      env matrix no longer trips the gates it targets, in which case the marker guard below"
  echo "      is checking nothing."
  fail=$((fail + 1))
else
  echo "OK:   skip-gate sweep reached both skip gates (label, oversized)"
fi

# gate → the marker its review body must carry.
marker_for() {
  case "$1" in
    oversized) echo '<!-- claude-review-oversized -->' ;;
    label)     echo '<!-- claude-review-skipped -->' ;;
    *)         echo "" ;;
  esac
}
while IFS= read -r gate; do
  [ -z "$gate" ] && continue
  marker=$(marker_for "$gate")
  if [ -z "$marker" ]; then
    echo "FAIL: review-plan.sh gate '$gate' yields review_level=skip but has no skip marker."
    echo "      Give its review body a marker in skills/review-orchestrator.md, add the marker"
    echo "      to SKIP_MARKERS in scripts/prior-review-state.sh, and map it in marker_for above."
    fail=$((fail + 1))
    continue
  fi
  if ! grep -qF "$marker" "$SCRIPT"; then
    echo "FAIL: gate '$gate' marker $marker is not in SKIP_MARKERS in prior-review-state.sh"
    fail=$((fail + 1))
  # Anchored to the `body` = spec on purpose: both markers also appear in this
  # skill's explanatory prose, so an unanchored grep passes even after a gate
  # stops stamping its marker — i.e. it would stop checking the thing it names.
  elif ! grep -F '`body` =' "$ORCHESTRATOR" | grep -qF "$marker"; then
    echo "FAIL: gate '$gate' marker $marker is not stamped by any \`body\` = spec in review-orchestrator.md"
    fail=$((fail + 1))
  # The context builder derives its OWN prior review for the round-2 ladder. If
  # it doesn't exclude the same markers, it resolves to a review that judged
  # nothing and reconstructs zero prior findings — forgiving real blockers.
  elif ! grep -qF "$marker" "$CONTEXT_BUILDER"; then
    echo "FAIL: gate '$gate' marker $marker is not excluded by review-context-builder.md's prior-review filter"
    fail=$((fail + 1))
  else
    echo "OK:   skip gate '$gate' → $marker (stamped, filtered by both consumers)"
  fi
done <<< "$skip_gates"

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
