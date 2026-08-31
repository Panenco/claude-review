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
#   * review-command.sh rendered the `native` removal notice on a run that
#     proceeds, and the only step that posted `message` was gated on the run NOT
#     proceeding, so the notice was unreachable. (That notice is gone — ADR 0005
#     turned the pass back on — but the CHANNEL is still asserted below.)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$ROOT/skills/review-scan.md"
VERIFY="$ROOT/skills/review-verify.md"
ORCH="$ROOT/skills/review-orchestrator.md"
POSTER="$ROOT/scripts/post-review.sh"
WORKFLOW="$ROOT/.github/workflows/pr-review.yml"
CMD="$ROOT/scripts/review-command.sh"
BUILDSPEC="$ROOT/scripts/build-spec.sh"
GUARD="$ROOT/scripts/guard.sh"
TESTER="$ROOT/skills/review-functional-tester.md"
VALIDATOR="$ROOT/scripts/validate-screenshots.sh"
fail=0

ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }
want() { # want <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then ok "$1"; else bad "$1 — no match for /$3/ in ${2#"$ROOT"/}"; fi
}
never() { # never <label> <file> <extended-regex>
  if grep -qiE "$3" "$2"; then bad "$1 — unexpected match for /$3/ in ${2#"$ROOT"/}"; else ok "$1"; fi
}

for f in "$SCAN" "$VERIFY" "$ORCH" "$POSTER" "$WORKFLOW" "$CMD" "$BUILDSPEC" "$GUARD" "$TESTER" "$VALIDATOR"; do
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
want "…and an unplaceable observation is not parked as a check" "$VERIFY" \
  'not a parking space for an observation you could not place'
# ...but it is the highest-evidence signal the pipeline produces, so it cannot be
# dropped silently either: this file's own rule is that every drop leaves a trace,
# and "the tester saw nothing" must stay distinguishable from "the tester
# reproduced a failure and verify could not place it".
want "…and never dropped silently — it lands in meta.refuted" "$VERIFY" \
  'never dropped silently'
want "…under a kind of its own" "$VERIFY" \
  '"kind": "functional"'
want "…declared in the verify.json schema" "$VERIFY" \
  'screenshot\|functional'
want "…while still moving the verdict in neither direction" "$VERIFY" \
  'moves the verdict in neither direction'
want "…and the tester still cannot move the verdict" "$VERIFY" \
  'never.*lowers the verdict|neither raise nor lower'

echo ""
echo "── only review-verify may look at a screenshot, and only through the validator ──"
# A truncated PNG returns `400 Could not process image`, which ends the reading
# turn BEFORE any output file is written. That is a total loss, not a lost
# image, which is why the ban was blanket. It is now narrow instead of gone, and
# every half of the replacement has to still be there.
want "review-verify names the validator" "$VERIFY" \
  'validate-screenshots\.sh'
want "…and treats its output file as the whitelist" "$VERIFY" \
  '/tmp/screenshots\.ok'
want "…and still names the 400 it is engineering around" "$VERIFY" \
  '400 Could not process image'
want "…and forbids a path the validator did not list" "$VERIFY" \
  'not in `?/tmp/screenshots\.ok`? byte for byte is forbidden|is forbidden'
want "…and stops reading images if a 400 arrives anyway" "$VERIFY" \
  'stop looking at images'
# The belt-and-braces half: the review is on disk before any image is opened, so
# a lost turn degrades to a text-only review instead of no review at all.
want "review-verify writes a complete verify.json BEFORE any image" "$VERIFY" \
  'BEFORE you open a single image'
want "…and says it must be postable, not a stub" "$VERIFY" \
  'Not a stub'
