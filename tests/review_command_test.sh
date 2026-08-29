#!/usr/bin/env bash
set -uo pipefail

# review_command_test.sh — fixture test for scripts/review-command.sh.
#
# A comment body → a run decision, asserted as
# "<action> <run_functional> <force_deep>".
# action: run | help | unknown | ignore

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/review-command.sh"
fail=0

# decision_of KEY=VAL... → "<action> <run_functional> <force_deep>"
decision_of() {
  env "$@" bash "$SCRIPT" | awk -F= '
    /^action=/        {a=$2}
    /^run_functional=/{f=$2}
    /^force_deep=/    {d=$2}
    END {print a, f, d}'
}
passes_of() { env "$@" bash "$SCRIPT" | sed -n 's/^passes=//p'; }
message_of() { env "$@" bash "$SCRIPT" | sed -n 's/^message=//p'; }

assert_cmd() {
  local label="$1" want="$2"; shift 2
  local got; got=$(decision_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}
assert_passes() {
  local label="$1" want="$2"; shift 2
  local got; got=$(passes_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label passes → '$got'"
  else
    echo "FAIL: $label passes — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

# ── Bare command prints the menu rather than guessing which pass was meant. ──
assert_cmd "bare /review"        "help false false" CMD_BODY="/review"
assert_cmd "explicit help"       "help false false" CMD_BODY="/review help"
assert_cmd "question mark"       "help false false" CMD_BODY="/review ?"

# ── The two passes, alone and combined. `code` is implicit everywhere. ──
assert_cmd "code"                "run false false"  CMD_BODY="/review code"
assert_cmd "functional"          "run true false"   CMD_BODY="/review functional"
assert_cmd "all"                 "run true false"   CMD_BODY="/review all"
assert_cmd "code + functional"   "run true false"   CMD_BODY="/review code functional"
assert_cmd "every token spelled" "run true true"    CMD_BODY="/review code functional native deep"

assert_passes "functional implies code" "code functional" CMD_BODY="/review functional"
assert_passes "no duplicate code"       "code functional" CMD_BODY="/review code functional"
assert_passes "all expands"             "code functional" CMD_BODY="/review all"
assert_passes "deep is a modifier"      "code deep"       CMD_BODY="/review deep"

# ── `deep` lifts guard.sh's oversized ceiling for THIS run (GATE_FORCE_DEEP).
#    It is a modifier, not a pass: it never implies the browser tester, and it
#    composes with the passes in the same comment. ──
assert_cmd "deep alone"          "run false true"   CMD_BODY="/review deep"
assert_cmd "deep + functional"   "run true true"    CMD_BODY="/review deep functional"
assert_cmd "code + deep"         "run false true"   CMD_BODY="/review code deep"
assert_cmd "all + deep"          "run true true"    CMD_BODY="/review all deep"
assert_cmd "full deep (aliases)" "run false true"   CMD_BODY="/review full deep"
assert_passes "code + deep"         "code deep"            CMD_BODY="/review code deep"
assert_passes "deep + functional"   "code deep functional" CMD_BODY="/review deep functional"
assert_passes "functional + deep"   "code functional deep" CMD_BODY="/review functional deep"
assert_passes "full and deep dedupe" "code deep"           CMD_BODY="/review full deep"

# The menu is the only place most people learn this exists, and the label/comment
# split is the part that is NOT guessable — a comment covers the run it starts,
# the label survives every push.
HELP=$(message_of CMD_BODY="/review")
for needle in '`deep`' 'deep-review' 'size ceiling'; do
  case "$HELP" in
    *"$needle"*) echo "OK:   help menu mentions $needle" ;;
    *) echo "FAIL: help menu never mentions $needle"; fail=$((fail + 1)) ;;
  esac
done
case "$HELP" in
  *'`deep` are accepted but do nothing'*|*'`deep` is accepted but does nothing'*)
    echo "FAIL: help menu still calls deep inert"; fail=$((fail + 1)) ;;
  *) echo "OK:   help menu no longer calls deep inert" ;;
esac

# ── The `native` pass is DELETED (ADR 0003). The token must still parse — a
#    reviewer who types the documented old command deserves a review, not the
#    unknown-option menu — but it must run nothing extra and say so. ──
assert_cmd "native is a no-op"        "run false false" CMD_BODY="/review native"
assert_cmd "alias plugin is a no-op"  "run false false" CMD_BODY="/review plugin"
assert_passes "native adds no pass"   "code"            CMD_BODY="/review native"
assert_passes "all no longer expands to native" "code functional" CMD_BODY="/review all"
if message_of CMD_BODY="/review native" | grep -q 'has been removed'; then
  echo "OK:   native says the pass was removed"
