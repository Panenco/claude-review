#!/usr/bin/env bash
set -uo pipefail

# finding_title_fallback_test.sh — regression guard for issue #57.
#
# A finding that reaches the renderer without a `title` must never surface as
# the literal "null" in any posted text: the PR review body, inline comments,
# or the Actions step summary. The bug (Panenco/qit#6486) had two halves —
# the orchestrator merge contract didn't list `title` as required (so the
# orchestrator dropped it), and the renderers read `.title` bare, printing
# "null"/"Untitled" headers on real REQUEST_CHANGES reviews.
#
# Two checks:
#   1. Invariant (drift-proof): every `.title` read in scripts/*.sh carries a
#      `//` fallback. This reads the real scripts, so deleting a fallback in a
#      future edit re-breaks this test rather than silently regressing prod.
#   2. Behaviour: the fallback jq fragments render "Untitled" — not "null" —
#      for a title-less finding.
#   3. Contract: the orchestrator's all-findings.json schema lists `title` as
#      a required field, so the merge step is told to preserve it.

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

echo "── Invariant: no bare .title read in scripts/*.sh ──"
# A "bare" read is `.title` not followed (allowing spaces) by `//`. Every
# legitimate render site clips to "Untitled" or to the evidence text.
BARE=$(grep -rnE '\.title([^a-zA-Z0-9_]|$)' scripts/*.sh | grep -vE '\.title +//' || true)
if [ -n "$BARE" ]; then
  echo "FAIL: bare .title read(s) without a // fallback (these render 'null'):"
  echo "$BARE"
  fail=$((fail + 1))
else
  echo "OK:   every .title read in scripts/*.sh has a // fallback"
fi

echo ""
echo "── Behaviour: title-less finding renders 'Untitled', never 'null' ──"

TITLELESS='[{"id":"j1","severity":"major","type":"bug","path":"a.ts","line_start":1}]'

# Mirrors build-review.sh summary line.
got=$(echo "$TITLELESS" | jq -r '[.[] | "\(.severity): \(.title // "Untitled")"] | join("; ")')
assert_eq "summary line"            "major: Untitled" "$got"

# Mirrors build-review.sh inline-comment header.
got=$(echo "$TITLELESS" | jq -r '.[] | "**[\((.type // "finding") | ascii_upcase)]** \(.title // "Untitled")"')
assert_eq "inline-comment header"   "**[BUG]** Untitled" "$got"

# Mirrors verdict-gate.sh step-summary line.
got=$(echo "$TITLELESS" | jq -r '.[] | "- **\(.severity | ascii_upcase)** [\(.type)] `\(.path):\(.line_start)` — \(.title // "Untitled")"')
assert_eq "step-summary line"       '- **MAJOR** [bug] `a.ts:1` — Untitled' "$got"

# A finding WITH a title still renders the title verbatim (fallback only fires
# when absent).
WITH_TITLE='[{"severity":"minor","title":"real header"}]'
got=$(echo "$WITH_TITLE" | jq -r '[.[] | "\(.severity): \(.title // "Untitled")"] | join("; ")')
assert_eq "present title preserved" "minor: real header" "$got"

echo ""
echo "── Contract: orchestrator lists title as required in all-findings.json ──"
# The schema sentence at skills/review-orchestrator.md must require `title`
# before `severity`, so the merge step never drops it.
if grep -qE '`id`, `title`, `severity`' skills/review-orchestrator.md; then
  echo "OK:   review-orchestrator.md requires \`title\` in the merge contract"
else
  echo "FAIL: review-orchestrator.md all-findings.json contract does not require \`title\`"
  fail=$((fail + 1))
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All finding-title fallback tests passed."
  exit 0
else
  echo "$fail finding-title fallback test(s) failed."
  exit 1
fi