PROV_LINE=$(grep -n 'BEFORE you open a single image' "$VERIFY" | head -1 | cut -d: -f1)
VAL_LINE=$(grep -n 'validate-screenshots\.sh' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$PROV_LINE" ] && [ -n "$VAL_LINE" ] && [ "$PROV_LINE" -lt "$VAL_LINE" ]; then
  ok "the write-first rule (line $PROV_LINE) precedes the validator call (line $VAL_LINE)"
else
  bad "review-verify must tell the model to write verify.json BEFORE it runs the validator (write=$PROV_LINE validator=$VAL_LINE)"
fi
# Vision is not a licence to invent. The changed-line gate is what keeps a
# picture from becoming a finding on its own.
want "review-verify still requires a changed line for anything promoted" "$VERIFY" \
  'tie to a changed line|point at the changed line'
want "…and says a picture alone is never a finding" "$VERIFY" \
  'never licence to file a finding|never grounds for a new finding'

# The tester keeps the ABSOLUTE ban: it runs against a wall clock with no
# provisional output to fall back on.
want "the functional tester still bans every screenshot Read" "$TESTER" \
  'Never `Read` anything under `/tmp/screenshots/`'
want "…and says why the exception is not its to borrow" "$TESTER" \
  'no such fallback|racing a wall clock'
want "the orchestrator still bans it for itself" "$ORCH" \
  'never `Read` a file under `/tmp/screenshots/`'
want "…and points the exception at review-verify only" "$ORCH" \
  'review-verify'
never "review-scan is never handed a screenshot path" "$SCAN" \
  '/tmp/screenshots'

# The subagent cannot resolve the script without being told where it lives.
want "the orchestrator hands review-verify the scripts dir" "$ORCH" \
  'CLAUDE_REVIEW_SCRIPTS=\$\{CLAUDE_REVIEW_SCRIPTS\}'

want "pr-review.yml verifies validate-screenshots.sh installed" "$WORKFLOW" \
  'validate-screenshots\.sh'
want "action.yml verifies it too" "$ROOT/action.yml" \
  'validate-screenshots\.sh'

# The API's own ceiling, not a guess: 5 MB of base64 (the Bedrock/Vertex limit,
# lower than the 10 MB direct one) is 3,750,000 raw bytes. A default above that
# would hand the model a file the API refuses.
DEFAULT_MAX=$(grep -o 'SCREENSHOT_MAX_BYTES:-[0-9]*' "$VALIDATOR" | head -1 | cut -d- -f2)
if [ -n "$DEFAULT_MAX" ] && [ "$DEFAULT_MAX" -le 3750000 ]; then
  ok "the default byte ceiling ($DEFAULT_MAX) stays under the 5 MB-base64 API limit"
else
  bad "SCREENSHOT_MAX_BYTES defaults to '$DEFAULT_MAX' — over the 3750000-byte equivalent of the API's 5 MB base64 cap"
fi
want "the validator refuses anything without a complete IEND" "$VALIDATOR" \
  'IEND'
DEPS=$(grep -vE '^[[:space:]]*#' "$VALIDATOR" | grep -cE '\b(python3|python|magick|convert|sips)\b')
if [ "${DEPS:-0}" -eq 0 ]; then
  ok "the validator adds no new binary dependency outside its comments"
else
  bad "the validator reaches for an image/scripting binary in $DEPS code line(s)"
fi

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
EXPAND_LINE=$(grep -n 'expand_placeholders "\$line"' "$POSTER" | head -1 | cut -d: -f1)
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
# review-verify describes the poster's inline cap to the model. It said "5-cap"
# long after the default moved to 10; it then said "10-cap" after the cap started
# scaling with the diff. Both understate what can post inline and invite
# pre-emptive dropping, so the contract is now on the MECHANISM, not on a
# literal: guard.sh computes the cap, the workflow hands it to the poster, and
# post-review.sh keeps exactly one env read with one fallback.
CAP=$(sed -n 's/^COMMENT_LIMIT="\${REVIEW_COMMENT_LIMIT:-\([0-9]*\)}".*/\1/p' "$POSTER" | head -1)
if [ -n "$CAP" ]; then
  ok "post-review.sh still reads REVIEW_COMMENT_LIMIT with a numeric fallback ($CAP)"
else
  bad "post-review.sh must keep COMMENT_LIMIT=\${REVIEW_COMMENT_LIMIT:-<n>} — the scale is computed upstream and passed in"
fi
want "guard.sh emits the scaled inline cap" "$GUARD" \
  "printf 'depth_scale=%s.ncomment_limit=%s"
want "…and the workflow hands it to the poster" "$WORKFLOW" \
  'REVIEW_COMMENT_LIMIT: \$\{\{ steps\.guard\.outputs\.comment_limit \}\}'
want "…and hands the item ceiling to the review agent" "$WORKFLOW" \
  'REVIEW_DEPTH_SCALE: \$\{\{ steps\.guard\.outputs\.depth_scale \}\}'
# The two halves must agree on the same env var name, or the poster silently
# keeps its fallback on every PR and the whole scale is dead code.
want "review-verify names the env var the poster actually reads" "$VERIFY" \
  'REVIEW_COMMENT_LIMIT'
want "review-scan is capped by the guard's number, not a literal" "$SCAN" \
  'REVIEW_DEPTH_SCALE'
never "review-verify no longer hardcodes a stale numeric cap" "$VERIFY" \
  'within the [0-9]+-cap'
# A real cross-file assertion: run the guard at both ends of the scale and check
# the poster's fallback lies inside the range it can emit. A retuned divisor that
# put the whole band above or below 10 would leave a short-circuited run posting
# a review at a cap the pipeline never actually uses.
SMALL=$(GATE_FILES_TSV=$'src/a.ts\t5\t1' bash "$GUARD" | sed -n 's/^comment_limit=//p')
LARGE=$(GATE_FILES_TSV=$'src/a.ts\t2000\t500' bash "$GUARD" | sed -n 's/^comment_limit=//p')
if [ -n "$SMALL" ] && [ -n "$LARGE" ] && [ "$SMALL" -le "$CAP" ] && [ "$CAP" -le "$LARGE" ]; then
  ok "the poster's fallback ($CAP) sits inside the guard's emitted range ($SMALL..$LARGE)"
else
  bad "post-review.sh falls back to $CAP, outside the guard's range ($SMALL..$LARGE)"
fi
# The item ceiling and the comment cap are one number and its double. Verify is
# told that; assert the guard really does it, so the prompt cannot go stale.
DS=$(GATE_FILES_TSV=$'src/a.ts\t400\t100' bash "$GUARD" | sed -n 's/^depth_scale=//p')
CL=$(GATE_FILES_TSV=$'src/a.ts\t400\t100' bash "$GUARD" | sed -n 's/^comment_limit=//p')
if [ -n "$DS" ] && [ "$CL" = "$(( DS * 2 ))" ]; then
  ok "guard.sh emits comment_limit as twice depth_scale ($DS → $CL), as review-verify states"
else
  bad "guard.sh emitted depth_scale=$DS comment_limit=$CL — review-verify says the cap is twice the scale"
fi
# The anti-padding rules are what stop a wider ceiling being filled with noise.
# They are load-bearing precisely BECAUSE the ceiling now moves, so pin them.
want "review-scan still bans suspicion with no object" "$SCAN" \
  'Suspicion with no object'
want "…still names the un-actionable shapes verbatim" "$SCAN" \
  'Double check this logic'
want "…and still says a made-up item costs more than a missing one" "$SCAN" \
  'made-up item costs more than a missing one'
want "…and says explicitly that the ceiling is not a target" "$SCAN" \
  'ceiling is a limit, not a quota|ceiling, not a target'
want "…and that a wider ceiling is not a weaker bar" "$SCAN" \
  'wider ceiling is not an easier one|relaxes as .REVIEW_DEPTH_SCALE. rises'
want "review-verify refuses to spend a free slot on a weak item" "$VERIFY" \
  'buys room, never licence'

echo ""
echo "── an explicit /review is never answered with silence ──"
want "guard.sh honours GATE_HUMAN_REQUESTED" "$ROOT/scripts/guard.sh" \
  'GATE_HUMAN_REQUESTED'
want "the workflow sets it from the triggering event" "$WORKFLOW" \
  'GATE_HUMAN_REQUESTED:.*issue_comment'

echo ""
echo "── a message on a PROCEEDING run is actually posted ──"
# No token emits one today, but the channel must stay reachable: the menu step is
# gated on `proceed != true`, so a notice attached to a proceeding run has no
# other way out. This is the seam the removal notice fell through.
PLAIN_MSG=$(CMD_BODY="/review code" bash "$CMD" | sed -n 's/^message=//p')
if [ -z "$PLAIN_MSG" ]; then ok "/review code renders none (so the poster step cannot fire spuriously)"; else bad "/review code rendered a message: '$PLAIN_MSG'"; fi
want "the workflow posts a message on a run that proceeds" "$WORKFLOW" \
  "proceed == 'true' && steps\.cmd\.outputs\.message != ''"

echo ""
echo "── the native second opinion: pinned, opt-in, and consumed (ADR 0005) ──"
NATIVE_SKILL="$ROOT/skills/review-native.md"
NATIVE_AGENT="$ROOT/agents/review-native.md"
for f in "$NATIVE_SKILL" "$NATIVE_AGENT"; do
  [ -f "$f" ] || bad "missing ${f#"$ROOT"/} — the native pass is wired but its file is absent"
done

# THE PIN. This is the whole reason the pass could come back (ADR 0004 deleted it
# over exactly this). The marketplace must be a LOCAL PATH built from a checkout
# pinned to a 40-hex SHA — never the live URL, in any form.
want "the marketplace is vendored by a SHA-pinned checkout" "$WORKFLOW" \
  'repository: anthropics/claude-plugins-public'
want "…and its ref is a full commit SHA" "$WORKFLOW" \
  'ref: [0-9a-f]{40}'
want "…and the action is handed a local path, not a URL" "$WORKFLOW" \
  "plugin_marketplaces: .*github\.workspace"
# Prose ABOUT the old URL is fine and deliberate (the comment explains the
# history); the input VALUE must never be one again.
never "…and never the live marketplace URL as the input value" "$WORKFLOW" \
  'plugin_marketplaces:.*https://'

# OPT-IN, both halves. `run_native` is the comment asking; `native_plugin.ready`
# is the vendoring having worked. RUN_NATIVE must require BOTH — dispatching a
# subagent that was never installed is a crashed review, not a missing opinion.
want "the workflow reads run_native from the parser" "$WORKFLOW" 'steps\.cmd\.outputs\.run_native'
want "RUN_NATIVE requires the pinned plugin to have resolved" "$WORKFLOW" \
  "RUN_NATIVE: .*native_plugin\.outputs\.ready == 'true' && steps\.cmd\.outputs\.run_native == 'true'"
want "the subagent is installed only when it resolved" "$WORKFLOW" 'NATIVE_READY.*native_plugin\.outputs\.ready'
want "…from agents/review-native.md" "$WORKFLOW" 'agents/review-native\.md'
if [ "$(CMD_BODY='/review code' bash "$CMD" | sed -n 's/^run_native=//p')" = "false" ]; then
  ok "a plain /review code does not switch the pass on"
else
  bad "/review code sets run_native — the second opinion must be opt-in"
fi

# THE SEAM that made this worth a contract test: three files have to agree on
# ONE filename, and nothing else reads it.
want "the skill writes /tmp/native.json" "$NATIVE_SKILL" '/tmp/native\.json'
never "…and not v3's /tmp/native-findings.json" "$NATIVE_SKILL" 'native-findings\.json'
want "review-verify is its consumer" "$VERIFY" '/tmp/native\.json'
want "the orchestrator dispatches review-native on RUN_NATIVE" "$ORCH" 'review-native'
want "…and names the file verify will read" "$ORCH" '/tmp/native\.json'
# Runners are reused and /tmp survives between jobs: a previous PR's file would
# be read as this one's. Every other stage artifact is cleared; this one too.
want "the stale-artifact sweep clears it" "$WORKFLOW" '/tmp/functional\.json /tmp/native\.json'
want "the skill guards on pr_number for exactly that reason" "$NATIVE_SKILL" 'pr_number'
want "…and verify discards a file from another PR" "$VERIFY" 'pr_number'

# The pass is advisory. It may never post, and it may never be the last word.
want "the skill forbids posting to the PR" "$NATIVE_SKILL" 'Do not run .gh pr comment'
want "…it says step 8 is overridden" "$NATIVE_SKILL" 'step 8 is OVERRIDDEN|Step 8 is OVERRIDDEN'
want "verify holds native findings to the same bar" "$VERIFY" 'no deference|same bar|exactly the bar'

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
# Every consumer's review-config.md POINTS AT `.claude/rules/`, and five of seven
# repos keep 12-17 rule files there — including comments.md in two of them. The
# reviewer read neither, so rules the teams wrote (and believed were enforced)
# were invisible, and a violation could never meet the quote-it-verbatim bar.
# Bounded on purpose: an ls plus at most 4 topical reads, never the whole tree.
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  want "$n reads the team's own rules directory" "$f" '\.claude/rules/'
  want "$n bounds how many rule files it reads" "$f" '(at most|most) \*{0,2}4\*{0,2}'
  want "$n names the always-applicable rule files" "$f" 'comments\.md.*general\.md'
  want "$n honours a rule file's paths glob" "$f" 'paths:'
done
# Asymmetric on purpose. Scan reads the directory upfront because it is the
# stage that hunts for convention violations; verify only ever needs the ONE
# file a finding's evidence cites, and scan is already required to name it. Four
# more Reads per run bought nothing.
want "review-scan reads the rules directory upfront" "$SCAN" \
  'one `ls` of it, and `Read` \*\*at most 4\*\*'
want "review-verify reads a rule file only when a finding cites it" "$VERIFY" \
  'only the single .{0,3}\.md.{0,3} file a finding.{0,40}cites'
want "…and says it does not read them upfront" "$VERIFY" \
  'Do NOT read `\.claude/rules/` upfront'

# Reviewers on three products spend review time deleting machine-written
# comments ("remove this shitty comments (check everywhere please)"). The class
# is capped, minor and advisory like prose, and must never delete a real why.
want "review-scan can flag comment noise in code" "$SCAN" '## Comment noise in code'
want "…and protects comments that carry a real why" "$SCAN" \
  'constraint, an invariant, a workaround'
want "…and files one finding per file, not per comment" "$SCAN" 'never one comment per finding'
want "review-verify judges the class on what it can see" "$VERIFY" 'comment-noise finding'
want "…and refutes a finding aimed at a single comment" "$VERIFY" \
  'naming a single comment is refuted'

# The class used to ride on `"prose": true`, which made it unemittable: the
# schema reserves `prose` for a DOCS_ONLY prose defect, that channel is open
# only on a DOCS_ONLY run, and verify's prose rule refutes anything whose two
# quoted passages are not both present — which comment noise never has. It now
# carries its own flag, exempt from failure_scenario the way `convention` is.
CN_SCAN=$(mktemp)
awk '/^## Comment noise in code/{f=1;next} f&&/^## /{f=0} f' "$SCAN" > "$CN_SCAN"
if [ -s "$CN_SCAN" ]; then
  want "…on its own flag, not the docs-only prose flag" "$CN_SCAN" '"comment_noise": true'
  never "…and never emitted under the prose flag" "$CN_SCAN" 'per review\*\*, `?"prose": true'
  want "…which it disowns by name" "$CN_SCAN" 'never set `"prose": true`'
  want "…exempt from failure_scenario like a convention finding" "$CN_SCAN" \
    'exempt from `failure_scenario`'
  want "…capped at 2 per review" "$CN_SCAN" '(max|most) \*{0,2}2\*{0,2} per review'
  want "…always minor" "$CN_SCAN" 'severity.{0,4}minor'
  want "…and never able to reach REQUEST_CHANGES" "$CN_SCAN" 'NEVER produce REQUEST_CHANGES'
  # Deleting comments through a committable patch is unguarded downstream.
  want "…and never ships a committable comment deletion" "$CN_SCAN" \
    'Never a ```suggestion``` fence on this class'
  # The old criterion 4 ("runs longer than the code it explains") described the
  # single most valuable comment shape there is, and the guard below it said the
  # opposite with neither marked dominant. The criterion is gone; the guard is
  # now an override that outranks the whole list, pointers to reasoning included.
  never "…no criterion turns comment length into a finding" "$CN_SCAN" \
    '(runs|run) longer than|longer than the code'
  want "…the real-why guard is an override, not a footnote" "$CN_SCAN" \
    'outranks every criterion'
  want "…and a pointer to where the reasoning lives is a real why" "$CN_SCAN" \
    'pointer to where the reasoning lives'
else
  bad "review-scan has no '## Comment noise in code' section"
fi
rm -f "$CN_SCAN"
want "review-scan exposes the comment_noise flag in its findings table" "$SCAN" \
  '^\| `comment_noise` \|'
want "…and in its output schema" "$SCAN" '"comment_noise": false'
want "review-verify keys the class on comment_noise, not prose" "$VERIFY" \
  '\*\*A comment-noise finding\*\* \(`"comment_noise": true`'
want "…and exposes the flag in meta.findings" "$VERIFY" '"comment_noise": false'

# The verdict rule is the one that must name the exclusion, not just imply it.
RC_LINE=$(grep -n 'REQUEST_CHANGES\*\*' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$RC_LINE" ] && sed -n "${RC_LINE}p" "$VERIFY" | grep -qiE 'not a convention finding|convention.*NEVER produce'; then
  ok "review-verify's REQUEST_CHANGES rule excludes convention findings on the rule line itself"
else
  bad "review-verify's REQUEST_CHANGES rule must exclude convention findings on line $RC_LINE"
fi
want "…and says so unambiguously" "$VERIFY" 'can NEVER produce REQUEST_CHANGES'
# Comment noise is advisory for the same reason convention and prose are, so the
# exclusion has to be structural — on the rule line, not implied elsewhere.
if [ -n "$RC_LINE" ] && sed -n "${RC_LINE}p" "$VERIFY" | grep -qiE '(nor|not) a comment-noise finding|"comment_noise": true'; then
  ok "review-verify's REQUEST_CHANGES rule excludes comment-noise findings on the rule line itself"
else
  bad "review-verify's REQUEST_CHANGES rule must exclude comment-noise findings on line ${RC_LINE:-?}"
fi
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
echo "── a check is ORIENTATION, not interrogation ──"
# The old channel handed the reviewer open questions to go answer ("does told
# once mean per browser, per user or per practice?"). The owner verdict: it
# "points out uncertainties which is very weird, takes time to understand and
# then self review". A check is now a short note saying what a block of changed
# code is FOR and which part of the spec it serves, anchored across the whole
# block. These pin that inversion in both directions — the new shape must be
# there, and the interrogation shape must be gone.
want "review-scan gates on worth-the-reader-time, not on uncertainty" "$SCAN" \
  'does a reviewer reading this block go faster'
never "…and the old uncertainty test is gone" "$SCAN" \
  'would a reviewer who knows this product still want|your answer is not the last word'
want "…so a note is explicitly never a question" "$SCAN" \
  'A question, in any costume'
want "…and narrating the obvious is named the cardinal sin" "$SCAN" \
  'Narrating the obvious'
want "…with the plain React component called out by name as the canonical never" "$SCAN" \
  'plain React component'
want "…and a note is short because it has one thing to say, not because it was squeezed" "$SCAN" \
  'Short because there is little to say, not because it was squeezed'
want "…with the read-aloud test replacing the character budget" "$SCAN" \
  'say it back to yourself|would actually talk like that'
# The two style rules that produced the #351 noun-piles, pinned in both files so
# neither drifts back: an em dash is how a second clause gets bolted on, and a
# clever sentence is how a reader loses the thread.
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  want "$n bans the em dash in a note" "$f" \
    'No em dashes, and no semicolons'
  want "$n asks for simple words and short sentences" "$f" \
    'Simple words, short sentences'
done
# The DISCOVERY method, not just the output shape: a doubt detector cannot
# produce orientation however the output is worded, so the traversal itself is
# segment -> say what it is for -> triage on worth-the-time.
want "review-scan segments the diff into blocks first" "$SCAN" \
  'Segment the changed code into blocks'
want "…then asks what each block is FOR" "$SCAN" \
  'Say what each block is for'
want "…then triages on what the reader cannot see for themselves" "$SCAN" \
  'is there anything here the reader cannot see'
want "…and says outright that being important is not a reason to write" "$SCAN" \
  'is a reason to \*\*read\*\* the block, not a reason to \*\*write about\*\* it'
want "…and says outright not to go hunting for doubts" "$SCAN" \
  'that traversal finds doubts, and a doubt is not a note'
never "…so the old doubt taxonomy is gone from review-scan" "$SCAN" \
  '^- \*\*(Prior art|Placement and precedent|Dense logic|Unwritten house idiom|Conspicuous absence)'
# Each block that survives triage must be kept for a nameable reason, and each
# dropped one for a nameable reason — the same "name a checkable artifact"
# discipline the old category list carried.
for pair in \
  'an invariant it depends on but does not state:ordering, a precondition' \
  'a consequence that lands outside the block:breaks, or silently shows nothing' \
  'a contract other code relies on:callers outside the diff' \
  'a reason the shape is unusual:constraint that made the obvious version wrong'
do
  keep=${pair%%:*}; obl=${pair#*:}
  if grep -F "$keep" "$SCAN" | grep -qiE "$obl"; then
    ok "the '$keep' triage rule names what it is looking at"
  else
    bad "the '$keep' triage rule must name a checkable artifact (/$obl/)"
  fi
done
# The new item shape. why_unresolved existed only to justify a question, so it
# must not survive in any form, in either file.
want "review-scan emits the orientation shape" "$SCAN" \
  'what_to_know.*spec_ref|start_line.*end_line'
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  never "$n carries no trace of the interrogation shape" "$f" \
    'what_to_check|why_unresolved'
done
# The spec reference: the in-repo document is the specification, the linked
# issue is a summary of it. build-spec.sh already orders them that way; a check
# that cites the issue as the source of truth undoes that.
want "review-scan cites the spec as a path:line into an in-repo document" "$SCAN" \
  '`path:line` of the section in the in-repo spec'
want "…by line number, never a heading anchor that rots when the heading is edited" "$SCAN" \
  'A line number, never a `#heading` anchor'
want "…and emits nothing at all when only an issue or ticket governs" "$SCAN" \
  'In-repo documents only'
want "review-verify renders that citation as a link, never as a sentence" "$VERIFY" \
  'Cite the spec as a link, never as a sentence'
want "…so a prose pointer cannot come back as a bullet" "$VERIFY" \
  'is a pointer that costs a line and teaches the reader nothing'
want "…and never re-derives spec_ref, because it never loads the spec" "$VERIFY" \
  'spec_ref.{0,20}is scan|do not re-derive'
# Anti-padding: at least as strong as before (the shapes above are pinned with
# the depth scale), with the failure mode changed shape rather than removed.
want "review-scan forbids padding to the ceiling" "$SCAN" \
  'Do not pad'
want "…and demands a named construct, not a category" "$SCAN" \
  'names the construct it is about'
# The two rates the owner asked for, and the tension between them, stated so a
# model cannot average them into one lukewarm behaviour.
want "review-scan says silence is the expected result on a simple code diff" "$SCAN" \
  'silence is the expected result when the bar below is met'
# A RATE IS NOT A BAR. The owner estimated 30-50% of PRs would be simple; 39
# labelled merged PRs from the two consumer repos measured 14% (4 of 28 code
# PRs, 3 of them borderline). A prompt carrying a target percentage invites the
# model to manufacture approvals to meet it — the padding failure with the sign
# flipped — so the skill encodes the BAR and never a rate, in either direction.
want "…with no quota in either direction" "$SCAN" \
  'no quota in either direction'
want "…and says the rate is not the model's concern" "$SCAN" \
  'How often a diff clears that bar is not your concern'
for f in "$SCAN" "$VERIFY"; do
  n=${f##*/}
  never "$n encodes no target approval rate" "$f" \
    'third (and|to) a half|[0-9]+% of (PRs|code PRs|reviews)|[0-9]+-[0-9]+% of'
done
want "review-verify carries no target rate either" "$VERIFY" \
  'no target rate in either direction'

# The poster can only tell "never came up" from "came up 40s after we stopped
# waiting" if it is handed the same number the orchestrator waits on. On
# spendfuse#351 it was not, so the one case that mattered — rc 0, arriving late —
# fell through the rc check and the review said nothing.
want "the workflow hands the poster the same wait the orchestrator uses" "$WORKFLOW" \
  'DEV_ENV_TIMEOUT_SECONDS: \$\{\{ inputs\.dev_env_timeout_seconds \}\}'
want "post-review keys the skip notice on whether the TESTER ran, not the rc" "$POSTER" \
  'THE QUESTION IS "DID THE TESTER RUN\?", NOT "DID THE BRING-UP FAIL\?"'

# ── the cardinality pass ────────────────────────────────────────────────────
# WHY THIS IS PINNED. spendfuse#351 (5572 non-generated lines, depth `full`,
# effort 4) produced ONE minor finding, and Anthropic's own plugin over the same
# 100 files produced none. Both were defensible on every value-shaped question —
# and both walked straight past `usePerOrgAlertRulePerformance`, an unbounded
# `Promise.allSettled` firing one full-table `GROUP BY` aggregate per
# organisation on mount. It is invisible when you trace values, because the seed
# has four organisations and the count is the input that has to change. The
# prompt had no lens for it at all: its only mention of N+1 was as an example of
# a note that is FORBIDDEN, which is not the same as a finding shape being real.
# Both halves are asserted — the pass, and the bar it must not lower.
# Blast radius, measured rather than guessed: size is necessary but not
# sufficient (0 of 14 PRs over 100 added lines were simple; only 4 of 14 under
# it were), and three path/vocabulary signals decided the rest.
want "review-scan says size does not predict blast radius" "$SCAN" \
  'size does not predict it'
want "…naming the workflow / deploy / dev-env path signal" "$SCAN" \
  'workflow file, a deploy script or a dev-env script'
want "…the migration signal" "$SCAN" \
  'A migration\*\* — `\.sql`, `\.prisma`'
want "…the auth/tenancy/visibility vocabulary signal" "$SCAN" \
  'Auth, tenancy or visibility vocabulary in the changed lines'
want "…and the new-identifier-others-call signal" "$SCAN" \
  'A new identifier something outside the diff will call'
want "…with the positive shape a quiet diff had" "$SCAN" \
  'introducing nothing new for anyone else to call'
# ADR 0004 killed the structural classifier on purpose. These are signals a
# reader weighs, not a tier resolver that decides before the model reads.
want "…explicitly NOT a lookup table, so no tier ladder comes back" "$SCAN" \
  'not a lookup table that decides for you'
want "…and a mechanical-looking change in that set is not quiet" "$SCAN" \
  'Mechanical-looking is not the same as quiet'
want "…so the never-a-note mechanical rule carves it out" "$SCAN" \
  'the shape is mechanical and the reach is not'
want "…while a DOCS_ONLY run inverts the default" "$SCAN" \
  'DOCS_ONLY.{0,20}run the default inverts'
want "…because a document is the baseline for future work" "$SCAN" \
  'baseline the next PRs are built on'
want "…with faithful slicing as the one docs-only case that earns silence" "$SCAN" \
  'faithful slicing'
want "…which is the exception, stated without a rate" "$SCAN" \
  'exception rather than the rule'
want "…discriminated by what the merged documents did not already imply" "$SCAN" \
  'could not have derived from the already-merged architecture'
# APPROVE. "No notes" no longer means "nobody needs to read this diff", so the
# old inverse-logic gate is gone and zero notes is a reason to approve.
never "the contradictory boolean is gone from review-scan" "$SCAN" \
  'human_review_adds_nothing'
never "…and from review-verify" "$VERIFY" \
  'human_review_adds_nothing'
want "review-scan says zero notes is a reason to approve" "$SCAN" \
  'Zero notes is a reason to approve, not a reason to hesitate'
want "…and that an unnameable doubt does not withhold approval" "$SCAN" \
  'doubt you cannot name is not a reason to withhold approval'
want "review-verify approves on the argued case alone" "$VERIFY" \
  'a real, non-empty `approve_argument` from scan'
never "…and the any-doubt veto is gone" "$VERIFY" \
  'Any doubt → not APPROVE'
want "…so notes never block APPROVE on a code diff" "$VERIFY" \
  'Surviving notes never block APPROVE on a code diff'
want "…but a note on a DOCS_ONLY run does" "$VERIFY" \
  'DOCS_ONLY.{0,60}add one more: zero surviving notes'
# A check still cannot move the verdict in the blocking direction.
want "a check can never reach REQUEST_CHANGES" "$VERIFY" \
  'note carries no severity and can NEVER produce REQUEST_CHANGES'
want "review-verify re-attacks carried notes" "$VERIFY" \
  'Refute each note'
want "…dropping one that narrates the block" "$VERIFY" \
  'It labels or narrates the block'
want "…and one that asks a question" "$VERIFY" \
  'It is a question'
want "…but not one that merely looks obvious to the reviewer of the reviewer" "$VERIFY" \
  'Do not drop a note because the block looks obvious to YOU'
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
want "…so a note it could only ground by fetching is not written" "$SCAN" \
  'could only write by reading a dependency.{0,60}is not written'
want "review-verify refutes one on the same ground" "$VERIFY" \
  'Nothing outside the checkout is reachable.{0,80}stands refuted'

# A human_review item raising a risk the repo has already declared an accepted
# trade-off sailed straight through: the suppression pass named findings only.
SUP_LINE=$(grep -n 'suppressed by' "$VERIFY" | head -1 | cut -d: -f1)
if [ -n "$SUP_LINE" ] && sed -n "${SUP_LINE}p" "$VERIFY" | grep -q 'human_review'; then
  ok "review-verify suppresses human_review notes, not just findings, on the rule line itself"
else
  bad "review-verify's suppression rule (line ${SUP_LINE:-?}) must name human_review notes too"
fi

# Three of seven noise counts were items whose concern was stated AND handled in
# a comment at the very line cited.
# Wording changed: the bullet used to read "already documents the risk and
# mitigates it" inside "A risk the code ..." — a literal duplication of "risk".
# The intent (an item the cited line already documents AND mitigates) is
# unchanged, so the regex now tolerates the de-duplicated phrasing.
want "review-scan drops a note the cited code already mitigates" "$SCAN" \
  'already documents (the risk )?and mitigates'

# ...but a drop with no trace is the same failure shape as the bugs above: the
# context builder went out and nothing recorded it; suppression was findings-only
# and nothing recorded that either. Every killed checkbox must be auditable in
# the uploaded verify.json, and must stay OUT of the posted review.
want "review-verify records every dropped human_review note" "$VERIFY" \
  'Every dropped note leaves a trace'
want "…tagged so the kinds are distinguishable in meta.refuted" "$VERIFY" \
  '"kind": "finding\|human_review\|screenshot\|functional"'
want "…carrying what was written" "$VERIFY" \
  'what_to_know that was written'
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
# The native pass is advisory and its findings are deduplicated into scan's
# wording, so its own output is the ONLY record of what the second opinion
# actually said. The stale sweep already clears it (see above); uploading it is
# what makes a disagreement between the two reviewers auditable after the fact.
want "the workflow uploads /tmp/native.json as an artifact" "$WORKFLOW" \
  '^ +/tmp/native\.json$'
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
echo "── copy that states a fact about behaviour is checked against the constant ──"
# v3 proved this by controlled experiment: on byte-identical code the reviewer
# WITH this directed check found "expires in 7 days" against a 72h
# ACTIVATION_TTL_MS, and WITHOUT it missed the same defect. The bar never moved —
# only whether anything told the model to go look. Nothing here runs a model, so
# these pin the instruction, never the catch.
want "review-scan directs a lookup when copy claims a fact about behaviour" "$SCAN" \
  'factual claim about behaviour'
want "…and names what to go read: the constant behind the claim" "$SCAN" \
  '`Grep` for the constant that implements the claim'
# Anchored on "mismatch": the bare phrase already appears in the spec section,
# so an unanchored match would pass with this whole rule deleted.
want "…keeping it an ORDINARY finding, not a new exempt class" "$SCAN" \
  'mismatch is an \*{0,2}ordinary finding at the ordinary bar'
want "…and carries the measured case that motivated it" "$SCAN" \
  'ACTIVATION_TTL_MS'
# The seam: verify's prose-is-minor re-rate would otherwise cap a copy defect at
# minor, and the verdict it earned would vanish between the two stages.
if grep -iE 'Re-rate a survivor whose severity' "$VERIFY" | grep -qiE 'user-facing copy'; then
  ok "the copy exemption rides on the re-rate rule line itself"
else
  bad "review-verify must exempt user-facing copy on the Re-rate line, not elsewhere"
fi
# And it must not have grown a fourth channel on the way in.
never "review-scan adds no new exempt class for copy" "$SCAN" \
  'uncertain_observations|"copy": true'

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
never "the PR body is no longer a spec source — judging a diff against its own summary is circular" "$BUILDSPEC" \
  'Spec source — the PR body'
want "not every markdown file is a specification" "$BUILDSPEC" \
  'CONTEXT — NOT A SPECIFICATION'
want "a doc this PR wrote is labelled, not trusted to settle its own questions" "$BUILDSPEC" \
  'WRITTEN BY THIS PR'
want "runbooks and reference material are never a specification" "$BUILDSPEC" \
  'docs/runbooks'
want "the assembler records whether a spec resolved" "$BUILDSPEC" \
  '/tmp/spec-status'
want "the poster makes 'no spec' visible" "$POSTER" \
  'No spec resolved'
never "…and it is not a verdict gate" "$POSTER" \
  'spec.*APPROVE|APPROVE.*spec'
want "review-scan is told a context section asks for nothing" "$SCAN" \
  'CONTEXT — NOT A SPECIFICATION'
never "review-scan no longer knows a PR-body spec fallback" "$SCAN" \
  'PR-body fallback'
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
want "…and never lets \"no spec\" stand in for a citation" "$SCAN" \
  '"no spec" is never a reason to skip a `spec_ref`'
want "…leaving spec_ref empty instead of inventing a criterion" "$SCAN" \
  'leave `spec_ref` empty rather than inventing a criterion'
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
want "…never off a context section" "$SCAN" \
  'never off a .CONTEXT'
want "…never off a partial spec" "$SCAN" \
  'never off a partial spec'
want "…and put more carefully when only a summary governs" "$SCAN" \
  'you are reading a summary'
want "…as a human_review note, never a finding" "$SCAN" \
  'human_review`? note, never a finding'
want "…stated as fact rather than asked as a question" "$SCAN" \
  'never asks the reviewer a question'
want "…capped at one per review" "$SCAN" \
  'At most one such note per review'
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
want "…never the tracker hook output, never a context section" "$ORCH" \
  'Never the external-tracker section and never a CONTEXT section'
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
echo "── an absence claim is checked against the BASE, not just HEAD ──"
# v3 judge rule 8, deleted with the panel and with no rationale recorded. The
# audited failure: a CRITICAL "nginx.conf has no /api/fgo route" filed against a
# stale head whose base had already shipped it. v4's refute pass reads HEAD only,
# so that false-positive class returns — and it clears the failure_scenario bar
# cleanly, so nothing else catches it.
want "review-verify checks the base before keeping an absence claim" "$VERIFY" \
  'Check the base, not HEAD'
want "…via a ref the sandbox can actually read" "$VERIFY" \
  'git show .{0,20}origin/'
want "…and refuses to file one it could not check there" "$VERIFY" \
  'cannot check against the base'
want "…citing the failure it exists to prevent" "$VERIFY" \
  'stale head whose base had already shipped'
# The BOUND is the capability, not a nicety: an unconditional base lookup is a
# per-finding tool call and this pipeline exists to not pay for those.
want "the base lookup fires on absence claims only, never on every finding" "$VERIFY" \
  'Absence claims only'
# ...and it must stay inside the deny list. $DENY is read out of the workflow above.
if printf '%s' "$DENY" | grep -qE 'git show|git grep'; then
  bad "a git read verb is now denied — the base lookup cannot run"
else
  ok "the sandbox still permits git read verbs for the base lookup"
fi

echo ""
echo "── the spec is one witness, not the verdict ──"
# v3's anti-spec-lawyering gate (review-judge.md:117-124) died with the judge
# panel, and v4 is MORE exposed than v3 was: build-spec.sh inlines whole planning
# documents (1500 lines each) labelled AUTHORITATIVE, and a planning document
# describes deferred phases and already-shipped work as readily as this PR's.
want "review-scan treats spec text as one witness" "$SCAN" \
  'one witness, not the verdict'
want "…counting types and tests in the diff as evidence of intent" "$SCAN" \
  'say what the author believes the contract is'
want "…so an internally consistent contract against loose wording is not a finding" "$SCAN" \
  'internally consistent'
want "…routed to the human_review channel at most, never to a finding" "$SCAN" \
  'at most one .{0,15}human_review'
want "…while an unambiguous contradiction is still a finding" "$SCAN" \
  'unambiguous AND the code contradicts'
want "…and a criterion this diff does not implement is not automatically a defect" "$SCAN" \
  'not automatically a defect'
# It lives in scan alone, on purpose: review-verify never reads /tmp/spec.md, and
# making it do so would load 3000 lines to second-guess a call scan already made.
never "review-verify is not made to load the spec to re-run this gate" "$VERIFY" \
  '/tmp/spec\.md'

echo ""
echo "── an injection attempt is RECORDED, and records nothing else ──"
# v3 set prompt_injection_detected and escalated to human review; escalation is a
# verdict gate, and ADR 0003 bans those. So v4 keeps the record and the BEHAVIOUR
# and drops the gate. It matters more here than in v3: build-spec.sh ingests
# markdown taken from the PR's own diff and labels it AUTHORITATIVE, and 2d3a1e5
# closed a live hole where skills/review-scan.md resolved as that spec.
want "review-scan sets the flag" "$SCAN" \
  'prompt_injection_detected.{0,10}true'
want "…on text that steers the reviewer instead of describing the work" "$SCAN" \
  'ignore previous instructions'
want "…and reviews as if the text were absent" "$SCAN" \
  'as if that text were absent'
want "…so it never suppresses, downgrades or argues for approval" "$SCAN" \
  'never suppresses a finding, never lowers a severity'
want "…and exposes it in its schema" "$SCAN" \
  '"prompt_injection_detected": false'
want "review-verify carries it into meta" "$VERIFY" \
  '"prompt_injection_detected": false'
want "…as a record, never a verdict input" "$VERIFY" \
  'record, never a verdict input'
want "…that never reaches the posted prose" "$VERIFY" \
  'adds nothing to .{0,10}body'
# A PR that ships its own "do not flag" line would otherwise silence its own
# review: both stages apply suppression unconditionally, from files read at HEAD.
want "…and a suppression the diff itself introduced is not a suppression" "$VERIFY" \
  "this PR's own diff added"

# THE GATE THAT MUST NOT COME BACK. This is the structural half of the pin: the
# two verdict rules are read by line, so no rewording can smuggle the flag in.
VLINE=$(grep -n '^- \*\*REQUEST_CHANGES\*\*' "$VERIFY" | head -1 | cut -d: -f1)
ALINE=$(grep -n '^- \*\*APPROVE\*\*' "$VERIFY" | head -1 | cut -d: -f1)
for l in "$VLINE" "$ALINE"; do
  if [ -z "$l" ]; then
    bad "could not locate a verdict rule line in review-verify"
  elif sed -n "${l}p" "$VERIFY" | grep -qi 'injection'; then
    bad "the verdict rule on line $l names the injection flag — it must never gate a verdict"
  else
    ok "verdict rule on line $l is free of the injection flag"
  fi
done

# Surfacing is the poster's job: deterministic, outside the model's byte budget,
# and structurally unable to touch the verdict or the exit code.
want "post-review.sh reads the flag" "$POSTER" \
  'meta\.prompt_injection_detected'
want "…and surfaces it on the PR without the model's help" "$POSTER" \
  'injection-shaped text in the PR input'
if grep -n 'INJECTION' "$POSTER" | grep -qiE 'VERDICT=|exit |crash_exit'; then
  bad "post-review.sh lets the injection flag reach a verdict or exit path"
else
  ok "the injection flag never reaches a verdict or an exit code"
fi

echo ""
echo "── no stale references to deleted assets ──"
never "require-review-json.sh does not name v3 artifacts" "$ROOT/scripts/require-review-json.sh" \
  'judge-\*\.json|functional-\*\.json'
want "…it names the v4 ones" "$ROOT/scripts/require-review-json.sh" \
  '/tmp/scan\.json .*/tmp/verify\.json .*/tmp/functional\.json'
# The seam that shipped a reference to a deleted agents/review-native.md. The
# invariant is not "never name that file" — it is back (ADR 0005) — it is that
# every subagent the onboarding prompt names must EXIST.
for a in review-scan review-verify review-functional-tester review-native; do
  if grep -q "agents/$a.md" "$ROOT/prompts/setup-review.md" && [ -f "$ROOT/agents/$a.md" ]; then
    ok "onboarding names agents/$a.md, and it exists"
  else
    bad "onboarding must name agents/$a.md, and the file must exist"
  fi
done

echo ""
echo "── the docs-only prose channel: gated, capped, and unable to move a verdict ──"
# Hand-validated against 8 real docs PRs. 13 of the 14 defensible findings came
# from ONE generic instruction — does this document contradict itself, another
# document in the same diff, or a standard it itself cites — and the two style
# rules asked for most loudly ("short", "no walls of text") produced ZERO. So the
# channel is narrow by construction, and length is a trigger to read, never a
# defect. The two config paths keep one read site each; the exactly-once loop
# above is what pins that, and a third mention anywhere would break it.
want "guard.sh classifies a docs-only PR for the review" "$GUARD" \
  "printf 'docs_only=%s"
want "…and the workflow hands it to the review agent" "$WORKFLOW" \
  'DOCS_ONLY: \$\{\{ steps\.guard\.outputs\.docs_only \}\}'

# Assert on the SECTION, not the file: "max 2" and "minor" already appear in the
# convention rules, so a file-wide grep would pass with no prose channel at all.
PROSE_SCAN=$(mktemp)
# Terminator changed: the file-wide "Out of scope, always" line used to sit at
# the end of this run of sections and was reused as the section boundary. It has
# moved up into "## The finding bar" where it is unambiguously file-wide, so the
# boundary is now the next top-level heading. Same intent: assert on the SECTION.
awk '/^### Prose defects/{f=1;next} f&&/^## /{f=0} f' "$SCAN" > "$PROSE_SCAN"
if [ -s "$PROSE_SCAN" ]; then
  ok "review-scan carries a prose-defect section"
  want "…gated on DOCS_ONLY" "$PROSE_SCAN" 'DOCS_ONLY'
  want "…stating the reader-harm sentence the model must complete" "$PROSE_SCAN" \
    'named reader.{0,40}named task.{0,20}cannot'
  want "…with a named role, never \"a reader\"" "$PROSE_SCAN" \
    'role that exists in this repo'
  want "…kind 1: self-contradiction, or another document in the same diff" "$PROSE_SCAN" \
    'contradicts itself'
  want "…kind 2: a standard the document itself cites" "$PROSE_SCAN" \
    'standard it itself cites'
  want "…kind 3: the rendered artefact disagrees with the prose" "$PROSE_SCAN" \
    'does not say what the prose around it says'
  want "…and nothing else qualifies" "$PROSE_SCAN" \
    'nothing else does'
  want "…length is a reason to read, never itself a finding" "$PROSE_SCAN" \
    'never itself a finding'
  want "…wordiness and layout preferences are refused by name" "$PROSE_SCAN" \
    'wordiness'
  want "…capped at 2 per review" "$PROSE_SCAN" '(max|most) \*{0,2}2\*{0,2} per review'
  want "…always minor" "$PROSE_SCAN" 'severity.{0,4}minor'
  want "…and never able to reach REQUEST_CHANGES" "$PROSE_SCAN" \
    'NEVER produce REQUEST_CHANGES'
else
  bad "review-scan has no '### Prose defects' section"
fi
rm -f "$PROSE_SCAN"

want "review-scan exposes the prose flag in its findings table" "$SCAN" \
  '^\| `prose` \|'
want "…and in its output schema" "$SCAN" '"prose": false'
# The channel is an exemption for ONE class. Everything else keeps the old bar.
want "the ordinary failure_scenario bar still governs every other finding" "$SCAN" \
  'A finding without a `failure_scenario`.*MUST NOT be emitted'
never "no rule turns a length measurement into a finding" "$SCAN" \
  '(line|word|character|paragraph) count[^.]*finding|finding[^.]*(line|word|character) count|(over|more than|longer than) [0-9]+ (lines|words)[^.]*finding'

# Verify side: the verdict RULE excludes the class, so the exclusion is
# structural rather than a convention the model is asked to honour.
RC_PROSE=$(grep -n 'REQUEST_CHANGES\*\*' "$VERIFY" | head -1 | cut -d: -f1)
# Wording changed: the rule now excludes THREE classes (convention, prose,
# comment-noise), so the list reads "not a prose finding" rather than "nor a
# prose finding". Same intent — the exclusion must be on the rule line itself.
if [ -n "$RC_PROSE" ] && sed -n "${RC_PROSE}p" "$VERIFY" | grep -qiE '(nor|not) a prose finding|"prose": true.{0,80}(NEVER|advisory)'; then
  ok "review-verify's REQUEST_CHANGES rule excludes prose findings on the rule line itself"
else
  bad "review-verify's REQUEST_CHANGES rule must exclude prose findings on line ${RC_PROSE:-?}"
fi
PV=$(grep -F 'A finding carrying `"prose": true`' "$VERIFY")
if [ -n "$PV" ]; then
  ok "review-verify has a refute rule for prose findings"
  case "$PV" in
    *'uncertain → refuted'*) ok "…uncertain is refuted, same default as any fresh claim" ;;
    *) bad "…must refute a prose finding it cannot confirm" ;;
  esac
  case "$PV" in
    *'`severity` to `minor`'*) ok "…severity is forced to minor" ;;
    *) bad "…must force prose severity to minor" ;;
  esac
  case "$PV" in
    *'at most **2**'*) ok "…and at most 2 survive" ;;
    *) bad "…must keep at most 2 prose findings" ;;
  esac
  case "$PV" in
    *length*) ok "…and a length complaint is refuted whatever it is labelled" ;;
    *) bad "…must refuse a length complaint wearing the prose label" ;;
  esac
