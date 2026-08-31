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
# Thread resolution and replies to other bots are gone: the 2-call pipeline
# produces neither, and their absence is normal. Multi-line ranges came BACK for
# check comments — `start_line` anchors an orientation note to the block it is
# about, so the reviewer sees the whole block the note describes rather than one
# line of it. Findings stay single-line: a suggestion fence has to replace exact lines.
#
# THIS SCRIPT OWNS THE BUDGETS. The models are told to hold them; historically they
# did not, so they are enforced here as a safety net:
#   body <= 1200 BYTES measured PRE-EXPANSION, with {{LINK:path:line}} counted as
#     `path:line` — exactly the arithmetic review-verify.md hands the model. An
#     expanded link costs ~130 bytes more (64-hex sha + URL + markdown), so
#     enforcing the cap after expansion truncated away whole findings from a body
#     the model had rendered perfectly within budget. Truncate first, expand after.
#     Cut on a line boundary; hard-cut mid-line when not even one line fits.
#     AND CUT BY VALUE, NOT BY POSITION: `### Also flagged` and `### What a
#     human should review` are appended LAST and hold the findings that could
#     not be posted inline, so a positional cut deleted exactly the items with
#     no other surface. Blocks are ranked (severity first, those two sections
#     ahead of `### Findings`, all of them ahead of prose), admitted best-first,
#     and printed in the order the model wrote them. Anything cut out of those
#     two sections is named in a `::warning::`.
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
# AND A FAILED POST NEVER LEAVES THE PR UNBLOCKED. The dismissal of a standing
# CHANGES_REQUESTED runs AFTER the POST has succeeded, never before it: the old
# order meant a rejected payload (a 422 on a comment line, which is unvalidated
# whenever `pulls/files` returns no patch data) cleared the only blocking review
# on the PR and then failed to replace it.
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
# Scaled with the diff by guard.sh (comment_limit = 2 x depth_scale, so 6..16)
# and passed in by the workflow. Computed upstream on purpose: this stays one
# env read with one default, and 10 is what a short-circuited run — which sets
# no guard outputs — still gets.
COMMENT_LIMIT="${REVIEW_COMMENT_LIMIT:-10}"
ROUND="${ROUND:-1}"
PRIOR_FINDINGS_JSON="${PRIOR_FINDINGS_JSON:-/tmp/prior-findings.json}"
STATE_MAX="${REVIEW_STATE_MAX:-4000}"
FUNCTIONAL_JSON="${FUNCTIONAL_JSON:-/tmp/functional.json}"
# Sibling of this script, because both are installed together into
# CLAUDE_REVIEW_SCRIPTS by action.yml. Overridable only so the tests can point
# at a stub; CI never sets it.
UPLOAD_SCREENSHOTS_SH="${UPLOAD_SCREENSHOTS_SH:-$(dirname "$0")/upload-screenshots.sh}"
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

# Text from a consumer script's log, safe to drop inside an HTML <sub>/<code>
# block. NOT `${s//</&lt;}`: bash 5.2 enables `patsub_replacement`, where `&` in
# the replacement expands to whatever matched — so that expansion yields `<lt;`
# and the raw `<` survives into the review. GitHub's ubuntu-24.04 runners ship
# bash 5.2.x, so this was live in CI. sed has one fixed meaning for `\&` on both
# versions. `&` goes first, or the entities it writes get escaped again.
html_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

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
#   post-rejected — the review rendered fine and GitHub REFUSED it. Nothing
#                 about the output was unreadable, and on a 4xx a re-run hits the
#                 same rejection, so "re-run, it usually succeeds" is wrong
#                 advice. Classified FIRST, off an explicit flag: by the time
#                 this runs $REVIEW_JSON is always non-empty, so the `unreadable`
#                 test below matches every POST failure and told the reader the
#                 output could not be parsed when it parsed perfectly.
#   quota       — agent returned rate_limit (re-run after reset / rotate token).
#   unreadable  — orchestrator output exists but is not usable JSON: the review
#                 likely RAN to completion and was lost in serialization, so a
#                 plain re-run usually recovers it. NOT "a human must review".
#   no-output   — no orchestrator artifact at all: a genuine crash.
POST_REJECTED=0
POST_ERROR=""
crash_exit() {
  local context="$1" kind quota_hit=false reset_phrase="" crash_msg payload run_link=""
  if [ -f "$ORCH_LOG" ] && grep -qE 'hit your limit · resets|"error": *"rate_limit"' "$ORCH_LOG" 2>/dev/null; then
    quota_hit=true
    reset_phrase=$(grep -oE 'resets [^"\\]+' "$ORCH_LOG" 2>/dev/null | head -1 || true)
  fi
  if [ "${POST_REJECTED:-0}" = "1" ]; then
    kind=post-rejected
  elif [ "$quota_hit" = "true" ]; then
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
    post-rejected)
      echo "::error::$context"
      if [ -n "$POST_ERROR" ]; then
        echo "::error::GitHub rejected the review payload — this is not a serialization slip and a plain re-run will hit it again. Any standing blocking review was left in place."
      fi ;;
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
      post-rejected)
        crash_msg+="> **Claude Review — GitHub rejected the review** :warning:"$'\n'">"$'\n'
        crash_msg+="> The review was produced and rendered; GitHub refused to create it, so nothing was posted. The most common cause is an inline comment anchored to a line GitHub will not accept — which is unvalidated whenever \`pulls/files\` returns no patch data."$'\n'">"$'\n'
        if [ -n "$POST_ERROR" ]; then
          crash_msg+="> \`$(html_escape "$POST_ERROR")\`"$'\n'">"$'\n'
        fi
        crash_msg+="> **Action required:** a re-run on the same commit will be rejected the same way. A human should review this PR; any previously standing Claude review was deliberately left in place." ;;
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
RAW_COMMENT_COUNT=$(jq '(.comments // []) | length' "$REVIEW_JSON" 2>/dev/null || echo 0)
jq '(.comments // []) | map(select(type == "object"))' "$REVIEW_JSON" > "$WORK/comments.json" || crash_exit "could not extract comments from $REVIEW_JSON."
OBJ_COMMENT_COUNT=$(jq 'length' "$WORK/comments.json" 2>/dev/null || echo 0)
# NOTHING IS SILENTLY DROPPED (see this script's header). A `null` or otherwise
# non-object entry cannot be rendered — but under the inline-XOR-body rule the
# body carries no bullet for it either, so discarding it quietly means the
# finding reaches the human NOWHERE. It is still discarded; it is no longer silent.
if [ "${RAW_COMMENT_COUNT:-0}" -gt "${OBJ_COMMENT_COUNT:-0}" ]; then
  echo "::warning::$(( RAW_COMMENT_COUNT - OBJ_COMMENT_COUNT )) malformed comment entries discarded from $REVIEW_JSON (not JSON objects) — anything they flagged reaches the reader nowhere."
fi

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

# ── 2a2. DID THE TESTER ACTUALLY RUN? ───────────────────────────────────────
# THE rc FILE IS NOT THE ANSWER, AND TREATING IT AS ONE THREW REAL EVIDENCE AWAY.
# `/tmp/dev-env/rc` is written only when `setup-dev-env.sh` RETURNS, while the
# orchestrator releases the tester on `web_ready`, written much earlier. A slow or
# hung later phase (a seed, a second service, the teardown) therefore means the
# tester genuinely drove the app and captured screenshots while rc never appeared
# — and the previous round dropped every one of them while asserting "No browser
# test ran; this review is static only."
#
# A `functional.json` carrying a valid `overall` is written by the tester itself
# at the END of its run. It is direct, first-hand evidence that a browser session
# happened, and it outranks the absence of a file some LATER phase writes. It is
# computed HERE, above both notices, so each can be phrased against the same fact.
FN_OVERALL=""
if [ "${FUNCTIONAL_REQUESTED:-false}" = "true" ] && [ -s "$FUNCTIONAL_JSON" ]; then
  case "$(jq -r '.overall // ""' "$FUNCTIONAL_JSON" 2>/dev/null || echo "")" in
    PASS|WARN|FAIL|CRASH) FN_OVERALL=$(jq -r '.overall' "$FUNCTIONAL_JSON") ;;
  esac
fi
TESTER_RAN=false
[ -n "$FN_OVERALL" ] && TESTER_RAN=true

