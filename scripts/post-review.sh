#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): critical steps carry explicit guards instead.

# post-review.sh — render /tmp/review.json into the one review this PR gets, post it,
# and set the check.
#
# v4 artifact contract (written by review-verify, copied through verbatim by the
# orchestrator):
#   { "verdict":  "APPROVE" | "COMMENT" | "REQUEST_CHANGES",
#     "body":     markdown carrying {{LINK:<path>[:<line>]}} placeholders and NO footer,
#     "comments": [ { "path", "line", "side", "body" } ],
#     "meta":     { "findings": [...], "human_review": [...], ... } }
# Thread resolution, replies to other bots and multi-line comment ranges are gone:
# the 2-call pipeline produces none of them, and their absence is normal.
#
# THIS SCRIPT OWNS THE BUDGETS. The models are told to hold them; historically they
# did not, so they are enforced here as a safety net:
#   body <= 1200 BYTES measured PRE-EXPANSION, with {{LINK:path:line}} counted as
#     `path:line` — exactly the arithmetic review-verify.md hands the model. An
#     expanded link costs ~130 bytes more (64-hex sha + URL + markdown), so
#     enforcing the cap after expansion truncated away whole findings from a body
#     the model had rendered perfectly within budget. Truncate first, expand after.
#     Cut on a line boundary; hard-cut mid-line when not even one line fits.
#   inline comments <= 5, critical/major first, each <= 700 BYTES (jq `length` is
#     codepoints, so a body of accented text measured ~half its real size).
# It also owns every GitHub URL: the models emit placeholders, never links.
#
# THIS SCRIPT ALSO OWNS THE INLINE-XOR-BODY RULE. review-verify.md tells the
# model each finding appears once — inline OR as a `### Findings` bullet. It
# does not hold (observed: a review that listed both findings in the body AND
# posted the same two inline). So it is enforced here: once the final `kept`
# set of inline comments is known, any `### Findings` bullet that matches a kept
# comment on path+line OR on path+title is deleted and the section header
# renumbered. Both keys are needed: review-verify is told to re-anchor a wrong
# line ("Wrong anchor -> fix it from your Read"), which moves the comment off the
# bullet's line and defeats path:line alone; and two files can carry the same
# title, which is why title alone is never enough. The match is ONE-TO-ONE: each
# kept comment can strip at most one bullet, because the invariant is that a
# SPECIFIC comment is carrying that finding — two same-titled bullets in one file
# with only one comment between them must not both vanish. Stripping runs BEFORE
# the budget is measured, so the freed bytes go to the content that is left.
#
# NOTHING IS SILENTLY DROPPED. A comment that cannot be posted inline (anchored
# outside a diff hunk, or past the 5-comment cap) becomes a body bullet under
# `### Also flagged` — under v4's inline-XOR-body rule a dropped comment would
# otherwise erase the finding from the review entirely. Which is why the strip
# matches against `kept` and never against the model's original comment list: a
# bullet for a DROPPED comment is the fallback and must survive.
#
# Exit semantics: 0 = a review reached the PR (REQUEST_CHANGES included — the
# blocking signal is the PR review, not the check color). 1 = pipeline failure
# (no usable orchestrator output, or the POST to GitHub failed).
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, REVIEW_BOT_USER
# Optional env: HEAD_SHA, GITHUB_STEP_SUMMARY, GITHUB_SERVER_URL, GITHUB_RUN_ID,
#               REVIEW_JSON, ORCH_LOG, JOB_START, SPEC_STATUS, REVIEW_BODY_MAX,
#               REVIEW_COMMENT_MAX, REVIEW_COMMENT_LIMIT, ROUND,
#               PRIOR_FINDINGS_JSON, REVIEW_STATE_MAX,
#               REVIEW_OUT_DIR (LOCAL-EVAL SEAM — see below)
#
# REVIEW_OUT_DIR IS THE DRY-RUN SEAM, AND IT IS A PATH, NOT A FLAG. This script
# is the only writer to GitHub on the review path, so one seam here covers the
# whole pipeline: set it and every GitHub WRITE becomes an artifact in that
# directory (verdict, body.md, comments.json, meta.json, summary.md and an
# actions.log naming each suppressed call). Reads still happen — hunk validation
# decides which comments go inline, so a dry run that skipped it would report a
# different review than the real one.
#
# A path, because truthiness is where this kind of switch goes wrong: `0`,
# `false`, `no` and `""` all have to mean the same thing to a boolean and never
# quite do. A path is set and meaningful, or unset and inert. Three independent
# barriers keep it out of production: `workflow_call` cannot inject arbitrary env
# into a called workflow; tests/pipeline_contract_test.sh asserts the name appears
# in neither pr-review.yml nor action.yml; and the check below refuses outright
# under GITHUB_ACTIONS. Loudly — a dry run that silently swallowed a real review
# is the only failure mode that matters here.

