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

# Reject only if the immutable tag is already PUBLISHED on the remote — that is
# the real "never reuse a release" condition. A local-only tag is a leftover
# from an aborted prior run (e.g. a push that failed after the tag was cut) and
# must not block a retry, so we check the remote here, not local refs.
if git ls-remote --tags --exit-code origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "error: $VERSION already published — immutable tags are never reused." >&2
  exit 1
fi

echo "→ publishing origin/main tip: $(git --no-pager log --oneline -1 origin/main)"

# -f only ever overwrites a stale local leftover from an aborted prior run
# (we proved above the tag is not published), so a retry cuts cleanly.
run git tag -f "$VERSION" origin/main   # immutable rollback anchor (cut FIRST)
run git tag -f "$MAJOR" origin/main     # point floating major at the same tip
run git push origin "$VERSION"
run git push origin "$MAJOR" --force

if [ "$DRY_RUN" -eq 1 ]; then
  echo "→ dry-run — nothing pushed."
else
  echo "→ published $VERSION; $MAJOR now points at $(git --no-pager log --oneline -1 "$VERSION")"
fi