else
  bad "review-verify has no refute rule for prose findings"
fi
want "review-verify exposes the prose flag in meta.findings" "$VERIFY" '"prose": false'

echo ""
echo "── the local-eval seam cannot reach production ──"
# REVIEW_OUT_DIR turns every GitHub write in post-review.sh into an artifact.
# That is exactly the shape of a change that could silently suppress a real
# review, so it gets three independent barriers. Two of them are asserted here;
# the third is structural (workflow_call cannot inject arbitrary env into a
# called workflow, so a consumer cannot set it even deliberately).
never "the seam is named nowhere in the reusable workflow" "$WORKFLOW" \
  'REVIEW_OUT_DIR'
never "…nor in the composite action" "$ROOT/action.yml" \
  'REVIEW_OUT_DIR'
want "post-review.sh refuses the seam under GITHUB_ACTIONS" "$POSTER" \
  'GITHUB_ACTIONS.*\}" = "true"'
want "…and says so as an ::error:: before exiting 1" "$POSTER" \
  '::error::REVIEW_OUT_DIR is a local-eval seam and must never be set in CI'

echo ""
echo "── build-spec route (a) does not trust the git diff alone ──"
# `merge-base origin/<base> HEAD` returns HEAD on an already-merged PR, so the
# git diff is empty and the strongest spec signal vanishes with no warning. The
# reconciliation against GitHub's own file list is what closes that, and the
# `gh pr view` fallback is what makes it work when pr.json predates the change.
want "route (a) reads the PR file list out of pr.json" "$BUILDSPEC" \
  '\(\.files // \[\]\)\[\] \| \.path'
