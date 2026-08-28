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
BUILDSPEC="$ROOT/scripts/build-spec.sh"
fail=0

ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
want() { # want <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then ok "$1"; else bad "$1 — no match for /$3/ in ${2#"$ROOT"/}"; fi
}
never() { # never <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then bad "$1 — unexpected match for /$3/ in ${2#"$ROOT"/}"; else ok "$1"; fi
}

for f in "$SCAN" "$VERIFY" "$ORCH" "$POSTER" "$WORKFLOW" "$CMD" "$BUILDSPEC"; do
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
# meta.human_review. It may look at meta.refuted for exactly ONE thing — the ids
# the model consciously dropped, so a refuted carry stops being carried. The
# REASONS stay diagnostics: the moment one reaches the body, the suppression
# audit trail turns into noise on the PR.
BAD_REFUTED=$(grep -nE '\.refuted' "$POSTER" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '\.id')
if [ -z "$BAD_REFUTED" ]; then
  ok "post-review.sh reads meta.refuted only for the ids it must stop carrying"
else
  bad "post-review.sh reads meta.refuted beyond ids: $BAD_REFUTED"
fi
never "…and no refutation reason reaches the review" "$POSTER" \
  'refuted.*reason|reason.*refuted'
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

# ...and the two decisions must stay SEPARATE. PR98 again: review-scan found a
# real bug (require-native-findings.sh self-disabling), review-verify agreed the
# code did what was asserted, then refuted the whole finding with the reason
# "the proposed suggestion would flip that asserted behaviour" — it dropped the
# FINDING where this rule says drop the FENCE. A true-positive loss is the worst
# outcome this reviewer has, so the separation is pinned three ways.
want "…and never refutes a finding over its fix" "$VERIFY" \
  'Refuting a finding because its suggested fix is wrong is an error'
want "…a confirmed defect with no safe patch is still a finding" "$VERIFY" \
  'confirmed defect with no safe patch is still a finding'
want "…and the fence is what gets dropped, never the finding" "$VERIFY" \
  'drop the fence, never the finding'
