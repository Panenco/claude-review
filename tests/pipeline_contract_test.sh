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
echo "── human_review is a last resort, not a place to park answerable questions ──"
# v3-vs-v4 head-to-head (6 PRs): v4's biggest weakness was punting questions it
# could have answered into checkboxes — a caller in the same file, a SHA-pinned
# action — while v3 checked them and reported the answer. A checkbox the model
# could have resolved is worse than no checkbox: it looks like diligence.
want "review-scan requires an attempt before emitting a human_review item" "$SCAN" \
  'try to answer it (first|before)'
want "…and scopes what counts as answerable" "$SCAN" \
  'repo at HEAD.*diff.*(on disk|checkout)'
want "…and rejects \"I did not check\" as a blocker" "$SCAN" \
  '"?I did not check"?|unverifiable here'
want "…and names the blockers that ARE legitimate" "$SCAN" \
  'production data.*policy decision.*runtime access'
want "review-verify re-attacks carried human_review items" "$VERIFY" \
  'refute the checkboxes'
# The answerable-scope claim has to name a route the sandbox can actually take.
# c778eba told the model to go read "a pinned dependency the repo already
# references" while --disallowedTools denies WebFetch, WebSearch and `gh api`
# SESSION-WIDE (it cannot be scoped per-subagent), so the only way to obey was to
# drop the item — worse than the checkbox it replaced. The deny list is read out
# of the workflow here so the prompt and the sandbox cannot drift apart again.
DENY=$(sed -n 's/.*--disallowedTools "\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)
if [ -z "$DENY" ]; then
  bad "could not read --disallowedTools out of the workflow"
else
  for t in "WebFetch" "WebSearch" "gh api"; do
    if printf '%s' "$DENY" | grep -qF "$t"; then
      ok "the sandbox still denies $t"
    else
      bad "$t is no longer denied — re-check what review-scan/review-verify claim is answerable"
    fi
  done
fi
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  never "$n does not route the model through a denied tool" "$f" \
    'WebFetch|WebSearch|gh api|curl '
  never "$n does not claim a remote dependency's source is in reach" "$f" \
    'pinned (dependency|action)|third-party (source|action)|upstream source'
done
want "review-scan says nothing outside the checkout is reachable" "$SCAN" \
  'Nothing outside the checkout is reachable, and you must not go fetch it'
want "…so \"not in the checkout\" is a legitimate blocker, not a reason to drop" "$SCAN" \
  'cannot verify from the checkout.{0,40}legitimate blocker'
want "…and it is listed among the real blockers" "$SCAN" \
  'names the real blocker.*not in the checkout'
want "review-verify accepts the same blocker" "$VERIFY" \
  'Nothing outside the checkout is reachable.{0,60}stands as a reason'

# A human_review item raising a risk the repo has already declared an accepted
# trade-off sailed straight through: the suppression pass named findings only.
SUP_LINE=$(grep -n 'suppressed by' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$SUP_LINE" ] && sed -n "${SUP_LINE}p" "$VERIFY" | grep -q 'human_review'; then
  ok "review-verify suppresses human_review items, not just findings, on the rule line itself"
else
  bad "review-verify's suppression rule (line ${SUP_LINE:-?}) must name human_review items too"
fi

# Three of seven noise counts were items whose concern was stated AND handled in
# a comment at the very line cited.
want "review-scan drops an item the cited code already mitigates" "$SCAN" \
  'already documents the risk and mitigates it'

# ...but a drop with no trace is the same failure shape as the bugs above: the
# context builder went out and nothing recorded it; suppression was findings-only
# and nothing recorded that either. Every killed checkbox must be auditable in
# the uploaded verify.json, and must stay OUT of the posted review.
want "review-verify records every dropped human_review item" "$VERIFY" \
  'Every dropped item leaves a trace'
want "…tagged so the two kinds are distinguishable in meta.refuted" "$VERIFY" \
  '"kind": "finding\|human_review"'
want "…carrying what was asked" "$VERIFY" \
  'what_to_check that was asked'
want "…and why it was dropped" "$VERIFY" \
  'suppressed by <file> \| already mitigated'
want "…and refuted stays diagnostics-only" "$VERIFY" \
  'refuted.{0,30}never appear in .{0,10}body.{0,10} or in a comment'
# Structural, not a wording preference: the poster reads meta.findings and
# meta.human_review. If it ever learns to read meta.refuted, diagnostics become
# review prose and the suppression audit trail turns into noise on the PR.
never "post-review.sh never reads meta.refuted into the review" "$POSTER" \
  'meta\.refuted|\.refuted'
# Free-of-charge audit trail: verify.json is uploaded verbatim, so a human can
# read the drops after a run without any new plumbing.
want "the workflow uploads /tmp/verify.json as an artifact" "$WORKFLOW" \
  '^ +/tmp/verify\.json$'
# The judge: the answer an author most wants is whether the fix actually works.
want "review-scan verifies the PR's stated fix holds at HEAD" "$SCAN" \
  'if the PR exists to fix something'
want "review-verify puts that answer in the verdict sentence" "$VERIFY" \
  'if the PR exists to fix something'

echo ""
echo "── a committable suggestion must be checked against tests and callers ──"
# PR98: right diagnosis, and a ```suggestion``` fence whose patch would have
# broken an existing test asserting the opposite behaviour. A wrong sentence is
# argued with; a wrong patch is clicked.
want "review-verify checks suggestions against tests and callers" "$VERIFY" \
  'grep.{0,40}tests and callers|tests and callers that exercise'
want "…and falls back to prose instead of shipping an unconfirmed patch" "$VERIFY" \
  'state the fix in .{0,10}prose'
want "…and says which failure mode is worse" "$VERIFY" \
  'wrong patch is worse than a wrong sentence'

echo ""
echo "── the spec reaches the reviewer: someone fetches it, someone judges it ──"
# v4 deleted review-context-builder and with it every spec read. The orchestrator
# kept writing /tmp/issue.json, but the ONLY readers were the functional-tester
# eligibility check and the tester's prompt — so on every PR where the tester did
# not run (the overwhelming majority) nothing on earth compared the code to what
# the code was supposed to do. Both halves of that seam are asserted here.
want "orchestrator still fetches linked-issue bodies into /tmp/issue.json" "$ORCH" \
  'gh issue view.*>\s*/tmp/issue\.json|/tmp/issue\.json'
want "review-scan reads /tmp/issue.json itself" "$SCAN" \
  '`?Read`? /tmp/issue\.json'
want "…and falls back to acceptance criteria in the PR body" "$SCAN" \
  'acceptance criteria from the PR body|PR body instead'
want "…ignoring bot-generated summaries, which are not a spec" "$SCAN" \
  'bot-generated summary'
# The bar is the whole product. An AC gap is a normal finding, not a new class
# of finding that gets to skip failure_scenario.
want "…and an AC gap still clears the ordinary finding bar" "$SCAN" \
  'ordinary finding at the ordinary bar|still name the input'
# Precise, not fuzzy: the line that enumerates legitimate why_unresolved
# blockers must not list a missing spec among them, now that one is loaded.
if grep -i 'names the real blocker' "$SCAN" | grep -qi 'no spec'; then
  bad "review-scan still lists \"no spec\" as a legitimate why_unresolved blocker"
else
  ok "review-scan does not list \"no spec\" among the legitimate blockers"
fi
want "…and says so once a spec is loaded" "$SCAN" \
  '"no spec" is never a `why_unresolved`'
# v3 had prompt_injection_detected; v4's only surviving defence is the CLI deny
# list, which cannot stop the model from OBEYING text it read.
want "review-scan treats PR/issue prose as untrusted data, not instructions" "$SCAN" \
  'untrusted data, never instructions'

echo ""
echo "── the auth recipe is DELIVERED by whoever promises it ──"
# Three files told the tester its prompt carried a ready-made auth recipe and
# the dev-env quirks list. The orchestrator passed API_URL/WEB_URL/AUTH_READY
# and nothing else, so "do not rediscover auth" left the tester with no auth at
# all. Promise and delivery must both be present, in the same direction.
TESTER="$ROOT/skills/review-functional-tester.md"
TESTER_AGENT="$ROOT/agents/review-functional-tester.md"
[ -f "$TESTER" ] && [ -f "$TESTER_AGENT" ] || { echo "FAIL: functional tester files missing"; exit 1; }
want "the tester is told to use the recipe from its prompt" "$TESTER" \
  'auth recipe from your prompt'
want "…and the agent definition says the prompt carries it" "$TESTER_AGENT" \
  'auth recipe'
want "the orchestrator extracts ### Auth from .github/review-config.md" "$ORCH" \
  'review-config\.md'
want "…including ### Known dev-env quirks, which the tester also expects" "$ORCH" \
  'Known dev-env quirks'
want "…and pastes it into the tester's Task prompt" "$ORCH" \
  'auth-recipe\.md'
want "the tester degrades to untested when no recipe was passed" "$TESTER" \
  'no recipe at all'
want "the tester names review-verify as the consumer of its output" "$TESTER" \
  'read by .review-verify.'

echo ""
echo "── the orphaned external-tracker wiring is gone, not half-gone ──"
# README called fetch-issue.sh "currently unwired" while the workflow still
# exported TRACKER_SECRETS to a step nothing read, and the onboarding prompt
# still walked new consumers through building the hook.
never "the workflow forwards TRACKER_SECRETS to no step" "$WORKFLOW" \
  'TRACKER_SECRETS: \$\{\{'
if grep -qE '^ *TRACKER_SECRETS:' "$WORKFLOW"; then
  # Kept on purpose: deleting a workflow_call SECRET is a hard error for any
  # caller that passes it explicitly, exactly like deleting an input.
  want "…and the surviving workflow_call declaration is marked DEPRECATED" "$WORKFLOW" \
    'DEPRECATED'
else
  ok "workflow declares no TRACKER_SECRETS at all"
fi
never "onboarding no longer tells consumers to create fetch-issue.sh" \
  "$ROOT/prompts/setup-review.md" 'fetch-issue\.sh'
never "onboarding no longer asks for a TRACKER_SECRETS secret" \
  "$ROOT/prompts/setup-review.md" 'TRACKER_SECRETS'

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
