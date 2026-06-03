#!/usr/bin/env bash
set -euo pipefail

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

# run() executes a command, or just prints it in --dry-run mode.
run() { if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

git fetch origin --tags --quiet

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  echo "error: $VERSION already exists — immutable tags are never reused." >&2
  exit 1
fi

echo "→ publishing origin/main tip: $(git --no-pager log --oneline -1 origin/main)"

run git tag "$VERSION" origin/main      # immutable rollback anchor (cut FIRST)
run git tag -f "$MAJOR" origin/main     # point floating major at the same tip
run git push origin "$VERSION"
run git push origin "$MAJOR" --force

if [ "$DRY_RUN" -eq 1 ]; then
  echo "→ dry-run — nothing pushed."
else
  echo "→ published $VERSION; $MAJOR now points at $(git --no-pager log --oneline -1 "$VERSION")"
fi