else
  echo "FAIL: /review native runs silently — it must say the pass was removed"
  fail=$((fail + 1))
fi
# Structural: nothing may re-grow a native_review output the workflow would read.
if CMD_BODY="/review native" bash "$SCRIPT" | grep -q '^native_review='; then
  echo "FAIL: review-command.sh still emits native_review — the pass is gone"
  fail=$((fail + 1))
else
  echo "OK:   no native_review key is emitted"
fi

# ── Aliases and sloppy typing — this is typed by hand in a PR comment. ──
assert_cmd "alias browser"       "run true false"   CMD_BODY="/review browser"
assert_cmd "alias e2e"           "run true false"   CMD_BODY="/review e2e"
assert_cmd "alias anthropic"     "run false false"  CMD_BODY="/review anthropic"
assert_cmd "alias judges"        "run false false"  CMD_BODY="/review judges"
assert_cmd "alias full=deep"     "run false true"   CMD_BODY="/review full"
assert_cmd "uppercase"           "run true false"   CMD_BODY="/review ALL"
assert_cmd "comma + period"      "run true false"   CMD_BODY="/review functional, native."
assert_cmd "backticked token"    "run true false"   CMD_BODY='/review `functional`'
assert_cmd "extra whitespace"    "run true false"   CMD_BODY="/review   functional  "
assert_cmd "leading whitespace"  "run false false"  CMD_BODY="   /review code"

# ── First line only, body must START with the trigger. Without both anchors a
#    comment quoting the docs would trigger real runs. ──
assert_cmd "trailing prose"      "run true false"   CMD_BODY=$'/review functional\n\nplease check the modal'
assert_cmd "trigger mid-sentence" "ignore false false" CMD_BODY="you can run /review all on this"
assert_cmd "trigger on line 2"   "ignore false false" CMD_BODY=$'looks good\n/review all'
assert_cmd "quoted in a codeblock" "ignore false false" CMD_BODY=$'```\n/review all\n```'
assert_cmd "unrelated comment"   "ignore false false" CMD_BODY="LGTM, merging"
assert_cmd "empty body"          "ignore false false" CMD_BODY=""
assert_cmd "CRLF line ending"    "run false false"  CMD_BODY=$'/review code\r\nnice'
assert_cmd "prefix is not a match" "ignore false false" CMD_BODY="/reviewer code"

# ── An unknown option shows the menu; it never degrades into a different review. ──
assert_cmd "unknown token"       "unknown false false" CMD_BODY="/review deploy"
assert_cmd "unknown wins early"  "unknown false false" CMD_BODY="/review functional deploy"

# ── Manual dispatch: the click is the opt-in, and a menu posted to nobody would
#    be a dead end. ──
assert_cmd "dispatch, no command" "run false false" CMD_EVENT=workflow_dispatch CMD_BODY=""
assert_cmd "dispatch, with command" "run true false" CMD_EVENT=workflow_dispatch CMD_BODY="/review all"

# ── A custom trigger must be honoured in the help text too, not just the match. ──
assert_cmd "custom trigger"      "run true false"  CMD_TRIGGER="/claude" CMD_BODY="/claude functional"
assert_cmd "custom trigger, default ignored" "ignore false false" CMD_TRIGGER="/claude" CMD_BODY="/review functional"
if message_of CMD_TRIGGER="/claude" CMD_BODY="/claude" | grep -q '`/claude code`'; then
  echo "OK:   help text quotes the custom trigger"
else
  echo "FAIL: help text still advertises the default trigger"
  fail=$((fail + 1))
fi

# ── A newline in a message would truncate $GITHUB_OUTPUT and corrupt every key
#    after it. ──
for body in "/review" "/review deploy" "/review help"; do
  lines=$(CMD_BODY="$body" bash "$SCRIPT" | wc -l | tr -d ' ')
  if [ "$lines" = "5" ]; then
    echo "OK:   '$body' emits 5 single-line keys"
  else
    echo "FAIL: '$body' emitted $lines lines — a multi-line value breaks \$GITHUB_OUTPUT"
    fail=$((fail + 1))
  fi
done

# ── LOOP PROTECTION. The menu is posted as a PR comment, which fires
#    issue_comment again. The workflow ignores bot comments; this is the second
#    lock — the reply text itself can never re-trigger. ──
for body in "/review" "/review deploy" "/review help" "/review native"; do
  reply=$(message_of CMD_BODY="$body")
  echoed=$(CMD_BODY="$reply" bash "$SCRIPT" | sed -n 's/^action=//p')
  if [ "$echoed" = "ignore" ]; then
    echo "OK:   the reply to '$body' does not parse as a command"
  else
    echo "FAIL: the reply to '$body' parses as '$echoed' — posting it would loop"
    fail=$((fail + 1))
  fi
