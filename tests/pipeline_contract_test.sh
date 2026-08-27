#!/usr/bin/env bash
set -uo pipefail

# pipeline_contract_test.sh — the parts of the v4 pipeline that live ACROSS
# files, where each file is individually correct and the seam between them is
# not. Nothing here runs a model; every assertion is about a contract two
# artifacts have to agree on.
#
# It exists because three shipped bugs were exactly this shape:
#   * review-scan was told to read /tmp/functional.json, which the orchestrator
#     dispatches in the SAME response — so it never existed when scan looked,
#     and nothing else ever read it. A reproduced FAIL surfaced nowhere.
#   * review-verify tells the model to count `{{LINK:path:line}}` as `path:line`
#     while post-review.sh measured the EXPANDED text, silently truncating away
#     whole findings from a body that was within budget as written.
#   * review-command.sh renders the `native` removal notice on a run that
#     proceeds, and the only step that posted `message` was gated on the run NOT
#     proceeding, so the notice was unreachable.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$ROOT/skills/review-scan.md"
VERIFY="$ROOT/skills/review-verify.md"
ORCH="$ROOT/skills/review-orchestrator.md"
POSTER="$ROOT/scripts/post-review.sh"
WORKFLOW="$ROOT/.github/workflows/pr-review.yml"
CMD="$ROOT/scripts/review-command.sh"
fail=0

ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
want() { # want <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then ok "$1"; else bad "$1 — no match for /$3/ in ${2#"$ROOT"/}"; fi
}
never() { # never <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then bad "$1 — unexpected match for /$3/ in ${2#"$ROOT"/}"; else ok "$1"; fi
}

for f in "$SCAN" "$VERIFY" "$ORCH" "$POSTER" "$WORKFLOW" "$CMD"; do
  [ -f "$f" ] || { echo "FAIL: $f not found"; exit 1; }
done

echo "── functional results reach the review through review-verify ──"
# The orchestrator issues both Task calls in one response on purpose (the
# wall-clock win is real), which is precisely why scan cannot be the consumer.
want "orchestrator still dispatches scan + tester in ONE response" "$ORCH" \
  'both Task calls together|same response'
want "orchestrator hands functional.json to verify" "$ORCH" \
  'review-verify\.md.*functional\.json|functional\.json.*verify'
never "review-scan is not told to read /tmp/functional.json" "$SCAN" \
  '`?Read`? (it|/tmp/functional\.json)|functional\.json`? exists'
# Belt and braces: no line that mentions the file may also carry a Read.
if grep 'functional\.json' "$SCAN" | grep -qiE '\bread\b'; then
  bad "review-scan mentions functional.json on a line that also says 'read'"
else
  ok "no line in review-scan pairs functional.json with a read"
fi
want "review-scan says why the file is not its to read" "$SCAN" \
  'functional\.json`? does not exist|NOT yours to read'
want "review-verify reads /tmp/functional.json" "$VERIFY" \
  '/tmp/functional\.json'
want "review-verify keeps the never-invent rule" "$VERIFY" \
  'Never invent a new finding'
want "…and states the exception explicitly" "$VERIFY" \
  'exception'
want "…scoped to a REPRODUCED failure" "$VERIFY" \
  'reproduced'
want "…with the fallback to a human_review item" "$VERIFY" \
  'human_review.*item|one `human_review`'
want "…and the tester still cannot move the verdict" "$VERIFY" \
  'never.*lowers the verdict|neither raise nor lower'

echo ""
echo "── the body budget the model is told matches the one enforced ──"
want "review-verify tells the model to count {{LINK:path:line}} as path:line" "$VERIFY" \
  'Count .*\{\{LINK:path:line\}\}.* as .*path:line'
want "post-review.sh measures the body PRE-expansion" "$POSTER" \
  'PRE-EXPANSION|pre-expansion'
want "post-review.sh subtracts exactly the 9-byte placeholder wrapper" "$POSTER" \
  'length\(s\) - 9 \* nph\(s\)'
want "post-review.sh truncates before it expands" "$POSTER" \
  'budget\.awk.*body\.raw|mode=fit'
# The order is the whole fix: expansion must be the LAST thing that touches the
# body, so it can never be what pushes a finding out of the review.
TRUNC_LINE=$(grep -n 'mode=fit' "$POSTER" | head -1 | cut -d: -f1)
EXPAND_LINE=$(grep -n 'render_link "\${BASH_REMATCH\[1\]}"' "$POSTER" | head -1 | cut -d: -f1)
if [ -n "$TRUNC_LINE" ] && [ -n "$EXPAND_LINE" ] && [ "$TRUNC_LINE" -lt "$EXPAND_LINE" ]; then
  ok "truncation (line $TRUNC_LINE) runs before link expansion (line $EXPAND_LINE)"
else
  bad "link expansion must come AFTER truncation (trunc=$TRUNC_LINE expand=$EXPAND_LINE)"
fi

echo ""
echo "── nothing that cannot be posted inline is silently discarded ──"
want "post-review.sh renders a body bullet for dropped comments" "$POSTER" \
  'Also flagged'
never "no code comment still claims the body already names every finding" "$POSTER" \
  'body already names every finding|remain listed in the review body'

echo ""
echo "── an explicit /review is never answered with silence ──"
want "guard.sh honours GATE_HUMAN_REQUESTED" "$ROOT/scripts/guard.sh" \
  'GATE_HUMAN_REQUESTED'