want "…falls back to gh pr view --json files when pr.json has none" "$BUILDSPEC" \
  'gh pr view "\$PR_NUMBER".*--json files'
want "…and warns when the two disagree" "$BUILDSPEC" \
  '::warning::git reports no markdown changed'
want "the orchestrator fetches files in turn 1, so it costs no extra call" "$ORCH" \
  'gh pr view .*--json .*,files'

echo ""
# Regression pin. The channel was deliberately NOT paid for by making the
# consumer's own docs rules reachable: one corpus PR EDITS .claude/rules/docs.md
# in the same diff that rule would judge, and only 1 of 14 findings needed it.
want "build-spec still excludes .claude/** from spec assembly" "$BUILDSPEC" \
  '\.claude/\*\|\*/\.claude/\*'

# ── the auth recipe must survive an awk without interval support ────────────
# The review job runs on a self-hosted image whose awk is mawk. Older mawk does
# not implement POSIX interval expressions and treats `{` literally, so
# `/^#{2,3} /` matched NOTHING and /tmp/auth-recipe.md came out 0 bytes — the
# functional tester never received the auth recipe on that fleet, and reported
# "AUTH_READY=false and /tmp/auth-recipe.md is empty" instead. Measured on
# seaters run 33257534059 against a config that really did have `### Auth`:
# 2901 bytes extracted with interval support, 0 without.
echo ""
echo "── the auth-recipe extractor is portable ──"
EXTRACTOR=$(grep -F "auth-recipe.md" "$ROOT/skills/review-orchestrator.md" | head -1)
case "$EXTRACTOR" in
  *'{'[0-9]*','[0-9]*'}'*)
    echo "FAIL: the extractor uses an interval expression — mawk on the review fleet ignores it"
    fail=$((fail + 1)) ;;
  *) echo "OK:   no interval expression in the extractor" ;;
