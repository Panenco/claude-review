#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): explicit exits on every path instead.

# upload-screenshots.sh — publishes the functional tester's PNGs to the repo's
# `review-assets` branch and prints one embeddable URL per uploaded file.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE BLOCK IN skills/review-orchestrator.md.
# This is the ONLY privileged GitHub API surface the review session needs: it
# POSTs blobs/trees/commits and PATCHes a ref. Everything else the pipeline's own
# agents do against GitHub is a read that `gh pr view/diff/list`, `gh issue view`
# and `gh search` already cover.
#
# As long as those writes were spelled out inline in a skill, the session had to
# grant `Bash` with `gh api` reachable — and every agent in this session reads
# ATTACKER-CONTROLLED PR content. Session-wide `--disallowedTools` cannot deny
# `gh api` selectively, so an unqualified `gh api` grant meant
# `gh api -X POST /repos/.../issues/N/comments` and friends stayed reachable by
# any subagent. Moving every privileged call in here lets `pr-review.yml` deny
# `Bash(gh api:*)` outright,
# which restores the read-only posture the deleted separate `native-review` job
# had (it ran with `contents: read` and a narrow allowlist) — and that posture is
# what made moving the plugin in-session safe in the first place.
#
# Behaviour is a VERBATIM extraction of the block that used to live in
# `skills/review-orchestrator.md` § "Screenshot publishing". Do not "tidy" it:
# every guard below is there because the corresponding failure was observed.
#
# Inputs (env):
#   GITHUB_REPOSITORY  owner/repo (required)
#   PR_NUMBER          PR number — namespaces the uploaded path (required)
#   GITHUB_REPO_TOKEN  token with `contents: write` on the repo. Separate from the
#                      review identity's token because a custom App token may lack
#                      that scope. Falls through to gh's own GH_TOKEN/GITHUB_TOKEN
#                      resolution when empty.
#   SCREENSHOT_DIR     directory of captures (default /tmp/screenshots)
#   SCREENSHOT_UPLOAD_TIMEOUT_SECONDS
#                      total wall-clock budget for this script (default 60,
#                      `0` disables the watchdog). See "THE TIME BUDGET".
#   REVIEW_OUT_DIR     LOCAL-EVAL SEAM — see "THE DRY-RUN SEAM".
#
# Output (stdout): one line per SUCCESSFULLY uploaded file —
#   https://github.com/<owner>/<repo>/raw/review-assets/pr-<PR_NUMBER>/<basename>
# That is the exact embed form the orchestrator inlines into findings; it renders
# on private repos, which raw.githubusercontent.com does not.
#
# STDOUT IS URLS OR NOTHING — NEVER A DIAGNOSTIC. `post-review.sh` builds
# `![](<line>)` straight from these lines, keyed on the basename, so anything
# else on stdout renders as a BROKEN IMAGE in a public review and leaks whatever
# internal path the diagnostic mentioned. Two rules keep that impossible:
#   1. every diagnostic in this file goes to stderr (the job log), and
#   2. the emit at the bottom re-validates each line against a URL-safe charset
#      and drops anything that does not match.
#
# URL-SAFE BASENAMES ONLY, AND WHY WE SKIP RATHER THAN PERCENT-ENCODE.
# A basename with a space or a `)` breaks the caller's markdown outright
# (`![](.../01 my shot.png)` does not render; `02(evil).png` closes the link
# early and leaks literal text into the review). Percent-encoding the emitted
# path would be served correctly by GitHub — but it would ALSO change the last
# path segment, and post-review.sh keys its caption→URL map on
# `url | split("/") | last` matched against the tester's RAW basename. An encoded
# URL therefore misses the lookup and the shot is dropped from the gallery with
# no warning anywhere, which is strictly worse than dropping it here loudly.
# So: files whose basename is not `[A-Za-z0-9._-]+` are skipped, named in a
# `::warning::`, and counted as unpublished by the caller (which already warns
# when fewer files land than the tester named). If post-review.sh ever encodes
# its lookup key too, this gate can become an encoder.
#
# THE TIME BUDGET. `post-review.sh` invokes this script bare and posts the review
# AFTERWARDS, so a hung `gh api` here does not cost a gallery — it costs the
# whole review: the job burns to the workflow timeout and the PR gets nothing.
# The parent invocation therefore re-execs itself as a child under a watchdog and
# buffers the child's stdout; on timeout it prints NOTHING, warns on stderr and
# exits 0. Portability: GNU `timeout` (or Homebrew's `gtimeout`) is preferred
# because it puts the child in its own process group and kills the hung `gh` with
# it; a dev Mac without coreutils falls back to a pure-bash background+watchdog
# that needs no external binary.
#
# THE DRY-RUN SEAM. `REVIEW_OUT_DIR` is post-review.sh's local-eval seam: set it
# and every GitHub WRITE becomes an artifact instead of a call. This script is
# invoked by post-review.sh UNGUARDED, so it has to honour the same seam or a
# local dry run with FUNCTIONAL_REQUESTED=true and PNGs on disk performs REAL
# blob/tree/commit/ref writes against the live target repo. When it is set: no
# write call is made, one line per suppressed call is appended to
# `$REVIEW_OUT_DIR/actions.log` (post-review.sh's format), and the URLs that
# WOULD have been produced are still printed so the caller's rendering path is
# exercised. Reads still happen. As in post-review.sh, the seam refuses to run
# under GITHUB_ACTIONS — loudly, because a dry run that silently swallowed a real
# review is the only failure mode that matters here.
#
# Exit 0 with no output means "nothing published" — no screenshots, none of them
# a real PNG, none of them safely nameable, the budget ran out, or the upload
# failed. Failure of this whole path is NON-FATAL by design: the orchestrator
# proceeds without embeds. It therefore never exits non-zero for an upload
# problem, only for missing required inputs or a misconfigured seam.

