#!/usr/bin/env bash
# usage-report.sh — Aggregate panenco/claude-review usage across consumer
# repos using the maintainer's local `gh` auth (already cross-org).
#
# Discovery: `gh search code 'uses: panenco/claude-review …'` finds repos
# that reference this action in a workflow file. Pass --repos to skip
# discovery and aggregate an explicit list.
#
# For each repo, lists the `claude-review-usage` artifacts (created by the
# review workflow's "Upload usage record" step), downloads each, extracts
# the inner usage.json, and prints a per-repo + aggregate summary.
#
# No PAT or webhook required — uses your `gh auth status` session.
#
# Usage:
#   bash scripts/usage-report.sh                       # default: last 30d
#   bash scripts/usage-report.sh --since 7d
#   bash scripts/usage-report.sh --since 2026-04-01
#   bash scripts/usage-report.sh --owner panenco       # scope discovery
#   bash scripts/usage-report.sh --repos a/b,c/d       # skip discovery
#   bash scripts/usage-report.sh --write docs/USAGE.md # also write to file
#   bash scripts/usage-report.sh --json                # raw JSONL on stdout
#
# Requires: gh, jq, unzip.

set -uo pipefail

# ── arg parsing ──
SINCE="30d"
REPOS=""
OWNER=""
WRITE_PATH=""
EMIT_JSON=false

print_help() {
  sed -n '1,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Tiny helper: error if a value-taking flag was passed as the last arg
# without an actual value (e.g. `--since` with nothing after it). Without
# this check we'd silently accept an empty value and the script would
# carry on with SINCE="", producing confusing output instead of telling
# the user they forgot the value.
require_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ]; then
    echo "::error::$flag requires a value (e.g. $flag 30d)" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)            require_value --since "${2:-}"; SINCE="$2"; shift 2 ;;
    --repos)            require_value --repos "${2:-}"; REPOS="$2"; shift 2 ;;
    --owner)            require_value --owner "${2:-}"; OWNER="$2"; shift 2 ;;
    --write)            require_value --write "${2:-}"; WRITE_PATH="$2"; shift 2 ;;
    --json)             EMIT_JSON=true; shift ;;
    -h|--help)          print_help; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; echo "Run with --help for usage." >&2; exit 2 ;;
  esac
done

# ── prerequisites ──
for bin in gh jq unzip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "::error::missing dependency: $bin" >&2; exit 1; }
done
if ! gh auth status >/dev/null 2>&1; then
  echo "::error::gh is not authenticated — run 'gh auth login' first" >&2
  exit 1
fi

# ── since → absolute ISO-8601 ──
# Accepts "30d" / "7d" relative, or a literal ISO date. macOS uses BSD `date
# -v`, Linux uses GNU `date -d` — try BSD first, fall back to GNU.
to_iso_since() {
  local input="$1"
  if [[ "$input" =~ ^([0-9]+)d$ ]]; then
    local n="${BASH_REMATCH[1]}"
    date -u -v-"${n}"d +%Y-%m-%dT00:00:00Z 2>/dev/null \
      || date -u -d "${n} days ago" +%Y-%m-%dT00:00:00Z 2>/dev/null \
      || { echo "::error::cannot compute date for --since=$input — neither BSD nor GNU date worked" >&2; exit 1; }
  else
    # Trust ISO-8601 input verbatim. GitHub's API accepts any prefix.
    echo "$input"
  fi
}
SINCE_ISO=$(to_iso_since "$SINCE")

# ── discovery ──
discover_repos() {
  # Avoid `uses: panenco/claude-review` — `uses:` is parsed as a GitHub search
  # qualifier and silently returns no results. Plain text + `path:` scopes the
  # match to workflow files so README/doc mentions don't clutter the list.
  local query='panenco/claude-review path:.github/workflows'
  local args=( --json repository --jq '.[].repository.nameWithOwner' --limit 100 )
  [ -n "$OWNER" ] && args+=( --owner "$OWNER" )
  # `gh search code` returns matches across all branches. Dedupe by repo.
  gh search code "$query" "${args[@]}" 2>/dev/null | sort -u
}

