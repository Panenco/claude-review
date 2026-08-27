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
# NOTHING IS SILENTLY DROPPED. A comment that cannot be posted inline (anchored
# outside a diff hunk, or past the 5-comment cap) becomes a body bullet under
# `### Also flagged` — under v4's inline-XOR-body rule a dropped comment would
# otherwise erase the finding from the review entirely.
#
# Exit semantics: 0 = a review reached the PR (REQUEST_CHANGES included — the
# blocking signal is the PR review, not the check color). 1 = pipeline failure
# (no usable orchestrator output, or the POST to GitHub failed).
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, REVIEW_BOT_USER
# Optional env: HEAD_SHA, GITHUB_STEP_SUMMARY, GITHUB_SERVER_URL, GITHUB_RUN_ID,
#               REVIEW_JSON, ORCH_LOG, JOB_START, REVIEW_BODY_MAX,
#               REVIEW_COMMENT_MAX, REVIEW_COMMENT_LIMIT

REPO="$GITHUB_REPOSITORY"
PR="$PR_NUMBER"
BOT="${REVIEW_BOT_USER:-github-actions[bot]}"
REVIEW_JSON="${REVIEW_JSON:-/tmp/review.json}"
ORCH_LOG="${ORCH_LOG:-/tmp/orchestrator-output.txt}"
JOB_START="${JOB_START:-/tmp/job-start}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
BODY_MAX="${REVIEW_BODY_MAX:-1200}"
COMMENT_MAX="${REVIEW_COMMENT_MAX:-700}"
COMMENT_LIMIT="${REVIEW_COMMENT_LIMIT:-5}"
WORK=$(mktemp -d) || { echo "::error::mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Byte length — the budgets are compared against `wc -c`, and ${#var} counts
# CHARACTERS, so a body with one em dash would otherwise be measured short.
blen() { printf '%s' "$1" | wc -c | tr -d ' '; }

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
    if gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id" -f body="$body" >/dev/null 2>&1; then
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
    gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - <<<"$payload" >/dev/null \
      || echo "::warning::Failed to post crash notification review"
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

# ── 3. Inline comments: in-hunk only, deduped, 5 max, 700 bytes each ────────
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
# the 5 that get posted inline and the rest that fall back to body bullets.
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
                | map({path, line, severity: sev, title: title,
                       reason: (if ._inhunk then "over the inline cap" else "outside a diff hunk" end)})) }
' "$WORK/comments.json" > "$WORK/split.json" \
  || { echo "::warning::Could not process inline comments — posting the body alone."
       jq -n '{kept: [], dropped: []}' > "$WORK/split.json"; }

jq '.kept' "$WORK/split.json" > "$WORK/comments.json"
# Each dropped comment becomes a body bullet — the finding must reach the reader
# somewhere, and under the inline-XOR-body rule the body does not already list it.
jq -r '.dropped[]
       | "- " + (if .severity == "" then "" else "**" + .severity + "** " end)
         + "{{LINK:" + .path + ":" + (.line | tostring) + "}} — " + .title' \
  "$WORK/split.json" > "$WORK/fallback.md"
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
if [ -s "$WORK/fallback.md" ]; then
  { echo ""
    echo "### Also flagged ($(grep -c '' "$WORK/fallback.md"))"
    cat "$WORK/fallback.md"
  } >> "$WORK/body.raw"
fi

# budget.awk — measures and truncates the PRE-expansion body.
#   mlen(line) = bytes, with each {{LINK:x}} counted as `x` (the wrapper is
#   exactly 9 bytes: `{{LINK:` + `}}`), which is what the model was told to count.
#   mode=measure → the whole file's measured byte size
#   mode=fit     → the file truncated to `max` measured bytes
# A trailing `###` section header whose every item was cut is dropped with them:
# a dangling `### Findings (2)` above nothing reads as a rendering bug.
cat > "$WORK/budget.awk" <<'BUDGET_AWK'
function nph(s,   n) { n = 0; while (match(s, /\{\{LINK:[^{}]*\}\}/)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
function mlen(s) { return length(s) - 9 * nph(s) }
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
{ line[NR] = $0; total += mlen($0) + 1 }
END {
  if (mode == "measure") { print total + 0; exit }
  n = 0; kept = 0
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
  while (kept > 0 && (out[kept] ~ /^[ \t]*$/ || out[kept] ~ /^[ \t]*###/)) kept--
  for (i = 1; i <= kept; i++) print out[i]
}
BUDGET_AWK

TRUNC_MARKER=$'\n_…truncated to fit the review budget._\n'
AVAIL=$(( BODY_MAX - $(blen "$FOOTER") ))
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
echo "Body: $(wc -c < "$WORK/body.md") bytes expanded (budget $BODY_MAX pre-expansion)"
echo "::endgroup::"

# ── 5. Dismiss own stale blocking reviews (keep COMMENTED for audit trail) ──
# Only a review that JUDGED the diff may clear a standing one. A skip-marked
# body (guard.sh's oversized split request) read no code, so dismissing on its
# way in would (a) un-block a PR nobody re-reviewed and (b) leave the next
# judged round reading `prior_verdict` off a DISMISSED review, which means "the
# author opted out" (see prior-review-state.sh). Leave it standing.
#
# Matched on the FIRST LINE only. An unanchored grep also matches a JUDGED
# review that quotes a marker in a finding, and would then leave the stale
# review it is supposed to dismiss standing.
echo "::group::Dismiss stale reviews"
if head -n1 "$WORK/body.md" 2>/dev/null \
     | grep -qE '^[[:space:]]*<!-- claude-review-(skipped|oversized) -->[[:space:]]*$'; then
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
  gh api --method PUT "repos/$REPO/pulls/$PR/reviews/$id/dismissals" \
    -f message="Superseded by new Claude review on updated commit." >/dev/null 2>&1 \
    || echo "::warning::Could not dismiss review $id (non-fatal)"
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
echo "Posting $VERDICT review with $(jq '.comments | length' "$WORK/payload.json") inline comments"
if ! POST_RESPONSE=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input "$WORK/payload.json" 2>&1); then
  echo "::endgroup::"
  crash_exit "Review POST failed — verdict is $VERDICT but no PR review was created: $(echo "$POST_RESPONSE" | head -c 400)"
fi
REVIEW_ID=$(echo "$POST_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
echo "Posted review${REVIEW_ID:+ #$REVIEW_ID}"
echo "::endgroup::"

# ── 8. Step summary ──────────────────────────────────────────────────────────
FINDING_COUNT=$(jq '(.meta.findings // []) | length' "$REVIEW_JSON")
HUMAN_COUNT=$(jq '(.meta.human_review // []) | length' "$REVIEW_JSON")
{
  echo "## Claude Review: $VERDICT"
  echo ""
  echo "### Findings ($FINDING_COUNT)"
  jq -r '(.meta.findings // [])[] | "- **\((.severity // "?") | ascii_upcase)** `\(.path // "?"):\(.line // "?")` — \(.title // "Untitled")"' "$REVIEW_JSON"
  if [ "$HUMAN_COUNT" -gt 0 ]; then
    echo ""
    echo "### For a human to review ($HUMAN_COUNT)"
    jq -r '(.meta.human_review // [])[] | "- `\(.path // "?"):\(.line // "?")` — \(.what_to_check // "")"' "$REVIEW_JSON"
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
