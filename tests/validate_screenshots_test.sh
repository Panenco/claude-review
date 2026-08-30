#!/usr/bin/env bash
set -uo pipefail

# validate_screenshots_test.sh — fixture test for scripts/validate-screenshots.sh.
#
# This script is the ONLY thing standing between a truncated capture and
# `400 Could not process image`, which ends a model's turn before it writes any
# output file. review-verify is allowed to look at screenshots precisely because
# this gate runs first, so what is asserted here is that the gate actually
# closes:
#
#   * a TRUNCATED PNG is rejected (the documented total-loss failure — a capture
#     that died mid-write has no IEND at end-of-file);
#   * a PNG with a flipped byte is rejected on its chunk CRC;
#   * an empty file, a non-PNG with a .png name, an over-size file and an
#     over-dimension file are all rejected;
#   * stdout carries PATHS ONLY — review-verify reads the allowlist line by line
#     and would treat a stray diagnostic as a file to open;
#   * the allowlist file is ALWAYS created, even when nothing passes, because
#     review-verify reads it unconditionally;
#   * without gzip the CRC check degrades LOUDLY but the structural walk still
#     rejects truncation — the runner is caller-chosen, so a missing binary must
#     never reopen the hole.

cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/validate-screenshots.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "OK:   $label"; else echo "FAIL: $label — want '$want', got '$got'"; fail=$((fail + 1)); fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "OK:   $label" ;;
    *) echo "FAIL: $label — expected to find '$needle'"; fail=$((fail + 1)) ;;
  esac
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "FAIL: $label — did NOT expect '$needle'"; fail=$((fail + 1)) ;;
    *) echo "OK:   $label" ;;
  esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── fixtures ────────────────────────────────────────────────────────────────
# A real 1x1 PNG (69 bytes): signature + IHDR + IDAT + IEND, all CRCs correct.
GOOD_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'

# hex → raw bytes, straight to stdout.
emit_hex() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }

# CRC-32 of stdin as big-endian hex, computed the way PNG stores it. Built from
# gzip's own footer, which is the same CRC-32/ISO-HDLC variant — an independent
# path to the number, so a wrong fixture would show up as the GOOD png failing.
crc_hex() {
  local le
  le=$(gzip -c -n | tail -c 8 | od -An -tx1 -N4 | tr -d ' \n')
  printf '%s' "${le:6:2}${le:4:2}${le:2:2}${le:0:2}"
}

# mkpng <dest> <width-hex-8> <height-hex-8> — a structurally valid PNG whose
# IHDR declares those dimensions, reusing the good file's IDAT + IEND verbatim
# (their CRCs cover only their own bytes, so they stay correct).
mkpng() {
  local dest="$1" body crc
  body="49484452${2}${3}0802000000"
  crc=$(emit_hex "$body" | crc_hex)
  emit_hex "89504e470d0a1a0a0000000d${body}${crc}" > "$dest"
  tail -c +34 "$WORK/good.png" >> "$dest"
}

printf '%s' "$GOOD_B64" | base64 -d > "$WORK/good.png"
assert_eq "the good fixture is the expected 69 bytes" "69" "$(wc -c < "$WORK/good.png" | tr -d ' ')"

run() { # run <dir> [env assignments...] → stdout; stderr into $ERR
  local dir="$1"; shift
  env SCREENSHOT_DIR="$dir" SCREENSHOT_ALLOWLIST="$WORK/ok.txt" "$@" bash "$SCRIPT" 2> "$WORK/err.txt"
}

# ── (a) a clean PNG is listed, on stdout and in the allowlist ────────────────
echo "── (a) a clean capture passes ──"
D="$WORK/a"; mkdir -p "$D"
cp "$WORK/good.png" "$D/01-list.png"
OUT=$(run "$D"); RC=$?
ERR=$(cat "$WORK/err.txt")
assert_eq "exit 0" "0" "$RC"
assert_eq "stdout is exactly the one path" "$D/01-list.png" "$OUT"
assert_eq "the allowlist holds the same line" "$D/01-list.png" "$(cat "$WORK/ok.txt")"
assert_not_contains "no diagnostic leaked onto stdout" "::" "$OUT"
assert_contains "the count is reported on stderr" "1 screenshot(s) cleared" "$ERR"

# ── (b) THE ONE THAT MATTERS: a truncated PNG is rejected ────────────────────
# A capture that failed mid-write is exactly this shape, and it is what returns
# `400 Could not process image` and ends the reading model's turn.
echo "── (b) a truncated capture is rejected ──"
D="$WORK/b"; mkdir -p "$D"
head -c 50 "$WORK/good.png" > "$D/02-truncated.png"
OUT=$(run "$D"); RC=$?
ERR=$(cat "$WORK/err.txt")
assert_eq "still exits 0 — a bad capture is not a pipeline failure" "0" "$RC"
assert_eq "nothing on stdout" "" "$OUT"
assert_eq "the allowlist exists and is empty" "" "$(cat "$WORK/ok.txt")"
assert_contains "the file is named in the warning" "02-truncated.png" "$ERR"
assert_contains "…and the reason says truncated" "truncated" "$ERR"

# A tail cut inside the FINAL chunk leaves every earlier chunk intact, so only
# the "ends exactly at IEND" test catches it.
head -c 65 "$WORK/good.png" > "$D/03-lost-iend.png"
rm -f "$D/02-truncated.png"
OUT=$(run "$D")
ERR=$(cat "$WORK/err.txt")
assert_eq "a PNG cut inside IEND is rejected too" "" "$OUT"
assert_contains "…named in the warning" "03-lost-iend.png" "$ERR"

