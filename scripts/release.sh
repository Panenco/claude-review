#!/usr/bin/env bash
# No `set -e`: this script fails fast via explicit `|| exit 1` (see run() and
# the fetch below) so a failed git step never silently continues to a push.
set -uo pipefail

# release.sh — publish a pipeline change to consumer repos.
#
# Two steps: cut an immutable `vX.Y.Z` rollback anchor at the current
# origin/main tip, then point the floating major tag (`v2`) at the same commit.
# Consumers pin the floating major; the immutable tag is a known-good rollback
# point. (Tags origin/main, NOT your local HEAD, which may be stale.)
#
#   scripts/release.sh v2.2.0            # publish
#   scripts/release.sh v2.2.0 --dry-run  # print the commands without pushing

VERSION=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    v*)        if [ -n "$VERSION" ]; then echo "error: unexpected extra arg: $arg" >&2; exit 1; fi; VERSION="$arg" ;;
    *)         echo "error: unknown arg: $arg (usage: scripts/release.sh vX.Y.Z [--dry-run])" >&2; exit 1 ;;
  esac
done

[ -n "$VERSION" ] || { echo "usage: scripts/release.sh vX.Y.Z [--dry-run]" >&2; exit 1; }
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like vX.Y.Z (got: $VERSION)" >&2; exit 1; }
MAJOR="${VERSION%%.*}"   # v2.2.0 -> v2

# run CMD... — the --dry-run gate for every side-effecting (tag/push) command.
# Normal run: executes CMD and aborts the release on failure, so a half-applied
# tag set is never pushed. --dry-run: prints CMD prefixed with [dry-run] and
# does nothing. Read-only git queries are called directly, not through run().
run() {
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; return; fi
  "$@" || { echo "error: command failed: $*" >&2; exit 1; }
}

git fetch origin --tags --quiet || { echo "error: git fetch failed" >&2; exit 1; }

TIP="$(git rev-parse origin/main)"

# The script is idempotent: re-running it FINISHES a partially-applied release
# (e.g. the immutable tag pushed but the major-tag move then failed) instead of
# dead-ending. Reuse is rejected ONLY when the immutable tag is already published
# at a DIFFERENT commit than this tip — the real "never re-point a release" rule.
# Already published at this exact tip → proceed and converge. Local-only (never
# pushed) → no remote sha, overwritten by the -f cut below.
REMOTE_VERSION_SHA="$(git ls-remote --tags origin "refs/tags/$VERSION" | cut -f1)"
if [ -n "$REMOTE_VERSION_SHA" ] && [ "$REMOTE_VERSION_SHA" != "$TIP" ]; then
  echo "error: $VERSION already published at ${REMOTE_VERSION_SHA:0:12}, not origin/main (${TIP:0:12})." >&2
  echo "       Immutable tags are never re-pointed — pick a new version." >&2
  exit 1
fi

echo "→ publishing origin/main tip: $(git --no-pager log --oneline -1 "$TIP")"

# -f makes each step re-runnable: it overwrites a stale local leftover, or
# re-points to the same already-published tip on a retry — both no-op on the
# remote (the immutable push is then "up to date"). The major-tag push always
# runs, so a re-run completes a move that failed the first time.
run git tag -f "$VERSION" "$TIP"   # immutable rollback anchor (cut FIRST)
run git tag -f "$MAJOR" "$TIP"     # point floating major at the same tip
run git push origin "$VERSION"
run git push origin "$MAJOR" --force

if [ "$DRY_RUN" -eq 1 ]; then
  echo "→ dry-run — nothing pushed."
else
  echo "→ published $VERSION; $MAJOR now points at $(git --no-pager log --oneline -1 "$VERSION")"
fi
