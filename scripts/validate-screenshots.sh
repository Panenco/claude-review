#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): explicit exits on every path instead.

# validate-screenshots.sh — decides which of the functional tester's PNGs are
# SAFE for a model to look at, and writes that whitelist to a file.
#
# WHY THIS EXISTS.
# A truncated or corrupt image handed to the model comes back as
# `400 Could not process image`. That error ENDS THE TURN before the agent
# writes any output file, so a single bad capture costs the whole review — not
# one screenshot. That total-loss failure is why every skill in this pipeline
# carried a blanket "never Read anything under /tmp/screenshots/".
#
# The ban was the right call while nothing stood between the capture and the
# model. This script is that something. It is run by `review-verify` (see
# skills/review-verify.md § "Seeing the screenshots") BEFORE it looks at any
# image, and review-verify may only `Read` a path this script listed. Nothing
# else in the pipeline may look at a screenshot at all — in particular the
# functional tester's own ban stays, because it runs against a hard wall-clock
# deadline with no provisional output file to fall back to.
#
# WHAT "SAFE" MEANS HERE. A PNG is accepted only when ALL of these hold:
#   1. it is a regular, non-empty file whose basename is `[A-Za-z0-9._-]+`;
#   2. it starts with the 8-byte PNG signature;
#   3. its chunk chain walks cleanly from byte 8 to EXACTLY end-of-file —
#      every declared length fits inside the file, and the last chunk is IEND;
#   4. every chunk's stored CRC-32 matches the CRC-32 of its own type+data;
#   5. IHDR's width and height are non-zero and <= SCREENSHOT_MAX_DIM;
#   6. the file is <= SCREENSHOT_MAX_BYTES.
# (3) is the one that actually catches the documented hazard: a capture that
# died mid-write has no IEND, or a final chunk that runs past EOF, and it is
# rejected with certainty rather than heuristically. (4) catches the rarer
# in-place corruption. (6) is the API's own ceiling — see THE SIZE LIMIT.
#
# HOW THE CRC IS COMPUTED WITHOUT A NEW DEPENDENCY. PNG's CRC-32 is
# CRC-32/ISO-HDLC, byte for byte the same variant gzip stores in its own
# 8-byte footer. So `gzip -c` over a byte range and a read of the first four
# footer bytes (little-endian) IS the CRC of that range — no python3, no
# ImageMagick, no `sips`, nothing this repo would have to start depending on.
# The runner is `inputs.runner` (caller-chosen), so depending on a binary that
# only ships with ubuntu-latest would be a silent trap on a self-hosted box;
# `od`, `tail`, `head` and `wc` are POSIX. `gzip` is not POSIX, so its absence
# DEGRADES rather than fails: the structural walk still runs and still rejects
# truncation, and a `::warning::` says the CRCs went unchecked. It is never
# silent, because a silently weaker gate is how the 400 comes back.
#
# THE SIZE LIMIT. The Claude API accepts up to 10 MB base64-encoded per image
# direct, but only 5 MB on Bedrock and Vertex, and max dimensions are
# 8000x8000 px. We enforce the LOWER ceiling so a review is not fragile to
# which platform serves it: 5 MB of base64 is 3,750,000 raw bytes, and the
# default below leaves headroom under that. Both are overridable.
#
# Inputs (env):
#   SCREENSHOT_DIR         directory of captures (default /tmp/screenshots)
#   SCREENSHOT_ALLOWLIST   file to write (default /tmp/screenshots.ok)
#   SCREENSHOT_MAX_BYTES   per-file byte ceiling (default 3500000)
#   SCREENSHOT_MAX_DIM     per-side pixel ceiling (default 8000)
#   SCREENSHOT_MAX_FILES   how many accepted files to list (default 8)
#
# Output: one absolute path per line, on stdout AND in $SCREENSHOT_ALLOWLIST.
# The allowlist file is ALWAYS created, even when empty — review-verify reads
# it unconditionally, and a missing file would leave it guessing. Diagnostics
# go to stderr only, so the file never contains anything but paths.
#
# Exit 0 with an empty list means "nothing here is safe to look at", which is a
# normal outcome (no functional run, no captures, every capture truncated). The
# only non-zero exit is a directory we could not write the allowlist into.

DIR="${SCREENSHOT_DIR:-/tmp/screenshots}"
OUT="${SCREENSHOT_ALLOWLIST:-/tmp/screenshots.ok}"
MAX_BYTES="${SCREENSHOT_MAX_BYTES:-3500000}"
MAX_DIM="${SCREENSHOT_MAX_DIM:-8000}"
MAX_FILES="${SCREENSHOT_MAX_FILES:-8}"

# A non-numeric override is a typo, not a request for zero. Fall back rather
# than reject everything or accept everything.
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=3500000 ;; esac
case "$MAX_DIM"   in ''|*[!0-9]*) MAX_DIM=8000 ;; esac
case "$MAX_FILES" in ''|*[!0-9]*) MAX_FILES=8 ;; esac

: > "$OUT" || {
  echo "::error::validate-screenshots: cannot write '$OUT'" >&2
  exit 1
}

# The PNG signature and the two chunk types we name, as lowercase hex — the
# form `od -tx1` prints. Comparing hex avoids converting bytes back to ASCII.
SIG_HEX="89504e470d0a1a0a"
IHDR_HEX="49484452"
IEND_HEX="49454e44"

GZIP_BIN="${VALIDATE_GZIP_BIN-$(command -v gzip || true)}"
CRC_SKIPPED=0

# hex_at <file> <offset> <count> — the bytes as unspaced lowercase hex.
hex_at() {
  od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'
}