# A functional pass that did not happen is invisible otherwise: the reviewer
# asked for a browser test, got a code review, and nothing said why.
# Deterministic here rather than in a prompt, for the same reason the spec notice
# is — the model cannot forget to mention it. `setup-dev-env.sh` used to promise
# this in a "setup-health section" that the v4 body no longer has.
#
# THE QUESTION IS "DID THE TESTER RUN?", NOT "DID THE BRING-UP FAIL?" — AND
# GATING ON THE rc ALONE MADE THE WORST CASE SILENT. Those two are not the same
# fact, and the gap between them is not hypothetical: on spendfuse#351 the
# bring-up SUCCEEDED — rc 0, API and web both probed up — but only AFTER the
# orchestrator's 360s turn-1b wait had already expired. `WEB_READY=false` meant
# no tester was ever dispatched, yet by the time this script ran the rc file said
# 0, so the whole block was skipped. A review explicitly asked for screenshots
# shipped with none, and not one word explaining it. `TESTER_RAN` is the fact
# that decides whether a notice is OWED; the rc only decides its WORDING.
#
# Two surfaces, because the two cases carry different weight:
#   DEV_ENV_BANNER — the pass was requested and NO tester result exists. A
#     visible GitHub alert under the verdict heading: the reader is looking at a
#     review that is missing half of what they asked for.
#   DEV_ENV_NOTICE — the tester DID run, but the bring-up never reported success.
#     A `<sub>` caveat on a pass that happened; see the two-wordings note below.
DEV_ENV_NOTICE=""
DEV_ENV_BANNER=""
if [ "${FUNCTIONAL_REQUESTED:-false}" = "true" ]; then
  DEV_ENV_RC_PATH="${DEV_ENV_RC_FILE:-/tmp/dev-env/rc}"
  DEV_ENV_RC=$(cat "$DEV_ENV_RC_PATH" 2>/dev/null || echo "")
  DEV_ENV_STARTED_PATH="${DEV_ENV_STARTED_FILE:-/tmp/dev-env/started}"
  WAIT_S="${DEV_ENV_TIMEOUT_SECONDS:-360}"
  case "$WAIT_S" in ''|*[!0-9]*) WAIT_S=360 ;; esac
  [ "$WAIT_S" -gt 540 ] && WAIT_S=540   # the orchestrator's own clamp

  # One line, and the LAST error the bring-up printed — a whole log in a review
  # body is unreadable and would evict findings under the byte budget.
  # Prefer the consumer script's OWN `::error::` annotation. setup-dev-env.sh
  # appends its generic "dev-start.sh exited non-zero" line afterwards, so
  # taking the last error-ish line quoted that tautology back at the reader
  # instead of the cause — measured on a real run, which reported
  # "dev-start.sh exited non-zero" where the log said
  # "API never became ready at http://localhost:20001/api within 300s".
  log="${DEV_ENV_LOG_FILE:-/tmp/dev-env/log}"
  tail=$(grep -a '::error::' "$log" 2>/dev/null | tail -1 | sed 's/^.*::error:://' | cut -c1-300)
  if [ -z "$tail" ]; then
    tail=$(grep -aiE '^(error|fatal)|error:' "$log" 2>/dev/null \
           | grep -av 'dev-start.sh exited non-zero' | tail -1 | cut -c1-300)
  fi

  # `why` is one clause completing "… because <why>". html_escape on the rc for
  # the same reason as `tail`: the rc is FILE CONTENT, not a number this script
  # computed, and it lands inside HTML. A `<b>` in that file reached a public
  # review body raw once already.
  #
  # `date -r FILE +%s` is the mtime on both GNU coreutils (runners) and BSD
  # (a maintainer running tests on macOS) — `stat` is the one that differs.
  HINT=""
  if [ ! -f "$DEV_ENV_STARTED_PATH" ]; then
    why="no dev environment was started for this run — the diff needed no build, or the repo ships no <code>.github/claude-review/dev-start.sh</code>"
  elif [ -z "$DEV_ENV_RC" ]; then
    why="the dev environment did not finish starting in time (waited ${WAIT_S}s)"
  elif [ "$DEV_ENV_RC" != "0" ]; then
    why="the dev environment exited $(html_escape "$DEV_ENV_RC")"
  else
    # rc 0 — the bring-up SUCCEEDED, so the only way no tester ran is that it
    # succeeded too late for the wait, or the tester was ineligible for a
    # reason this script cannot see (most often: no acceptance criteria).
    started=$(cat "$DEV_ENV_STARTED_PATH" 2>/dev/null || echo "")
    rc_at=$(date -r "$DEV_ENV_RC_PATH" +%s 2>/dev/null || echo "")
    case "$started$rc_at" in ''|*[!0-9]*) started=""; rc_at="" ;; esac
    if [ -n "$started" ] && [ -n "$rc_at" ] && [ "$rc_at" -gt "$(( started + WAIT_S ))" ]; then
      why="the dev environment came up $(( rc_at - started ))s in, past the ${WAIT_S}s the reviewer waits for it, so no tester was dispatched"
      HINT=" Raise <code>dev_env_timeout_seconds</code> (max 540) in the caller workflow, and set <code>dev_cache_paths</code>/<code>dev_cache_key_files</code> so the build starts warm."
    else
      why="the dev environment was ready, so the pass was skipped for another reason — most often the governing spec carries no acceptance criteria to test against"
    fi
  fi

  # TWO WORDINGS, ONE FACT. "No browser test ran" is only true when nothing
  # says otherwise; said over a gallery of the tester's own screenshots it is
  # simply false. When the tester finished, the bring-up record is still worth
  # reporting — it is why the run looks odd — but as a caveat on a pass that
  # DID happen, never as a claim that none did.
  if [ "$TESTER_RAN" = "true" ]; then
    if [ "$DEV_ENV_RC" != "0" ]; then
      # The caveat's own sentence supplies "The dev environment ", so it takes
      # the short form; `why` above is a full clause the banner completes
      # "… because <why>" with, and the two must not be interchanged — gluing
      # the clause in here read "The dev environment the dev environment exited 5".
      why_short=$([ -z "$DEV_ENV_RC" ] && echo "did not finish starting in time" || echo "exited $(html_escape "$DEV_ENV_RC")")
      DEV_ENV_NOTICE=$'\n<sub>⚠ The dev environment '"$why_short"' — but the functional tester completed and reported '"$FN_OVERALL"$', so the pass below ran against an environment whose bring-up never reported success. Read it with that in mind.'
      [ -n "$tail" ] && DEV_ENV_NOTICE+=" Last error: <code>$(html_escape "$tail")</code>"
      DEV_ENV_NOTICE+=$' (full log: the run\'s <code>dev-env/log</code> artifact).</sub>\n'
    fi
  else
    DEV_ENV_BANNER=$'\n> [!WARNING]\n> **Functional pass requested but skipped** — '"$why"$'. No browser test ran and there are no screenshots, so this review is static only.'
    [ -n "$tail" ] && DEV_ENV_BANNER+=" Last error: <code>$(html_escape "$tail")</code>"
    DEV_ENV_BANNER+="$HINT"
    DEV_ENV_BANNER+=$' Full log: the run\'s <code>dev-env/log</code> artifact.\n'
  fi
fi

# ── 2c. The functional screenshot gallery ───────────────────────────────────
# WHY THE POSTER OWNS THIS, as it did before v4 (`build-review.sh`). v4 moved the
# invocation into `skills/review-orchestrator.md`, which said to embed the URLs
# "in the relevant comment body" — and review-verify only writes a comment when
# the tester REPRODUCED a failure. So on a PASS there was no comment,
# `upload-screenshots.sh` never ran, and every capture died in the run artifact.
# Evidence that the app was actually driven is worth most exactly when nothing
# broke: that is the run a human would otherwise have to repeat by hand.
#
# Deterministic here rather than in a prompt, for the same reason the two notices
# above are — the model cannot forget it. It also removes the last reason any
# agent needed `upload-screenshots.sh`, so no session agent touches the raw
# GitHub API at all and `Bash(gh api:*)` stays denied without a carve-out.
#
# RENDER ONLY WHAT THE TESTER NAMED. Scanning the tree for recent PNGs cannot
# work: `actions/checkout` rewrites checked-in mtimes to ~now, so a product asset
# is indistinguishable from a capture (observed on PR #30, where a repo's own
# logo was published as review evidence).
#
# It is appended AFTER truncation and is NOT counted in the body budget, exactly
# like the state block below: closed, a `<details>` costs one visible line, and a
# run's own evidence must never evict a finding.
#
# AND THE BODY CAN NEVER CONTRADICT ITSELF ABOUT IT. The gallery and the dev-env
# notice were once computed independently, so one run printed `Functional pass:
# PASS — 3 screenshots` two lines above `No browser test ran`. Both cannot be
# true. The fix that followed suppressed the gallery whenever rc was not 0 — and
# that deleted real screenshots from runs where the tester HAD driven the app
# (see 2a2). So the two are now decided by ONE fact, `TESTER_RAN`:
#   tester ran  → gallery renders, and 2b words its notice as a caveat.
#   no evidence → no gallery, and 2b says no browser test ran.
# Neither string can appear beside the other, in either direction.
SHOT_GALLERY=""
if [ "${FUNCTIONAL_REQUESTED:-false}" = "true" ] && [ "$TESTER_RAN" != "true" ] && [ -n "$DEV_ENV_BANNER" ]; then
  echo "Dev environment never came up and no functional.json records a completed run — no gallery, so the body cannot both claim a functional pass and report that none ran."