# ── (c) a flipped byte fails on the chunk CRC ───────────────────────────────
echo "── (c) in-place corruption fails the CRC ──"
D="$WORK/c"; mkdir -p "$D"
cp "$WORK/good.png" "$D/04-corrupt.png"
printf '\xff' | dd of="$D/04-corrupt.png" bs=1 seek=45 count=1 conv=notrunc 2>/dev/null
OUT=$(run "$D")
ERR=$(cat "$WORK/err.txt")
assert_eq "nothing passes" "" "$OUT"
assert_contains "the reason names the CRC" "CRC mismatch" "$ERR"

# ── (d) empty, non-PNG, and unsafe-name files ───────────────────────────────
echo "── (d) the other rejections ──"
D="$WORK/d"; mkdir -p "$D"
: > "$D/05-empty.png"
printf 'this is prose, not an image, and it is long enough to clear the floor' > "$D/06-text.png"
cp "$WORK/good.png" "$D/07 spaced.png"
cp "$WORK/good.png" "$D/08-fine.png"
OUT=$(run "$D")
ERR=$(cat "$WORK/err.txt")
assert_eq "only the sound file is listed" "$D/08-fine.png" "$OUT"
assert_contains "the empty file is named" "05-empty.png" "$ERR"
assert_contains "the non-PNG is named" "06-text.png" "$ERR"
assert_contains "…with a signature reason" "bad signature" "$ERR"
assert_contains "the unsafe basename is named" "07 spaced.png" "$ERR"

# ── (e) the API's size and dimension ceilings ───────────────────────────────
echo "── (e) the API ceilings ──"
D="$WORK/e"; mkdir -p "$D"
cp "$WORK/good.png" "$D/09-big.png"
OUT=$(run "$D" SCREENSHOT_MAX_BYTES=40)
ERR=$(cat "$WORK/err.txt")
assert_eq "a file over the byte ceiling is dropped" "" "$OUT"
assert_contains "…and the ceiling is quoted" "exceeds the 40-byte" "$ERR"

rm -f "$D/09-big.png"
# 0x2328 = 9000 px, over the API's 8000x8000 maximum.
mkpng "$D/10-huge.png" "00002328" "00002328"
OUT=$(run "$D")
ERR=$(cat "$WORK/err.txt")
assert_eq "an over-dimension PNG is dropped" "" "$OUT"
assert_contains "…and the size is quoted" "9000x9000 px" "$ERR"

# The same builder at a sane size must PASS, or the fixture proves nothing.
rm -f "$D/10-huge.png"
mkpng "$D/11-ok.png" "00000640" "000003c0"
OUT=$(run "$D")
assert_eq "the same builder at 1600x960 passes" "$D/11-ok.png" "$OUT"

# ── (f) an empty directory still produces the allowlist ─────────────────────
echo "── (f) the allowlist always exists ──"
D="$WORK/f"; mkdir -p "$D"
rm -f "$WORK/ok.txt"
OUT=$(run "$D"); RC=$?
assert_eq "exit 0 on an empty directory" "0" "$RC"
assert_eq "nothing listed" "" "$OUT"
if [ -f "$WORK/ok.txt" ]; then echo "OK:   the allowlist file was created anyway"; else
  echo "FAIL: no allowlist file — review-verify reads it unconditionally"; fail=$((fail + 1)); fi

# A directory that does not exist at all is the strategy:skip case.
OUT=$(run "$WORK/no-such-dir"); RC=$?
assert_eq "a missing directory is a silent no-op" "0" "$RC"
assert_eq "…with no output" "" "$OUT"

# ── (g) the list is capped ──────────────────────────────────────────────────
echo "── (g) the cap ──"
D="$WORK/g"; mkdir -p "$D"
for n in 1 2 3 4 5; do cp "$WORK/good.png" "$D/2$n-shot.png"; done
OUT=$(run "$D" SCREENSHOT_MAX_FILES=2)
assert_eq "only two paths survive the cap" "2" "$(printf '%s\n' "$OUT" | grep -c 'shot.png')"

# ── (h) no gzip: loud degradation, truncation STILL rejected ────────────────
echo "── (h) the no-gzip fallback ──"
D="$WORK/h"; mkdir -p "$D"
cp "$WORK/good.png" "$D/30-fine.png"
head -c 50 "$WORK/good.png" > "$D/31-truncated.png"
OUT=$(run "$D" VALIDATE_GZIP_BIN=)
ERR=$(cat "$WORK/err.txt")
assert_eq "the sound file still passes" "$D/30-fine.png" "$OUT"
assert_contains "the truncated one is still rejected" "31-truncated.png" "$ERR"
assert_contains "and the missing CRC check is announced" "CRCs went unchecked" "$ERR"

# ── (i) a non-numeric override falls back instead of opening the gate ───────
echo "── (i) a typo'd override ──"
D="$WORK/i"; mkdir -p "$D"
cp "$WORK/good.png" "$D/40-shot.png"
OUT=$(run "$D" SCREENSHOT_MAX_BYTES=lots SCREENSHOT_MAX_DIM=big)
assert_eq "the defaults take over and the file passes" "$D/40-shot.png" "$OUT"

echo
if [ "$fail" -eq 0 ]; then echo "All validate-screenshots assertions passed."; else echo "$fail assertion(s) FAILED."; fi
exit "$fail"
