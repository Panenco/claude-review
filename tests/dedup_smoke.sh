#!/usr/bin/env bash
set -euo pipefail

# dedup_smoke.sh — local smoke test against the live Haiku endpoint.
# Drives the review-dedup skill against a deterministic fixture set and
# asserts on shape (well-formed JSON, length <= input, every output id in
# input). NOT run in CI - requires CLAUDE_CODE_OAUTH_TOKEN.
#
# Usage:
#   CLAUDE_CODE_OAUTH_TOKEN=... bash tests/dedup_smoke.sh

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "CLAUDE_CODE_OAUTH_TOKEN not set - skipping (this script needs the live API)"
  exit 0
fi

cd "$(dirname "$0")/.."

if ! [ -x "$HOME/.local/bin/claude" ]; then
  echo "::error::Claude CLI not found at ~/.local/bin/claude - install it first"
  exit 1
fi

SKILL=$(cat skills/review-dedup.md)

# Synthetic merged input mixing duplicates with distinct issues.
cat > /tmp/all-findings-merged.json <<'EOF'
[
  {"id":"c1","severity":"major","type":"bug","path":"src/auth.ts","line_start":42,"title":"Missing await on db call","evidence":"userRepo.create - promise discarded"},
  {"id":"c2","severity":"major","type":"wrong-impl","path":"src/auth.ts","line_start":44,"title":"Async result not awaited","evidence":"userRepo.create returns Promise<User>, not awaited"},
  {"id":"s1","severity":"minor","type":"consistency","path":"src/utils.ts","line_start":17,"title":"Inconsistent return type","evidence":"siblings return Result<T>; this returns T | null"},
  {"id":"c5","severity":"critical","type":"security","path":"src/api.ts","line_start":5,"title":"SQL injection via query param","evidence":"db.exec(SELECT * FROM users WHERE id = id_value)"}
]
EOF

OUT=/tmp/deduped-findings.json
rm -f "$OUT"

"$HOME/.local/bin/claude" -p "You are the dedup reviewer. Read /tmp/all-findings-merged.json. OUTPUT_PATH=$OUT - write the deduped JSON array to that exact path. Follow the skill below exactly.

=== review-dedup skill (follow exactly) ===

$SKILL" \
  --model "${MODEL_FAST:-claude-haiku-4-5}" \
  --permission-mode dontAsk \
  --setting-sources user \
  --allowedTools Read,Write \
  --disallowedTools Bash,Edit,Glob,Grep,WebFetch,WebSearch \
  --max-turns 4 > /tmp/dedup-smoke.txt 2>&1

if [ ! -f "$OUT" ]; then
  echo "::error::skill did not write $OUT"
  cat /tmp/dedup-smoke.txt
  exit 1
fi

if ! jq -e 'type == "array"' "$OUT" >/dev/null; then
  echo "::error::output is not a JSON array"
  cat "$OUT"
  exit 1
fi

if ! jq -e 'all(type == "object" and has("severity") and has("path") and has("line_start") and has("id"))' "$OUT" >/dev/null; then
  echo "::error::output entries missing required keys"
  cat "$OUT"
  exit 1
fi

OUT_LEN=$(jq 'length' "$OUT")
IN_LEN=$(jq 'length' /tmp/all-findings-merged.json)
if [ "$OUT_LEN" -gt "$IN_LEN" ]; then
  echo "::error::output length ($OUT_LEN) exceeds input ($IN_LEN)"
  exit 1
fi

if ! jq --slurpfile in /tmp/all-findings-merged.json -e 'all(.id as $id | $in[0] | any(.id == $id))' "$OUT" >/dev/null; then
  echo "::error::output contains an id not present in input - skill invented findings"
  exit 1
fi

if [ "$OUT_LEN" -ge "$IN_LEN" ]; then
  echo "WARN: output length ($OUT_LEN) did not shrink from input ($IN_LEN). The fixture has obvious duplicates (c1+c2 on adjacent lines, same root cause). Skill prompt may have regressed."
fi

echo "PASSED: dedup smoke ($IN_LEN -> $OUT_LEN findings)"