fi
if [ "$TESTER_RAN" = "true" ]; then
  echo "::group::Functional screenshots"
  NAMED=$(jq '[(.screenshots // [])[] | select((.file // "") | test("\\.png$"; "i"))] | length' \
            "$FUNCTIONAL_JSON" 2>/dev/null || echo 0)
  # WHY `untested` IS PART OF THIS BLOCK AND NOT AN AFTERTHOUGHT. On a live
  # qiv run the tester verified 3 of 7 acceptance criteria, listed the other
  # 4 in `untested` with real reasons, and reported PASS — which is correct
  # per its own contract, PASS means "everything you exercised held". The
  # review body then said `Functional pass: PASS — 2 screenshots` and nothing
  # else, so a reader saw a green functional pass over a third of the spec.
  # The tester was honest and the poster threw the honesty away.
  UNTESTED=$(jq '(.untested // []) | length' "$FUNCTIONAL_JSON" 2>/dev/null || echo 0)
  UNTESTED=${UNTESTED:-0}
  if [ "${NAMED:-0}" -eq 0 ] && [ "$UNTESTED" -eq 0 ]; then
    echo "Tester reported $FN_OVERALL with no PNG and nothing untested — nothing to publish."
  else
    # stdout is one embeddable URL per uploaded file; diagnostics go to stderr
    # and stay in the job log. Non-fatal by contract: no URLs means no gallery,
    # never a failed review.
    : > "$WORK/shot-urls.txt"
    if [ "${NAMED:-0}" -gt 0 ]; then
      PR_NUMBER="$PR" GITHUB_REPOSITORY="$REPO" \
        "$UPLOAD_SCREENSHOTS_SH" > "$WORK/shot-urls.txt" \
        || echo "::warning::upload-screenshots.sh failed — posting the review without the gallery."
    fi
    # `|| true`, not `|| echo 0`: grep already PRINTS 0 for an empty file and
    # then exits 1, so a fallback echo makes this two lines and every integer
    # test below a syntax error.
    UPLOADED=$(grep -c . "$WORK/shot-urls.txt" 2>/dev/null || true)
    UPLOADED=${UPLOADED:-0}
    echo "Published $UPLOADED of $NAMED screenshot(s) named by the tester."
    [ "$UPLOADED" -lt "$NAMED" ] && \
      echo "::warning::$(( NAMED - UPLOADED )) screenshot(s) the tester named were not published — they remain in the run's claude-review artifact."
    [ "$UNTESTED" -gt 0 ] && \
      echo "::notice::$UNTESTED criterion(s) the tester could not reach — surfaced in the review body."
    # Captions are model-written and land inside an HTML block and a markdown
    # image label, so `[`, `]`, `<` and `>` are stripped rather than escaped —
    # one stray bracket would otherwise swallow the URL or open a tag.
    SHOT_GALLERY=$(jq -r --rawfile urls "$WORK/shot-urls.txt" --arg overall "$FN_OVERALL" '
      # 80 to match the cap the tester skill states, and cut on a WORD
      # boundary: a hard slice ended live captions "the app has already la"
      # and "access code has e". This is the safety net, not the rule —
      # review-functional-tester.md is where the length is actually set.
      def clean: (. // "") | gsub("[\\[\\]<>\n\r]"; " ") | gsub("\\s+"; " ")
                 | sub("^ "; "") | sub(" $"; "")
                 | if length <= 80 then .
                   else (.[0:79] | sub("\\s+\\S*$"; "")) + "…" end;
      def clean140: (. // "") | gsub("[\\[\\]<>\n\r]"; " ") | gsub("\\s+"; " ")
                 | sub("^ "; "") | sub(" $"; "")
                 | if length <= 140 then .
                   else (.[0:139] | sub("\\s+\\S*$"; "")) + "…" end;
      ($urls | split("\n") | map(select(length > 0))
       | map({key: (split("/") | last), value: .}) | from_entries) as $u
      | [ (.screenshots // [])[]
          | select((.file // "") | test("\\.png$"; "i"))
          | (.file | split("/") | last) as $base
          | {cap: ((.description | clean) as $c | if $c == "" then $base else $c end),
             url: ($u[$base] // "")}
          | select(.url != "") ] as $shots
      # 140, longer than a caption: these carry a reason, and a truncated
      # reason ("time budget ran" / "the seed only has") is worse than none.
      | [ (.untested // [])[] | select(type == "string")
          | clean140 | select(length > 0) ] as $gaps
      | (($shots | length) as $n
         | "Functional pass: \($overall) — \($n) screenshot"
           + (if $n == 1 then "" else "s" end)) as $shotpart
      | (if ($gaps | length) > 0
         then " · \($gaps | length) criteria not verified" else "" end) as $gappart
      | if ($shots | length) == 0 and ($gaps | length) == 0 then ""
        else "\n<details><summary>" + $shotpart + $gappart + "</summary>\n\n"
             + ($shots | map("**\(.cap)**\n\n![](\(.url))\n") | join("\n"))
             + (if ($gaps | length) > 0
                then "\n**Not verified by this run**\n\n"
                     + ($gaps | map("- \(.)") | join("\n")) + "\n"
                else "" end)
             + "\n</details>\n"
        end' "$FUNCTIONAL_JSON" 2>/dev/null) || SHOT_GALLERY=""
  fi
  echo "::endgroup::"
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
# NOTHING IS SILENTLY DROPPED (see this header): the fence a check loses below is
# model-written content, so its removal is announced even though keeping it could
# damage the PR.
# THREE OR MORE backticks, both here and in `unfence` below. GitHub opens a
# fenced block on any run of three or more, so ````suggestion is as committable
# as ```suggestion — and a regex pinned to exactly three let that shape through
# with its range intact AND no warning anywhere.
FENCED_CHECKS=$(jq '[.[] | select(((.body // "") | test("^\\s*\\*\\*check\\*\\*"; "i"))
                                  and ((.body // "") | test("(^|\n)[ \t]*`{3,}[ \t]*suggestion"; "i")))] | length' \
                  "$WORK/comments.json" 2>/dev/null || echo 0)
if [ "${FENCED_CHECKS:-0}" -gt 0 ]; then
  echo "::warning::Stripped a committable suggestion fence from $FENCED_CHECKS check comment(s) — a check spans a whole block, so an applied fence would replace every line of it."
fi
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
  # A `**check**` comment is an orientation note for a human, not a defect. It has no
  # severity, so it already sorts behind every finding — under pressure the slots
  # go to defects and the notes fall back, which is the right way round. A
  # dropped one returns under the human-review heading, never under "Also flagged".
  def kind: if ((.body // "") | test("^\\s*\\*\\*check\\*\\*"; "i")) then "check" else "finding" end;
  # A CHECK NEVER CARRIES A COMMITTABLE FENCE — STRUCTURALLY, not by prompt rule.
  # The range below is granted to checks alone on the strength of a line in
  # review-verify.md; nothing enforced it, so a `**check**` with start_line:10
  # line:13 AND a ```suggestion``` fence was the code-deleting shape all over
  # again: Apply-suggestion replaces all four lines with the single line in the
  # fence. The RANGE is the feature (a check points at the block it asks about),
  # so the FENCE is what goes. Everything else — the question, the prose either
  # side of it — is left exactly as written.
  #
  # THREE OR MORE BACKTICKS, and the closer must be at least as long as the
  # opener — the rule GitHub itself applies. Pinning both ends to exactly three
  # let a ````suggestion block through untouched, and closing a four-backtick
  # opener on a three-backtick line inside it would stop the strip early and
  # leave the real closer stranded in the output.
  #
  # AN UNTERMINATED FENCE DROPS THE OPENER, NOT THE QUESTION. The in-fence flag
  # never cleared without a closer, so every line the model wrote after the
  # opener vanished — and the warning said a FENCE was stripped, which is not the
  # same as saying the question went with it. That is what the NOTHING IS
  # SILENTLY DROPPED banner at the top of this file forbids, and losing the fence
  # is the safety requirement while losing the question never was. So in-fence
  # lines are BUFFERED, not discarded: a closer discards the buffer (the fence
  # really was a suggestion), and reaching the end still inside one restores it.
  # Safe by construction — if any line after the opener had been a fence, the
  # fence would have closed, so an unterminated buffer holds no fence line and
  # cannot re-open one. The lone exception is a SHORTER fence line the closer
  # rule skipped over; it is a bare marker carrying no words, so it is dropped
  # rather than left behind unbalanced.
  def fencelen: ((capture("^[ \t]*(?<b>`{3,})") | .b | length) // 0);
  def unfence:
    ((. // "") | split("\n")
     | reduce .[] as $l ({o: [], b: [], f: 0};
         if .f > 0 then (if ($l | fencelen) >= .f then .b = [] | .f = 0 else .b += [$l] end)
         elif ($l | test("^[ \t]*`{3,}[ \t]*suggestion"; "i")) then .f = ($l | fencelen)
         else .o += [$l] end)
     | (if .f > 0 then .o + (.b | map(select((fencelen) == 0))) else .o end)
     | join("\n") | gsub("\n{3,}"; "\n\n") | sub("\\s+$"; ""));
  # Longest codepoint prefix of $s that fits $max bytes. Starts at the byte
  # budget (bytes >= codepoints, always) and walks down; ASCII exits at once.
  # Defined ABOVE `title` because `title` cuts with it.
  def bcut($s; $max):
    if ($s | utf8bytelength) <= $max then $s
    else ({i: ([$max, ($s | length)] | min)}
          | until((($s[:.i]) | utf8bytelength) <= $max; .i = (.i - 1))
          | $s[:.i])
    end;
  # BOTH SURFACES MUST CUT THE SAME STRING, OR THE 90-CHARACTER IDENTITY SPLITS.
  # This title becomes the `### Also flagged` bullet; the matching body bullet is
  # cut by budget.awk t90(), which cuts the NORMALISED string at 90 BYTES. This
  # used to cut the RAW string at 90 CODEPOINTS, so any title over 90 characters
  # whose normalisation changes length inside that window produced two different
  # keys — and #133 double-print came straight back. Verified both directions:
  # a title of 40 A, TWO spaces and 60 B printed the finding TWICE (once in
  # `### Findings`, once in `### Also flagged`) where the single-space control
  # deduped correctly; and the mirror, where a genuinely different, shorter
  # finding in the body collided with the raw cut and DELETED the dropped one.
  # So normalise FIRST — CR out, whitespace runs collapsed, trimmed, exactly
  # what norm() does — then cut, on a codepoint boundary at 90 bytes, which is
  # where t90() cuts too. #133 (z2c) trailing-space trim is kept: after the
  # collapse at most one space can be left dangling by the cut.
  def title:
    ((.body // "") | split("\n") | (.[0] // "")
     | sub("^\\s*\\*\\*[A-Za-z]+\\*\\*\\s*"; "")
     | gsub("\r"; "") | gsub("[ \t]+"; " ") | sub("^ "; "") | sub(" $"; "")
     | bcut(.; 90) | sub("[ \t]+$"; ""))
    | if length == 0 then "flagged inline" else . end;
  def clamp($max):
    (if utf8bytelength <= $max then . else (bcut(.; $max - 3)) + "…" end)
    # An odd number of ``` fences means the closer is gone: drop the opener and
    # everything after it rather than re-closing a half-written suggestion.
    | if (((. / "```") | length) % 2 == 0)
      then (((. / "```") | .[:-1] | join("```")) | sub("\\s+$"; "")) + "…"
      else . end;
  ($valid | split("\n") | map(select(length > 0))) as $lines
  | ($lines | length > 0) as $validated
  # A SET, not a list: a range is checked line by line, so `any` over the list
  # would be O(range x hunks) on every comment of every review.
  | ($lines | map({key: ., value: true}) | from_entries) as $lset
  | map(select((.path // "") != "" and .line != null))
  | map(.line = ((.line | tostring | tonumber?) // 0))
  | map(select(.line > 0))
  # `start_line` turns a comment into a block-anchored one, so a check can point
  # at the whole handler it is asking about rather than one arbitrary line.
  # GitHub 422s a range whose start is not strictly above the anchor, and a
  # 422 fails the ATOMIC post — every other comment dies with it. So anything
  # that is not a well-formed, plausibly-sized block collapses to single-line.
  | map(.start_line = ((.start_line | tostring | tonumber?) // 0))
  # RANGES ARE CHECKS-ONLY. review-verify.md: ranges are "checks only", and
  # "Findings stay single-line — a suggestion fence must replace exact lines".
  # A finding posted with a range is not cosmetic, it DAMAGES THE PR: the
  # "Apply suggestion" button replaces every line from start_line to line, so a
  # one-line fix carrying start_line:10 line:13 silently deletes three lines of
  # real code the moment a human clicks it. A check never carries a fence, so
  # only a check may span a block.
  | map(if kind == "check" then . else .start_line = 0 end)
  | map(if kind == "check" then .body = ((.body // "") | unfence) else . end)
  # 120 LINES, NOT 30. A check is orientation across a whole changed block, so the
  # span is the feature: 30 cut it off on more than one contiguous changed run in
  # ten. Measured over this repo history: 89% of runs fit in 30, 96% in 120, and
  # what sits above 120 is a whole-file rewrite, which is not a block. The cap
  # still matters because a run whose hunks could not be derived skips the in-hunk
  # range check below, and a 422 on a malformed range kills the ATOMIC post.
  | map(if (.start_line > 0) and (.start_line < .line) and ((.line - .start_line) <= 120)
        then . else .start_line = 0 end)
  | to_entries
  | map(.value + {_i: .key, _r: (.value | sev | rank)})
  | unique_by([.path, .line, .body])
  | sort_by(._r, ._i)
  # DEGRADE THE RANGE, NEVER THE PLACEMENT. A block a check wants to wrap is
  # usually only partly in the diff — seaters#2134 asked for 226-253 across a
  # sparse diff. Rejecting the comment for that put the question in the body,
  # which is exactly where a check must never go: it is inline or it is unread.
  # So an unusable range is dropped and the comment anchors at `line`, and only
  # a `line` that is itself out of hunk falls back.
  | map(. as $c | ($c.side // "RIGHT") as $side
        | $c + {start_line:
            (if ($c.start_line > 0) and $validated
             then (if ([range($c.start_line; $c.line + 1)]
                       | all($lset[($c.path + ":" + (. | tostring) + ":" + $side)] // false))
                   then $c.start_line else 0 end)
             else $c.start_line end)})
  | map(. as $c | ($c.side // "RIGHT") as $side | $c + {_inhunk:
      (if $validated
       then ($lset[($c.path + ":" + ($c.line | tostring) + ":" + $side)] // false)
       else true end)})
  | ([.[] | select(._inhunk)]) as $in
  | ([.[] | select(._inhunk | not)]) as $out
  | { kept: ($in[:$limit] | map(
        {path, line, side: (.side // "RIGHT"), body: ((.body // "") | clamp($cmax))}
        + (if .start_line > 0
           then {start_line, start_side: (.side // "RIGHT")} else {} end))),
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
# The invisible byte sequences isblank() erases before deciding, and the byte
# values utrim() needs. Both are built with sprintf: awk cannot portably carry a
# literal high byte in a regex or a string constant, and this file runs the
# program under LC_ALL=C so `%c` yields exactly one byte per value.
function initinvis(   i) {
  ninvis = 0
  invis[++ninvis] = sprintf("%c", 13)                 # CR
  invis[++ninvis] = sprintf("%c", 11)                 # VT
  invis[++ninvis] = sprintf("%c", 12)                 # FF
  invis[++ninvis] = sprintf("%c%c", 194, 133)         # U+0085 NEL
  invis[++ninvis] = sprintf("%c%c", 194, 160)         # U+00A0 NBSP
  invis[++ninvis] = sprintf("%c%c", 216, 156)         # U+061C ARABIC LETTER MARK
  invis[++ninvis] = sprintf("%c%c%c", 225, 154, 128)  # U+1680 OGHAM SPACE MARK
  invis[++ninvis] = sprintf("%c%c%c", 225, 160, 142)  # U+180E MONGOLIAN VOWEL SEP
  # U+2000..U+200F: the en/em space family, ZWSP, ZWNJ, ZWJ, and the two BIDI
  # MARKS. The loop used to stop at 141 (U+200D), one codepoint short of U+200E
  # LEFT-TO-RIGHT MARK — which is as invisible as the ZWSP beside it and put the
  # whole catastrophic shape back: an lrm-only line read as content, `skipping`
  # never cleared, and the rest of the body went with a stripped bullet.
  for (i = 128; i <= 143; i++) invis[++ninvis] = sprintf("%c%c%c", 226, 128, i)
  # U+2028..U+202F: the two separators, the five BIDI embedding/override
  # controls (U+202A..U+202E) and the narrow NBSP. Listed as a run for the same
  # reason: leaving any of them out is the U+200E hole again with a different
  # byte.
  for (i = 168; i <= 175; i++) invis[++ninvis] = sprintf("%c%c%c", 226, 128, i)
  # U+205F MEDIUM MATH SPACE, U+2060 WORD JOINER, U+2061..U+2064 the invisible
  # math operators.
  for (i = 159; i <= 164; i++) invis[++ninvis] = sprintf("%c%c%c", 226, 129, i)
  # U+2066..U+2069: the BIDI isolates (LRI, RLI, FSI, PDI).
  for (i = 166; i <= 169; i++) invis[++ninvis] = sprintf("%c%c%c", 226, 129, i)
  invis[++ninvis] = sprintf("%c%c%c", 227, 128, 128)  # U+3000 IDEOGRAPHIC SPACE
  invis[++ninvis] = sprintf("%c%c%c", 239, 187, 191)  # U+FEFF ZWNBSP / BOM
  # U+FFF9..U+FFFB: the interlinear annotation controls.
  for (i = 185; i <= 187; i++) invis[++ninvis] = sprintf("%c%c%c", 239, 191, i)
  for (i = 128; i <= 255; i++) ordv[sprintf("%c", i)] = i
}
# Drop a trailing PARTIAL UTF-8 sequence. t90() cuts 90 bytes; jq cuts to 90
# bytes on a codepoint boundary (`bcut`). Without this the two disagree on the
# last character of any title whose 90th byte lands mid-sequence — the same
# double-print / silent-delete pair the normalisation desync produced.
function utrim(s,   L, i, b, need) {
  L = length(s)
  i = L
  while (i > 0) { b = ordv[substr(s, i, 1)] + 0; if (b >= 128 && b < 192) i--; else break }
  if (i == 0) return s
  b = ordv[substr(s, i, 1)] + 0
  if (b < 192) return s
  need = (b >= 240 ? 4 : (b >= 224 ? 3 : 2))
  if (i + need - 1 > L) return substr(s, 1, i - 1)
  return s
}
function nph(s,   n) { n = 0; while (match(s, /\{\{LINK:[^{}]*\}\}/)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
function mlen(s) { return length(s) - 9 * nph(s) }
# The `path[:line]` inside a line's FIRST {{LINK:}}, or "" — the bullet's identity.
function phkey(s) { return (match(s, /\{\{LINK:[^{}]*\}\}/) ? substr(s, RSTART + 7, RLENGTH - 9) : "") }
# `path` of a phkey, with the `:<line>` suffix (if any) removed.
function bpath(s) { sub(/:[0-9]+$/, "", s); return s }
# The `:<line>` suffix of a phkey, or "" — the other half of bpath().
function bline(s) { return (match(s, /:[0-9]+$/) ? substr(s, RSTART + 1) : "") }
# Compare titles on their text alone: CR gone, whitespace runs collapsed, trimmed.
# Backticks, markdown and non-ASCII are left exactly as written — both sides are
# rendered from the same string, so byte equality is the point.
function norm(s) { gsub(/\r/, "", s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
# The 90-character title prefix the two SURFACES can be compared on. A fallback
# bullet's title came through the jq `title` def, which clamps to `.[:90]` and
# then trims what the cut left dangling; a body bullet's title is whole. Compared
# whole they never match, so the body side is cut here — and trimmed the same
# way, or a title whose 90th character is a space differs by that one byte.
function t90(s) { s = utrim(substr(norm(s), 1, 90)); sub(/[ \t]+$/, "", s); return s }
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
# Severity of a bullet: the `**word**` before its first {{LINK:}}, lowercased, or
# "" for a bullet that carries none — `- **minor** {{LINK:p:l}} - title`.
function bsev(s,   r) {
  r = s
  sub(/^[ \t]*[-*][ \t]+/, "", r)
  if (match(r, /^\*\*[A-Za-z]+\*\*/)) return tolower(substr(r, RSTART + 2, RLENGTH - 4))
  return ""
}
# Severity as an ordering key. Anything unrecognised — a check, an unmarked
# bullet — sorts behind every graded finding.
function srank(s) { return (s == "critical" ? 0 : (s == "major" ? 1 : (s == "minor" ? 2 : 3))) }
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
# The FALLBACK filter needs a STRICTER test than isdup(). isdup() matches
# path+line OR path+title and never looks at severity, which is right where it is
# used: the strip matches a bullet against a comment ACTUALLY BEING POSTED, and
# one comment supplies both keys, so a severity mismatch cannot arise. Reused
# against arbitrary `### Findings` bullets it DELETED REAL FINDINGS — a dropped
# `**critical** SQL injection` at src/foo.ts:99 was discarded because an
# unrelated `**minor** variable name is unclear` bullet sat at that same line,
# and the log announced the deletion as a de-duplication.
# BUT UNANIMITY IS TOO STRICT, AND #132's VERSION DOUBLE-PRINTED. Demanding path
# AND severity AND title, with no line key at all, means any drift on either
# field prints the finding twice — once under `### Findings`, once under
# `### Also flagged`, with two contradictory severities on one defect. Two ways
# it fires: the model writes `**critical**` in the body and `**major**` in the
# comment (routine), and — MECHANICALLY, with no inconsistency at all — the jq
# `title` def clamps to `.[:90]`, so every finding with a longer title has a
# fallback bullet that is a truncated PREFIX of the body's.
#
# The identity is path + the 90-char title prefix + (line OR severity). Both
# weak keys are kept, and either one confirming is enough: the title carries the
# identity, and one corroborating field distinguishes a drifted restatement from
# a genuinely second finding that happens to share a title. (y1b) — same title,
# different line AND different severity — is what keeps both keys honest.
function fbdup(key, ln,   p, m, a, i, id) {
  p = bpath(key)
  if (p == "") return 0
  m = split(fidx[p SUBSEP t90(btitle(ln))], a, " ")
  for (i = 1; i <= m; i++) {
    id = a[i]
    if (used[id]) continue
    if (fline[id] == bline(key) || fsev[id] == bsev(ln)) { used[id] = 1; return 1 }
  }
  return 0
}
# The last resort: cut a single line mid-way rather than return an empty body.
# Byte by byte, but never THROUGH a codepoint — the walk stops on whatever byte
# the budget runs out on, and a trailing lead-or-continuation byte with no rest
# of its sequence is an orphan jq renders as U+FFFD. So the result goes through
# utrim(), exactly like t90(): the body may end early, it may not end in a
# question mark in a black diamond.
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
  return utrim(out)
}
# The block boundaries mode=strip and mode=fit both key on. One definition, two
# callers, so the two passes cannot drift on what a bullet or a section is.
function ishdr(s)    { return (s ~ /^[ \t]*###/) }
# WHAT COUNTS AS BLANK IS NOT AN ASCII QUESTION, AND `/^[ \t]*$/` GOT IT WRONG.
# This predicate is shared by mode=strip, mode=fit and prune(), and it called a
# line holding one U+00A0, one U+200B or a lone CR "content". In strip that meant
# `skipping` never cleared after a stripped bullet, so every line to the end of
# the body went with it — measured: 7 lines gone, the body ending at the title,
# and the only diagnostic was "Dropped 7 body line(s) duplicating an inline
# comment", which they did not.
# awk here runs under LC_ALL=C and is BYTE-oriented, so the UTF-8 sequences are
# matched explicitly; they are built with sprintf in initinvis() because a
# literal 0x80-0xFF byte cannot be written into a regex portably across awks.
# None of those bytes is a regex metacharacter, so a dynamic regex over them is
# safe.
function isblank(s,   i) {
  for (i = 1; i <= ninvis; i++) gsub(invis[i], "", s)
  return (s ~ /^[ \t]*$/)
}
# A TOP-LEVEL bullet is ONE finding. An indented `  - ` beneath it is that
# finding's detail — never a finding of its own, and never a block boundary. It
# is the ONLY bullet predicate any pass may use: an `isbullet` that also matched
# the indented form let a detail line into the strip's bullet arm, where it found
# no {{LINK:}}, took an empty key, skipped the duplicate test and came out as
# "kept" while its parent was stripped. See the strip loop.
# Counting an indented bullet as a finding is also how `### Findings (5)` ended
# up over two findings.
function istop(s)    { return (s ~ /^[-*][ \t]/) }
# The three sections this pipeline defines as BULLET LISTS. #133 closed the
# sub-bullet route into `### Findings (0)` above loose prose; blank-line-separated
# prose was the other one — prune() saw a non-blank line and kept the section,
# renumber() counted top-level bullets and wrote (0). A findings header over
# stranded prose is not a section with content, it is a header the strip or the
# budget emptied, so it goes with whatever is left inside it.
function isbulletsec(s) {
  return (s ~ /^[ \t]*###[ \t]*(Findings|Also flagged|What a human should review)/)
}
# ── MULTI-LINE MARKDOWN CONSTRUCTS ARE INDIVISIBLE ──────────────────────────
# mode=fit had no model for any construct that spans lines, so it split them by
# the ordinary rules — a blank line inside a fence started a new block, and a
# `- name: build` at column 0 inside a YAML fence was an `istop` top-level
# bullet. Opener, body and closer were then ranked and admitted INDEPENDENTLY,
# and greedy fill makes partial admission the NORMAL outcome, not a corner case.
# Both halves damage the page:
#   - the opener dropped, body and closer kept — the fenced lines render as
#     ordinary markdown, so YAML `- name:` config lines become `### Context`
#     bullets and the review asserts changes the model never claimed;
#   - the closer dropped — the fence never closes, and EVERYTHING after it is
#     literal preformatted text on GitHub: `### Findings`, the truncation
#     marker, the footer, and the `<!-- claude-review-state {...} -->` block.
#     Findings stop being findings, links go dead, and the internal state JSON
#     is shown to the reader.
# A ```mermaid diagram is not hypothetical: skills/review-verify.md mandates one.
# So a fenced region, a markdown table and a blockquote run are each ONE block:
# never split, admitted or dropped whole.
#
# The fence marker a line opens or closes with — a run of three or more
# backticks or tildes, leading whitespace ignored — or "" for any other line.
# THREE OR MORE, and the closer must be at least as long as the opener: the same
# rule GitHub applies and the same one `unfence` in section 3 already honours.
function fmark(s,   r) {
  r = s
  sub(/^[ \t]+/, "", r)
  if (match(r, /^`{3,}/)) return substr(r, 1, RLENGTH)
  if (match(r, /^~{3,}/)) return substr(r, 1, RLENGTH)
  return ""
}
# Does `s` close a fence opened with marker `open`? Same character, at least as
# long, and nothing but whitespace after the run — an info string (```mermaid)
# opens, it never closes.
function fcloses(s, open,   r, m) {
  m = fmark(s)
  if (m == "" || substr(m, 1, 1) != substr(open, 1, 1) || length(m) < length(open)) return 0
  r = s
  sub(/^[ \t]+/, "", r)
  return (substr(r, length(m) + 1) ~ /^[ \t]*$/)
}
# A table row is any non-blank line carrying a pipe; the separator is the
# `---|---` line under the header, which is what tells a table from a sentence
# that happens to contain a pipe.
function istrow(s)   { return (index(s, "|") > 0 && !isblank(s)) }
function istsep(s,   r) {
  r = s
  gsub(/[ \t]/, "", r)
  if (index(r, "|") == 0) return 0
  return (r ~ /^\|?:?-+:?(\|:?-+:?)*\|?$/)
}
function isquote(s)  { return (s ~ /^[ \t]*>/) }
# mask[i] = 1 for every line of a[1..cnt] inside a fenced region, opener and
# closer included. NOTHING INSIDE A FENCE IS MARKUP: a `- name: build` in a YAML
# fence is not a finding, a `### steps` in one is not a section, and a blank line
# in one is not a separator. Counting them is how `### Findings (3)` ended up
# over a single bullet and two lines of workflow config. An unterminated fence
# runs to the end, which is what GitHub renders too.
function fencemask(a, cnt, mask,   i, m) {
  for (i = 1; i <= cnt; i++) mask[i] = 0
  i = 1
  while (i <= cnt) {
    m = fmark(a[i])
    if (m == "") { i++; continue }
    mask[i] = 1
    i++
    while (i <= cnt) { mask[i] = 1; if (fcloses(a[i], m)) { i++; break }; i++ }
  }
}
# grpend[i] = the LAST line of the indivisible construct that starts at line i,
# or 0 if none starts there. An unterminated fence runs to end of input, which
# is what GitHub does with it too. Fences are matched first and their interior
# skipped whole: a fenced block may legitimately contain `>` and `|` lines.
function groups(   i, j, m) {
  for (i = 1; i <= NR; i++) grpend[i] = 0
  i = 1
  while (i <= NR) {
    m = fmark(line[i])
    if (m != "") {
      j = i + 1
      while (j <= NR && !fcloses(line[j], m)) j++
      if (j > NR) j = NR
      grpend[i] = j
      i = j + 1
      continue
    }
    if (isquote(line[i])) {
      j = i
      while (j < NR && isquote(line[j + 1])) j++
      grpend[i] = j
      i = j + 1
      continue
    }
    # A header or a bullet that happens to carry a pipe is still a header or a
    # bullet: it keeps its own rank and never becomes the head of a table.
    if (i < NR && !ishdr(line[i]) && !istop(line[i]) && istrow(line[i]) && istsep(line[i + 1])) {
      j = i + 2
      while (j <= NR && istrow(line[j])) j++
      grpend[i] = j - 1
      i = j
      continue
    }
    i++
  }
}
# Drop every `###` section left with no item, plus trailing blank lines. For a
# bullet-list section an "item" is a TOP-LEVEL BULLET, not any non-blank line.
# Operates on out[1..cnt] in place; returns the new count.
function prune(cnt,   i, j, has, m) {
  fencemask(out, cnt, ofence)
  for (i = 1; i <= cnt; i++) del[i] = 0
  for (i = 1; i <= cnt; i++) {
    if (ofence[i] || !ishdr(out[i])) continue
    has = 0
    for (j = i + 1; j <= cnt && (ofence[j] || !ishdr(out[j])); j++) {
      if (!ofence[j] && isblank(out[j])) continue
      if (isbulletsec(out[i]) && !(!ofence[j] && istop(out[j]))) continue
      has = 1; break
    }
    if (has) continue
    for (j = i; j == i || (j <= cnt && (ofence[j] || !ishdr(out[j]))); j++) del[j] = 1
  }
  m = 0
  for (i = 1; i <= cnt; i++) if (!del[i]) out[++m] = out[i]
  fencemask(out, m, ofence)
  while (m > 0 && !ofence[m] && isblank(out[m])) m--
  return m
}
# Rewrite every `### Header (n)` to the number of bullets that actually follow
# it, in place over out[1..cnt]. Headers carry a count the model wrote before
# anything was stripped or cut, so after either the number is a claim about
# content that is no longer on the page.
function renumber(cnt,   i, j, n) {
  fencemask(out, cnt, ofence)
  for (i = 1; i <= cnt; i++) {
    if (ofence[i] || out[i] !~ /^[ \t]*###/) continue
    if (out[i] !~ /\([0-9]+\)/) continue
    n = 0
    for (j = i + 1; j <= cnt && (ofence[j] || !ishdr(out[j])); j++)
      if (!ofence[j] && istop(out[j])) n++
    sub(/\([0-9]+\)/, "(" n ")", out[i])
  }
}
# Every kept comment gets one id, listed under its `path:line` key and under its
# `path`+title key. A bullet claims an ID, never a key.
BEGIN {
  initinvis()
  nk = 0
  while (keysfile != "" && (getline kk < keysfile) > 0) {
    # mode=fbfilter reads a DIFFERENT index: `path[:line]<TAB>sev<TAB>title`,
    # written by mode=fbindex, keyed on the full path+severity+title signature.
    if (mode == "fbfilter") {
      nf = split(kk, kfld, "\t")
      ka = kfld[1]
      if (ka == "" || nf < 3) continue
      nk++
      # Keyed on path + the 90-char title prefix ALONE; the line and the
      # severity ride alongside so fbdup() can require either one of them, not
      # both. Keying on all three is what made a drifted severity — or a title
      # the jq clamp truncated — miss and print the finding twice.
      fk = bpath(ka) SUBSEP t90(kfld[3])
      fline[nk] = bline(ka); fsev[nk] = tolower(kfld[2])
      fidx[fk] = fidx[fk] " " nk
      continue
    }
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
  # The identity of every `### Findings` bullet still standing in the body:
  # `path[:line]<TAB>severity<TAB>title`. Written AFTER the strip has run, so what
  # it lists is what the reader will actually see — the input to the
  # `### Also flagged` de-duplication below. The SEVERITY is part of the record
  # because path+line alone cannot tell one finding from another sitting on it.
  if (mode == "fbindex") {
    insec = 0
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (l ~ /^[ \t]*###/) { insec = (l ~ /^[ \t]*###[ \t]*Findings/); continue }
      if (!insec) continue
      # istop, not the loose `/^[ \t]*[-*][ \t]/` #133 deleted `isbullet` to
      # prevent. An indented detail line is not a finding, and one carrying a
      # {{LINK:}} of its own would be indexed as one — which is enough for
      # fbdup() to delete the real fallback bullet sitting at that path.
      if (!istop(l)) continue
      k = phkey(l)
      if (k != "") print k "\t" bsev(l) "\t" btitle(l)
    }
    exit
  }
  # Drop each fallback bullet whose finding the body already lists — and ONLY
  # those. fbdup() requires the whole signature (path, severity, title), not
  # isdup()'s path+line OR path+title; see fbdup() for the finding that
  # disappeared under the looser test. The one-to-one claim is unchanged: a body
  # bullet is spent by at most one fallback bullet.
  if (mode == "fbfilter") {
    for (i = 1; i <= NR; i++) {
      l = line[i]
      k = phkey(l)
      if (k != "" && fbdup(k, l)) continue
      print l
    }
    exit
  }
  n = 0; kept = 0
  if (mode == "strip") {
    # A `### Findings` bullet matching a comment being posted inline — same path
    # and line, or same path and title — is the duplicate. Only that section: a
    # `### What a human should review` item may legitimately point at the same
    # path:line as a finding, and `### Also flagged` (the bullets for comments
    # that could NOT be posted inline) is not appended until after this pass.
    # NOTHING INSIDE A FENCE IS MARKUP. Without this a `### steps` in a YAML
    # fence opened a section, a blank line in one cleared `skipping`, and a
    # `- name: build` in one was a top-level bullet — which is also what the
    # header count below was counting.
    fencemask(line, NR, lfence)
    insec = 0; skipping = 0; nh = 0
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (!lfence[i] && ishdr(l)) {
        skipping = 0; insec = (l ~ /^[ \t]*###[ \t]*Findings/)
        out[++kept] = l
        if (insec) hdr[++nh] = kept
        continue
      }
      if (!lfence[i] && isblank(l)) { skipping = 0; out[++kept] = l; continue }
      # TOP-LEVEL bullets only. An indented `  - ` detail line belongs to the
      # bullet above it, so it must fall through to the `skipping` test below and
      # go wherever its parent went. Matching it here gave it an empty key (it
      # carries no {{LINK:}}), skipped the duplicate test, kept it AND cleared
      # `skipping` — so a stripped critical left its own detail prose standing,
      # reparented under `### Findings`, which renumber() then counted as (0).
      if (!lfence[i] && insec && istop(l)) {
        k = phkey(l)
        if (k != "" && isdup(k, l)) { skipping = 1; continue }
        skipping = 0; out[++kept] = l; continue
      }
      if (skipping) continue          # a continuation or detail line of a stripped bullet
      out[++kept] = l
    }
    fencemask(out, kept, ofence)
    for (h = 1; h <= nh; h++) {
      n = 0
      for (j = hdr[h] + 1; j <= kept && (ofence[j] || !ishdr(out[j])); j++)
        if (!ofence[j] && istop(out[j])) n++
      sub(/\([0-9]+\)/, "(" n ")", out[hdr[h]])
    }
    kept = prune(kept)
    for (i = 1; i <= kept; i++) print out[i]
    exit
  }
  # THE BUDGET CUTS BY VALUE, NOT BY POSITION — AND IT USED TO CUT BY POSITION.
  # `### What a human should review` and `### Also flagged` are APPENDED to the
  # END of the body by 4b, so a positional truncator eats them FIRST. Those two
  # sections exist precisely because their items could NOT be posted inline: they
  # have no other surface, and cutting them deletes the finding from the review
  # outright. Reproduced at the default 1800 with a 14-byte overflow: an
  # out-of-hunk **critical** ("auth middleware is skipped for admin routes")
  # vanished from every surface while two **minor** nits in `### Findings`
  # survived, and `### Also flagged (1)` renumbered honestly so nothing on the
  # page hinted at the loss.
  #
  # So the file is cut into BLOCKS, each block is ranked, blocks are admitted
  # best-first until the budget is spent, and what survives is printed in the
  # ORIGINAL order — the reader still reads the body the model wrote, minus the
  # least valuable parts of it.
  #
  # A BLOCK IS WHAT A LINE OWNS, exactly as in mode=strip: a `###` header alone,
  # or a top-level bullet plus its continuation and detail lines, or a paragraph
  # plus its continuation lines. That ownership is what keeps a dropped bullet
  # from orphaning its sub-bullets under the next finding, and a dropped header
  # from reparenting its criticals under `### Also flagged` — both were live
  # defects (see (y3)/(y3b)). Leading blank lines belong to the block that
  # FOLLOWS them, so a separator never outlives the thing it separated.
  #
  # RANK, best first: the review title (~30 bytes, and a body that opens
  # mid-sentence reads as a rendering bug), then every bullet by SEVERITY and, at
  # equal severity, by section — `### Also flagged` and `### What a human should
  # review` ahead of `### Findings`, and all of them ahead of ordinary prose. A
  # bullet can never be admitted without its own header, so a section whose
  # header does not fit is dropped whole rather than reparented.
  #
  # AND A FENCE, A TABLE OR A BLOCKQUOTE IS ONE BLOCK — see groups() above for
  # what splitting one costs the page.
  groups()
  nb = 0; curhdr = 0; pb = 0; cur = 0
  for (i = 1; i <= NR; i++) {
    l = line[i]
    if (isblank(l)) { if (pb == 0) pb = i; continue }
    if (ishdr(l)) {
      nb++; bstart[nb] = (pb ? pb : i); bend[nb] = i; bfirst[nb] = i
      bishdr[nb] = 1; bhdr[nb] = 0
      secw[nb] = (l ~ /^[ \t]*###[ \t]*(Also flagged|What a human should review)/) ? 0 \
                 : ((l ~ /^[ \t]*###[ \t]*Findings/) ? 1 : 2)
      curhdr = nb; cur = 0; pb = 0; continue
    }
    # AN ATX HEADING OWNS ITS LINE AND NOTHING ELSE. `## Claude review — X` used
    # to open an ordinary block, so a paragraph the model wrote directly beneath
    # it with no blank line between was folded in by the continuation rule below
    # — and when that block went over budget the TITLE went with it. Measured at
    # the default 1800: the posted body opened with a blank line and then
    # `### Findings (2)`, with no `## Claude review` line anywhere. hardcut()
    # does not rescue that; it only fires when NOTHING was admitted.
    if (l ~ /^[ \t]*#/) {
      nb++; bstart[nb] = (pb ? pb : i); bend[nb] = i; bfirst[nb] = i
      bishdr[nb] = 0; bhdr[nb] = curhdr; cur = 0; pb = 0; continue
    }
    # A multi-line construct: absorbed WHOLE by whatever is open (so an indented
    # `  > note` under a bullet still belongs to that bullet), otherwise a block
    # of its own running to its last line. Either way it is never split.
    if (grpend[i] > 0) {
      if (!istop(l) && cur > 0 && pb == 0) { bend[cur] = grpend[i]; i = grpend[i]; continue }
      nb++; bstart[nb] = (pb ? pb : i); bend[nb] = grpend[i]; bfirst[nb] = i
      bishdr[nb] = 0; bhdr[nb] = curhdr; cur = nb; pb = 0; i = grpend[i]; continue
    }
    # A continuation line: not a bullet of its own, not separated by a blank,
    # and something is open to continue.
    if (!istop(l) && cur > 0 && pb == 0) { bend[cur] = i; continue }
    nb++; bstart[nb] = (pb ? pb : i); bend[nb] = i; bfirst[nb] = i
    bishdr[nb] = 0; bhdr[nb] = curhdr; cur = nb; pb = 0
  }
  for (b = 1; b <= nb; b++) {
    bcost[b] = 0
    for (i = bstart[b]; i <= bend[b]; i++) { bcost[b] += mlen(line[i]) + 1; blk[i] = b }
    if (bishdr[b]) { brank[b] = 900; continue }
    fl = line[bfirst[b]]
    w = (bhdr[b] ? secw[bhdr[b]] : 2)
    if (istop(fl)) brank[b] = 1 + srank(bsev(fl)) * 4 + w
    else if (fl ~ /^[ \t]*#/) brank[b] = 0
    else brank[b] = 20
  }
  # THE TITLE LINE IS NOT NEGOTIABLE. It is what identifies the comment as the
  # review; a body that opens mid-sentence, or with no `## Claude review` line at
  # all, is indistinguishable from a rendering failure. Rank 0 was not enough on
  # its own (see the ATX arm above), so it is admitted BEFORE the ranked passes
  # and outside the budget test. If even the title alone overruns `max` it is
  # hard-cut on a codepoint boundary and it is all that is printed.
  n = 0; tb = 0; tcut = 0; titlecut = ""
  for (b = 1; b <= nb; b++) if (!bishdr[b] && brank[b] == 0) { tb = b; break }
  if (tb > 0) {
    adm[tb] = 1; n = bcost[tb]
    if (n > max) { tcut = 1; titlecut = hardcut(line[bfirst[tb]], max); n = max }
  }
  # awk has no sort; the ranks are a handful of small integers, so one pass per
  # rank is both stable (original order within a rank) and cheap.
  for (r = 0; r <= 20; r++) {
    for (b = 1; b <= nb; b++) {
      if (bishdr[b] || adm[b] || brank[b] != r) continue
      need = bcost[b]; hb = bhdr[b]
      # A block that is not a top-level bullet must not PULL IN a bullet-list
      # header: prune() deletes a `### Findings` / `### Also flagged` /
      # `### What a human should review` section holding no bullet, so admitting
      # the pair spent budget on two lines that never reach the page — and cut
      # content that would otherwise have fit. Bullets are ranked ahead of prose,
      # so by the time this fires the header is already in if anything earned it.
      if (hb > 0 && !adm[hb] && isbulletsec(line[bfirst[hb]]) && !istop(line[bfirst[b]])) continue
      if (hb > 0 && !adm[hb]) need += bcost[hb]
      if (n + need > max) { lostb[b] = 1; continue }
      if (hb > 0 && !adm[hb]) { adm[hb] = 1; n += bcost[hb] }
      adm[b] = 1; n += bcost[b]
    }
  }
  kept = 0
  for (i = 1; i <= NR; i++) {
    if (blk[i] == 0 || !adm[blk[i]]) continue
    if (tcut && blk[i] == tb) { if (i == bfirst[tb] && length(titlecut) > 0) out[++kept] = titlecut; continue }
    out[++kept] = line[i]
  }
  # NOTHING IS SILENTLY DROPPED. A `### Findings` bullet the budget cut is still
  # in the round-2 state block; an `### Also flagged` or human-review item is
  # not, because it is the fallback for a comment that could not be posted at
  # all. So those, and only those, are named to the run log.
  if (lostfile != "")
    for (b = 1; b <= nb; b++)
      if (lostb[b] && bhdr[b] > 0 && secw[bhdr[b]] == 0 && istop(line[bfirst[b]]))
        print line[bfirst[b]] > lostfile
  # Not one line fit: cut mid-line rather than return an empty body.
  if (kept == 0 && NR > 0) {
    h = hardcut(line[1], max)
    if (length(h) > 0) out[++kept] = h
  }
  kept = prune(kept)
  # A header's count was written before the budget was known. Whatever the cut
  # removed, the number must describe what is left — `### Findings (15)` over 9
  # bullets is the review lying about how much it found.
  renumber(kept)
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
# A DROPPED COMMENT WHOSE FINDING THE BODY ALREADY LISTS MUST NOT BE PRINTED
# TWICE. 4a strips only bullets that duplicate a comment going INLINE — that is
# deliberate, because a bullet for a dropped comment IS the fallback. But models
# routinely emit a finding on BOTH surfaces, so a comment that overflowed the cap
# kept its original `### Findings` bullet AND collected a new `### Also flagged`
# one, and the reader saw the same finding back to back. At 25 comments the
# duplicate list overflowed the budget and the truncator cut it, which is how a
# reader got `### Findings (15)` over 9 bullets with 6 findings reaching nobody.
# So: filter the fallback against the body that survived the strip, before the
# header counts it — matching on the FULL signature (path, severity, title), not
# on path+line, which deletes a different finding that happens to share a line.
if [ -s "$WORK/fallback.md" ]; then
  if LC_ALL=C awk -v mode=fbindex -f "$WORK/budget.awk" "$WORK/body.raw" > "$WORK/body-keys.txt" \
     && LC_ALL=C awk -v mode=fbfilter -v keysfile="$WORK/body-keys.txt" \
          -f "$WORK/budget.awk" "$WORK/fallback.md" > "$WORK/fallback.dedup"; then
    FB_BEFORE=$(grep -c '' "$WORK/fallback.md")
    mv "$WORK/fallback.dedup" "$WORK/fallback.md"
    FB_AFTER=$(grep -c '' "$WORK/fallback.md" || true)
    if [ "${FB_AFTER:-0}" -lt "${FB_BEFORE:-0}" ]; then
      echo "Dropped $(( FB_BEFORE - FB_AFTER )) 'Also flagged' bullet(s) the body already lists."
    fi
  else
    echo "::warning::Could not de-duplicate the fallback bullets against the body — a finding may appear twice."
  fi
fi
if [ -s "$WORK/fallback.md" ]; then
  { echo ""
    echo "### Also flagged ($(grep -c '' "$WORK/fallback.md"))"
    cat "$WORK/fallback.md"
  } >> "$WORK/body.raw"
fi

TRUNC_MARKER=$'\n_…truncated to fit the review budget._\n'
AVAIL=$(( BODY_MAX - $(blen "$FOOTER") - $(blen "$SPEC_NOTICE") - $(blen "$DEV_ENV_NOTICE") - $(blen "$DEV_ENV_BANNER") ))
MEASURED=$(LC_ALL=C awk -v mode=measure -f "$WORK/budget.awk" "$WORK/body.raw")
if [ "${MEASURED:-0}" -gt "$AVAIL" ]; then
  echo "Body measures $MEASURED bytes pre-expansion, over the ${BODY_MAX}-byte budget — truncating by value (severity first, and the sections that have no other surface ahead of ordinary prose)."
  : > "$WORK/fit-lost.txt"
  LC_ALL=C awk -v mode=fit -v lostfile="$WORK/fit-lost.txt" \
    -v max="$(( AVAIL - $(blen "$TRUNC_MARKER") ))" \
    -f "$WORK/budget.awk" "$WORK/body.raw" > "$WORK/body.trunc"
  mv "$WORK/body.trunc" "$WORK/body.raw"
  printf '%s' "$TRUNC_MARKER" >> "$WORK/body.raw"
  # An `### Also flagged` / `### What a human should review` item the budget cut
  # reaches the reader NOWHERE: it could not be posted inline, which is why it
  # was there, and the fallback sections are not carried in the state block. The
  # generic "over the budget — truncating" line said nothing about which. See
  # this file's NOTHING IS SILENTLY DROPPED banner.
  if [ -s "$WORK/fit-lost.txt" ]; then
    while IFS= read -r lost_line; do
      [ -z "$lost_line" ] && continue
      lost_line=$(printf '%s' "$lost_line" \
        | sed 's/^[-*][ \t]*//; s/^\[ \][ \t]*//; s/{{LINK:\([^{}]*\)}}/\1/g')
      echo "::warning::Over the ${BODY_MAX}-byte body budget: dropped \"$lost_line\" — it could not be posted inline either, so it now reaches the reader nowhere."
    done < "$WORK/fit-lost.txt"
  fi
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
  # THE BANNER GOES DIRECTLY UNDER THE VERDICT HEADING, not in the footer's
  # small print. A requested pass that never ran is the first thing the reader
  # needs, not a `<sub>` line they scroll past — that placement is exactly how
  # spendfuse#351 read as a clean review of a screen nobody had looked at. Line
  # 1 of body.raw is `## Claude review — <verdict>`; the banner follows it, and
  # it is written AFTER truncation so no finding can evict it and it can never
  # be the thing that gets cut.
  if [ -n "$DEV_ENV_BANNER" ] && [ "${BANNER_PLACED:-0}" = "0" ]; then
    printf '%s\n' "$DEV_ENV_BANNER" >> "$WORK/body.md"
    BANNER_PLACED=1
  fi
done < "$WORK/body.raw"
# An empty body.raw never entered the loop, so the banner still owes its slot.
if [ -n "$DEV_ENV_BANNER" ] && [ "${BANNER_PLACED:-0}" = "0" ]; then
  printf '%s\n' "$DEV_ENV_BANNER" >> "$WORK/body.md"
fi

# Before the footer because it is content, not metadata, and after truncation
# because it is not measured — see 2c.
# THE FOOTER GOES LAST. It is the cost/logs line that closes the review, so
# every notice above is content and belongs above it. Both notices used to be
# appended AFTER it, which left a warning trailing the line that should end the
# body.
printf '%s' "$SHOT_GALLERY" >> "$WORK/body.md"
printf '%s' "$SPEC_NOTICE" >> "$WORK/body.md"
printf '%s' "$DEV_ENV_NOTICE" >> "$WORK/body.md"
printf '%s' "$FOOTER" >> "$WORK/body.md"
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
# Seeded, not left missing: section 8 reads it, and a skip-marked review skips
# the whole block below.
: > "$WORK/this-round.json"
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
       # Checks are EXCLUDED HERE TOO, and inline is where a check NORMALLY lives — the
       # `dropped` arm below only ever saw the ones that overflowed the cap. The
       # tell is right there in `csev`: this arm derives the severity from the
       # body text, and a `**check**` has none, so a question was persisted as a
       # finding with `sev: ""`, warned about as `(, src/foo.ts)`, and — since
       # round 2 can never "resolve" a question — carried forever.
       | map(select(((.body // "") | test("^\\s*\\*\\*check\\*\\*"; "i")) | not))
       | map({p: (.path // ""), l: (.line | num), sev: csev,
              t: ((.body // "") | split("\n") | (.[0] // "")
                  | sub("^\\s*\\*\\*[A-Za-z]+\\*\\*\\s*"; "")),
              fs: (((.body // "") | split("\n\n")) | (.[1] // "")),
              cf: "", inline: true, _o: 1}))
    + ((($sp[0].dropped) // [])
       # Checks are EXCLUDED, exactly as they already are from kept-keys.txt and
       # fallback.md — this arm was the one that missed it. A check is a
       # question, not a defect: round 2 has no way to "resolve" one, so a check
       # that overflowed the cap was persisted as a finding with `sev: ""`,
       # carried forever, and rendered as `(, src/foo.ts)`.
       | map(select(.kind != "check"))
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
    # THE ROUND A FINDING WAS FIRST SEEN IS NOT A `carried_from` PRIVILEGE.
    # `r` was inherited only through the re-wording escape valve, so a finding
    # the model simply RE-LISTED in the same words got a fresh id-match, no
    # `cf`, and `r: $round`. Verified over three rounds: R1 files it (r:1), R2
    # re-lists it verbatim (r:2), R3 reports `_(first seen round 2)_`. That
    # number is what a reviewer uses to judge how long a finding has been
    # ignored, so resetting it understates the age of exactly the findings that
    # matter most. Any id the priors already carry keeps the round they carry.
    | ($prior | map({key: .id, value: (.r // 1)}) | from_entries) as $pr
    | map(if $pr[.id] != null then . + {r: ([$pr[.id], .r] | min)} else . end)
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

# ── 5. Supersede prior crash banners ─────────────────────────────────────────
# ONLY A RUN THAT JUDGED THE DIFF MAY CLEAR A CRASH BANNER — the same rule
# section 7 applies to standing blocking reviews, and for the same reason. A
# crash banner says "**Action required:** a human should review this PR" about an
# earlier failure nobody has resolved. guard.sh's oversized split request read no
# code, so PATCHing that banner into "_Superseded by a newer Claude review run on
# this PR._" retires a human-action signal on the strength of a run that judged
# nothing. Section 7 already refused to dismiss for this body; section 5 ran
# unconditionally.
echo "::group::Supersede prior crash banners"
if is_skip_marked; then
  echo "Skip-marked review (judged nothing) — leaving prior crash banners standing."
else
  supersede_crash_banners
fi
echo "::endgroup::"

# ── 6. Atomic POST ───────────────────────────────────────────────────────────
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
  # The banner is chosen off THIS flag, not off `[ -s "$REVIEW_JSON" ]` — which
  # is always true here, so every POST failure used to render as "the result
  # could not be parsed … almost always a transient serialization slip … re-run,
  # it usually succeeds". The output parsed fine and a 422 recurs on retry.
  POST_REJECTED=1
  POST_ERROR=$(printf '%s' "$POST_RESPONSE" | tr '\n' ' ' | head -c 300)
  crash_exit "Review POST failed — verdict is $VERDICT but no PR review was created: $(echo "$POST_RESPONSE" | head -c 400)"
else
  REVIEW_ID=$(echo "$POST_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
  echo "Posted review${REVIEW_ID:+ #$REVIEW_ID}"
fi
echo "::endgroup::"

# ── 7. Dismiss own stale blocking reviews — ONLY NOW ────────────────────────
# THIS RUNS AFTER THE POST, AND THAT ORDER IS THE WHOLE POINT. It used to run
# before it, so a rejected POST (a 422 on an inline comment line — unvalidated
# whenever `pulls/files` returns no patch data) went: dismiss succeeds, POST
# fails, exit 1 — and the PR was left with NO blocking review at all. The
# standing CHANGES_REQUESTED was the only thing holding the merge, and it was
# cleared to make room for a review that never arrived. crash_exit() above never
# returns, so reaching this line is itself the proof that a replacement is up.
#
# Only a review that JUDGED the diff may clear a standing one. A skip-marked
# body (guard.sh's oversized split request) read no code, so dismissing on its
# way in would (a) un-block a PR nobody re-reviewed and (b) leave the next
# judged round reading `prior_verdict` off a DISMISSED review, which means "the
# author opted out" (see prior-review-state.sh). Leave it standing.
echo "::group::Dismiss stale reviews"
if is_skip_marked; then
  echo "Skip-marked review (judged nothing) — leaving standing reviews in place."
  STALE_IDS=""
elif [ -z "$OUT_DIR" ] && [ -z "$REVIEW_ID" ]; then
  # The list is read AFTER the POST, so the review this run just created is in
  # it — and a REQUEST_CHANGES review dismissing ITSELF unblocks the PR exactly
  # the way the old ordering did. It is excluded by id; with no id to exclude,
  # the safe direction is to leave every standing review alone. A stale block is
  # a nuisance, an unblocked PR is the failure this section exists to prevent.
  echo "::warning::The POST returned no review id — leaving standing reviews in place rather than risk dismissing the review just posted."
  STALE_IDS=""
else
  STALE_IDS=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" 2>/dev/null \
    | jq -s --arg bot "$BOT" --arg newid "${REVIEW_ID:-}" '
        (add // [])
        | [.[] | select(.user.login == $bot and (.state == "CHANGES_REQUESTED" or .state == "APPROVED")
                        and ((.id | tostring) != $newid)) | .id]
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

# ── 8. Step summary ──────────────────────────────────────────────────────────
# THE SUMMARY COUNTS THE SAME FLOOR THE STATE BLOCK DOES, NOT meta ALONE.
# 4c already documents why meta cannot be trusted for this: it is model-written
# and can be empty or absent while three criticals post inline. The state block
# was rebuilt on `kept` + `dropped` unioned with meta; the summary was left
# reading meta, so a REQUEST_CHANGES carrying two criticals rendered
# `### Findings (0)` and `::warning::Claude review: REQUEST_CHANGES — 0 blocking
# finding(s)`. `this-round.json` IS that union (checks excluded, ids resolved),
# so both surfaces now report one number. A skip-marked review judged nothing
# and writes no state, which is why the file is seeded empty above.
SUMMARY_FINDINGS="$WORK/summary-findings.json"
if [ -s "$WORK/this-round.json" ] && jq -e 'type == "array"' "$WORK/this-round.json" >/dev/null 2>&1; then
  jq 'map({sev: (.sev // ""), p: (.p // ""), l: (.l // 0), t: (.t // "")})
      | sort_by(if .sev == "critical" then 0 elif .sev == "major" then 1
                elif .sev == "minor" then 2 else 3 end)' \
    "$WORK/this-round.json" > "$SUMMARY_FINDINGS" 2>/dev/null \
    || jq -n '[]' > "$SUMMARY_FINDINGS"
else
  jq '(.meta.findings // [])
      | map({sev: ((.severity // "") | ascii_downcase), p: (.path // ""),
             l: (.line // 0), t: (.title // "")})' "$REVIEW_JSON" > "$SUMMARY_FINDINGS" 2>/dev/null \
    || jq -n '[]' > "$SUMMARY_FINDINGS"
fi
FINDING_COUNT=$(jq 'length' "$SUMMARY_FINDINGS" 2>/dev/null || echo 0)
FINDING_COUNT=${FINDING_COUNT:-0}
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
  jq -r '.[] | "- **\((if (.sev // "") == "" then "?" else .sev end) | ascii_upcase)** `\(if .p == "" then "?" else .p end):\(if (.l // 0) > 0 then .l else "?" end)` — \(if (.t // "") == "" then "Untitled" else .t end)"' \
    "$SUMMARY_FINDINGS"
  if [ "$HUMAN_COUNT" -gt 0 ]; then
    echo ""
    echo "### For a human to review ($HUMAN_COUNT)"
    jq -r '(.meta.human_review // [])[] | "- `\(.path // "?"):\(.end_line // .line // "?")` — \(.what_it_does // "")"' "$REVIEW_JSON"
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