esac

# Behavioural: it must still capture the section it is meant to capture.
CFG=$(mktemp)
cat > "$CFG" <<'CFGEOF'
## Build prep
irrelevant
### Auth
the recipe body
```bash
echo hi
```
### Known dev-env quirks
a quirk
## Something else
not part of the recipe
CFGEOF
PROG=$(printf '%s' "$EXTRACTOR" | sed -e "s/^[^']*'//" -e "s/'.*$//")
GOT=$(awk "$PROG" "$CFG")
case "$GOT" in
  *"the recipe body"*) echo "OK:   it captures the Auth section" ;;
  *) echo "FAIL: the extractor did not capture the Auth section"; fail=$((fail + 1)) ;;
esac
case "$GOT" in
  *"a quirk"*) echo "OK:   …and the dev-env quirks section" ;;
  *) echo "FAIL: the extractor dropped the quirks section"; fail=$((fail + 1)) ;;
esac
case "$GOT" in
  *"not part of the recipe"*)
    echo "FAIL: the extractor leaked a section it should have ended at"; fail=$((fail + 1)) ;;
  *) echo "OK:   …and stops at the next section" ;;
esac
rm -f "$CFG"

# ── the turn-1 dev-env wait: gated, clamped, and still a real wait ──────────
# Three measured failures, one block:
#   * The wait was UNCONDITIONAL, but the workflow step that creates
#     /tmp/dev-env/rc is not. On a code-only review that step is skipped, so the
#     loop spun to its full timeout waiting for a file nothing would write —
#     Panenco/qiv run 33298278779: ~600s of a 1185s job, 49% of the wall clock.
#   * The timeout came straight from the caller, and qiv passes 900. The tool
#     killed the call (exit 143) and the WHOLE block's stdout was lost: no
#     DEV_ENV_RC, no DEADLINE_EPOCH.
#   * The clamp that answered that assumed a fixed 600s ceiling. It is not
#     fixed: the Bash tool's timeout is a PER-CALL argument, 120000ms by
#     default and 600000ms at most, and Panenco/qiv run 33305382018 was killed
#     at "2m 0s" with exactly the same loss. No clamp can promise survival, so
#     the wait is now its own tool call and DEADLINE_EPOCH is emitted by the
#     block that never blocks — see "turn 1 survives a killed wait" below.
# So this section EXECUTES the shipped blocks (paths repointed at a temp dir)
# instead of grepping them.
echo ""
echo "── the turn-1 dev-env wait is gated and clamped ──"
DEVROOT=$(mktemp -d)
DEVENV="$DEVROOT/dev-env"
SNIP="$DEVROOT/wait.sh"
awk '/^# The dev-env boots in the background/{p=1} p{print} p&&/^echo "DEADLINE_EPOCH=/{exit}' \
  "$ORCH" | sed "s#/tmp/dev-env#$DEVENV#g" > "$SNIP"
