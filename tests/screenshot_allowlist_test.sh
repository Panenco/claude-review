#!/usr/bin/env bash
set -uo pipefail

# screenshot_allowlist_test.sh — fixture test for the allowlist-based
# screenshot collection in build-review.sh.
#
# Background. PR #30 originally tried to filter checked-in repo PNGs by
# mtime (`find . -mmin -60`), but Cursor caught that `actions/checkout`
# rewrites every file's mtime to ~now during clone, which means the
# filter cannot distinguish a checked-in product asset (e.g. seaters'
# `screenshots/wl_logo.png`) from a freshly captured tester screenshot.
#
# The fix: collect ONLY the basenames the functional tester explicitly
# named in `functional-meta.screenshots[].file` and
# `functional-findings[].screenshot`. Try the absolute path first, then
# resolve the basename in agent-only output dirs, falling back to the
# repo root as a last resort. This guarantees that pre-existing repo
# PNGs not named by the tester are never picked up — regardless of
# their mtime.

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Fixture: consumer repo with checked-in PNGs (fresh mtime from
# actions/checkout) + agent-produced screenshots in /tmp/screenshots. ──
mkdir -p "$TMP/repo/screenshots" "$TMP/agent-tmp/screenshots" "$TMP/all-screenshots" "$TMP/repo/.playwright-mcp"
echo "checked-in-logo" > "$TMP/repo/screenshots/wl_logo.png"
echo "checked-in-barcode" > "$TMP/repo/barcode.png"
echo "agent-list" > "$TMP/agent-tmp/screenshots/01-list-page.png"
echo "agent-detail" > "$TMP/agent-tmp/screenshots/02-detail.png"
echo "agent-mcp" > "$TMP/repo/.playwright-mcp/03-mcp-default.png"
# Touch every file to "now" so mtime cannot distinguish them — the
# situation we'd be in after `actions/checkout` ran a moment ago.
find "$TMP" -name '*.png' -exec touch {} \;

# Build a synthetic functional-meta naming a mix of:
#   - absolute path (preferred — agent wrote here)
#   - plain filename (legacy path — agent passed only "02-detail.png")
#   - JSON file — must be filtered as non-image
#   - Playwright-MCP default location
FUNCTIONAL_META=$(jq -n \
  --arg abs1 "$TMP/agent-tmp/screenshots/01-list-page.png" \
  '{screenshots: [
     {file: $abs1, description: "List page", area: "list"},
     {file: "02-detail.png", description: "Detail", area: "detail"},
     {file: "/tmp/api-response.json", description: "API JSON", area: "api"},
     {file: "03-mcp-default.png", description: "MCP-default", area: "mcp"}
   ]}')
FUNCTIONAL_FINDINGS=$(jq -n \
  '[{id:"f1",severity:"major",path:"src/a.ts",line_start:1,title:"x",evidence:"x","reasoning":"x","expected":"x",type:"finding",screenshot:"01-list-page.png"}]')
echo "$FUNCTIONAL_FINDINGS" > /tmp/functional-findings.json

# ── Allowlist resolution (mirrors build-review.sh:243-294) ──
FN_INPUT="[]"
[ -f /tmp/functional-findings.json ] && jq -e 'type == "array"' /tmp/functional-findings.json >/dev/null 2>&1 \
  && FN_INPUT=$(cat /tmp/functional-findings.json)

EXPECTED_FILES=$(jq -n \
  --argjson meta "$FUNCTIONAL_META" \
  --argjson fn "$FN_INPUT" \
  'def img_paths: map(select(type == "string" and (test("\\.(png|jpg|jpeg|webp)$"; "i")))) | unique;
   (($meta.screenshots // []) | map(.file // ""))
   + (($fn // []) | map(.screenshot // ""))
   | img_paths')

# JSON entry must be filtered out. `unique` dedupes by string value, not
# basename — so an absolute path to 01-list-page.png and a plain
# "01-list-page.png" finding entry are two distinct strings → 4 entries:
# abs(01), "02-detail", "/tmp/api-response.json"→dropped, "03-mcp",
# plain("01-list-page"). Both 01-list-page entries resolve to the same
# basename and `cp -n` makes the second a no-op.
assert_eq "expected list filtered to images" "4" "$(echo "$EXPECTED_FILES" | jq 'length')"
assert_eq "JSON entry filtered out of expected list" "0" \
  "$(echo "$EXPECTED_FILES" | jq '[.[] | select(test("\\.json$"))] | length')"

cd "$TMP/repo"
while read -r expected; do
  [ -z "$expected" ] && continue
  base=$(basename "$expected")
  if [ -f "$expected" ]; then
    cp -n "$expected" "$TMP/all-screenshots/$base"
    continue
  fi
  found=""
  for d in "$TMP/agent-tmp/screenshots" "$TMP/agent-tmp/playwright-mcp-output" .playwright-mcp .playwright-mcp/screenshots screenshots .; do
    [ -f "$d/$base" ] && { found="$d/$base"; break; }
  done
  if [ -n "$found" ]; then
    cp -n "$found" "$TMP/all-screenshots/$base"
  fi
done < <(echo "$EXPECTED_FILES" | jq -r '.[]')

# ── Assertions ──
assert_eq "01-list-page.png picked up via absolute path" "1" \
  "$(ls "$TMP/all-screenshots/" | grep -c '^01-list-page\.png$')"
assert_eq "02-detail.png picked up via basename resolve" "1" \
  "$(ls "$TMP/all-screenshots/" | grep -c '^02-detail\.png$')"
assert_eq "03-mcp-default.png picked up from .playwright-mcp" "1" \
  "$(ls "$TMP/all-screenshots/" | grep -c '^03-mcp-default\.png$')"

# Critical: pre-existing repo PNGs the tester didn't name must NOT
# appear, even though their mtimes were freshly touched.
assert_eq "wl_logo.png NOT picked up (not named by tester)" "0" \
  "$(ls "$TMP/all-screenshots/" | grep -c '^wl_logo\.png$')"
assert_eq "barcode.png NOT picked up (not named by tester)" "0" \
  "$(ls "$TMP/all-screenshots/" | grep -c '^barcode\.png$')"
assert_eq "all-screenshots count exactly 3" "3" \
  "$(ls "$TMP/all-screenshots/" | wc -l | tr -d ' ')"

# ── Empty-functional-findings.json variant: must not error ──
echo '[]' > /tmp/functional-findings.json
EMPTY_FN_INPUT="[]"
EMPTY_EXPECTED=$(jq -n \
  --argjson meta '{}' \
  --argjson fn "$EMPTY_FN_INPUT" \
  'def img_paths: map(select(type == "string" and (test("\\.(png|jpg|jpeg|webp)$"; "i")))) | unique;
   (($meta.screenshots // []) | map(.file // ""))
   + (($fn // []) | map(.screenshot // ""))
   | img_paths')
assert_eq "empty meta + empty findings → empty allowlist" "0" "$(echo "$EMPTY_EXPECTED" | jq 'length')"

rm -f /tmp/functional-findings.json

if [ "$fail" -eq 0 ]; then
  echo
  echo "All screenshot-allowlist tests passed."
  exit 0
else
  echo
  echo "$fail screenshot-allowlist test assertion(s) failed."
  exit 1
fi