REPO_LIST=()
if [ -n "$REPOS" ]; then
  IFS=',' read -r -a REPO_LIST <<< "$REPOS"
else
  while IFS= read -r r; do
    [ -n "$r" ] && REPO_LIST+=("$r")
  done < <(discover_repos)
fi

if [ "${#REPO_LIST[@]}" -eq 0 ]; then
  echo "::warning::no consumer repos found." >&2
  echo "  - try --repos owner/a,owner/b to skip discovery" >&2
  echo "  - or --owner <org> to scope code search" >&2
  exit 0
fi

# ── collect ──
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ALL_JSONL="$TMP/all-usage.jsonl"
: > "$ALL_JSONL"

REPO_COUNT_FOUND=0
for repo in "${REPO_LIST[@]}"; do
  repo="${repo// /}"
  [ -z "$repo" ] && continue
  echo "→ $repo" >&2

  # List artifacts named claude-review-usage. The `name=` query param filters
  # server-side. `--paginate` flattens pages, `--jq` runs per-page.
  artifacts=$(gh api --paginate \
      -H "Accept: application/vnd.github+json" \
      "/repos/$repo/actions/artifacts?per_page=100&name=claude-review-usage" \
      --jq '.artifacts[]? | {id, created_at, run_id: .workflow_run.id, run_attempt: .workflow_run.run_attempt, head_sha: .workflow_run.head_sha}' \
      2>/dev/null) || {
    echo "  (failed to list artifacts — likely 404 or no access)" >&2
    continue
  }
  # Filter by created_at >= since locally so the user's --since works the
  # same against any GitHub plan tier.
  filtered=$(echo "$artifacts" | jq -c --arg since "$SINCE_ISO" 'select(.created_at >= $since)')
  count=$(echo "$filtered" | grep -c '^{' || true)
  echo "  $count artifact(s) since $SINCE_ISO" >&2
  [ "$count" -eq 0 ] && continue
  REPO_COUNT_FOUND=$((REPO_COUNT_FOUND + 1))

  while IFS= read -r meta; do
    [ -z "$meta" ] && continue
    id=$(echo "$meta" | jq -r '.id')
    [ -z "$id" ] && continue
    zip_path="$TMP/${repo//\//_}-$id.zip"
    if ! gh api -H "Accept: application/vnd.github+json" \
         "/repos/$repo/actions/artifacts/$id/zip" > "$zip_path" 2>/dev/null; then
      echo "    artifact $id: download failed (skipping)" >&2
      continue
    fi
    payload=$(unzip -p "$zip_path" usage.json 2>/dev/null) || {
      echo "    artifact $id: usage.json missing or unreadable (skipping)" >&2
      continue
    }
    # Augment with the artifact-level fields (run_id from the artifact wins
    # over the inner record's, since the inner record is written by the
    # consumer side and could be empty if env wasn't passed correctly).
    echo "$payload" | jq -c \
        --arg repo "$repo" \
        --argjson art "$meta" '
      . as $r |
      ($r // {}) + {
        repo: ($r.repo // $repo),
        run_id: ($r.run_id // ($art.run_id | tostring) // null),
        head_sha: ($r.head_sha // $art.head_sha // null),
        recorded_at: ($r.recorded_at // $art.created_at)
      }' >> "$ALL_JSONL" 2>/dev/null \
      || echo "    artifact $id: usage.json malformed (skipping)" >&2
  done <<< "$filtered"
done

TOTAL_RUNS=$(wc -l < "$ALL_JSONL" | tr -d ' ')
if [ "$TOTAL_RUNS" -eq 0 ]; then
  echo "::warning::found 0 usage records across ${#REPO_LIST[@]} repo(s) since $SINCE_ISO." >&2
  echo "  - consumers may not be on a release that includes the usage step yet" >&2
  echo "  - or no review runs in this window" >&2
  exit 0
fi

# ── emit ──
if [ "$EMIT_JSON" = true ]; then
  cat "$ALL_JSONL"
  exit 0
fi

render_markdown() {
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '%s\n\n' '# Claude Review usage'
  printf -- '_Generated %s — window: %s → %s_\n\n' "$now_iso" "$SINCE_ISO" "$now_iso"
  printf -- '- Repos with activity: **%s** / %s discovered\n' "$REPO_COUNT_FOUND" "${#REPO_LIST[@]}"
  printf -- '- Total runs: **%s**\n' "$TOTAL_RUNS"

  # Aggregate verdict mix globally. `-r` so the multi-line string is emitted
  # as raw markdown rather than a JSON-quoted blob.
  jq -s -r '
    {
      approve:         [.[] | select(.verdict == "APPROVE")] | length,
      comment:         [.[] | select(.verdict == "COMMENT")] | length,
      request_changes: [.[] | select(.verdict == "REQUEST_CHANGES")] | length,
      crashed:         [.[] | select(.verdict == null and (.analyzer_outcome // "") != "success")] | length,
      round1:          [.[] | select(.round == 1)] | length,
      round2_plus:     [.[] | select(.round != null and .round >= 2)] | length,
      with_findings:   [.[] | select((.findings_count // 0) > 0)] | length,
      total_findings:  ([.[] | (.findings_count // 0)] | add // 0),
      tech_change:     [.[] | select(.technical_change == true)] | length,
      smoke_pass:      [.[] | select(.functional_overall == "PASS")] | length,
      smoke_warn:      [.[] | select(.functional_overall == "WARN")] | length,
      smoke_fail:      [.[] | select(.functional_overall == "FAIL")] | length
    } | "- Verdicts: APPROVE \(.approve) · COMMENT \(.comment) · REQUEST_CHANGES \(.request_changes) · crashed \(.crashed)
- Rounds: round-1 \(.round1) · round-2+ \(.round2_plus)
- Findings raised: \(.total_findings) across \(.with_findings) run(s)
- Smoke result mix: PASS \(.smoke_pass) · WARN \(.smoke_warn) · FAIL \(.smoke_fail) · technical-change PRs \(.tech_change)"' "$ALL_JSONL"

  printf '\n## Per-repo\n\n'
  printf '%s\n' '| Repo | Runs | Round-1 | Round-2+ | APPROVE | COMMENT | REQ_CHANGES | Crashed | Findings | Latest |'
  printf '%s\n' '|---|---:|---:|---:|---:|---:|---:|---:|---:|---|'
  jq -s -r '
    group_by(.repo) |
    map({
      repo: .[0].repo,
      runs: length,
      round1: ([.[] | select(.round == 1)] | length),
      round2: ([.[] | select(.round != null and .round >= 2)] | length),
      approve: ([.[] | select(.verdict == "APPROVE")] | length),
      comment: ([.[] | select(.verdict == "COMMENT")] | length),
      rc: ([.[] | select(.verdict == "REQUEST_CHANGES")] | length),
      crashed: ([.[] | select(.verdict == null and (.analyzer_outcome // "") != "success")] | length),
      findings: ([.[] | (.findings_count // 0)] | add // 0),
      latest: ([.[].recorded_at // "" | select(. != "")] | sort | last)
    }) |
    sort_by(-.runs) |
    .[] |
    "| \(.repo) | \(.runs) | \(.round1) | \(.round2) | \(.approve) | \(.comment) | \(.rc) | \(.crashed) | \(.findings) | \(.latest // "—") |"
  ' "$ALL_JSONL"

  printf '\n## Recent runs (last 20)\n\n'
  jq -s -r '
    sort_by(.recorded_at // "") | reverse | .[0:20] | .[] |
    "- `" + (.recorded_at // "—") + "` **" + .repo + "#" + ((.pr_number // "?") | tostring) +
    "** round=" + ((.round // "?") | tostring) +
    " verdict=" + (.verdict // "—") +
    " findings=" + ((.findings_count // 0) | tostring) +
    " functional=" + (.functional_overall // "N/A")
  ' "$ALL_JSONL"
  printf '\n'
}

if [ -n "$WRITE_PATH" ]; then
  mkdir -p "$(dirname "$WRITE_PATH")"
  render_markdown > "$WRITE_PATH"
  echo "Wrote $WRITE_PATH" >&2
  cat "$WRITE_PATH"
else
  render_markdown
fi