REPO="$GITHUB_REPOSITORY"
PR="$PR_NUMBER"
BOT="${REVIEW_BOT_USER:-github-actions[bot]}"
REVIEW_JSON="${REVIEW_JSON:-/tmp/review.json}"
ORCH_LOG="${ORCH_LOG:-/tmp/orchestrator-output.txt}"
JOB_START="${JOB_START:-/tmp/job-start}"
SPEC_STATUS="${SPEC_STATUS:-/tmp/spec-status}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
BODY_MAX="${REVIEW_BODY_MAX:-1800}"
COMMENT_MAX="${REVIEW_COMMENT_MAX:-700}"
COMMENT_LIMIT="${REVIEW_COMMENT_LIMIT:-10}"
ROUND="${ROUND:-1}"
PRIOR_FINDINGS_JSON="${PRIOR_FINDINGS_JSON:-/tmp/prior-findings.json}"
STATE_MAX="${REVIEW_STATE_MAX:-4000}"
# Shared byte-for-byte with prior-findings.sh: the two must never disagree about
# what "the same finding" is. Line is deliberately not part of the identity.
JQ_NORM='def norm: gsub("[\r\n]+"; " ") | sub("^[ \t]*\\*\\*(critical|major|minor)\\*\\*[ \t]*"; ""; "i") | gsub("[`*]"; "") | gsub("[ \t]+"; " ") | sub("^ "; "") | sub(" $"; "") | ascii_downcase | sub("[.!?]+$"; "");'
OUT_DIR="${REVIEW_OUT_DIR:-}"
if [ -n "$OUT_DIR" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::error::REVIEW_OUT_DIR is a local-eval seam and must never be set in CI"
  exit 1
fi
if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" || { echo "::error::could not create REVIEW_OUT_DIR '$OUT_DIR'"; exit 1; }
  : > "$OUT_DIR/actions.log"
  # There is no step summary locally, so the artifact IS the summary sink.
  SUMMARY="$OUT_DIR/summary.md"
  : > "$SUMMARY"
fi
# One line per GitHub call this run did not make — the record that makes a dry
# run auditable rather than merely quiet.
log_suppressed() { printf '%s\n' "$1" >> "$OUT_DIR/actions.log"; }
WORK=$(mktemp -d) || { echo "::error::mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Byte length — the budgets are compared against `wc -c`, and ${#var} counts
# CHARACTERS, so a body with one em dash would otherwise be measured short.
blen() { printf '%s' "$1" | wc -c | tr -d ' '; }

# A body guard.sh rendered without a model call. Matched on the FIRST LINE only:
# an unanchored grep also matches a JUDGED review that quotes a marker in a
# finding. One helper, two callers (4c and section 5), so they cannot drift.
is_skip_marked() {
  head -n1 "$WORK/body.md" 2>/dev/null \
    | grep -qE '^[[:space:]]*<!-- claude-review-(skipped|oversized) -->[[:space:]]*$'
}

# Crash banners can't be deleted (no review-delete API); PATCH them to a
# benign superseded form. The superseded marker shares no substring with the
# crash marker, so a superseded review is never re-matched. Matched on the
# body's FIRST LINE (where crash_exit stamps it), never with contains(): this
# function REWRITES the bodies it matches, so an unanchored match would clobber
# a real review that merely quotes the marker in a finding.
supersede_crash_banners() {
  local ids body
  ids=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT" '
        (add // [])
        | [.[] | select(.user.login == $bot
                        and (((.body // "") | split("\n") | (.[0] // "") | sub("\\s+$"; "")) == "<!-- claude-review-crash -->")) | .id]
        | .[]' 2>/dev/null || true)
  [ -z "$ids" ] && { echo "No prior crash banners to supersede."; return 0; }
  body=$'<!-- claude-review-superseded -->\n\n_Superseded by a newer Claude review run on this PR._'
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if [ -n "$OUT_DIR" ]; then
      log_suppressed "PATCH crash-banner $id"
      echo "Would supersede prior crash review #$id"
    elif gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id" -f body="$body" >/dev/null 2>&1; then
      echo "Superseded prior crash review #$id"
    else
      echo "::warning::Could not supersede crash review #$id"
    fi
  done <<< "$ids"
}

# crash_exit <context-message> — posts the most accurate banner it can + exit 1.
# Three kinds, in priority order:
#   quota       — agent returned rate_limit (re-run after reset / rotate token).
#   unreadable  — orchestrator output exists but is not usable JSON: the review
#                 likely RAN to completion and was lost in serialization, so a
#                 plain re-run usually recovers it. NOT "a human must review".
#   no-output   — no orchestrator artifact at all: a genuine crash.
crash_exit() {
  local context="$1" kind quota_hit=false reset_phrase="" crash_msg payload run_link=""
  if [ -f "$ORCH_LOG" ] && grep -qE 'hit your limit · resets|"error": *"rate_limit"' "$ORCH_LOG" 2>/dev/null; then
    quota_hit=true
    reset_phrase=$(grep -oE 'resets [^"\\]+' "$ORCH_LOG" 2>/dev/null | head -1 || true)
  fi
  if [ "$quota_hit" = "true" ]; then
    kind=quota
  elif [ -s "$REVIEW_JSON" ]; then
    kind=unreadable
  else
    kind=no-output
  fi
  run_link=$(run_url)

  case "$kind" in
    quota)
      if [ -n "$reset_phrase" ]; then
        echo "::error::Claude OAuth quota exhausted ($reset_phrase) — review agent returned rate_limit before producing output."
      else
        echo "::error::Claude OAuth quota exhausted (rate_limit returned, no reset window in the agent log) — review agent could not produce output."
      fi
      echo "::error::Re-run after the quota resets, or rotate CLAUDE_CODE_OAUTH_TOKEN to a token with available quota." ;;
    unreadable)
      echo "::error::Orchestrator output is present but unusable ($context). The review likely completed but its result was malformed — re-running the workflow usually recovers it." ;;
    no-output)
      echo "::error::$context"
      echo "::error::Check the 'Review: orchestrate' step log — common causes: OAuth token expired, network failure, max-turns limit hit, runner OOM." ;;
  esac

  if [ -n "${PR:-}" ] && [ -n "${REPO:-}" ]; then
    supersede_crash_banners
    crash_msg="<!-- claude-review-crash -->"$'\n\n'
    case "$kind" in
      quota)
        crash_msg+="> **Claude Review — quota exhausted** :hourglass:"$'\n'">"$'\n'
        if [ -n "$reset_phrase" ]; then
          crash_msg+="> The Claude OAuth token hit its limit ($reset_phrase)."$'\n'
        else
          crash_msg+="> The Claude OAuth token returned rate_limit (the agent log did not include a reset window)."$'\n'
        fi
        crash_msg+=">"$'\n'
        crash_msg+="> **Action required:** re-run the workflow after the quota resets, or rotate \`CLAUDE_CODE_OAUTH_TOKEN\` to a token with available quota. No code review was produced for this push." ;;
      unreadable)
        crash_msg+="> **Claude Review — result unreadable** :warning:"$'\n'">"$'\n'
        crash_msg+="> The review agent ran and produced output, but the result could not be parsed, so no review was posted. This is almost always a transient serialization slip, not a problem with your PR."$'\n'">"$'\n'
        crash_msg+="> **Action required:** re-run the workflow — it usually succeeds on retry. No human action is needed unless it recurs." ;;
      no-output)
        crash_msg+="> **Claude Review — incomplete** :warning:"$'\n'">"$'\n'
        crash_msg+="> The automated review agent stopped before producing any output. Common causes: max-turns budget exhausted, network failure, runner OOM."$'\n'">"$'\n'
        crash_msg+="> **Action required:** re-run the workflow — if it was transient this clears it. If it keeps failing, a human should review this PR and the run logs." ;;
    esac
    [ -n "$run_link" ] && crash_msg+=$'\n'">"$'\n'"> [Run logs]($run_link)"
    payload=$(jq -n --arg body "$crash_msg" '{event: "COMMENT", body: $body}')
    if [ -n "$OUT_DIR" ]; then
      log_suppressed "POST review COMMENT crash-banner ($kind)"
      printf '%s' "$crash_msg" > "$OUT_DIR/body.md"
      printf '%s\n' "COMMENT" > "$OUT_DIR/verdict"
    else
      gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - <<<"$payload" >/dev/null \
        || echo "::warning::Failed to post crash notification review"
    fi
  fi
  exit 1
}

run_url() {
  [ -n "${GITHUB_RUN_ID:-}" ] || return 0
  printf '%s/%s/actions/runs/%s' "$SERVER" "$REPO" "$GITHUB_RUN_ID"
}

# ── 1. Validate the orchestrator's single artifact ──────────────────────────
if [ ! -f "$REVIEW_JSON" ]; then
  crash_exit "$REVIEW_JSON not found — orchestrator did not write output."
fi
if ! jq -e 'type == "object"' "$REVIEW_JSON" >/dev/null 2>&1; then
  crash_exit "$REVIEW_JSON is not valid JSON."
fi
VERDICT=$(jq -r '.verdict // empty' "$REVIEW_JSON")
case "$VERDICT" in
  APPROVE|COMMENT|REQUEST_CHANGES) ;;
  *) crash_exit "$REVIEW_JSON has unknown verdict '${VERDICT:-<missing>}'." ;;