done

# ── The parser is NOT the authorization gate. A script that accepted an actor
#    input would invite the check to migrate here — after a runner is claimed. ──
if grep -qiE 'CMD_(ACTOR|ASSOCIATION|AUTHOR|PERMISSION)' "$SCRIPT"; then
  echo "FAIL: review-command.sh reads an actor/permission input — authorization belongs at the job's if:, before a runner is claimed"
  fail=$((fail + 1))
else
  echo "OK:   parser takes no actor input (authorization stays at the job gate)"
fi

echo
echo "── wiring: the trigger and its authorization gate ──"

# The parser can be perfect and the pipeline still be wrong: an on-demand trigger
# is only as safe as the lines deciding who may pull it.
WF="$ROOT/.github/workflows/pr-review.yml"
CALLER="$ROOT/.github/workflows/claude-review.yml"

assert_wiring() {
  local label="$1" cond="$2"
  if [ "$cond" = "yes" ]; then
    echo "OK:   $label"
  else
    echo "FAIL: $label"
    fail=$((fail + 1))
  fi
}

# THE security boundary — on a public repo, commenting is open to everyone.
ASSOC_LINE=$(grep -F 'github.event.comment.author_association' "$WF")
assert_wiring "review job gates on author_association" \
  "$(printf '%s' "$ASSOC_LINE" | grep -Fq 'contains(fromJSON(' && echo yes || echo no)"
assert_wiring "gate allows exactly OWNER, MEMBER and COLLABORATOR" \
  "$(printf '%s' "$ASSOC_LINE" | grep -Fq '["OWNER","MEMBER","COLLABORATOR"]' && echo yes || echo no)"

# CONTRIBUTOR means "has had a PR merged", not write access. Assert on the gate
# LINE, not the file — the surrounding comment mentions it by name.
assert_wiring "CONTRIBUTOR is not treated as write access" \
  "$(printf '%s' "$ASSOC_LINE" | grep -Fq 'CONTRIBUTOR' && echo no || echo yes)"

# A leftover `pull_request` trigger would restore the behaviour this replaces.
assert_wiring "caller does not trigger reviews on pull_request" \
  "$(grep -qE '^  pull_request:' "$CALLER" && echo no || echo yes)"
assert_wiring "caller triggers on issue_comment" \
  "$(grep -qE '^  issue_comment:' "$CALLER" && echo yes || echo no)"

# A reusable workflow sees the CALLER's event — the reason consumers need no
# `with:` wiring. As a forwarded input, anyone who missed it would get silence.
assert_wiring "workflow reads the comment body off the caller event" \
  "$(grep -q 'CMD_BODY: ${{ github.event.comment.body || inputs.command }}' "$WF" && echo yes || echo no)"

# An issue_comment payload has no `pull_request` object, so a leftover reference
# resolves to empty and the run dies on every comment.
assert_wiring "no step reads github.event.pull_request" \
  "$(grep -q 'github.event.pull_request' "$WF" && echo no || echo yes)"

# `deep` is parsed here but ENFORCED in guard.sh. Without this env line the token
# parses, logs, and changes nothing — exactly the inert state this replaced.
assert_wiring "the guard reads force_deep as GATE_FORCE_DEEP" \
  "$(grep -q 'GATE_FORCE_DEEP: ${{ steps.cmd.outputs.force_deep }}' "$WF" && echo yes || echo no)"

# A step still on the plan's advisory flag would install a browser and boot a
# dev-env for a comment that never asked for one.
assert_wiring "functional infra gates on the resolved functional flag" \
  "$(grep -q "steps.review_plan.outputs.run_functional == 'true'" "$WF" && echo no || echo yes)"

# Both replies must speak as the review App, not github-actions[bot] — and the
# identity must be resolved BEFORE them, or they silently fall back to the
# default token (seen live: the menu posted as github-actions[bot]).
ID_LINE=$(grep -n '\- name: Resolve review identity' "$WF" | cut -d: -f1)
for step in 'Acknowledge the request' 'Reply with the command menu'; do
  step_line=$(grep -n "\- name: $step" "$WF" | cut -d: -f1)
  token=$(sed -n "${step_line},$((step_line + 12))p" "$WF" | grep -c 'GH_TOKEN: ${{ steps.review_identity.outputs.token }}')
  assert_wiring "'$step' posts as the review identity" \
    "$([ "$token" = "1" ] && echo yes || echo no)"
  assert_wiring "'$step' comes after the identity is resolved" \
    "$([ "$step_line" -gt "$ID_LINE" ] && echo yes || echo no)"
done

if [ "$fail" -eq 0 ]; then
  echo "All review-command tests passed."
else
  echo "$fail review-command test(s) failed."
  exit 1
fi