if grep -q 'while ' "$SNIP" && grep -q '^echo "DEADLINE_EPOCH=' "$SNIP" && grep -q "$DEVENV" "$SNIP"; then
  ok "extracted the orchestrator's turn-1 dev-env block"
else
  bad "could not extract the turn-1 dev-env block from review-orchestrator.md"
fi

OUT=""; ELAPSED=0
run_wait() { # run_wait <RUN_FUNCTIONAL> <DEV_ENV_TIMEOUT_SECONDS>
  local t0 t1
  t0=$(date +%s)
  OUT=$(RUN_FUNCTIONAL="$1" DEV_ENV_TIMEOUT_SECONDS="$2" FUNCTIONAL_BUDGET_SECONDS=480 \
        bash "$SNIP" 2>&1)
  t1=$(date +%s)
  ELAPSED=$(( t1 - t0 ))
}
# NOTE: a here-string, not `printf | grep -q`. Under `set -o pipefail` grep -q
# exits on the first match, printf takes SIGPIPE, and the pipeline returns 141 —
# an assertion that fails at random.
has() { grep -qiE "$1" <<<"$OUT"; }

# (a) code-only review: the pre-start step was skipped, so nothing exists at all.
rm -rf "$DEVENV"
run_wait false 900
if [ "$ELAPSED" -lt 10 ]; then ok "a code-only run does not wait at all (${ELAPSED}s)"
else bad "a code-only run still waited ${ELAPSED}s"; fi
has '^DEV_ENV_WAIT=0$'   && ok "…and says so: DEV_ENV_WAIT=0"          || bad "…DEV_ENV_WAIT was not 0"
has '^WEB_READY=false$'  && ok "…still emits WEB_READY=false"          || bad "…did not emit WEB_READY=false"
has '^DEADLINE_EPOCH=[0-9]+$' && ok "…still emits DEADLINE_EPOCH"      || bad "…did not emit DEADLINE_EPOCH"
if has '^DEV_ENV_RC=timeout$'; then bad "…but DEV_ENV_RC lies: nothing timed out, nothing was started"
else ok "…and DEV_ENV_RC is honest about never having started"; fi