REPO="${GITHUB_REPOSITORY:-}"
PR="${PR_NUMBER:-}"
DIR="${SCREENSHOT_DIR:-/tmp/screenshots}"
OUT_DIR="${REVIEW_OUT_DIR:-}"

# Same refusal, same wording as post-review.sh. To stderr, not stdout, because of
# the stdout contract above.
if [ -n "$OUT_DIR" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::error::REVIEW_OUT_DIR is a local-eval seam and must never be set in CI" >&2
  exit 1
fi

if [ -z "$REPO" ] || [ -z "$PR" ]; then
  echo "upload-screenshots: GITHUB_REPOSITORY and PR_NUMBER are required" >&2
  exit 2
fi

# ── the watchdog wrapper ─────────────────────────────────────────────────────
# Runs once, in the parent. The child re-exec carries UPLOAD_SCREENSHOTS_CHILD=1
# and falls straight through to the work below.
BUDGET="${SCREENSHOT_UPLOAD_TIMEOUT_SECONDS:-60}"
case "$BUDGET" in ''|*[!0-9]*) BUDGET=60 ;; esac
if [ -z "${UPLOAD_SCREENSHOTS_CHILD:-}" ] && [ "$BUDGET" -gt 0 ]; then
  BUF=$(mktemp) || {
    echo "::warning::upload-screenshots: mktemp failed — no gallery this run." >&2
    exit 0
  }
  # Overridable ONLY so the test can force the no-coreutils fallback; CI never
  # sets it. Unset (not empty) means "resolve it yourself".
  TMO="${UPLOAD_TIMEOUT_BIN-$(command -v timeout || command -v gtimeout || true)}"
  if [ -n "$TMO" ]; then
    UPLOAD_SCREENSHOTS_CHILD=1 "$TMO" -k 5 "$BUDGET" "${BASH:-bash}" "$0" > "$BUF"
    RC=$?
  else
    # Pure-bash fallback: background the child, arm a sleeper that TERMs then
    # KILLs it. The marker file, not the exit status, is what says "timed out" —
    # a signal death has no reserved status we could tell apart from the child's
    # own.
    MARK="$BUF.timedout"
    UPLOAD_SCREENSHOTS_CHILD=1 "${BASH:-bash}" "$0" > "$BUF" &
    KID=$!
    ( sleep "$BUDGET"
      kill -0 "$KID" 2>/dev/null || exit 0
      : > "$MARK"
      kill -TERM "$KID" 2>/dev/null
      sleep 2
      kill -KILL "$KID" 2>/dev/null ) >/dev/null 2>&1 &
    DOG=$!
    wait "$KID"
    RC=$?
    kill -TERM "$DOG" 2>/dev/null
    wait "$DOG" 2>/dev/null
    if [ -f "$MARK" ]; then RC=124; rm -f "$MARK"; fi
  fi
  # 124 = GNU timeout expired (or our marker), 137/143 = the -k escalation.
  if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ] || [ "$RC" -eq 143 ]; then
    rm -f "$BUF"
    echo "::warning::upload-screenshots: exceeded its ${BUDGET}s budget — posting the review without the gallery." >&2
    exit 0
  fi
  cat "$BUF"
  rm -f "$BUF"
  exit "$RC"
fi

if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR" || {
    echo "::error::could not create REVIEW_OUT_DIR '$OUT_DIR'" >&2
    exit 1
  }
fi
# One line per GitHub call this run did not make — same sink and same format as
# post-review.sh's helper. APPEND, never truncate: post-review.sh created the log
# and has already written to it by the time it calls us.
log_suppressed() { printf '%s\n' "$1" >> "$OUT_DIR/actions.log"; }

