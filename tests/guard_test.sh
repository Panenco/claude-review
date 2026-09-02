#!/usr/bin/env bash
set -uo pipefail

# guard_test.sh — fixture test for scripts/guard.sh.
#
# The guard is a pure function: (changed files + labels + the round-2 delta) → one
# of five gates, with no network and no LLM. Inputs go in via env; we assert on the emitted
# "proceed gate verdict" triple and, for the oversized gate, on the split-request
# body it renders itself (there is no model call on that path).
#
# gates: ok | label | unchanged | oversized | empty

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/guard.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }
fail=0

# summary_of KEY=VAL... → "<proceed> <gate> <verdict>" (verdict "-" when empty)
summary_of() {
  env "$@" bash "$SCRIPT" | awk -F= '
    /^proceed=/ {p=$2}
    /^gate=/    {g=$2}
    /^verdict=/ {v=($2 == "" ? "-" : $2)}
    END {print p, g, v}'
}
body_of() {
  env "$@" bash "$SCRIPT" | awk '/^body<<GUARD_BODY$/{f=1;next} /^GUARD_BODY$/{f=0} f'
}
# docs_only_of KEY=VAL... → the emitted docs_only value, "-" when no line was emitted
docs_only_of() {
  local v; v=$(env "$@" bash "$SCRIPT" | sed -n 's/^docs_only=//p' | head -1)
  printf '%s' "${v:--}"
}
# scale_of KEY=VAL... → "<depth_scale> <comment_limit>", "- -" when neither emitted
scale_of() {
  local out d c
  out=$(env "$@" bash "$SCRIPT")
  d=$(sed -n 's/^depth_scale=//p' <<< "$out" | head -1)
  c=$(sed -n 's/^comment_limit=//p' <<< "$out" | head -1)
  printf '%s %s' "${d:--}" "${c:--}"
}