# (b) functional asked for, but the consumer ships no dev-start.sh — the step is
# skipped just the same, so the marker is the signal, not RUN_FUNCTIONAL alone.
mkdir -p "$DEVENV"
run_wait true 900
if [ "$ELAPSED" -lt 10 ] && has '^DEV_ENV_WAIT=0$'; then
  ok "RUN_FUNCTIONAL=true with no bring-up marker still does not wait"
else
  bad "RUN_FUNCTIONAL=true with no marker waited ${ELAPSED}s (DEV_ENV_WAIT not 0)"
fi

# (c) a real bring-up that already finished: the clamp must bind on the caller's
# 900 and the outputs must come through.
date +%s > "$DEVENV/started"
echo 0 > "$DEVENV/rc"
printf 'web_ready=true\nweb_url=http://127.0.0.1:3000\n' > "$DEVENV/outputs"
run_wait true 900
has '^DEV_ENV_WAIT=540$' && ok "a 900s caller value is clamped to 540" || bad "900 was not clamped to 540"
has '^web_ready=true$'   && ok "…and the dev-env outputs still come through" || bad "…dev-env outputs were dropped"
has '^DEV_ENV_RC=0$'     && ok "…and DEV_ENV_RC reports the real rc"         || bad "…DEV_ENV_RC did not report rc=0"

# (d) a value under the cap is the caller's, not the cap's.
run_wait true 120
has '^DEV_ENV_WAIT=120$' && ok "a value under the cap is honoured as passed" || bad "120 was not honoured"

# (e) junk from a caller must not become an unbounded (or zero) wait.
run_wait true "15 minutes"
has '^DEV_ENV_WAIT=360$' && ok "a non-numeric timeout falls back to 360" || bad "a non-numeric timeout did not fall back to 360"

# (f) THE WAIT MUST STILL WAIT. This is the regression the gate could cause: a
# bare `cat` raced the background bring-up and ruled the tester ineligible on
# every consumer. rc lands 2s in; the block must still be there to see it.
rm -f "$DEVENV/rc"
( sleep 2; echo 0 > "$DEVENV/rc" ) &
run_wait true 60
if [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 30 ] && has '^DEV_ENV_RC=0$'; then
  ok "the wait still waits for a bring-up in flight (${ELAPSED}s, rc seen)"
else
  bad "the wait did not pick up an rc that landed 2s in (${ELAPSED}s)"
fi
wait 2>/dev/null

# (g) and a bring-up that never finishes is still reported as a timeout.
rm -f "$DEVENV/rc"
run_wait true 3
has '^DEV_ENV_RC=timeout$' && ok "a bring-up that never finishes still reads as timeout" || bad "a never-finishing bring-up did not report timeout"

# The clamp is a courtesy, not the guarantee (the ceiling is per-call and as low
# as 120s) — but it still has to sit in the band that is defensible at both ends:
# at most 540 so a 600s call has room to print its tail, and never below 360,
# because real bring-up measures 291-305s and a shorter wait re-creates the
# original bug — the tester ruled ineligible on every consumer.
CAP=$(sed -n 's/^\[ "\$w" -gt \([0-9]*\) \].*/\1/p' "$SNIP" | head -1)
if [ -n "$CAP" ] && [ "$CAP" -le 540 ] && [ "$CAP" -ge 360 ]; then
  ok "the clamp is ${CAP}s — under a 600s call's ceiling and above a real 291-305s bring-up"
else
  bad "the clamp is '${CAP:-missing}' — it must be between 360 and 540"
fi

# ── turn 1 survives a killed wait ──────────────────────────────────────────
# THE BUG THIS PINS. Panenco/qiv run 33305382018 ended the turn-1 tool result
# with "Exit code 143 / Command timed out after 2m 0s". The kill threw away the
# block's stdout from the point of the kill, so WEB_READY, DEV_ENV_RC and
# DEADLINE_EPOCH never reached the orchestrator — and DEADLINE_EPOCH is the
# functional tester's hard wall-clock stop, handed to it in its Task prompt. A
# tester dispatched without a real deadline, or an orchestrator inventing one,
# is a correctness failure, not a slow run.
#
# The clamp shipped in #141 cannot fix this: the ceiling is a PER-CALL argument
# (120000ms default, 600000ms max), so it is 120s on any call that does not ask
# for more, and no clamp value survives that. The fix is structural — turn 1 is
# two Bash calls in one response, and everything that does not depend on the
# wait is printed by the block that never waits.
echo ""
echo "── turn 1 survives a killed wait ──"