# Only override gh's token when we actually have one. Exporting an EMPTY GH_TOKEN
# would shadow the ambient GITHUB_TOKEN and turn every call below into a 401.
if [ -n "${GITHUB_REPO_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_REPO_TOKEN"
fi

# No screenshots → nothing to do. This early return is load-bearing: the common
# case is a review with `strategy: skip`, and the block must be a silent no-op
# there rather than a failed API call.
ls "$DIR"/*.png >/dev/null 2>&1 || exit 0

# The branch may not exist yet (first review ever on this repo). An absent ref is
# not an error — it selects the "create" arm at the bottom. A READ, so the dry
# run makes it too: which arm we would have taken is part of what it reports.
BASE_SHA=$(gh api "repos/$REPO/git/refs/heads/review-assets" --jq '.object.sha' 2>/dev/null || true)
BASE_TREE=""
[ -n "$BASE_SHA" ] && BASE_TREE=$(gh api "repos/$REPO/git/commits/$BASE_SHA" --jq '.tree.sha')

ENTRIES="[]"
for img in "$DIR"/*.png; do
  # A capture that failed mid-write leaves a truncated or empty file behind. Publishing one embeds
  # a broken image in the review, so upload only what is actually a PNG. If `file` is unavailable
  # the check passes, because dropping every screenshot is the worse failure.
  MIME=$(file -b --mime-type "$img" 2>/dev/null || echo image/png)
  [ "$MIME" = "image/png" ] || continue
  B=$(basename "$img")
  # The name has to survive `![](<url>)` in a public review body. See "URL-SAFE
  # BASENAMES ONLY" above for why this skips instead of encoding.
  case "$B" in
    ''|*[!A-Za-z0-9._-]*)
      echo "::warning::upload-screenshots: skipped '$B' — a basename outside [A-Za-z0-9._-] cannot be embedded safely; rename the capture." >&2
      continue ;;
  esac
  if [ -n "$OUT_DIR" ]; then
    log_suppressed "POST git/blobs pr-${PR}/$B"
    SHA="dry-run-not-uploaded"
  else
    # stdin --input, not -f content= — the argv form silently drops blobs >~200 KB
    #
    # `base64 -w0` is GNU-only; BSD/macOS base64 has no -w and wraps at 76 columns,
    # which the fixture test would trip over. Capture into a variable first so a
    # rejected -w0 cannot leak a partial blob into the pipe, then fall back.
    B64=$(base64 -w0 < "$img" 2>/dev/null) || B64=$(base64 < "$img" | tr -d '\n')
    SHA=$(printf '%s' "$B64" | jq -Rs '{content: ., encoding: "base64"}' \
      | gh api "repos/$REPO/git/blobs" --method POST --input - --jq '.sha') || continue
  fi
  ENTRIES=$(echo "$ENTRIES" | jq --arg p "pr-${PR}/$B" --arg s "$SHA" '. + [{path:$p,mode:"100644",type:"blob",sha:$s}]')
done

# Every capture was rejected or every blob POST failed — nothing to commit.
COUNT=$(echo "$ENTRIES" | jq length)
[ "${COUNT:-0}" -gt 0 ] || exit 0

if [ -n "$OUT_DIR" ]; then
  log_suppressed "POST git/trees $COUNT blob(s)"
  log_suppressed "POST git/commits Review screenshots (auto-replaced)"
  if [ -n "$BASE_SHA" ]; then
    log_suppressed "PATCH git/refs/heads/review-assets"
  else
    log_suppressed "POST git/refs refs/heads/review-assets"
  fi
else
  TREE=$(echo "$ENTRIES" | jq -c --arg bt "$BASE_TREE" 'if $bt == "" then {tree:.} else {base_tree:$bt,tree:.} end' \
    | gh api "repos/$REPO/git/trees" --method POST --input - --jq '.sha') || exit 0
  COMMIT=$(gh api "repos/$REPO/git/commits" --method POST -f message="Review screenshots (auto-replaced)" -f tree="$TREE" --jq '.sha') || exit 0

  # Update-vs-create split: PATCH an existing ref (force, because the branch is a
  # scratch asset store and history there is worthless), POST a new one otherwise.
  if [ -n "$BASE_SHA" ]; then
    gh api "repos/$REPO/git/refs/heads/review-assets" --method PATCH -f sha="$COMMIT" -F force=true >/dev/null || exit 0
  else
    gh api "repos/$REPO/git/refs" --method POST -f ref="refs/heads/review-assets" -f sha="$COMMIT" >/dev/null || exit 0
  fi
fi

# Only now are the blobs actually reachable at the URLs below, so this is the
# only place the URLs may be printed. Printing them earlier would hand the
# orchestrator embeds for a commit that never landed. (Under the seam nothing was
# uploaded at all, but the caller's rendering path still has to be exercised.)
#
# The last gate on the stdout contract: a line that is not a plain `https://`
# URL never reaches the caller, whatever produced it.
echo "$ENTRIES" | jq -r --arg r "$REPO" '.[] | "https://github.com/\($r)/raw/review-assets/\(.path)"' \
| while IFS= read -r line; do
    case "$line" in
      https://*[!A-Za-z0-9._~:/-]*|https:// )
        echo "::warning::upload-screenshots: suppressed a malformed embed URL." >&2 ;;
      https://*)
        printf '%s\n' "$line" ;;
      *)
        echo "::warning::upload-screenshots: suppressed non-URL output on stdout." >&2 ;;
    esac
  done
exit 0
