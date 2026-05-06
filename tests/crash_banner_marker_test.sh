#!/usr/bin/env bash
set -uo pipefail

# crash_banner_marker_test.sh — regression for the crash-banner /
# superseded-review marker logic in post-review.sh.
#
# cursor#bugbot caught two related issues on PR #28:
#   - the supersession filter `contains("<!-- claude-review-crash -->")`
#     does NOT false-match the prior superseded form (verified — the
#     superseded body's substring after "claude-review-crash" diverges).
#     But the marker-overlap concern was real: any future change to the
#     supersession filter could flip this. Test the boundary explicitly.
#   - the idempotency filter excluding `<!-- claude-review-crash -->` did
#     NOT exclude the superseded form, which meant a re-run after a
#     prior crash + supersession on the same SHA would treat the
#     superseded review as "already substantive" and skip the new POST.
#     Fixed by switching the supersede body to a distinct marker
#     (`<!-- claude-review-superseded -->`) and adding it to the
#     idempotency-excluded set.
#
# This test pins all four cases:
#   1. fresh crash banner — supersession filter matches, idempotency excludes
#   2. superseded review (new marker) — supersession filter does NOT match,
#      idempotency excludes
#   3. legacy superseded review (old marker, kept around to reflect what
#      may exist on PRs from before the marker change) — supersession
#      does NOT match (boundary preserved), idempotency does NOT exclude
#      (acknowledged; old PRs' supersession form is rare; documented as
#      a degraded edge)
#   4. ordinary substantive review — supersession does NOT match,
#      idempotency does NOT exclude

cd "$(dirname "$0")/.."

fail=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — want '$want', got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

CRASH_BODY='<!-- claude-review-crash -->

> **Claude Review — incomplete** :warning:'

# Current (post-fix) superseded body — uses the distinct marker.
SUPERSEDED_BODY='<!-- claude-review-superseded -->

_Superseded by a successful review run on `abc123`._'

# Legacy (pre-fix) superseded body — what may exist on PRs from before
# the marker change. Tested for boundary safety only.
LEGACY_SUPERSEDED_BODY='<!-- claude-review-crash superseded -->

_Superseded by a successful review run on `def456`._'

ORDINARY_BODY='## Claude PR Review — APPROVE

### Spec sources
- Linked issue: #1
'

# Mirror the supersession filter from post-review.sh:300-302.
matches_supersession_filter() {
  local body="$1"
  printf '%s' "$body" | jq -Rrs 'contains("<!-- claude-review-crash -->")'
}

# Mirror the idempotency-exclusion logic from post-review.sh:240-260.
# The filter EXCLUDES (returns false → "skip this review") when either
# marker is present.
should_exclude_from_idempotency() {
  local body="$1"
  printf '%s' "$body" | jq -Rrs '
    (contains("<!-- claude-review-crash -->"))
    or (contains("<!-- claude-review-superseded -->"))
  '
}

echo "── Supersession filter (matches only fresh crash banners) ──"
assert_eq "fresh crash banner — match"        "true"  "$(matches_supersession_filter "$CRASH_BODY")"
assert_eq "current superseded — NO match"     "false" "$(matches_supersession_filter "$SUPERSEDED_BODY")"
assert_eq "legacy superseded — NO match"      "false" "$(matches_supersession_filter "$LEGACY_SUPERSEDED_BODY")"
assert_eq "ordinary review — NO match"        "false" "$(matches_supersession_filter "$ORDINARY_BODY")"

echo ""
echo "── Idempotency exclusion (skip both crash + current superseded) ──"
assert_eq "fresh crash banner — excluded"     "true"  "$(should_exclude_from_idempotency "$CRASH_BODY")"
assert_eq "current superseded — excluded"     "true"  "$(should_exclude_from_idempotency "$SUPERSEDED_BODY")"
assert_eq "ordinary review — NOT excluded"    "false" "$(should_exclude_from_idempotency "$ORDINARY_BODY")"
# Legacy superseded form (pre-fix marker) is intentionally NOT excluded:
# the new code emits the new marker, the legacy form only persists on
# old PRs that already had a crash+success cycle before this change.
# Tolerable degraded edge for the migration window.
assert_eq "legacy superseded — NOT excluded (acknowledged degraded edge)" "false" "$(should_exclude_from_idempotency "$LEGACY_SUPERSEDED_BODY")"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All crash-banner-marker tests passed."
  exit 0
else
  echo "$fail crash-banner-marker test(s) failed."
  exit 1
fi