esac
jq -r '.body // ""' "$REVIEW_JSON" > "$WORK/body.raw" || crash_exit "could not extract review body from $REVIEW_JSON."
jq '(.comments // []) | map(select(type == "object"))' "$REVIEW_JSON" > "$WORK/comments.json" || crash_exit "could not extract comments from $REVIEW_JSON."

# A record, never a gate: ADR 0003 forbids one, and 76% of v3's REQUEST_CHANGES
# was gate-driven. It reaches the footer and the summary; the verdict never sees it.
INJECTION=$(jq -r '.meta.prompt_injection_detected // false' "$REVIEW_JSON" 2>/dev/null)

# ── 2. Footer ────────────────────────────────────────────────────────────────
# Built before the body is measured: it is part of the 1200 and is the last thing
# that can push the body over. Whatever of duration / cost / run link this run
# actually knows — never written by the model.
FOOTER_PARTS=()
if [ -f "$JOB_START" ]; then
  START=$(cat "$JOB_START" 2>/dev/null)
  case "$START" in
    ''|*[!0-9]*) ;;
    *) ELAPSED=$(( $(date +%s) - START ))
       [ "$ELAPSED" -ge 0 ] && FOOTER_PARTS+=( "$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s" ) ;;
  esac
fi
COST=$(grep -oE '"total_cost_usd"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' "$ORCH_LOG" 2>/dev/null \
        | grep -oE '[0-9]+(\.[0-9]+)?$' | sort -g | tail -1)
[ -n "$COST" ] && FOOTER_PARTS+=( "$(printf '$%.2f' "$COST")" )
[ "$INJECTION" = "true" ] && FOOTER_PARTS+=( "⚠ injection-shaped text in the PR input" )
RUN_LINK=$(run_url)
[ -n "$RUN_LINK" ] && FOOTER_PARTS+=( "[logs]($RUN_LINK)" )
FOOTER=""
if [ "${#FOOTER_PARTS[@]}" -gt 0 ]; then
  FOOTER=$'\n<sub>'
  for i in "${!FOOTER_PARTS[@]}"; do
    [ "$i" -gt 0 ] && FOOTER+=" · "
    FOOTER+="${FOOTER_PARTS[$i]}"
  done
  FOOTER+=$'</sub>\n'
fi

# ── 2b. "No spec resolved" ───────────────────────────────────────────────────
# build-spec.sh writes one token; only the two states where NOTHING specified
# this PR produce a line. A missing or unrecognised file emits nothing, so a
# partial run never invents a claim about the spec. It is a statement of fact
# appended after the verdict is chosen — never an input to it.
SPEC_NOTICE=""
case "$(cat "$SPEC_STATUS" 2>/dev/null)" in
  context-only|none)
    SPEC_NOTICE=$'\n<sub>No spec resolved — reviewed on the diff alone. Link an issue, or commit the intent doc, to have the next review check against what was asked.</sub>\n' ;;
esac

# A dev-env that never came up is invisible otherwise: the reviewer asked for a
# functional pass, got a code review, and nothing said why. Deterministic here
# rather than in a prompt, for the same reason the spec notice is — the model
# cannot forget to mention it. `setup-dev-env.sh` used to promise this in a
# "setup-health section" that the v4 body no longer has.
DEV_ENV_NOTICE=""
if [ "${FUNCTIONAL_REQUESTED:-false}" = "true" ]; then
  DEV_ENV_RC=$(cat "${DEV_ENV_RC_FILE:-/tmp/dev-env/rc}" 2>/dev/null || echo "")
  if [ "$DEV_ENV_RC" != "0" ]; then
    why=$([ -z "$DEV_ENV_RC" ] && echo "did not finish starting in time" || echo "exited $DEV_ENV_RC")
    # One line, and the LAST error the bring-up printed — a whole log in a review
    # body is unreadable and would evict findings under the byte budget.
    tail=$(grep -aiE '^(error|fatal)|error:' "${DEV_ENV_LOG_FILE:-/tmp/dev-env/log}" 2>/dev/null | tail -1 | cut -c1-300)
    DEV_ENV_NOTICE=$'\n<sub>⚠ Functional pass requested but skipped — the dev environment '"$why"'. No browser test ran; this review is static only.'
    [ -n "$tail" ] && DEV_ENV_NOTICE+=" Last error: <code>${tail//</&lt;}</code>"
    DEV_ENV_NOTICE+=$' (full log: the run\'s <code>dev-env/log</code> artifact).</sub>\n'
  fi
fi

# ── 3. Inline comments: in-hunk only, deduped, capped, 700 bytes each ───────
# GitHub 422s the whole atomic POST if any comment line is outside a diff hunk,
# and GitHub omits `.patch` entirely for large files — so a critical finding in a
# big file can derive no valid line. Those comments, and everything past the cap,
# are NOT discarded: they come back as body bullets in section 4.
echo "::group::Inline comments"
if ! gh api --paginate "repos/$REPO/pulls/$PR/files" 2>/dev/null | jq -s 'add // []' > "$WORK/pr-files.json"; then
  echo '[]' > "$WORK/pr-files.json"
fi
# The FILE-tab sentinel is unambiguous: patch lines only start with @@/+/-/space/backslash.
jq -r '.[] | "FILE\t" + .filename, (.patch // "")' "$WORK/pr-files.json" > "$WORK/patches.txt"
awk '
  /^FILE\t/ { file=substr($0, index($0, "\t")+1); next }
  /^@@ / {
    lspec = $2; rspec = $3
    sub(/^-/, "", lspec); sub(/^\+/, "", rspec)
    n = split(lspec, lp, ","); lstart = lp[1] + 0; lcount = (n >= 2 ? lp[2] + 0 : 1)
    n = split(rspec, rp, ","); rstart = rp[1] + 0; rcount = (n >= 2 ? rp[2] + 0 : 1)
    for (i = lstart; i < lstart + lcount; i++) print file ":" i ":LEFT"
    for (i = rstart; i < rstart + rcount; i++) print file ":" i ":RIGHT"
  }
' "$WORK/patches.txt" | sort -u > "$WORK/valid-lines.txt"
[ -s "$WORK/valid-lines.txt" ] \
  || echo "::warning::Could not derive diff hunks from pulls/files — posting comments unvalidated."

