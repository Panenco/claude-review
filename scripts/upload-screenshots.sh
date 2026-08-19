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
# grant `Bash` with `gh api` reachable — and the review session runs the OFFICIAL
# `code-review` plugin prompt (`review-native`) over ATTACKER-CONTROLLED PR
# content. Session-wide `--disallowedTools` cannot deny `gh api` selectively, so
# an unqualified `gh api` grant meant `gh api -X POST /repos/.../issues/N/comments`
# and friends stayed reachable by that plugin's ~10 subagents. Moving every
# privileged call in here lets `pr-review.yml` deny `Bash(gh api:*)` outright,
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
#
# Output (stdout): one line per SUCCESSFULLY uploaded file —
#   https://github.com/<owner>/<repo>/raw/review-assets/pr-<PR_NUMBER>/<basename>
# That is the exact embed form the orchestrator inlines into findings; it renders
# on private repos, which raw.githubusercontent.com does not.
#
# Exit 0 with no output means "nothing published" — no screenshots, none of them
# a real PNG, or the upload failed. Failure of this whole path is NON-FATAL by
# design: the orchestrator proceeds without embeds. It therefore never exits
# non-zero for an upload problem, only for missing required inputs.

R="${GITHUB_REPOSITORY:-}"
PR="${PR_NUMBER:-}"
DIR="${SCREENSHOT_DIR:-/tmp/screenshots}"

if [ -z "$R" ] || [ -z "$PR" ]; then
  echo "upload-screenshots: GITHUB_REPOSITORY and PR_NUMBER are required" >&2
  exit 2
fi

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
# not an error — it selects the "create" arm at the bottom.
BASE_SHA=$(gh api "repos/$R/git/refs/heads/review-assets" --jq '.object.sha' 2>/dev/null || true)
BASE_TREE=""
[ -n "$BASE_SHA" ] && BASE_TREE=$(gh api "repos/$R/git/commits/$BASE_SHA" --jq '.tree.sha')

ENTRIES="[]"
for img in "$DIR"/*.png; do
  # A capture that failed mid-write leaves a truncated or empty file behind. Publishing one embeds
  # a broken image in the review, so upload only what is actually a PNG. If `file` is unavailable
  # the check passes, because dropping every screenshot is the worse failure.
  MIME=$(file -b --mime-type "$img" 2>/dev/null || echo image/png)
  [ "$MIME" = "image/png" ] || continue
  B=$(basename "$img")
  # stdin --input, not -f content= — the argv form silently drops blobs >~200 KB
  #
  # `base64 -w0` is GNU-only; BSD/macOS base64 has no -w and wraps at 76 columns,
  # which the fixture test would trip over. Capture into a variable first so a
  # rejected -w0 cannot leak a partial blob into the pipe, then fall back.
  B64=$(base64 -w0 < "$img" 2>/dev/null) || B64=$(base64 < "$img" | tr -d '\n')
  SHA=$(printf '%s' "$B64" | jq -Rs '{content: ., encoding: "base64"}' \
    | gh api "repos/$R/git/blobs" --method POST --input - --jq '.sha') || continue
  ENTRIES=$(echo "$ENTRIES" | jq --arg p "pr-${PR}/$B" --arg s "$SHA" '. + [{path:$p,mode:"100644",type:"blob",sha:$s}]')
done

# Every capture was rejected or every blob POST failed — nothing to commit.
[ "$(echo "$ENTRIES" | jq length)" -gt 0 ] || exit 0

TREE=$(echo "$ENTRIES" | jq -c --arg bt "$BASE_TREE" 'if $bt == "" then {tree:.} else {base_tree:$bt,tree:.} end' \
  | gh api "repos/$R/git/trees" --method POST --input - --jq '.sha') || exit 0
COMMIT=$(gh api "repos/$R/git/commits" --method POST -f message="Review screenshots (auto-replaced)" -f tree="$TREE" --jq '.sha') || exit 0

# Update-vs-create split: PATCH an existing ref (force, because the branch is a
# scratch asset store and history there is worthless), POST a new one otherwise.
if [ -n "$BASE_SHA" ]; then
  gh api "repos/$R/git/refs/heads/review-assets" --method PATCH -f sha="$COMMIT" -F force=true >/dev/null || exit 0
else
  gh api "repos/$R/git/refs" --method POST -f ref="refs/heads/review-assets" -f sha="$COMMIT" >/dev/null || exit 0
fi

# Only now are the blobs actually reachable at the URLs below, so this is the
# only place the URLs may be printed. Printing them earlier would hand the
# orchestrator embeds for a commit that never landed.
echo "$ENTRIES" | jq -r --arg r "$R" '.[] | "https://github.com/\($r)/raw/review-assets/\(.path)"'
exit 0