# be32_at <file> <offset> — a 4-byte big-endian integer as decimal.
be32_at() {
  local h
  h=$(hex_at "$1" "$2" 4)
  [ ${#h} -eq 8 ] || return 1
  printf '%d' "$((16#$h))"
}

# crc_at <file> <offset> <length> — CRC-32 of that byte range, lowercase hex.
# Empty output means "not computed" (no gzip), which the caller treats as skip.
crc_at() {
  [ -n "$GZIP_BIN" ] || return 0
  local le b0 b1 b2 b3
  le=$(tail -c "+$(( $2 + 1 ))" "$1" 2>/dev/null | head -c "$3" \
       | "$GZIP_BIN" -c -n 2>/dev/null | tail -c 8 | od -An -tx1 -N4 | tr -d ' \n')
  [ ${#le} -eq 8 ] || return 0
  # gzip stores the CRC little-endian; PNG stores it big-endian.
  b0=${le:0:2}; b1=${le:2:2}; b2=${le:4:2}; b3=${le:6:2}
  printf '%s' "$b3$b2$b1$b0"
}

reject() { # reject <basename> <reason>
  echo "::warning::validate-screenshots: skipped '$1' — $2. It will not be shown to any model." >&2
}

# check_png <file> <basename> <size> — 0 when the file is safe to look at.
check_png() {
  local f="$1" b="$2" size="$3"
  local off=8 len stored computed w h
  local type=""

  if [ "$(hex_at "$f" 0 8)" != "$SIG_HEX" ]; then
    reject "$b" "not a PNG (bad signature)"
    return 1
  fi

  while [ "$off" -lt "$size" ]; do
    # A chunk is 4 length + 4 type + data + 4 CRC. Anything shorter left in the
    # file is a capture that stopped mid-header.
    if [ $(( off + 12 )) -gt "$size" ]; then
      reject "$b" "truncated: $(( size - off )) trailing bytes are too few for a chunk"
      return 1
    fi
    len=$(be32_at "$f" "$off") || { reject "$b" "unreadable chunk length at byte $off"; return 1; }
    if [ "$len" -gt "$size" ] || [ $(( off + 12 + len )) -gt "$size" ]; then
      reject "$b" "truncated: chunk at byte $off declares $len bytes that run past end-of-file"
      return 1
    fi
    type=$(hex_at "$f" $(( off + 4 )) 4)
    if [ "$off" -eq 8 ] && { [ "$type" != "$IHDR_HEX" ] || [ "$len" -ne 13 ]; }; then
      reject "$b" "first chunk is not a 13-byte IHDR"
      return 1
    fi
    stored=$(hex_at "$f" $(( off + 8 + len )) 4)
    computed=$(crc_at "$f" $(( off + 4 )) $(( len + 4 )))
    if [ -z "$computed" ]; then
      CRC_SKIPPED=1
    elif [ "$stored" != "$computed" ]; then
      reject "$b" "corrupt: CRC mismatch on the chunk at byte $off"
      return 1
    fi
    off=$(( off + 12 + len ))
  done

  # `type` now holds the LAST chunk walked. A PNG that ends anywhere other than
  # exactly after IEND is the truncation this whole script exists to catch.
  if [ "$off" -ne "$size" ] || [ "$type" != "$IEND_HEX" ]; then
    reject "$b" "truncated: no complete IEND chunk at end-of-file"
    return 1
  fi

  w=$(be32_at "$f" 16) || { reject "$b" "unreadable IHDR width"; return 1; }
  h=$(be32_at "$f" 20) || { reject "$b" "unreadable IHDR height"; return 1; }
  if [ "$w" -lt 1 ] || [ "$h" -lt 1 ] || [ "$w" -gt "$MAX_DIM" ] || [ "$h" -gt "$MAX_DIM" ]; then
    reject "$b" "${w}x${h} px is outside 1..${MAX_DIM} px per side"
    return 1
  fi
  return 0
}

ls "$DIR"/*.png >/dev/null 2>&1 || exit 0

ACCEPTED=0
for img in "$DIR"/*.png; do
  [ -f "$img" ] || continue
  B=$(basename "$img")

  # The same charset gate upload-screenshots.sh applies, for the same reason
  # plus one more: these paths are written one-per-line into the allowlist, and
  # a name carrying a space or a newline would not survive that round trip.
  case "$B" in
    ''|*[!A-Za-z0-9._-]*)
      reject "$B" "a basename outside [A-Za-z0-9._-] cannot be listed safely"
      continue ;;
  esac

  SIZE=$(wc -c < "$img" 2>/dev/null | tr -d ' ')
  case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
  if [ "$SIZE" -lt 45 ]; then
    reject "$B" "only ${SIZE} bytes — too small to be a complete PNG"
    continue
  fi
  if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    reject "$B" "${SIZE} bytes exceeds the ${MAX_BYTES}-byte per-image API ceiling"
    continue
  fi

  check_png "$img" "$B" "$SIZE" || continue

  if [ "$ACCEPTED" -ge "$MAX_FILES" ]; then
    echo "::notice::validate-screenshots: '$B' passed but the list is capped at ${MAX_FILES}." >&2
    continue
  fi
  printf '%s\n' "$img" >> "$OUT"
  printf '%s\n' "$img"
  ACCEPTED=$(( ACCEPTED + 1 ))
done

if [ "$CRC_SKIPPED" -eq 1 ]; then
  echo "::warning::validate-screenshots: gzip is unavailable, so chunk CRCs went unchecked. Structure and truncation were still verified." >&2
fi
echo "::notice::validate-screenshots: ${ACCEPTED} screenshot(s) cleared for review-verify." >&2
exit 0