# The separation has to live INSIDE the refute mandate, not only down in the
# inline-comment section — that distance is what let the refute framing swallow
# it. Anything after "## Repo conventions" is out of that section.
SEP_LINE=$(grep -nE '`fix` is not under test' "$VERIFY" | head -1 | cut -d: -f1)
CONV_LINE=$(grep -n '^## Repo conventions' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$SEP_LINE" ] && [ -n "$CONV_LINE" ] && [ "$SEP_LINE" -lt "$CONV_LINE" ]; then
  ok "the defect/patch split is stated in the refute section itself (line $SEP_LINE)"
else
  bad "review-verify must say the fix is not under test inside the refute section (split=${SEP_LINE:-?} conventions=${CONV_LINE:-?})"
fi
# Structural: no rule anywhere may pair killing a finding with the state of its
# patch, unless it is one of the rules forbidding exactly that.
TIED=$(grep -niE 'refut|drop the finding|drop it' "$VERIFY" \
  | grep -iE 'suggestion|patch|fence|`fix`' | grep -i 'finding' \
  | grep -viE 'is an error|never the finding|not under test|no safe patch is still a finding')
if [ -z "$TIED" ]; then
  ok "no rule in review-verify ties refuting a finding to the quality of its fix"
else
  bad "review-verify ties a refutation to the fix: $TIED"
fi

echo ""
echo "── the severity ladder: drifted prose is not a user-reachable logic bug ──"
# PR99 got REQUEST_CHANGES for documentation drift, against this repo's own bar
# (doc accuracy non-blocking; REQUEST_CHANGES for critical/major defects only).
# `major` was left to inference, so prose inaccuracy kept landing there. The
# exception is real and must survive: this repo executes its skill prompts and
# prompts/setup-review.md, so stale text there can break a consumer.
want "review-scan rates drifted prose minor, not major" "$SCAN" \
  'Inaccurate prose is .{0,3}`?minor`?'
want "…naming why: it is not a user-reachable logic bug" "$SCAN" \
  'not a user-reachable logic bug'
want "…and it never reaches major on its own" "$SCAN" \
  'never reaches .{0,3}`?major`?'
want "…while executable text stays judged by the failure it causes" "$SCAN" \
  'skill prompts, the setup recipe'
never "…so no blanket \"docs are always minor\" rule ships" "$SCAN" \
  'documentation is always minor|docs are always minor|all documentation.{0,20}minor'
# Rule and exception must share a line: split apart, the exception is the half
# that gets deleted, and stale executable text silently becomes minor.
if grep -iE 'Inaccurate prose is' "$SCAN" | grep -qiE 'exception is text this repo'; then
  ok "the prose-is-minor rule carries its executable-asset exception in the same paragraph"
else
  bad "review-scan must state the executable-asset exception alongside the prose-is-minor rule"
fi
want "review-verify re-rates a survivor that overshoots the ladder" "$VERIFY" \
  'Re-rate a survivor whose severity'
want "…before that severity decides the verdict" "$VERIFY" \
  'before it decides the verdict'

echo ""
echo "── the spec reaches the reviewer: ONE file, and the DOCUMENT governs ──"
# v4 deleted review-context-builder and with it every spec read. The first
# repair restored only the linked GitHub issue; the external tracker and in-repo
# spec documents stayed dead, so a team tracking work in Linear got a reviewer
# with no requirements at all. The second repair put the issue on top — but the
# issue holds a SUMMARY and the repo holds the extensive specification, so that
# ordering told the reviewer the thin source outranked the real one.
want "orchestrator's turn 1 runs the spec assembler" "$ORCH" \
  'CLAUDE_REVIEW_SCRIPTS.*build-spec\.sh'
want "…and names /tmp/spec.md as the single spec artifact" "$ORCH" \
  '/tmp/spec\.md'
want "…still writing /tmp/issue.json, which the assembler and the tester read" "$ORCH" \
  '/tmp/issue\.json'
want "…and fetching headRefName, which the tracker-id scan needs" "$ORCH" \
  'headRefName'
want "…and baseRefName, without which the PR's own spec doc cannot be found" "$ORCH" \
  'baseRefName'
want "review-scan reads /tmp/spec.md" "$SCAN" \
  '`?Read`? /tmp/spec\.md'
never "…and is NOT taught the individual spec sources it no longer resolves" "$SCAN" \
  'Read /tmp/issue\.json|/tmp/external-issue\.md|docs/prds'

# Precedence. The in-repo document is the specification; the issue and the
# tracker ticket are summaries of it. spec.md must say which one governs, in its
# headers and in a block at the top, because scan never learns where any of it
# came from and cannot work the authority out for itself.
want "assembly source 1 is the in-repo spec document, marked AUTHORITATIVE" "$BUILDSPEC" \
  'Spec source — in-repo spec document.*AUTHORITATIVE'
want "…whose header says it governs" "$BUILDSPEC" \
  'AUTHORITATIVE — this governs'
want "assembly source 2: the linked GitHub issue, marked a SUMMARY" "$BUILDSPEC" \
  'Spec source — linked GitHub issue.*SUMMARY'
want "assembly source 3: the external tracker hook, also a SUMMARY" "$BUILDSPEC" \
  'Spec source — external tracker.*SUMMARY'
want "…invoked as .github/claude-review/fetch-issue.sh when executable" "$BUILDSPEC" \
  '\.github/claude-review/fetch-issue\.sh'
want "assembly source 4: the PR body, as the fallback" "$BUILDSPEC" \
  'Spec source — the PR body'
want "…and a bot-generated summary is called out as not a spec" "$BUILDSPEC" \
  'bot-generated summary'
want "the file names the source that governs THIS run" "$BUILDSPEC" \
  'GOVERNING SOURCE'
want "…states the precedence rule outright" "$BUILDSPEC" \
  'summary of it and does NOT override it'
want "…and says so when only a summary resolved" "$BUILDSPEC" \
  'No in-repo spec document resolved'
want "an empty spec.md is a normal outcome, not a failure" "$BUILDSPEC" \
  'no spec source resolved'
# Emission order IS the precedence, because the model reads the file top-down.
D=$(grep -n 'Spec source — in-repo spec document' "$BUILDSPEC" | head -1 | cut -d: -f1)
I=$(grep -n 'Spec source — linked GitHub issue' "$BUILDSPEC" | head -1 | cut -d: -f1)
T=$(grep -n 'Spec source — external tracker' "$BUILDSPEC" | head -1 | cut -d: -f1)
if [ -n "$D" ] && [ -n "$I" ] && [ -n "$T" ] && [ "$D" -lt "$I" ] && [ "$I" -lt "$T" ]; then
  ok "the document is emitted before the summaries (doc=$D issue=$I tracker=$T)"
else
  bad "the authoritative document must be emitted first (doc=${D:-?} issue=${I:-?} tracker=${T:-?})"
fi

# Discovery is load-bearing: a document we fail to find means reviewing against
# a summary and never saying so — the silent degradation this seam exists to
# remove. Four routes, in descending order of signal.
want "discovery: markdown added or modified by the PR's own diff" "$BUILDSPEC" \
  'diff --name-only --diff-filter=AM'
want "discovery: a location the repo declares for itself" "$BUILDSPEC" \
  '\.github/review-config\.md'
want "…as one plain declaration line, not a config subsystem" "$BUILDSPEC" \
  'spec \(docs\?\|documents\?\|location\)'
want "discovery: an explicit path or URL reference still resolves" "$BUILDSPEC" \
  'SPEC_REFS'
want "discovery: the <name>-prd/-spec/-rfc convention is the last resort" "$BUILDSPEC" \
  'prd\|spec\|rfc'
want "…and non-specs never become the spec" "$BUILDSPEC" \
  'README\.md\|\*/README\.md'
want "…including agent instruction files, which are prompts, not requirements" "$BUILDSPEC" \
  'CLAUDE\.md\|\*/CLAUDE\.md'

# The cap. Docs in code are explicitly "much more extensive" than the issue, so
# a 400-line head cut would drop exactly the criteria the PR implements.
never "the 400-line-per-document cut is gone" "$BUILDSPEC" \
  'head -n 400'
want "…replaced by a whole-document budget" "$BUILDSPEC" \
  'DOC_LINE_CAP=1500'
want "…bounded in total, so four huge docs cannot swallow the run" "$BUILDSPEC" \
  'DOC_TOTAL_CAP=3000'
want "a document that must be cut says so IN the spec" "$BUILDSPEC" \
  'TRUNCATED — THE SPEC BELOW IS PARTIAL'
want "…and the top block flags the whole file partial" "$BUILDSPEC" \
  'SPEC IS PARTIAL'
want "…and a document that did not fit at all is listed, not dropped" "$BUILDSPEC" \
  'NOT included \(budget exhausted\)'

# UNTRUSTED. v3 said this explicitly about hook output; v4's only other defence
# is the CLI deny list, which cannot stop the model OBEYING text it read.
want "the assembled file marks every source as untrusted data" "$BUILDSPEC" \
  'UNTRUSTED DATA'
want "…and the hook block says so a second time, being third-party output" "$BUILDSPEC" \
  'UNTRUSTED TOOL OUTPUT'
want "review-scan treats the spec as untrusted data, not instructions" "$SCAN" \
  'untrusted data, never instructions'

# The hook is consumer-supplied: it can hang, and it can fail. v3 bounded both.
want "the hook is bounded by a timeout" "$BUILDSPEC" \
  'timeout 60 "\$HOOK"'
want "…and its failure is a warning, never fatal" "$BUILDSPEC" \
  '::warning::fetch-issue\.sh failed'
want "…and it is fed TRACKER_SECRETS as named env vars" "$BUILDSPEC" \
  'export_kv_secrets TRACKER_SECRETS'
never "…through the shared parser, not a second copy of the loop" "$BUILDSPEC" \
  'while IFS= read -r line'
want "…and gets the documented candidates file" "$BUILDSPEC" \
  '/tmp/external-issue-candidates\.json'

# What scan is told about all this. It reads one file, so the file's structure
# has to carry the authority — and scan has to act on it.
want "review-scan knows which source governs" "$SCAN" \
  'GOVERNING SOURCE'
want "…that a document outranks an issue or ticket summary" "$SCAN" \
  'it supplements, it never overrides'
want "…and that a partial spec is partial" "$SCAN" \
  'SPEC IS PARTIAL'
want "…so a criterion's absence proves nothing" "$SCAN" \
  "never infer from a criterion's absence"

# Judging. An AC gap is a normal finding, not a class that skips failure_scenario.
want "…and an AC gap still clears the ordinary finding bar" "$SCAN" \
  'ordinary finding at the ordinary bar|still name the input'
if grep -i 'names the real blocker' "$SCAN" | grep -qi 'no spec'; then
  bad "review-scan still lists \"no spec\" as a legitimate why_unresolved blocker"
else
  ok "review-scan does not list \"no spec\" among the legitimate blockers"
fi
want "…and says so once a spec is loaded" "$SCAN" \
  '"no spec" is never a `why_unresolved`'
echo ""
echo "── out-of-scope work is ONE human_review item, and only against a real spec ──"
# The inverse of AC compliance: not "did it do what was asked" but "did it also
# do things nobody asked for". It has no failure scenario, so it can never be a
# finding. Against a real spec document the question is sharp and safe to put;
# against the PR-body fallback it is circular (the body summarises the diff),
# and against a truncated document the pages we cut may be what asked for it.
want "review-scan raises out-of-scope work at all" "$SCAN" \
  'out-of-scope work|Out-of-scope work'
want "…gated on a governing source that is a document, issue or ticket" "$SCAN" \
  'GOVERNING SOURCE.{0,20}must be an in-repo spec document'
want "…never off the PR-body fallback" "$SCAN" \
  'Never off the PR-body fallback'
want "…never off a partial spec" "$SCAN" \
  'never off a partial spec'
want "…and put more carefully when only a summary governs" "$SCAN" \
  'you are reading a summary'
want "…as a human_review item, never a finding" "$SCAN" \
  'human_review`? item, never a finding'
want "…capped at one per review" "$SCAN" \
  'At most one such item per review'
want "…naming specific files or symbols, not a vague hunch" "$SCAN" \
  'specific files or symbols'
want "…and exempting work incidental to the stated change" "$SCAN" \
  'incidental to delivering the stated change'

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
# The tester plans against the GOVERNING spec source — the document when the repo
# has one, else the linked issue. Planning against a summary while a fuller
# specification sits in the repo is the same silent degradation the assembler
# exists to fix. What it must still never plan against: third-party hook output,
# and a PR body that summarises the very diff it is supposed to be testing.
want "the tester's criteria come from the governing spec source" "$ORCH" \
  'in-repo spec document section of /tmp/spec\.md when one resolved, otherwise the linked issue'
want "…never the tracker hook output, never the PR-body fallback" "$ORCH" \
  'Never the external-tracker section and never the PR-body fallback'
want "…and the tester runs diff-touched criteria first" "$ORCH" \
  'the ones the diff touches first'
want "the tester still refuses to invent a plan with no criteria" "$TESTER" \
  'Do not invent scenarios'
want "…and reports what it never reached instead of implying completeness" "$TESTER" \
  'list every criterion you never reached'

echo ""
echo "── the external tracker is wired end to end, not half-wired ──"
# It has now failed in both directions: v3 shipped a README section for a hook
# whose secret nothing forwarded, and v4 deleted the forwarding while keeping
# the contract. Secret → step → parser → hook → spec.md, every link asserted.
want "the workflow forwards TRACKER_SECRETS to the orchestrate step" "$WORKFLOW" \
  'TRACKER_SECRETS: \$\{\{ secrets\.TRACKER_SECRETS \}\}'
want "…and the workflow_call secret is declared" "$WORKFLOW" \
  '^ *TRACKER_SECRETS:'
if grep -A6 '^ *TRACKER_SECRETS:' "$WORKFLOW" | grep -qi 'DEPRECATED'; then
  bad "the TRACKER_SECRETS declaration is still marked DEPRECATED, but it is live again"
else
  ok "…no longer marked DEPRECATED"
fi
want "the workflow verifies build-spec.sh installed" "$WORKFLOW" \
  'build-spec\.sh'
want "action.yml verifies it too, plus the shared parser" "$ROOT/action.yml" \
  'build-spec\.sh kv-secrets\.sh'
want "onboarding walks consumers through fetch-issue.sh again" \
  "$ROOT/prompts/setup-review.md" 'fetch-issue\.sh'
want "…and through the TRACKER_SECRETS repo secret it needs" \
  "$ROOT/prompts/setup-review.md" 'TRACKER_SECRETS'
never "the README no longer calls the hook REMOVED" "$ROOT/README.md" \
  'fetch-issue\.sh.*REMOVED|Never run'
want "…and documents the candidates-file schema the hook reads" "$ROOT/README.md" \
  'external-issue-candidates\.json'

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
echo "── the round-2 carry-over crosses four files ──"
# The defect: post-review.sh gives criticals and majors the inline slots and then
# deletes their bullets from the body, and the truncator deletes the overflow.
# The body was the only surface round 2 read, so the findings it could not see
# were exactly the worst ones. Carrying them is allowed; PINNING the verdict to
# them is the thing v4 deleted and must never come back.
PF="$ROOT/scripts/prior-findings.sh"
[ -f "$PF" ] || { echo "FAIL: scripts/prior-findings.sh not found"; exit 1; }

want "review-scan reads the consolidated carry-over file" "$SCAN" \
  '`?Read`? /tmp/prior-findings\.md'
never "…and no longer treats a fixed finding as something to say nothing about" "$SCAN" \
  'say nothing at all about the fixed ones'
want "…every carried finding lands in one of two buckets" "$SCAN" \
  'Silence is not a bucket'
want "…the fixed ones named, with evidence" "$SCAN" \
  'resolved_prior'
want "…and \"looks fixed\" is not evidence" "$SCAN" \
  'evidence.{0,40}names the change that closed it|Looks fixed'
want "…uncertainty keeps a carried finding alive" "$SCAN" \
  'If you cannot tell, it is unresolved'
want "…and a re-worded carry keeps its id" "$SCAN" \
  'carried_from'

want "review-verify states the flipped default for carried findings" "$VERIFY" \
  'already survived.*refutation|KEPT when you are uncertain'
want "…and demands a written reason to refute one" "$VERIFY" \
  'meta\.refuted'
# THE PIN. Making a finding VISIBLE is the fix; making a verdict STICK is the bug
# that produced twelve rounds of flip-flop. Both halves must stay on the page.
want "review-verify still forbids the ladder, the ratchet and the pinning" "$VERIFY" \
  'no ladder, no ratchet and no pinning'
want "…and says outright that carrying is not pinning" "$VERIFY" \
  'Carrying a finding is not pinning a verdict'
# Case-sensitive and comment-free on purpose: the prose in section 5 explains why
# a skip-marked post must not dismiss, and mentions `prior_verdict` doing so. What
# must never exist is the poster READING one.
if grep -nE 'PRIOR_VERDICT' "$POSTER" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  bad "post-review.sh reads PRIOR_VERDICT — the verdict is recomputed every round"
else
  ok "post-review.sh takes no verdict input from the prior round"
fi
never "dismissal is not gated on carried findings" "$POSTER" \
  'STALE_IDS.*carried|carried.*STALE_IDS'

# The state block must be appended AFTER the footer, i.e. after truncation and
# after link expansion — otherwise the budget can evict the carry-over, which is
# the exact failure it exists to prevent.
FOOTER_LINE=$(grep -n "printf '%s' \"\$FOOTER\" >> \"\$WORK/body.md\"" "$POSTER" | head -1 | cut -d: -f1)
STATE_LINE=$(grep -n "claude-review-state" "$POSTER" | tail -1 | cut -d: -f1)
if [ -n "$FOOTER_LINE" ] && [ -n "$STATE_LINE" ] && [ "$STATE_LINE" -gt "$FOOTER_LINE" ]; then
  ok "the state block is written after the footer (footer=$FOOTER_LINE state=$STATE_LINE)"
else
  bad "the state block must be appended after the footer (footer=${FOOTER_LINE:-?} state=${STATE_LINE:-?})"
fi

# One identity, two scripts. A drift here means the poster and the consolidator
# disagree about what "the same finding" is, and every carry becomes a duplicate.
NORM_POSTER=$(grep -n '^JQ_NORM=' "$POSTER" | head -1 | cut -d: -f2-)
NORM_PF=$(grep -n '^JQ_NORM=' "$PF" | head -1 | cut -d: -f2-)
if [ -n "$NORM_POSTER" ] && [ "$NORM_POSTER" = "$NORM_PF" ]; then
  ok "post-review.sh and prior-findings.sh share the finding identity byte for byte"
else
  bad "the JQ_NORM definitions have drifted between post-review.sh and prior-findings.sh"
fi

want "pr-review.yml verifies prior-findings.sh installed" "$WORKFLOW" \
  'prior-findings\.sh'
want "action.yml verifies it too" "$ROOT/action.yml" \
  'prior-findings\.sh'
want "prior-findings.sh reads the JUDGED review list" "$PF" \
  'prior-reviews\.json'
never "…and never the standing list, which includes reviews that judged nothing" "$PF" \
  'bot-reviews\.json'

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