# One pass: normalise, order by severity then the model's own order, split into
# the ones that get posted inline and the rest that fall back to body bullets.
# The cap is a brake on a runaway review, not a budget to spend: across the
# banked corpus no review has ever reached it.
#
# `clamp` measures BYTES (jq's `length` is codepoints — 900 `é` is 900 by that
# count and 1800 bytes on the wire). A ```suggestion fence the clamp cut through
# is DROPPED, not re-closed: re-closing yields a committable suggestion that
# silently deletes the tail of the replacement code.
jq --argjson limit "$COMMENT_LIMIT" --argjson cmax "$COMMENT_MAX" \
   --rawfile valid "$WORK/valid-lines.txt" '
  def sev:
    ((.severity // "") | ascii_downcase) as $f
    | if ($f | length) > 0 then $f
      elif ((.body // "") | test("^\\s*\\*\\*critical\\*\\*"; "i")) then "critical"
      elif ((.body // "") | test("^\\s*\\*\\*major\\*\\*"; "i")) then "major"
      elif ((.body // "") | test("^\\s*\\*\\*minor\\*\\*"; "i")) then "minor"
      else "" end;
  def rank: if . == "critical" then 0 elif . == "major" then 1 elif . == "minor" then 2 else 3 end;
  # A `**check**` comment is a human-review question, not a defect. It carries no
  # severity, so it already sorts behind every finding — under pressure the slots
  # go to defects and the questions fall back, which is the right way round. A
  # dropped one returns under the human-review heading, never under "Also flagged".
  def kind: if ((.body // "") | test("^\\s*\\*\\*check\\*\\*"; "i")) then "check" else "finding" end;
  def title:
    ((.body // "") | split("\n") | (.[0] // "")
     | sub("^\\s*\\*\\*[A-Za-z]+\\*\\*\\s*"; "") | .[:90] | sub("\\s+$"; ""))
    | if length == 0 then "flagged inline" else . end;
  # Longest codepoint prefix of $s that fits $max bytes. Starts at the byte
  # budget (bytes >= codepoints, always) and walks down; ASCII exits at once.
  def bcut($s; $max):
    if ($s | utf8bytelength) <= $max then $s
    else ({i: ([$max, ($s | length)] | min)}
          | until((($s[:.i]) | utf8bytelength) <= $max; .i = (.i - 1))
          | $s[:.i])
    end;
  def clamp($max):
    (if utf8bytelength <= $max then . else (bcut(.; $max - 3)) + "…" end)
    # An odd number of ``` fences means the closer is gone: drop the opener and
    # everything after it rather than re-closing a half-written suggestion.
    | if (((. / "```") | length) % 2 == 0)
      then (((. / "```") | .[:-1] | join("```")) | sub("\\s+$"; "")) + "…"
      else . end;
  ($valid | split("\n") | map(select(length > 0))) as $lines
  | ($lines | length > 0) as $validated
  | map(select((.path // "") != "" and .line != null))
  | map(.line = ((.line | tostring | tonumber?) // 0))
  | map(select(.line > 0))
  | to_entries
  | map(.value + {_i: .key, _r: (.value | sev | rank)})
  | unique_by([.path, .line, .body])
  | sort_by(._r, ._i)
  | map(. as $c | $c + {_inhunk:
      (if $validated
       then ($lines | any(. == ($c.path + ":" + ($c.line | tostring) + ":" + ($c.side // "RIGHT"))))
       else true end)})
  | ([.[] | select(._inhunk)]) as $in
  | ([.[] | select(._inhunk | not)]) as $out
  | { kept: ($in[:$limit] | map({path, line, side: (.side // "RIGHT"), body: ((.body // "") | clamp($cmax))})),
      dropped: ((($in[$limit:]) + $out)
                | sort_by(._r, ._i)
                | map({path, line, severity: sev, title: title, kind: kind,
                       reason: (if ._inhunk then "over the inline cap" else "outside a diff hunk" end)})) }
' "$WORK/comments.json" > "$WORK/split.json" \
  || { echo "::warning::Could not process inline comments — posting the body alone."
       jq -n '{kept: [], dropped: []}' > "$WORK/split.json"; }

jq '.kept' "$WORK/split.json" > "$WORK/comments.json"
# What the body-bullet strip in section 4 matches against: ONE record per comment
# that will actually be posted inline — `path:line<TAB>**sev** title` (the body's
# first line). One record per COMMENT, not one per key, is what lets a match
# consume the whole comment: both of its keys are spent together, so it can never
# strip a second bullet. Derived from `kept`, post-hunk-filter, post-dedupe,
# post-cap: a comment that fell back to the body is NOT in here.
# Checks are EXCLUDED. A check may legitimately sit at the same `path:line` as a
# finding, and verify writes no body bullet for a check — so a check in this index
# could only ever strip a `### Findings` bullet belonging to a finding that is not
# posted inline, deleting it from the review entirely.
jq -r '.[] | select(((.body // "") | test("^\\s*\\*\\*check\\*\\*"; "i")) | not)
             | .path + ":" + (.line | tostring) + "\t"
             + ((.body // "") | split("\n") | (.[0] // ""))' \
  "$WORK/comments.json" > "$WORK/kept-keys.txt"
# Each dropped comment becomes a body bullet — the finding must reach the reader
# somewhere, and under the inline-XOR-body rule the body does not already list it.
jq -r '.dropped[] | select(.kind != "check")
       | "- " + (if .severity == "" then "" else "**" + .severity + "** " end)
         + "{{LINK:" + .path + ":" + (.line | tostring) + "}} — " + .title' \
  "$WORK/split.json" > "$WORK/fallback.md"
jq -r '.dropped[] | select(.kind == "check")
       | "- [ ] {{LINK:" + .path + ":" + (.line | tostring) + "}} — " + .title' \
  "$WORK/split.json" > "$WORK/fallback-checks.md"
DROPPED_COUNT=$(jq '.dropped | length' "$WORK/split.json")
if [ "${DROPPED_COUNT:-0}" -gt 0 ]; then
  jq -r '.dropped | group_by(.reason)[]
         | "::warning::" + (length | tostring) + " inline comment(s) " + .[0].reason
           + " — listed as body bullets instead."' "$WORK/split.json"
fi
echo "Inline comments: $(jq 'length' "$WORK/comments.json") (max $COMMENT_LIMIT, $COMMENT_MAX bytes each), $DROPPED_COUNT fell back to the body"
echo "::endgroup::"

# ── 4. Render the body: budget PRE-expansion, then expand {{LINK:...}} ──────
# The models emit placeholders because only this script knows repo + PR number.
# GitHub's per-file diff anchor is the sha256 of the raw path string, lowercase
# hex; the line suffix is `R<n>` (RIGHT side). Verified against a live PR — do
# not "fix" the format.
echo "::group::Render body"

# body.awk — one program, three modes, all over the PRE-EXPANSION body.
#   mlen(line) = bytes, with each {{LINK:x}} counted as `x` (the wrapper is
#   exactly 9 bytes: `{{LINK:` + `}}`), which is what the model was told to count.
#   mode=strip   → delete `### Findings` bullets already posted inline (matched
#                  on path+line OR path+title), renumber the header, drop
#                  sections left empty
#   mode=measure → the whole file's measured byte size
#   mode=fit     → the file truncated to `max` measured bytes
# prune() is shared by strip and fit: a `###` header whose every item is gone —
# stripped as a duplicate, or cut by the budget — is dropped with them. A
# dangling `### Findings (2)` above nothing reads as a rendering bug.
cat > "$WORK/budget.awk" <<'BUDGET_AWK'
function nph(s,   n) { n = 0; while (match(s, /\{\{LINK:[^{}]*\}\}/)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
function mlen(s) { return length(s) - 9 * nph(s) }
# The `path[:line]` inside a line's FIRST {{LINK:}}, or "" — the bullet's identity.
function phkey(s) { return (match(s, /\{\{LINK:[^{}]*\}\}/) ? substr(s, RSTART + 7, RLENGTH - 9) : "") }
# `path` of a phkey, with the `:<line>` suffix (if any) removed.
function bpath(s) { sub(/:[0-9]+$/, "", s); return s }
# Compare titles on their text alone: CR gone, whitespace runs collapsed, trimmed.
# Backticks, markdown and non-ASCII are left exactly as written — both sides are
# rendered from the same string, so byte equality is the point.
function norm(s) { gsub(/\r/, "", s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
# Title of an inline comment = its first line minus the leading `**severity**`.
function ctitle(s) { sub(/^[ \t]*\*\*[A-Za-z]+\*\*[ \t]*/, "", s); return norm(s) }
# Title of a `### Findings` bullet = everything after its first {{LINK:}} and the
# ` — ` separator. ONLY the first separator is consumed, so a title that itself
# contains an em dash survives whole.
function btitle(s,   r) {
  if (!match(s, /\{\{LINK:[^{}]*\}\}/)) return ""
  r = substr(s, RSTART + RLENGTH)
  sub(/^[ \t]*(—|–)[ \t]*/, "", r)
  return norm(r)
}
# Claim the first not-yet-used comment in a key's id list, or 0. Claiming marks
# the COMMENT used, so it is spent for both of its keys at once.
function claim(list,   m, a, i) {
  m = split(list, a, " ")
  for (i = 1; i <= m; i++) if (!used[a[i]]) { used[a[i]] = 1; return 1 }
  return 0
}
# A bullet duplicates a comment going inline when they agree on path AND line, or
# on path AND title. Neither key alone is safe: verify re-anchors comments off the
# bullet's line, and two paths can carry the same title. path:line is tried and
# consumed first — it is the stronger key — and only its miss falls through to
# the title. A bullet that claims nothing is a finding no comment is carrying,
# and it stays.
function isdup(key, ln,   p, t) {
  if (claim(lidx[key])) return 1
  p = bpath(key); t = btitle(ln)
  if (p == "" || t == "") return 0
  return claim(tidx[p SUBSEP t])
}
function hardcut(s, budget,   out, ml, ph, phm) {
  out = ""; ml = 0
  while (length(s) > 0) {
    ph = ""
    if (substr(s, 1, 7) == "{{LINK:" && match(s, /^\{\{LINK:[^{}]*\}\}/)) ph = substr(s, 1, RLENGTH)
    if (ph != "") {
      phm = length(ph) - 9
      if (ml + phm > budget) break
      out = out ph; ml += phm; s = substr(s, length(ph) + 1)
    } else {
      if (ml + 1 > budget) break
      out = out substr(s, 1, 1); ml++; s = substr(s, 2)
    }
  }
  return out
}
# Drop every `###` section left with no item, plus trailing blank lines.
# Operates on out[1..cnt] in place; returns the new count.
function prune(cnt,   i, j, has, m) {
  for (i = 1; i <= cnt; i++) del[i] = 0
  for (i = 1; i <= cnt; i++) {
    if (out[i] !~ /^[ \t]*###/) continue
    has = 0
    for (j = i + 1; j <= cnt && out[j] !~ /^[ \t]*###/; j++)
      if (out[j] !~ /^[ \t]*$/) { has = 1; break }
    if (has) continue
    for (j = i; j == i || (j <= cnt && out[j] !~ /^[ \t]*###/); j++) del[j] = 1
  }
  m = 0
  for (i = 1; i <= cnt; i++) if (!del[i]) out[++m] = out[i]
  while (m > 0 && out[m] ~ /^[ \t]*$/) m--
  return m
}
# Every kept comment gets one id, listed under its `path:line` key and under its
# `path`+title key. A bullet claims an ID, never a key.
BEGIN {
  nk = 0
  while (keysfile != "" && (getline kk < keysfile) > 0) {
    ki = index(kk, "\t")
    if (ki == 0) { ka = kk; kf = "" } else { ka = substr(kk, 1, ki - 1); kf = substr(kk, ki + 1) }
    if (ka == "") continue
    nk++
    lidx[ka] = lidx[ka] " " nk
    kp = bpath(ka); kt = ctitle(kf)
    if (kp != "" && kt != "") tidx[kp SUBSEP kt] = tidx[kp SUBSEP kt] " " nk
  }
}
{ line[NR] = $0; total += mlen($0) + 1 }
END {
  if (mode == "measure") { print total + 0; exit }
  n = 0; kept = 0
  if (mode == "strip") {
    # A `### Findings` bullet matching a comment being posted inline — same path
    # and line, or same path and title — is the duplicate. Only that section: a
    # `### What a human should review` item may legitimately point at the same
    # path:line as a finding, and `### Also flagged` (the bullets for comments
    # that could NOT be posted inline) is not appended until after this pass.
    insec = 0; skipping = 0; nh = 0
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (l ~ /^[ \t]*###/) {
        skipping = 0; insec = (l ~ /^[ \t]*###[ \t]*Findings/)
        out[++kept] = l
        if (insec) hdr[++nh] = kept
        continue
      }
      if (l ~ /^[ \t]*$/) { skipping = 0; out[++kept] = l; continue }
      if (insec && l ~ /^[ \t]*[-*][ \t]/) {
        k = phkey(l)
        if (k != "" && isdup(k, l)) { skipping = 1; continue }
        skipping = 0; out[++kept] = l; continue
      }
      if (skipping) continue          # a wrapped continuation line of a stripped bullet
      out[++kept] = l
    }
    for (h = 1; h <= nh; h++) {
      n = 0
      for (j = hdr[h] + 1; j <= kept && out[j] !~ /^[ \t]*###/; j++)
        if (out[j] ~ /^[ \t]*[-*][ \t]/) n++
      sub(/\([0-9]+\)/, "(" n ")", out[hdr[h]])
    }
    kept = prune(kept)
    for (i = 1; i <= kept; i++) print out[i]
    exit
  }
  for (i = 1; i <= NR; i++) {
    l = mlen(line[i]) + 1
    if (n + l > max) break
    out[++kept] = line[i]; n += l
  }
  # Not one line fit: cut mid-line rather than return an empty body.
  if (kept == 0 && NR > 0) {
    h = hardcut(line[1], max)
    if (length(h) > 0) out[++kept] = h
  }
  kept = prune(kept)
  for (i = 1; i <= kept; i++) print out[i]
}
BUDGET_AWK

# 4a. Inline-XOR-body, enforced. Runs against `kept` (the comments that are
# really going inline) and BEFORE the fallback append and the budget, so a
# stripped duplicate's bytes go to the content that survives.
if [ -s "$WORK/kept-keys.txt" ]; then
  BEFORE_LINES=$(grep -c '' "$WORK/body.raw")
  if LC_ALL=C awk -v mode=strip -v keysfile="$WORK/kept-keys.txt" \
       -f "$WORK/budget.awk" "$WORK/body.raw" > "$WORK/body.strip"; then
    mv "$WORK/body.strip" "$WORK/body.raw"
    AFTER_LINES=$(grep -c '' "$WORK/body.raw")
    if [ "$AFTER_LINES" -lt "$BEFORE_LINES" ]; then
      echo "Dropped $(( BEFORE_LINES - AFTER_LINES )) body line(s) duplicating an inline comment."
    fi
  else
    echo "::warning::Could not de-duplicate body bullets against inline comments — posting the body as rendered."
  fi
fi

# 4b. Anything that could not be posted inline comes back as a body bullet.
# review-verify renders no `### What a human should review` section any more —
# every check is an inline comment — so this is the only writer of that heading,
# and it appears only for the checks that could not be anchored.
if [ -s "$WORK/fallback-checks.md" ]; then
  { echo ""
    echo "### What a human should review"
    cat "$WORK/fallback-checks.md"
  } >> "$WORK/body.raw"
fi
if [ -s "$WORK/fallback.md" ]; then
  { echo ""
    echo "### Also flagged ($(grep -c '' "$WORK/fallback.md"))"
    cat "$WORK/fallback.md"
  } >> "$WORK/body.raw"
fi

TRUNC_MARKER=$'\n_…truncated to fit the review budget._\n'
AVAIL=$(( BODY_MAX - $(blen "$FOOTER") - $(blen "$SPEC_NOTICE") - $(blen "$DEV_ENV_NOTICE") ))
MEASURED=$(LC_ALL=C awk -v mode=measure -f "$WORK/budget.awk" "$WORK/body.raw")
if [ "${MEASURED:-0}" -gt "$AVAIL" ]; then
  echo "Body measures $MEASURED bytes pre-expansion, over the ${BODY_MAX}-byte budget — truncating."
  LC_ALL=C awk -v mode=fit -v max="$(( AVAIL - $(blen "$TRUNC_MARKER") ))" \
    -f "$WORK/budget.awk" "$WORK/body.raw" > "$WORK/body.trunc"
  mv "$WORK/body.trunc" "$WORK/body.raw"
  printf '%s' "$TRUNC_MARKER" >> "$WORK/body.raw"
fi

path_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}
# The cross-round finding id: sha256(path + "\n" + normalised title), first 8 hex.
finding_id() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-8
  else
    printf '%s\n%s' "$1" "$2" | shasum -a 256 | cut -c1-8
  fi
}
emit_state() {
  jq -c --argjson round "$ROUND" --argjson trunc "$TRUNCATED" \
    '{v: 1, round: $round, truncated: ($trunc == 1), findings: .}' \
    "$WORK/state-findings.json" > "$WORK/state.json"
}
state_bytes() { wc -c < "$WORK/state.json" | tr -d ' '; }
render_link() {
  local spec="$1" path lineno="" url
  path="${spec%:}"
  if [[ "$path" =~ ^(.+):([0-9]+)$ ]]; then
    path="${BASH_REMATCH[1]}"; lineno="${BASH_REMATCH[2]}"
  fi
  url="${SERVER}/${REPO}/pull/${PR}/files#diff-$(path_sha "$path")"
  [ -n "$lineno" ] && url="${url}R${lineno}"
  if [ -n "$lineno" ]; then printf '[%s:%s](%s)' "$path" "$lineno" "$url"
  else printf '[%s](%s)' "$path" "$url"; fi
}
: > "$WORK/body.md"
while IFS= read -r line || [ -n "$line" ]; do
  out=""
  while [[ "$line" =~ \{\{LINK:([^{}]*)\}\} ]]; do
    ph="${BASH_REMATCH[0]}"
    out+="${line%%"$ph"*}$(render_link "${BASH_REMATCH[1]}")"
    line="${line#*"$ph"}"
  done
  printf '%s%s\n' "$out" "$line" >> "$WORK/body.md"
done < "$WORK/body.raw"

printf '%s' "$FOOTER" >> "$WORK/body.md"
printf '%s' "$SPEC_NOTICE" >> "$WORK/body.md"
printf '%s' "$DEV_ENV_NOTICE" >> "$WORK/body.md"
echo "Body: $(wc -c < "$WORK/body.md") bytes expanded (budget $BODY_MAX pre-expansion)"
echo "::endgroup::"

# ── 4c. The round-2 state block ─────────────────────────────────────────────
# Everything above this line is for the human; this is for the next round.
#
# WHY IT EXISTS. Findings that get an inline slot are deleted from the body by
# 4a, and findings past the budget are deleted by the truncator above. The body
# was the only surface the next round read, so the two things it could not see
# were exactly the critical/major findings and the ones that overflowed. R1 files
# a critical, R2 sees a clean delta, APPROVE, section 5 dismisses the standing
# block, and a real bug is silently unblocked.
#
# WHY IT IS APPENDED HERE, after truncation, after expansion, after the footer:
# so the budget can never evict it and it can never evict content. It is not
# measured by budget.awk and carries no {{LINK:}} placeholders.
#
# WHY IT IS NOT BUILT FROM meta.findings ALONE: meta is model-written and can be
# empty or absent while three criticals post inline (tests (n) and (k5) both
# exercise that). The floor is what the poster ITSELF decided to post — `kept`
# and `dropped` — unioned with meta for the failure_scenario text.
#
# WHY IT IS SUPPRESSED FOR SKIP-MARKED BODIES: the guard's oversized block judged
# nothing (pr-review.yml writes /tmp/review.json from it). A state block there
# would tell the next round "round N found nothing".
echo "::group::Review state"
echo '[]' > "$WORK/carried.json"
if is_skip_marked; then
  echo "Skip-marked review (judged nothing) — no state block."
else
  jq -n --argjson round "$ROUND" \
     --slurpfile rj "$REVIEW_JSON" \
     --slurpfile kp "$WORK/comments.json" \
     --slurpfile sp "$WORK/split.json" '
    def csev:
      ((.body // "") | ascii_downcase)
      | if test("^\\s*\\*\\*critical\\*\\*") then "critical"
        elif test("^\\s*\\*\\*major\\*\\*") then "major"
        elif test("^\\s*\\*\\*minor\\*\\*") then "minor"
        else "" end;
    def num: ((. // 0) | tostring | tonumber?) // 0;
    (($rj[0].meta.findings // [])
     | map({p: (.path // ""), l: (.line | num), sev: ((.severity // "") | ascii_downcase),
            t: (.title // ""), fs: (.failure_scenario // ""),
            cf: (.carried_from // ""), inline: false, _o: 0}))
    + (($kp[0] // [])
       | map({p: (.path // ""), l: (.line | num), sev: csev,
              t: ((.body // "") | split("\n") | (.[0] // "")
                  | sub("^\\s*\\*\\*[A-Za-z]+\\*\\*\\s*"; "")),
              fs: (((.body // "") | split("\n\n")) | (.[1] // "")),
              cf: "", inline: true, _o: 1}))
    + ((($sp[0].dropped) // [])
       | map({p: (.path // ""), l: (.line | num), sev: (.severity // ""),
              t: (.title // ""), fs: "", cf: "", inline: false, _o: 2}))
    | map(select(.p != "" and .t != "")) | map(. + {r: $round})' > "$WORK/round.json" \
    || echo '[]' > "$WORK/round.json"

  : > "$WORK/round-ids.txt"
  jq -r "$JQ_NORM"'.[] | .p + "\t" + (.t | norm)' "$WORK/round.json" 2>/dev/null \
    | while IFS=$'\t' read -r rp rt; do finding_id "$rp" "$rt" >> "$WORK/round-ids.txt"; done

  PRIORS="$PRIOR_FINDINGS_JSON"
  if ! jq -e 'type == "array"' "$PRIOR_FINDINGS_JSON" >/dev/null 2>&1; then
    echo '[]' > "$WORK/no-priors.json"
    PRIORS="$WORK/no-priors.json"
  fi

  # `carried_from` is the re-wording escape valve: a finding the model kept under
  # new words adopts the old id and the round it was FIRST seen, so it counts once.
  jq --rawfile idsraw "$WORK/round-ids.txt" --slurpfile pri "$PRIORS" '
    ($idsraw | split("\n") | map(select(length > 0))) as $ids
    | ($pri[0] // []) as $prior
    | to_entries | map(.value + {id: ($ids[.key] // "")})
    | map(select(.id != ""))
    | map(. as $f
          | ($prior | map(select(.id == $f.cf)) | .[0]) as $old
          | if ($f.cf != "") and ($old != null)
            then $f + {id: $f.cf, r: ($old.r // $f.r)}
            else $f end)
    | map(del(.cf))
    | group_by(.id)
    | map(sort_by(._o)
          | (.[0]) as $b
          | $b + {fs: ([.[] | (.fs // "") | select(. != "")] | (.[0] // "")),
                  inline: ([.[] | .inline] | any),
                  l: ([.[] | (.l // 0) | select(. > 0)] | (.[0] // 0)),
                  r: ([.[] | .r] | min)})
    # ONE finding, two surfaces, two wordings. The id is path + normalised
    # TITLE, and the model routinely words the inline comment differently from
    # its own meta.findings entry ("A failed save fetch leaves the button
    # reading X" vs "Failed save fetch leaves the button on X"), so the same
    # defect landed in the state twice. Round 2 then had to account for a
    # finding that does not exist, and "if you cannot tell, it is unresolved"
    # makes a phantom STICKY — it carries forward every round after.
    # The XOR rule already guarantees a finding occupies exactly ONE surface,
    # so the same path+line+severity appearing on BOTH is that split, not two
    # defects. Merge only that exact signature: a group carrying an inline and
    # a non-inline entry. Anything else stays as many findings as it looks.
    | group_by([.p, (.l // 0), .sev])
    | map(if (length > 1) and ((.[0].l // 0) > 0)
             and (([.[] | .inline] | unique | length) == 2)
          then [ sort_by(._o)
                 | (.[0]) as $b
                 | $b + {fs: ([.[] | (.fs // "") | select(. != "")] | (.[0] // "")),
                         inline: true,
                         r: ([.[] | .r] | min)} ]
          else . end)
    | add // []
    | map(del(._o))' "$WORK/round.json" > "$WORK/this-round.json" \
    || echo '[]' > "$WORK/this-round.json"

  # Silence is not a bucket: a carried finding this round neither re-listed nor
  # accounted for in resolved_prior/refuted stays in the state and is announced.
  # It does NOT touch the verdict, the body, or the dismissal in section 5.
  jq --slurpfile rj "$REVIEW_JSON" --slurpfile this "$WORK/this-round.json" '
    ([($rj[0].meta.resolved_prior // [])[] | .id // empty]
     + [($rj[0].meta.refuted // [])[] | .id // empty]
     + [($this[0] // [])[] | .id]) as $seen
    | map(select((.id | IN($seen[])) | not))' "$PRIORS" > "$WORK/carried.json" \
    || echo '[]' > "$WORK/carried.json"

  jq -r '.[] | "::warning::Carried finding \(.id) (\(.sev // "?"), \(.p)) was neither re-listed nor resolved this round — kept in the review state."' \
    "$WORK/carried.json"

  # A literal `-->` inside a title would terminate the comment early and spill
  # JSON into the rendered review, so it is neutralised before anything is emitted.
  jq -s 'def srank: if .sev == "critical" then 0 elif .sev == "major" then 1 elif .sev == "minor" then 2 else 3 end;
         (.[0] + .[1]) | unique_by(.id) | sort_by([srank, .r])
         | walk(if type == "string" then gsub("-->"; "—>") else . end)' \
    "$WORK/this-round.json" "$WORK/carried.json" > "$WORK/state-findings.json" \
    || echo '[]' > "$WORK/state-findings.json"

  TRUNCATED=0
  emit_state
  # Degrade in the order that costs the next round least: the failure scenarios
  # of findings it can re-read from the inline comments, then the longest
  # scenarios, then the least severe findings (the list is severity-sorted).
  if [ "$(state_bytes)" -gt "$STATE_MAX" ]; then
    TRUNCATED=1
    jq 'map(if .inline then del(.fs) else . end)' "$WORK/state-findings.json" > "$WORK/sf.tmp" \
      && mv "$WORK/sf.tmp" "$WORK/state-findings.json"
    emit_state
  fi
  while [ "$(state_bytes)" -gt "$STATE_MAX" ]; do
    jq 'if ([.[] | select((.fs // "") != "")] | length) == 0 then empty
        else ([to_entries[] | select((.value.fs // "") != "")] | max_by(.value.fs | length) | .key) as $k
             | del(.[$k].fs) end' "$WORK/state-findings.json" > "$WORK/sf.tmp"
    [ -s "$WORK/sf.tmp" ] || break
    mv "$WORK/sf.tmp" "$WORK/state-findings.json"
    emit_state
  done
  while [ "$(state_bytes)" -gt "$STATE_MAX" ]; do
    jq 'if length <= 1 then empty else .[0:-1] end' "$WORK/state-findings.json" > "$WORK/sf.tmp"
    [ -s "$WORK/sf.tmp" ] || break
    mv "$WORK/sf.tmp" "$WORK/state-findings.json"
    emit_state
  done

  { printf '\n<!-- claude-review-state\n'
    cat "$WORK/state.json"
    printf -- '-->\n'
  } >> "$WORK/body.md"
  echo "Review state: $(jq '.findings | length' "$WORK/state.json") finding(s), $(wc -c < "$WORK/state.json") bytes (invisible to the reader, cap $STATE_MAX)"
fi
echo "::endgroup::"

# ── 5. Dismiss own stale blocking reviews (keep COMMENTED for audit trail) ──
# Only a review that JUDGED the diff may clear a standing one. A skip-marked
# body (guard.sh's oversized split request) read no code, so dismissing on its
# way in would (a) un-block a PR nobody re-reviewed and (b) leave the next
# judged round reading `prior_verdict` off a DISMISSED review, which means "the
# author opted out" (see prior-review-state.sh). Leave it standing.
echo "::group::Dismiss stale reviews"
if is_skip_marked; then
  echo "Skip-marked review (judged nothing) — leaving standing reviews in place."
  STALE_IDS=""
else
  STALE_IDS=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT" '
        (add // [])
        | [.[] | select(.user.login == $bot and (.state == "CHANGES_REQUESTED" or .state == "APPROVED")) | .id]
        | .[]' 2>/dev/null || true)
fi
while IFS= read -r id; do
  [ -z "$id" ] && continue
  echo "Dismissing review $id"
  if [ -n "$OUT_DIR" ]; then
    log_suppressed "DISMISS $id"
  else
    gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
      -f message="Superseded by new Claude review on updated commit." >/dev/null 2>&1 \
      || echo "::warning::Could not dismiss review $id (non-fatal)"
  fi
done <<< "$STALE_IDS"
echo "::endgroup::"

# ── 6. Supersede prior crash banners ─────────────────────────────────────────
echo "::group::Supersede prior crash banners"
supersede_crash_banners
echo "::endgroup::"

# ── 7. Atomic POST ───────────────────────────────────────────────────────────
echo "::group::Post review"
jq -n \
  --arg event "$VERDICT" \
  --rawfile body "$WORK/body.md" \
  --slurpfile comments "$WORK/comments.json" \
  '{event: $event, body: $body, comments: $comments[0]}' > "$WORK/payload.json" || crash_exit "could not build review payload."
COMMENT_COUNT=$(jq '.comments | length' "$WORK/payload.json")
echo "Posting $VERDICT review with $COMMENT_COUNT inline comments"
REVIEW_ID=""
if [ -n "$OUT_DIR" ]; then
  log_suppressed "POST review $VERDICT $COMMENT_COUNT comments"
  printf '%s\n' "$VERDICT" > "$OUT_DIR/verdict"
  cp "$WORK/body.md" "$OUT_DIR/body.md"
  cp "$WORK/comments.json" "$OUT_DIR/comments.json"
  jq '.meta // {}' "$REVIEW_JSON" > "$OUT_DIR/meta.json" || echo '{}' > "$OUT_DIR/meta.json"
  echo "Dry run — wrote the review to $OUT_DIR instead of posting it"
elif ! POST_RESPONSE=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input "$WORK/payload.json" 2>&1); then
  echo "::endgroup::"
  crash_exit "Review POST failed — verdict is $VERDICT but no PR review was created: $(echo "$POST_RESPONSE" | head -c 400)"
else
  REVIEW_ID=$(echo "$POST_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
  echo "Posted review${REVIEW_ID:+ #$REVIEW_ID}"
fi
echo "::endgroup::"

# ── 8. Step summary ──────────────────────────────────────────────────────────
FINDING_COUNT=$(jq '(.meta.findings // []) | length' "$REVIEW_JSON")
HUMAN_COUNT=$(jq '(.meta.human_review // []) | length' "$REVIEW_JSON")
RESOLVED_COUNT=$(jq '(.meta.resolved_prior // []) | length' "$REVIEW_JSON")
CARRY_COUNT=$(jq 'length' "$WORK/carried.json" 2>/dev/null || echo 0)
{
  echo "## Claude Review: $VERDICT"
  echo ""
  if [ "$INJECTION" = "true" ]; then
    echo "> ⚠ Injection-shaped text was present in this PR's input. Findings were judged as if it were absent; no verdict changed."
    echo ""
  fi
  echo "### Findings ($FINDING_COUNT)"
  jq -r '(.meta.findings // [])[] | "- **\((.severity // "?") | ascii_upcase)** `\(.path // "?"):\(.line // "?")` — \(.title // "Untitled")"' "$REVIEW_JSON"
  if [ "$HUMAN_COUNT" -gt 0 ]; then
    echo ""
    echo "### For a human to review ($HUMAN_COUNT)"
    jq -r '(.meta.human_review // [])[] | "- `\(.path // "?"):\(.line // "?")` — \(.what_to_check // "")"' "$REVIEW_JSON"
  fi
  if [ "$RESOLVED_COUNT" -gt 0 ]; then
    echo ""
    echo "### Resolved since earlier rounds ($RESOLVED_COUNT)"
    jq -r '(.meta.resolved_prior // [])[] | "- `\(.id // "?")` — \(.evidence // "")"' "$REVIEW_JSON"
  fi
  if [ "$CARRY_COUNT" -gt 0 ]; then
    echo ""
    echo "### Carried from earlier rounds ($CARRY_COUNT)"
    jq -r '.[] | "- **\(.sev | ascii_upcase)** `\(.p):\(.l)` — \(.t) _(first seen round \(.r))_"' "$WORK/carried.json"
  fi
  echo ""
  echo "Review posted${REVIEW_ID:+ (review #$REVIEW_ID)} on \`${HEAD_SHA:-HEAD}\`."
} >> "$SUMMARY"

# ── 9. Exit code ─────────────────────────────────────────────────────────────
case "$VERDICT" in
  APPROVE)
    exit 0 ;;
  COMMENT)
    if [ "$HUMAN_COUNT" -gt 0 ]; then
      echo "::warning::Claude posted $FINDING_COUNT finding(s) and $HUMAN_COUNT item(s) for a human to review."
    else
      echo "::warning::Claude posted $FINDING_COUNT non-blocking finding(s). See the PR review for details."
    fi
    exit 0 ;;
  REQUEST_CHANGES)
    echo "::warning::Claude review: REQUEST_CHANGES — $FINDING_COUNT blocking finding(s). See the PR review and the run summary for details."
    exit 0 ;;
esac