want "the workflow sets it from the triggering event" "$WORKFLOW" \
  'GATE_HUMAN_REQUESTED:.*issue_comment'

echo ""
echo "── a message on a PROCEEDING run is actually posted ──"
# review-command.sh emits `message` on action=run for the removed `native` pass.
NATIVE_MSG=$(CMD_BODY="/review native" bash "$CMD" | sed -n 's/^message=//p')
PLAIN_MSG=$(CMD_BODY="/review code" bash "$CMD" | sed -n 's/^message=//p')
if [ -n "$NATIVE_MSG" ]; then ok "/review native still renders a notice"; else bad "/review native renders no notice"; fi
if [ -z "$PLAIN_MSG" ]; then ok "/review code renders none (so the poster step cannot fire spuriously)"; else bad "/review code rendered a message: '$PLAIN_MSG'"; fi
want "the workflow posts a message on a run that proceeds" "$WORKFLOW" \
  "proceed == 'true' && steps\.cmd\.outputs\.message != ''"

echo ""
echo "── repo conventions reach BOTH stages, and cannot escalate a verdict ──"
# v4 dropped the v3 judge's config read, so every consumer repo's hand-written
# "Do not flag" entries went silently unread fleet-wide and the reviewer
# re-raised trade-offs the team had already accepted. Both stages must read the
# two files, suppression must be stated in both, and the convention class must
# stay capped, minor, and unable to reach REQUEST_CHANGES.
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  want "$n names .github/review-config.md" "$f" '\.github/review-config\.md'
  want "$n names bugbot.md" "$f" '`?bugbot\.md`?'
  want "$n reads each config only when present" "$f" 'only if they exist'
  want "$n forbids globbing for other config files" "$f" 'do not glob|no globbing'
  want "$n carries the suppression rule" "$f" 'accepted trade-off'
  want "$n puts suppression first" "$f" 'comes first'
  want "$n caps convention findings at 2" "$f" '(max|most) \*{0,2}2\*{0,2}( per review)?'
  want "$n keeps convention findings minor" "$f" 'severity.{0,3} to .{0,2}minor|severity: .{0,2}minor'
  want "$n requires the rule quoted verbatim as evidence" "$f" 'evidence.*verbatim|verbatim.*config file'
  want "$n exposes the convention flag in its schema" "$f" '"convention":'
  want "$n does not weaken the ordinary bar" "$f" \
    'ordinary finding bar is unchanged|Ordinary findings keep the full `failure_scenario` bar'
done
# The verdict rule is the one that must name the exclusion, not just imply it.
RC_LINE=$(grep -n 'REQUEST_CHANGES\*\*' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$RC_LINE" ] && sed -n "${RC_LINE}p" "$VERIFY" | grep -qiE 'not a convention finding|convention.*NEVER produce'; then
  ok "review-verify's REQUEST_CHANGES rule excludes convention findings on the rule line itself"
else
  bad "review-verify's REQUEST_CHANGES rule must exclude convention findings on line $RC_LINE"
fi
want "…and says so unambiguously" "$VERIFY" 'can NEVER produce REQUEST_CHANGES'
# Cost guard: the whole point is TWO Reads, not a config subsystem. Each file
# may name each config path exactly once — a second mention is a second read
# site, which is how "read the config" grows back into one.
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  for p in 'review-config\.md' 'bugbot\.md'; do
    c=$(grep -cE "$p" "$f")
    if [ "$c" -eq 1 ]; then
      ok "$n names ${p%%\\*} exactly once (one Read, not a config subsystem)"
    else
      bad "$n names ${p%%\\*} $c times — each config path gets exactly one read site"
    fi
  done
done

echo ""
echo "── this repo's own review-config is not v3-stale ──"
# It is a config file the reviewer now actually reads and acts on, so stale
# claims in it become wrong instructions to the model.
CFG="$ROOT/.github/review-config.md"
never "review-config does not name the deleted core/sweep reviewers" "$CFG" \
  'core \(Opus\)|sweep \(Sonnet\)|[Cc]ore.{0,5}and sweep reviewers'
never "review-config does not name the deleted validate step" "$CFG" \
  'Validate review config'
never "review-config does not name deleted v3 artifacts" "$CFG" \
  'build-review\.sh|core-meta\.json'
want "…it names the v4 stages instead" "$CFG" 'review-scan.*review-verify'

echo ""
echo "── no stale references to deleted assets ──"
never "require-review-json.sh does not name v3 artifacts" "$ROOT/scripts/require-review-json.sh" \
  'judge-\*\.json|functional-\*\.json'
want "…it names the v4 ones" "$ROOT/scripts/require-review-json.sh" \
  '/tmp/scan\.json .*/tmp/verify\.json .*/tmp/functional\.json'
never "the onboarding prompt does not install a deleted subagent" \
  "$ROOT/prompts/setup-review.md" 'agents/review-native\.md'
for a in review-scan review-verify review-functional-tester; do
  if grep -q "agents/$a.md" "$ROOT/prompts/setup-review.md" && [ -f "$ROOT/agents/$a.md" ]; then
    ok "onboarding names agents/$a.md, and it exists"
  else
    bad "onboarding must name agents/$a.md, and the file must exist"
  fi
done

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All pipeline contract tests passed."
  exit 0
else
  echo "$fail pipeline contract test(s) failed."
  exit 1
fi