assert_gate() {
  local label="$1" want="$2"; shift 2
  local got; got=$(summary_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}
assert_docs_only() {
  local label="$1" want="$2"; shift 2
  local got; got=$(docs_only_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → docs_only=$got"
  else
    echo "FAIL: $label — want docs_only='$want' got '$got'"
    fail=$((fail + 1))
  fi
}
assert_scale() {
  local label="$1" want="$2"; shift 2
  local got; got=$(scale_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → depth_scale/comment_limit = $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "OK:   $label" ;;
    *) echo "FAIL: $label — expected to find '$needle'"; fail=$((fail + 1)) ;;
  esac
}

# 65 runtime files — one over the default file ceiling.
BIG_FILES=$(for i in $(seq 1 65); do printf 'src/f%d.ts\t10\t10\n' "$i"; done)

echo "── the review path (everything not short-circuited) ──"
# No tiers any more: docs, tiny fixes, promotions, sensitive paths and 300-line
# features all take the SAME path. review-scan self-scales its own depth.
assert_gate "small runtime fix" "true ok -" \
  GATE_FILES_TSV=$'src/util.ts\t5\t3'
assert_gate "docs only" "true ok -" \
  GATE_FILES_TSV=$'README.md\t10\t0'
assert_gate "test only" "true ok -" \
  GATE_FILES_TSV=$'src/app.test.ts\t40\t0'
assert_gate "auth change (no sensitive-path tier — scan decides)" "true ok -" \
  GATE_FILES_TSV=$'src/services/auth.service.ts\t3\t1'
assert_gate "promotion branch (no promotion tier)" "true ok -" \
  GATE_BASE_REF=main GATE_HEAD_REF=staging GATE_FILES_TSV=$'apps/web/x.ts\t10\t2'
assert_gate "an unrelated label changes nothing" "true ok -" \
  GATE_LABELS=$'enhancement' GATE_FILES_TSV=$'src/app.ts\t40\t5'
# The override only lifts the SIZE ceiling. On a PR that was never oversized
# neither input changes anything — there is no depth tier left for them to pick.
assert_gate "deep-review on a normal PR changes nothing" "true ok -" \
  GATE_LABELS=$'deep-review' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "/review deep on a normal PR changes nothing" "true ok -" \
  GATE_FORCE_DEEP=true GATE_FILES_TSV=$'src/app.ts\t40\t5'

echo
echo "── 1) skip-review label → no post at all ──"
assert_gate "skip-review label" "false label -" \
  GATE_LABELS=$'enhancement\nskip-review' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "label beats oversized" "false label -" \
  GATE_LABELS=$'skip-review' GATE_FILES_TSV="$BIG_FILES"
assert_gate "custom skip label honoured" "false label -" \
  GATE_SKIP_LABEL=no-bot GATE_LABELS=$'no-bot' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "the default label is inert once overridden" "true ok -" \
  GATE_SKIP_LABEL=no-bot GATE_LABELS=$'skip-review' GATE_FILES_TSV=$'src/app.ts\t40\t5'
# grep -Fxq, not a substring match: a label that merely contains the word must not skip.
assert_gate "'do-not-skip-review' is not the skip label" "true ok -" \
  GATE_LABELS=$'do-not-skip-review' GATE_FILES_TSV=$'src/app.ts\t40\t5'

echo
echo "── 2) round 2+ with an empty delta → skip the whole run, post nothing ──"
# PR 94 cost ~$35-40 across 7 FULL re-reviews. A re-run with no new commits must
# cost nothing at all, and must post nothing — a duplicate review of identical
# code is the token regression this gate exists to stop (docs/adr/0003).
assert_gate "no commits since the last review" "false unchanged -" \
  GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "only generated churn since the last review" "false unchanged -" \
  GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES=$'pnpm-lock.yaml\ndist/app.min.js' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "one real file since the last review → review it" "true ok -" \
  GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES=$'src/app.ts' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "a real file beside generated churn still reviews" "true ok -" \
  GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES=$'pnpm-lock.yaml\nsrc/app.ts' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
# ROUND 1 MUST NEVER SKIP. With no prior SHA there is nothing to diff against, so
# an empty delta means "not applicable", not "nothing changed" — reading it the
# other way would silently skip every first review.
assert_gate "round 1 (no prior SHA) ignores the delta entirely" "true ok -" \
  GATE_DELTA_FILES='' GATE_FILES_TSV=$'src/app.ts\t40\t5'
# The opt-out still outranks it: order matters only for which reason gets logged.
assert_gate "skip label beats unchanged" "false label -" \
  GATE_LABELS=$'skip-review' GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
# Nothing is posted — a second identical review body on the PR is worse than
# silence, and post-review.sh is never reached on this path.
if [ -z "$(body_of GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' GATE_FILES_TSV=$'src/app.ts\t40\t5')" ]; then
  echo "OK:   the unchanged gate posts nothing"
else
  echo "FAIL: the unchanged gate emitted a body — an empty delta must post nothing"
  fail=$((fail + 1))
fi

# ── 2b) …but it must never silence a human who typed the command ────────────
# `/review code` then `/review functional` on the same commit: the second got a
# 👀 reaction and then nothing — no comment, no tester, green check. That is the
# exact failure prior-review-state.sh:120 already rejected ("answering that with
# silence is worse than answering it with the same block twice"). The gate is
# for AUTOMATIC re-runs; an explicit request always gets an answer.
assert_gate "an explicit /review on an unchanged commit still runs" "true ok -" \
  GATE_HUMAN_REQUESTED=true GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "…and so does one where only generated files moved" "true ok -" \
  GATE_HUMAN_REQUESTED=true GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES=$'pnpm-lock.yaml' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
# The other direction: not human-requested (or unset) keeps the gate.
assert_gate "an automatic re-run on an unchanged commit still skips" "false unchanged -" \
  GATE_HUMAN_REQUESTED=false GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
# Only the literal "true" opts out — a workflow expression that evaluated to
# something else must not accidentally disable the gate.
for v in "" "TRUE" "yes" "1"; do
  assert_gate "GATE_HUMAN_REQUESTED='$v' is not an opt-out" "false unchanged -" \
    GATE_HUMAN_REQUESTED="$v" GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
    GATE_FILES_TSV=$'src/app.ts\t40\t5'
done
# A human request does NOT buy past the other three gates: the opt-out label,
# the size ceiling and "nothing reviewable" are not about re-run frequency.
assert_gate "skip-review still outranks a human request" "false label -" \
  GATE_HUMAN_REQUESTED=true GATE_LABELS=$'skip-review' GATE_PRIOR_HEAD_SHA=deadbee \
  GATE_DELTA_FILES='' GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_gate "oversized still blocks a human request" "false oversized REQUEST_CHANGES" \
  GATE_HUMAN_REQUESTED=true GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
  GATE_FILES_TSV="$BIG_FILES"
assert_gate "nothing reviewable still skips a human request" "false empty -" \
  GATE_HUMAN_REQUESTED=true GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' \
  GATE_FILES_TSV=$'pnpm-lock.yaml\t9000\t9000'

echo
echo "── 3) oversized → REQUEST_CHANGES split request, no model call ──"
assert_gate "65 files (over the 60-file ceiling)" "false oversized REQUEST_CHANGES" \
  GATE_FILES_TSV="$BIG_FILES"
assert_gate "exactly 60 files is not oversized" "true ok -" \
  GATE_FILES_TSV="$(for i in $(seq 1 60); do printf 'src/f%d.ts\t1\t0\n' "$i"; done)"
assert_gate "3500 lines (over the 3000-line ceiling)" "false oversized REQUEST_CHANGES" \
  GATE_FILES_TSV=$'src/big.ts\t2000\t1500'
assert_gate "exactly 3000 lines is not oversized" "true ok -" \
  GATE_FILES_TSV=$'src/big.ts\t2000\t1000'
assert_gate "ceilings are configurable" "false oversized REQUEST_CHANGES" \
  GATE_SIZE_CEILING=10 GATE_FILES_TSV=$'src/big.ts\t6\t5'
# Generated churn must never be what makes a PR too big to review.
assert_gate "a huge lockfile beside a small diff is not oversized" "true ok -" \
  GATE_FILES_TSV=$'src/a.ts\t5\t5\npnpm-lock.yaml\t9000\t9000'
assert_gate "70 generated files beside one source file is not oversized" "true ok -" \
  GATE_FILES_TSV="$(for i in $(seq 1 70); do printf 'dist/f%d.min.js\t10\t10\n' "$i"; done)"$'\nsrc/a.ts\t5\t5'

# One committed openapi.combined.json put a 143-line reviewable diff over 45000
# lines, and the PR was refused with no code read. It held three defects.
assert_gate "a committed OpenAPI spec beside a small diff is not oversized" "true ok -" \
  GATE_FILES_TSV=$'openapi.combined.json\t22800\t22535\nscripts/openapi/boot-java.sh\t50\t26\n.github/workflows/ci-node.yml\t14\t3'
assert_gate "…and a nested one too" "true ok -" \
  GATE_FILES_TSV=$'apps/api/openapi.yaml\t9000\t9000\nsrc/a.ts\t5\t5'
assert_gate "…swagger, a GraphQL schema and .gen. output the same way" "true ok -" \
  GATE_FILES_TSV=$'swagger.json\t4000\t0\nschema.graphql\t3000\t0\nsrc/types.gen.ts\t2000\t0\nsrc/a.ts\t5\t5'
assert_gate "a repo declares its own build output through GATE_GENERATED_GLOBS" "true ok -" \
  GATE_GENERATED_GLOBS='*.pot proto/**' GATE_FILES_TSV=$'locale/messages.pot\t9000\t0\nsrc/a.ts\t5\t5'
# The exclusion must not swallow a real source file that merely reads like one.
assert_gate "a hand-written file named for a spec still counts" "false oversized REQUEST_CHANGES" \
  GATE_FILES_TSV=$'src/openapi-client.ts\t2000\t1500'
assert_gate "an unmatched extra glob changes nothing" "false oversized REQUEST_CHANGES" \
  GATE_GENERATED_GLOBS='*.pot' GATE_FILES_TSV=$'src/big.ts\t2000\t1500'
# A declared glob is a PATTERN, not a path list. Splitting it unquoted also
# pathname-expands it against the checkout: `proto/**` became the real directory
# `proto/gen`, matched nothing, and the declaration did nothing at all.
GLOBDIR=$(mktemp -d); mkdir -p "$GLOBDIR/proto/gen"
GOT=$(cd "$GLOBDIR" && env GATE_GENERATED_GLOBS='proto/**' \
      GATE_FILES_TSV=$'proto/gen/api.pb.ts\t9000\t0\nsrc/a.ts\t5\t5' \
      bash "$SCRIPT" | sed -n 's/^gate=//p')
assert_contains "a declared glob is not expanded against the working directory" "ok" "$GOT"
rm -rf "$GLOBDIR"

BODY=$(body_of GATE_FILES_TSV="$BIG_FILES")
assert_contains "split body carries the oversized skip marker" "<!-- claude-review-oversized -->" "$BODY"
assert_contains "split body is stamped REQUEST_CHANGES" "## Claude review — REQUEST_CHANGES" "$BODY"
assert_contains "split body states the measured size" "65 files, 1300 non-generated lines" "$BODY"
assert_contains "split body says how to proceed" "Split it into focused PRs" "$BODY"
assert_contains "split body names the opt-out label" '`skip-review`' "$BODY"
if [ "${#BODY}" -le 1200 ]; then
  echo "OK:   split body fits the 1200-char body budget (${#BODY})"
else
  echo "FAIL: split body is ${#BODY} chars, over the 1200 budget"
  fail=$((fail + 1))
fi
# The marker must be the FIRST line: post-review.sh and prior-review-state.sh
# both anchor their skip detection there.
if [ "$(printf '%s\n' "$BODY" | head -n1)" = "<!-- claude-review-oversized -->" ]; then
  echo "OK:   skip marker is the body's first line"
else
  echo "FAIL: skip marker is not the body's first line"
  fail=$((fail + 1))
fi
# Only the oversized gate posts anything.
for g in "GATE_LABELS=skip-review" "GATE_FILES_TSV=pnpm-lock.yaml	1	1"; do
  if [ -z "$(body_of "$g" GATE_FILES_TSV=$'pnpm-lock.yaml\t1\t1')" ]; then
    echo "OK:   no body emitted for a non-oversized short-circuit ($g)"
  else
    echo "FAIL: a non-oversized short-circuit emitted a body ($g)"
    fail=$((fail + 1))
  fi
done

echo
echo "── 4) nothing reviewable → skip ──"
assert_gate "lockfile only" "false empty -" \
  GATE_FILES_TSV=$'pnpm-lock.yaml\t9000\t9000'
assert_gate "generated bundle only" "false empty -" \
  GATE_FILES_TSV=$'dist/app.min.js\t50\t10\nbuild/x.generated.ts\t5\t5'
assert_gate "no files at all" "false empty -" \
  GATE_FILES_TSV=''
assert_gate "unset GATE_FILES_TSV" "false empty -" \
  GATE_SKIP_LABEL=skip-review

echo
echo "── 5) docs_only — the proceed path tells the review there is no code to break ──"
# On a docs-only PR the failure_scenario bar deletes every finding an honest
# reader could make, so review-scan opens a narrow prose channel on this flag.
# It is a classification, never a gate: the run proceeds identically either way.
assert_docs_only "an all-markdown PR" "true" \
  GATE_FILES_TSV=$'docs/plan.md\t40\t2\nREADME.md\t3\t0'
assert_docs_only "one source file beside the docs drops it" "false" \
  GATE_FILES_TSV=$'docs/plan.md\t40\t2\nsrc/app.ts\t1\t1'
# Generated files are excluded from the size count, so they cannot flip this either.
assert_docs_only "a lockfile beside the docs does not" "true" \
  GATE_FILES_TSV=$'docs/plan.md\t40\t2\npnpm-lock.yaml\t900\t900'
assert_docs_only "LICENSE counts as a document" "true" \
  GATE_FILES_TSV=$'LICENSE\t1\t1'
# Proceed-path output only: a short-circuited run has no review to configure.
assert_docs_only "not emitted on the oversized gate" "-" \
  GATE_FILES_TSV="$BIG_FILES"
assert_docs_only "not emitted on the skip label" "-" \
  GATE_LABELS=$'skip-review' GATE_FILES_TSV=$'README.md\t2\t0'
assert_docs_only "not emitted on the unchanged gate" "-" \
  GATE_PRIOR_HEAD_SHA=deadbee GATE_DELTA_FILES='' GATE_FILES_TSV=$'README.md\t2\t0'
assert_docs_only "not emitted when nothing is reviewable" "-" \
  GATE_FILES_TSV=$'pnpm-lock.yaml\t900\t900'

echo
echo "── house rules ──"
if grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$SCRIPT"; then
  echo "FAIL: guard.sh uses set -e (banned, bugbot.md)"
  fail=$((fail + 1))
else
  echo "OK:   guard.sh does not use set -e"
fi
if grep -q 'gh \|curl \|wget ' "$SCRIPT"; then
  echo "FAIL: guard.sh reaches the network — it must stay a pure function of its inputs"
  fail=$((fail + 1))
else
  echo "OK:   guard.sh makes no network calls"
fi
# 135: 100 → 110 when `deep-review` was added, → 115 for the docs_only
# classification (one loop branch and one printf), → 135 for the depth scale
# (FOUR lines of code — a weight, a divide, a clamp, a printf — plus the comment
# that justifies the constants and the two extra lines in the output contract).
# NOT raised for `/review deep`. The ceiling guards against the tier ladder
# creeping back in, not against a comment, a single override, or one more line of
# output — and the depth scale is deliberately a continuous function rather than
# the tiers, which is why it cost four lines and not forty.
# → 153 for the generated-file list: three case arms, a loop for the repo-declared
# globs, and the `set -f` that keeps those globs literal. Still one flat predicate
# with no branching on size, which is the property this ceiling protects.
LINES=$(grep -c '' "$SCRIPT")
if [ "$LINES" -le 153 ]; then
  echo "OK:   guard.sh is $LINES lines (the whole point is that it is small)"
else
  echo "FAIL: guard.sh has grown to $LINES lines — the tiers belong in review-scan, not here"
  fail=$((fail + 1))
fi

echo


# --- two equivalent overrides for the size ceiling -------------------------
# A PR that genuinely cannot be split is worse off unreviewed than reviewed
# imperfectly: PR #106 (6692 lines, credential handling) merged with no review.
#
# `/review deep` (GATE_FORCE_DEEP, from review-command.sh) covers the run it
# started. The `deep-review` label covers every push, so a big PR that cannot be
# split does not need the command re-typed each round. EITHER is sufficient.
big="$(printf 'a.ts\t9000\t0')"
assert_gate "oversized blocks by default" "false oversized REQUEST_CHANGES" \
  "GATE_FILES_TSV=$big"
assert_gate "neither input → still blocked" "false oversized REQUEST_CHANGES" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=enhancement" "GATE_FORCE_DEEP=false"
assert_gate "deep-review label overrides oversized" "true ok -" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=deep-review"
assert_gate "/review deep overrides oversized" "true ok -" \
  "GATE_FILES_TSV=$big" "GATE_FORCE_DEEP=true"
assert_gate "command + label together is not a conflict" "true ok -" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=deep-review" "GATE_FORCE_DEEP=true"
# skip-review is label-only ON PURPOSE — "never review this PR" is persistent
# state, so there is no one-shot comment form of it. It outranks both overrides.
assert_gate "skip-review still wins over deep-review" "false label -" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=$(printf 'deep-review\nskip-review')"
assert_gate "skip-review still wins over /review deep" "false label -" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=skip-review" "GATE_FORCE_DEEP=true"
assert_gate "a near-miss label is not the override" "false oversized REQUEST_CHANGES" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=deep-review-please"
assert_gate "custom GATE_FORCE_LABEL is honoured" "true ok -" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=huge-ok" "GATE_FORCE_LABEL=huge-ok"
# Only the literal "true": a workflow expression that resolved to anything else
# (empty, "True", the string "run_functional") must not silently lift the ceiling.
for v in "" "TRUE" "yes" "1"; do
  assert_gate "GATE_FORCE_DEEP='$v' does not override" "false oversized REQUEST_CHANGES" \
    "GATE_FILES_TSV=$big" "GATE_FORCE_DEEP=$v"
done
# The split request is the only place the author is told how to proceed, so it
# must name BOTH routes, not just the label it used to name.
OVER=$(body_of "GATE_FILES_TSV=$big")
assert_contains "split request names the override label" "deep-review" "$OVER"
assert_contains "split request names the /review deep command" '`/review deep`' "$OVER"
assert_contains "split request still names the opt-out label" '`skip-review`' "$OVER"
assert_contains "split request honours a custom trigger" '`/claude deep`' \
  "$(body_of "GATE_FILES_TSV=$big" "GATE_TRIGGER=/claude")"
if [ "${#OVER}" -le 1200 ]; then
  echo "OK:   split body still fits the 1200-char budget (${#OVER})"
else
  echo "FAIL: split body is ${#OVER} chars, over the 1200 budget"
  fail=$((fail + 1))
fi


# --- depth scale: review depth is a function of diff size --------------------
# weight = ng_lines + 25*ng_files; depth_scale = min(3 + weight/250, 8);
# comment_limit = 2*depth_scale. The old pipeline used a flat 5 items / 10
# inline comments whether the PR was 20 lines or 2500 — the constant this
# replaces. Each case below pins one band edge, so a retuned divisor cannot slip
# through as "still roughly the same".
echo ""
echo "── depth scales with the diff, and only on the review path ──"
# weight 50 → 3. The floor is deliberately BELOW the old flat 5: a 25-line fix
# almost never had five honest human-review questions in it.
assert_scale "a 25-line one-file fix sits on the floor" "3 6" \
  GATE_FILES_TSV=$'src/util.ts\t20\t5'
# weight 249 is the last value in the bottom band, 250 the first in the next.
assert_scale "last weight in the bottom band" "3 6" \
  GATE_FILES_TSV=$'src/a.ts\t224\t0'
assert_scale "one unit more moves the band" "4 8" \
  GATE_FILES_TSV=$'src/a.ts\t225\t0'
# The team-limit PR: 400 lines over 4 files → weight 500 → 5 / 10, byte-for-byte
# the caps that shipped before the scale existed. The common case must not move.
assert_scale "a 400-line 4-file PR reproduces the old flat caps" "5 10" \
  GATE_FILES_TSV=$'a.ts\t100\t0\nb.ts\t100\t0\nc.ts\t100\t0\nd.ts\t100\t0'
# weight 1500 → 3+6=9, clamped. Attention is the constraint past ~1000 lines.
assert_scale "a 1000-line 20-file change is clamped at the top" "8 16" \
  GATE_FILES_TSV="$(for i in $(seq 1 20); do printf 'src/f%d.ts\t50\t0\n' "$i"; done)"
# Forced through by the label, so the scale still has to be emitted — and still
# clamped, not extrapolated off a 9000-line diff.
assert_scale "an oversized PR forced through still clamps at 8" "8 16" \
  "GATE_FILES_TSV=$big" "GATE_LABELS=deep-review"
# Files carry weight of their own: 60 one-line files is a real review even
# though the line count is trivial.
assert_scale "many tiny files still buy depth" "8 16" \
  GATE_FILES_TSV="$(for i in $(seq 1 60); do printf 'src/f%d.ts\t1\t0\n' "$i"; done)"
# Generated files are excluded from the counts, so they must not buy depth either.
assert_scale "a lockfile does not inflate the scale" "3 6" \
  GATE_FILES_TSV=$'src/a.ts\t10\t0\npackage-lock.json\t9000\t9000'
# comment_limit is exactly twice depth_scale — the ratio the old constants had
# (10 inline for 5 checks), held rather than re-derived.
for tsv in $'a.ts\t20\t5' $'a.ts\t400\t0' $'a.ts\t5000\t0'; do
  read -r D C <<< "$(scale_of "GATE_FILES_TSV=$tsv" GATE_FORCE_DEEP=true)"
  if [ "$C" = "$(( D * 2 ))" ]; then
    echo "OK:   comment_limit is 2x depth_scale ($D → $C)"
  else
    echo "FAIL: comment_limit $C is not 2x depth_scale $D"; fail=$((fail + 1))
  fi
done
# Short-circuited paths emit no scale at all: nothing downstream runs, and an
# empty step output is what makes post-review.sh fall back to its own default.
assert_scale "skip-review emits no scale" "- -" \
  GATE_FILES_TSV=$'src/a.ts\t10\t0' GATE_LABELS=skip-review
assert_scale "the oversized gate emits no scale" "- -" \
  "GATE_FILES_TSV=$big"
assert_scale "an empty diff emits no scale" "- -" \
  GATE_FILES_TSV=$'package-lock.json\t10\t0'
# Monotonic: more diff never buys less depth. A divisor typo that inverted the
# relation would still pass every single-point assertion above.
prev=0
for n in 10 100 300 600 900 1500 3000; do
  cur=$(scale_of "GATE_FILES_TSV=$(printf 'a.ts\t%d\t0' "$n")" GATE_FORCE_DEEP=true | cut -d" " -f1)
  if [ "$cur" -ge "$prev" ]; then prev=$cur; else
    echo "FAIL: depth_scale fell from $prev to $cur at ${n} lines"; fail=$((fail + 1)); prev=$cur
  fi
done
echo "OK:   depth_scale never decreases as the diff grows (ends at $prev)"

if [ "$fail" -eq 0 ]; then
  echo "All guard tests passed."
  exit 0
else
  echo "$fail guard test assertion(s) failed."
  exit 1
fi