# The nth ```bash fence inside the "## Turn 1" section.
turn1_block() {
  awk -v want="$1" '
    /^## Turn 1/ { s = 1; next }
    s && /^## /  { exit }
    s && /^```bash$/ { n++; if (n == want) inb = 1; next }
    s && /^```$/ { if (inb) exit; next }
    s && inb { print }
  ' "$ORCH"
}
NBLOCKS=$(awk '
  /^## Turn 1/ { s = 1; next }
  s && /^## /  { exit }
  s && /^```bash$/ { n++ }
  END { print n + 0 }
' "$ORCH")
if [ "$NBLOCKS" = "2" ]; then
  ok "turn 1 ships exactly two Bash blocks"
else
  bad "turn 1 ships $NBLOCKS Bash block(s) — the wait must be its own call, so a kill costs only the wait"
fi
want "…and the heading says so, so the contract is honest" "$ORCH" \
  '^## Turn 1 .*two Bash calls'
want "…both issued in ONE response, so the split costs no extra turn" "$ORCH" \
  'both blocks below in the same response'
# The wait genuinely needs more than the 120s default: bring-up measures
# 291-305s. Without an explicit per-call timeout the wait is killed on every
# consumer, which IS the original ineligibility bug.
want "…and the wait call is told to ask for the ceiling it needs" "$ORCH" \
  'timeout: 600000'

A1RAW="$DEVROOT/turn1a.raw"
turn1_block 1 > "$A1RAW"
if [ -s "$A1RAW" ] && grep -q '^echo "DEADLINE_EPOCH=' "$A1RAW"; then
  ok "the first block emits DEADLINE_EPOCH"
else
  bad "the first turn-1 block does not emit DEADLINE_EPOCH — a killed wait would take it"
fi
# …and it must be unable to block, or "it emits it" means nothing.
if grep -qE '^(while |.*[^a-z]sleep )' "$A1RAW" || grep -q '/tmp/dev-env' "$A1RAW"; then
  bad "the first turn-1 block waits on the dev-env — then a kill can still take DEADLINE_EPOCH"
else
  ok "…and nothing in it sleeps, polls, or touches /tmp/dev-env"
fi

# Behavioural, not a grep: run the shipped block with gh and build-spec.sh
# stubbed and every /tmp path repointed, and read what actually comes out.
A1DIR="$DEVROOT/a1"
mkdir -p "$A1DIR/tmp" "$A1DIR/bin" "$A1DIR/scripts"
printf '#!/bin/sh\nprintf "{}\\n"\n' > "$A1DIR/bin/gh"
printf '#!/bin/sh\nexit 0\n'        > "$A1DIR/scripts/build-spec.sh"
chmod +x "$A1DIR/bin/gh" "$A1DIR/scripts/build-spec.sh"
sed "s#/tmp/#$A1DIR/tmp/#g" "$A1RAW" > "$A1DIR/turn1a.sh"
T0=$(date +%s)
A1OUT=$(cd "$A1DIR" && PATH="$A1DIR/bin:$PATH" CLAUDE_REVIEW_SCRIPTS="$A1DIR/scripts" \
        PR_NUMBER=1 RUN_FUNCTIONAL=true FUNCTIONAL_BUDGET_SECONDS=480 \
        bash "$A1DIR/turn1a.sh" 2>&1)
T1=$(date +%s)
if grep -qE '^DEADLINE_EPOCH=[0-9]+$' <<<"$A1OUT"; then
  ok "running it really prints DEADLINE_EPOCH=<epoch>"
else
  bad "running the first turn-1 block printed no DEADLINE_EPOCH"
fi
if [ $(( T1 - T0 )) -lt 10 ]; then
  ok "…in $(( T1 - T0 ))s, so no tool ceiling can reach it"
else
  bad "the first turn-1 block took $(( T1 - T0 ))s — it is not the non-blocking half"
fi

# THE KILL ITSELF. Put the wait block in a real bring-up wait and SIGKILL it
# mid-loop, exactly as the tool does at its ceiling. Its own tail is lost — that
# is the point — and the deadline the orchestrator holds is the one block 1a
# already delivered above.
rm -rf "$DEVENV"
mkdir -p "$DEVENV"
date +%s > "$DEVENV/started"
KOUT="$DEVROOT/killed.out"
RUN_FUNCTIONAL=true DEV_ENV_TIMEOUT_SECONDS=900 FUNCTIONAL_BUDGET_SECONDS=480 \
  bash "$SNIP" > "$KOUT" 2>&1 &
KPID=$!
sleep 3
kill -9 "$KPID" 2>/dev/null
wait "$KPID" 2>/dev/null
if grep -q '^DEV_ENV_WAIT=540$' "$KOUT"; then
  ok "the wait block was really mid-wait when it was killed"
else
  bad "could not get the wait block into a wait to kill it"
fi
if grep -q '^DEADLINE_EPOCH=' "$KOUT"; then
  bad "the killed wait somehow still printed its tail — this case is not testing the kill"
else
  ok "…and the kill did take its tail, DEADLINE_EPOCH included"
fi
if grep -qE '^DEADLINE_EPOCH=[0-9]+$' <<<"$A1OUT"; then
  ok "…yet the orchestrator still holds a real DEADLINE_EPOCH, from the block that never waits"
else
  bad "a killed wait leaves the orchestrator with no DEADLINE_EPOCH at all"
fi
# And the degraded path must be spelled out, or the orchestrator stalls or
# invents a deadline instead.
want "a lost wait degrades to WEB_READY=false, never to a stall" "$ORCH" \
  'came back killed, empty or truncated'
rm -rf "$DEVROOT"

# ── the marker the gate depends on is actually produced ────────────────────
echo ""
echo "── the workflow produces the bring-up marker, and no stale one ──"
step_body() { # step_body <line number of the "- name:" line> → that step only
  awk -v s="$1" 'NR>s{ if ($0 ~ /^      - name:/) exit; print }' "$WORKFLOW"
}
PRE_LN=$(grep -n 'name: Pre-start dev environment' "$WORKFLOW" | head -1 | cut -d: -f1)
CLR_LN=$(grep -n 'name: Clear stale dev-env state' "$WORKFLOW" | head -1 | cut -d: -f1)
PRE_BODY=$(step_body "${PRE_LN:-0}")
case "$PRE_BODY" in
  *"date +%s > /tmp/dev-env/started"*) ok "the pre-start step writes /tmp/dev-env/started" ;;
  *) bad "the pre-start step does not write the marker the orchestrator gates on" ;;
esac
if [ -n "$CLR_LN" ] && [ -n "$PRE_LN" ] && [ "$CLR_LN" -lt "$PRE_LN" ]; then
  ok "…and stale dev-env state is cleared before it, so an absent marker means this run"
else
  bad "no 'Clear stale dev-env state' step before the pre-start step — a reused runner's marker would be trusted"
fi
CLR_BODY=$(step_body "${CLR_LN:-0}")
case "$CLR_BODY" in
  *"rm -rf /tmp/dev-env"*) ok "…and it really removes /tmp/dev-env" ;;
  *) bad "the clear step does not remove /tmp/dev-env" ;;
esac
# It must NOT inherit the pre-start step's own conditions, or it would only ever
# run on the runs that recreate the directory anyway.
case "$CLR_BODY" in
  *functional*|*needs_build*) bad "the clear step is gated on the functional/build conditions — it would never clear a stale marker" ;;
  *) ok "…on every proceeding run, not only the ones that start a dev-env" ;;
esac

# ── the orchestrator's model is plumbing-grade, and it does not cascade ────
# The top-level session makes ~7-12 API calls (a Read, one Bash, the Task
# dispatches, one jq) and writes no review prose — 7-19% of a run's spend at
# Opus rates. Every reviewing pass keeps its own model, pinned in the frontmatter
# the install step envsubst's, so `--model` here reaches nothing else.
echo ""
echo "── the orchestrator session runs the cheap model, and it does not cascade ──"
if grep -F -q -- '--model ${{ inputs.model_orchestrator }}' "$WORKFLOW"; then
  ok "the orchestrate step runs inputs.model_orchestrator"
else
  bad "the orchestrate step does not run inputs.model_orchestrator"
fi
if grep -F -q -- '--model ${{ inputs.model_high }}' "$WORKFLOW"; then
  bad "the orchestrate step still runs the REVIEWING model for pure plumbing"
else
  ok "…not the reviewing model"
fi
ORCH_DEFAULT=$(awk '/^      model_orchestrator:/{p=1;next} p&&/^        default:/{gsub(/^ *default: *"?|"$/,"");print;exit} p&&/^      [a-z_]+:/{exit}' "$WORKFLOW")
case "$ORCH_DEFAULT" in
  claude-sonnet-*|claude-haiku-*) ok "model_orchestrator defaults to a cheap model ($ORCH_DEFAULT)" ;;
  "") bad "model_orchestrator has no default — callers would get an empty --model" ;;
  *) bad "model_orchestrator defaults to '$ORCH_DEFAULT', which is not a cheap model" ;;
esac

# THE CASCADE CHECK. Every subagent must pin its own model to an env var the
# install step fills from an input that is NOT model_orchestrator. If any agent
# file stopped pinning one, it would silently inherit this session's Sonnet —
# a quality regression, not a saving.
INSTALL_LN=$(grep -n 'name: Install review subagents' "$WORKFLOW" | head -1 | cut -d: -f1)
INSTALL_BODY=$(step_body "${INSTALL_LN:-0}")
for af in "$ROOT"/agents/*.md; do
  an=$(basename "$af" .md)
  mv_=$(sed -n '/^---$/,/^---$/p' "$af" | sed -n 's/^model:[[:space:]]*//p' | head -1)
  case "$mv_" in
    '${MODEL_HIGH}'|'${MODEL_FUNCTIONAL}'|'${MODEL_STANDARD}') ;;
    '') bad "$an pins no model — it would inherit the orchestrator's cheap session model"
        continue ;;
    *)  bad "$an pins '$mv_', which is not one of the reviewing model vars"
        continue ;;
  esac
  vn=${mv_#'${'}; vn=${vn%'}'}
  in_=$(printf '%s' "$vn" | tr 'A-Z' 'a-z')          # MODEL_HIGH -> model_high
  if grep -F -q "$vn: \${{ inputs.$in_ }}" <<<"$INSTALL_BODY" \
     && grep -F -q "\$$vn" <<<"$INSTALL_BODY"; then
    ok "$an pins \${$vn}, filled from inputs.$in_ — the orchestrator's model cannot reach it"
  else
    bad "$an pins \${$vn} but the install step does not fill it from inputs.$in_"
  fi
done
# Belt and braces: the orchestrator must not be told to hand its own model down.
want "the orchestrator is told never to pass its own model to a subagent" "$ORCH" \
  'never the model you yourself are running on'
never "…and no longer names a specific model id as the one to pass" "$ORCH" \
  'exact model id from env \(`claude-opus-5`\)'

# The local sweep must measure the cost production actually pays.
LOCAL="$ROOT/scripts/review-local.sh"
want "review-local runs the orchestrator on its own (cheap) model" "$LOCAL" \
  '\-\-model "\$ORCH_MODEL"'
want "…defaulting to Sonnet, like the workflow" "$LOCAL" \
  'ORCH_MODEL="\$\{EVAL_ORCH_MODEL:-claude-sonnet-5\}"'
want "…while the subagents keep EVAL_MODEL" "$LOCAL" \
  'MODEL_HIGH="\$MODEL"'

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All pipeline contract tests passed."
  exit 0
else
  echo "$fail pipeline contract test(s) failed."
  exit 1
fi
