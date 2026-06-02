#!/usr/bin/env bash
# cost-snapshot.sh — Measure what the Claude PR Review pipeline actually SPENDS
# (GitHub Actions runner-minutes + Claude model $) and what it YIELDS (findings,
# verdicts) across one or more consumer repos, over a time window.
#
# This is the before/after ruler: run it now to capture a baseline, make
# pipeline changes, run it again with the same flags, and diff the two reports.
#
# Why it exists separately from usage-report.sh:
#   usage-report.sh is ARTIFACT-centric — it reads the per-run `claude-review-usage`
#   artifact, which is only uploaded on a SUCCESSFUL build. That misses every
#   cancelled/failed run — and cancelled re-runs (a PR repushed 17 times in a
#   week) are exactly where the Actions burn and the re-run amplification hide.
#   This tool is RUN-centric: it enumerates the workflow's run history (including
#   cancelled/failed), reads real wall-time from the timing API for Actions
#   minutes, and JOINS the usage artifact for verdict/findings/Claude-$ where one
#   exists.
#
# Spend sources:
#   - Actions minutes  → /repos/{repo}/actions/runs/{id}/timing .run_duration_ms
#                        (always available; billed = ceil(ms/60000) per run).
#   - Claude $         → the usage artifact's `claude_cost_usd` field (recorded by
#                        report-usage.sh). Runs from before that field shipped show
#                        cost coverage < 100%; the report states the coverage so a
#                        partial Claude-$ total is never mistaken for the full one.
#
# Usage:
#   bash scripts/cost-snapshot.sh                                  # discover consumers, last 7d
#   bash scripts/cost-snapshot.sh --repos owner/repo-a,owner/repo-b
#   bash scripts/cost-snapshot.sh --owner my-org --since 30d --rate 0.008
#   bash scripts/cost-snapshot.sh --since 7d --write ./review-cost-snapshot.md
#   bash scripts/cost-snapshot.sh --json > baseline.jsonl         # raw per-run rows
#   bash scripts/cost-snapshot.sh --full-cost                     # recover Claude $ now (slow)
#
# Note: the report contains per-repo spend figures — treat the output as
# internal/financial data. Don't commit it into a public repo.
#
# --full-cost downloads the 7-day full artifact for any run whose usage record
# lacks claude_cost_usd and greps the cost from it. Use it for a baseline taken
# BEFORE the report-usage.sh instrumentation has shipped; omit it once consumers
# are on a release that records claude_cost_usd (then the usage artifact alone
# carries cost, for 90 days, at no download cost).
#
# Per-run fetches run in parallel (JOBS, default 12 — set JOBS=N to tune), so
# even --full-cost across hundreds of runs is minutes, not tens of minutes.
#
# Requires: gh (authenticated, cross-org), jq. With --full-cost: also unzip.

set -uo pipefail

# ── defaults ──
SINCE="7d"
REPOS=""
OWNER=""                       # optional: scope consumer-discovery to one org
WORKFLOW="Claude PR Review"   # display name (consumer workflow's `name:`)
RATE="0.008"                  # $/min, private ubuntu-latest 2-core (Mar-2025 list price)
WRITE_PATH=""
EMIT_JSON=false
FULL_COST=false               # recover Claude $ from the 7-day full artifact when
                              # the usage artifact lacks claude_cost_usd (slow)
RUN_LIMIT=400                 # per-repo run cap; warns if hit

print_help() { sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

require_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ] || [[ "$value" == -* ]]; then
    echo "::error::$flag requires a value (e.g. $flag 7d)" >&2; exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)    require_value --since "${2:-}";    SINCE="$2";    shift 2 ;;
    --repos)    require_value --repos "${2:-}";    REPOS="$2";    shift 2 ;;
    --owner)    require_value --owner "${2:-}";    OWNER="$2";    shift 2 ;;
    --workflow) require_value --workflow "${2:-}"; WORKFLOW="$2"; shift 2 ;;
    --rate)     require_value --rate "${2:-}";     RATE="$2";     shift 2 ;;
    --limit)    require_value --limit "${2:-}";    RUN_LIMIT="$2";shift 2 ;;
    --write)    require_value --write "${2:-}";    WRITE_PATH="$2";shift 2 ;;
    --json)     EMIT_JSON=true; shift ;;
    --full-cost) FULL_COST=true; shift ;;
    -h|--help)  print_help; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; echo "Run with --help for usage." >&2; exit 2 ;;
  esac
done

# ── prerequisites ──
NEED=(gh jq)
[ "$FULL_COST" = true ] && NEED+=(unzip)
for bin in "${NEED[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "::error::missing dependency: $bin" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "::error::gh is not authenticated — run 'gh auth login'" >&2; exit 1; }

# ── since → absolute ISO-8601 (BSD date first, GNU fallback) ──
to_iso_since() {
  local input="$1"
  if [[ "$input" =~ ^([0-9]+)d$ ]]; then
    local n="${BASH_REMATCH[1]}"
    date -u -v-"${n}"d +%Y-%m-%dT00:00:00Z 2>/dev/null \
      || date -u -d "${n} days ago" +%Y-%m-%dT00:00:00Z 2>/dev/null \
      || { echo "::error::cannot compute date for --since=$input" >&2; exit 1; }
  else
    echo "$input"
  fi
}
SINCE_ISO=$(to_iso_since "$SINCE")

# ── repo list ──
REPO_LIST=()
if [ -n "$REPOS" ]; then
  IFS=',' read -r -a REPO_LIST <<< "$REPOS"
else
  # Discover repos that reference this action in a workflow file (same query
  # usage-report.sh uses). `uses:` is a search qualifier, so match plain text.
  # --owner is added only when set, so the default scans every accessible repo.
  SEARCH_ARGS=(--json repository --jq '.[].repository.nameWithOwner' --limit 100)
  [ -n "$OWNER" ] && SEARCH_ARGS+=(--owner "$OWNER")
  while IFS= read -r r; do [ -n "$r" ] && REPO_LIST+=("$r"); done < <(
    gh search code 'panenco/claude-review path:.github/workflows' "${SEARCH_ARGS[@]}" 2>/dev/null | sort -u
  )
fi
if [ "${#REPO_LIST[@]}" -eq 0 ]; then
  echo "::warning::no repos to scan — pass --repos owner/a,owner/b or --owner <org>" >&2
  exit 0
fi

# ── collect per-run rows as JSONL ──
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows.jsonl"; : > "$ROWS"
JOBS="${JOBS:-12}"   # parallel workers for the per-run timing/cost fan-out (env-tunable)

# Timestamped progress to stderr (so a long run shows what it's doing + how long).
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >&2; }
fmt_elapsed() { local s="$1"; if [ "$s" -ge 60 ]; then printf '%dm%02ds' "$((s/60))" "$((s%60))"; else printf '%ds' "$s"; fi; }
RUN_START=$(date +%s)

# Process ONE run → emit one JSON row to stdout: fetch timing (+ Claude $ via the
# usage field, or with --full-cost the full artifact). Pure per-run work so it
# runs concurrently — reads USAGE_MAP/FULL_COST/TMP as read-only globals.
process_run() {
  local repo="$1" rid="$2" ev="$3" concl="$4" branch="$5" created="$6"
  local ms cost c faid fz
  ms=$(gh api "/repos/$repo/actions/runs/$rid/timing" --jq '.run_duration_ms // 0' 2>/dev/null || echo 0)
  [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
  cost=$(jq -r --arg rid "$rid" '.[$rid].claude_cost_usd // empty' "$USAGE_MAP" 2>/dev/null)
  if [ -z "$cost" ] && [ "$FULL_COST" = true ] \
     && { [ "$ev" = "pull_request" ] || [ "$ev" = "workflow_dispatch" ]; } \
     && { [ "$concl" = "success" ] || [ "$concl" = "failure" ]; }; then
    faid=$(gh api "/repos/$repo/actions/runs/$rid/artifacts" \
             --jq '.artifacts[]? | select(.name|test("^claude-review-[0-9]+$")) | .id' 2>/dev/null | head -1)
    if [ -n "$faid" ]; then
      fz="$TMP/f-$rid.zip"
      if gh api "/repos/$repo/actions/artifacts/$faid/zip" > "$fz" 2>/dev/null; then
        c=$(unzip -p "$fz" 'tmp/orchestrator-output.txt' 2>/dev/null \
              | grep -oE '"total_cost_usd"[[:space:]]*:[[:space:]]*[0-9]+(\.[0-9]+)?' \
              | grep -oE '[0-9]+(\.[0-9]+)?$' | sort -g | tail -1)
        [ -n "$c" ] && cost="$c"
      fi
      rm -f "$fz"
    fi
  fi
  if [ -z "$cost" ] || ! printf '%s' "$cost" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then cost="null"; fi
  jq -nc \
    --arg repo "$repo" --arg rid "$rid" --arg ev "$ev" --arg concl "$concl" \
    --arg branch "$branch" --arg created "$created" --argjson ms "$ms" \
    --argjson cost "$cost" \
    --slurpfile umap "$USAGE_MAP" '
    ($umap[0][$rid] // {}) as $u |
    { repo: $repo, run_id: $rid, event: $ev, conclusion: $concl, branch: $branch,
      created_at: $created, duration_ms: $ms,
      billed_min: (if $ms > 0 then (($ms + 59999) / 60000 | floor) else 0 end),
      verdict: ($u.verdict // null),
      findings_count: ($u.findings_count // null),
      functional_strategy: ($u.functional_strategy // null),
      claude_cost_usd: $cost,
      has_usage: ($u | has("verdict")) }'
}

# Download ONE usage artifact + extract its record → emit one {run_id, …} JSON
# line to stdout. Pure per-artifact work, runs concurrently (no shared state —
# the caller folds all lines into the map in a single jq pass afterwards).
load_usage_artifact() {
  local repo="$1" meta="$2"
  local aid rid zip payload
  aid=$(echo "$meta" | jq -r '.id'); rid=$(echo "$meta" | jq -r '.run_id')
  [ -z "$aid" ] && return
  zip="$TMP/u-$aid.zip"
  gh api "/repos/$repo/actions/artifacts/$aid/zip" > "$zip" 2>/dev/null || { rm -f "$zip"; return; }
  payload=$(unzip -p "$zip" usage.json 2>/dev/null) || { rm -f "$zip"; return; }
  rm -f "$zip"
  echo "$payload" | jq -c --arg rid "$rid" '{
    run_id: $rid,
    verdict: (.verdict // null),
    findings_count: (.findings_count // 0),
    functional_strategy: (.functional_strategy // null),
    claude_cost_usd: (.claude_cost_usd // null),
    round: (.round // null)
  }' 2>/dev/null || true
}

for repo in "${REPO_LIST[@]}"; do
  repo="${repo// /}"; [ -z "$repo" ] && continue
  repo_start=$(date +%s)
  log "→ $repo"

  # 1) Build a run_id → usage-record map (verdict/findings/strategy/claude_cost).
  #    Mirror usage-report.sh: list claude-review-usage artifacts, download the
  #    inner usage.json. Keyed by run_id so the run-list join below is O(1).
  log "  loading usage records…"
  umap_start=$(date +%s)
  USAGE_MAP="$TMP/usage-${repo//\//_}.json"; echo '{}' > "$USAGE_MAP"
  arts=$(gh api --paginate "/repos/$repo/actions/artifacts?per_page=100&name=claude-review-usage" \
          --jq '.artifacts[]? | select(.created_at >= "'"$SINCE_ISO"'") | {id, run_id: .workflow_run.id}' 2>/dev/null || true)
  uarts=()
  while IFS= read -r meta; do [ -n "$meta" ] && uarts+=("$meta"); done <<< "$arts"
  art_total=${#uarts[@]}
  # Download + extract in PARALLEL batches (each worker → one private record file),
  # then fold them into the map with ONE jq pass below — no shared-state race.
  rm -f "$TMP"/urow-*.json
  ui=0
  while [ "$ui" -lt "$art_total" ]; do
    bend=$(( ui + JOBS )); [ "$bend" -gt "$art_total" ] && bend="$art_total"
    k="$ui"
    while [ "$k" -lt "$bend" ]; do
      load_usage_artifact "$repo" "${uarts[$k]}" > "$TMP/urow-$k.json" &
      k=$(( k + 1 ))
    done
    wait
    ui="$bend"
    printf '\r[%s]   [%s] usage %d/%d' "$(date +%H:%M:%S)" "$repo" "$ui" "$art_total" >&2
  done
  [ "$art_total" -gt 0 ] && printf '\n' >&2
  if ls "$TMP"/urow-*.json >/dev/null 2>&1; then
    cat "$TMP"/urow-*.json | jq -s 'reduce .[] as $r ({}; . + {($r.run_id): ($r | del(.run_id))})' \
      > "$USAGE_MAP" 2>/dev/null || echo '{}' > "$USAGE_MAP"
  fi
  rm -f "$TMP"/urow-*.json
  log "  $art_total usage records loaded ($(fmt_elapsed $(( $(date +%s) - umap_start ))))"

  # 2) Enumerate ALL runs of this workflow in the window (incl cancelled/failed).
  log "  listing runs…"
  runs=$(gh run list --repo "$repo" --workflow "$WORKFLOW" --created ">=$SINCE_ISO" \
           --limit "$RUN_LIMIT" \
           --json databaseId,event,conclusion,status,headBranch,createdAt \
           --jq '.[] | "\(.databaseId)\t\(.event)\t\(.conclusion // .status)\t\(.headBranch)\t\(.createdAt)"' 2>/dev/null || true)
  rcount=$(printf '%s\n' "$runs" | grep -c . || true)
  [ "$rcount" -ge "$RUN_LIMIT" ] && log "  ::warning:: hit --limit $RUN_LIMIT for $repo; raise --limit for a complete count"
  log "  $rcount runs since $SINCE_ISO"

  # 3) Fetch per-run timing (+ full-cost) in PARALLEL batches — the work is
  #    network-bound and independent per run, so we fan out JOBS at a time
  #    (~10–16× faster than serial). Each worker writes its row to a private
  #    file (no shared-file interleaving); rows are collected after each batch,
  #    and a live k/N counter prints so a long run never looks stuck.
  tuples=()
  while IFS= read -r line; do [ -n "$line" ] && tuples+=("$line"); done <<< "$runs"
  total=${#tuples[@]}
  [ "$total" -eq 0 ] && continue
  rm -f "$TMP"/row-*.json
  idx=0
  while [ "$idx" -lt "$total" ]; do
    batch_end=$(( idx + JOBS )); [ "$batch_end" -gt "$total" ] && batch_end="$total"
    b="$idx"
    while [ "$b" -lt "$batch_end" ]; do
      IFS=$'\t' read -r rid ev concl branch created <<< "${tuples[$b]}"
      [ -n "$rid" ] && process_run "$repo" "$rid" "$ev" "$concl" "$branch" "$created" > "$TMP/row-$b.json" &
      b=$(( b + 1 ))
    done
    wait
    idx="$batch_end"
    printf '\r[%s]   [%s] %d/%d runs' "$(date +%H:%M:%S)" "$repo" "$idx" "$total" >&2
  done
  printf '\n' >&2
  cat "$TMP"/row-*.json >> "$ROWS" 2>/dev/null
  rm -f "$TMP"/row-*.json
  log "  ✓ $repo done ($(fmt_elapsed $(( $(date +%s) - repo_start ))))"
done
log "✓ all repos done in $(fmt_elapsed $(( $(date +%s) - RUN_START )))"

TOTAL=$(grep -c . "$ROWS" || true)
if [ "$TOTAL" -eq 0 ]; then
  echo "::warning::0 runs found across ${#REPO_LIST[@]} repo(s) since $SINCE_ISO." >&2
  exit 0
fi

# ── emit raw ──
if [ "$EMIT_JSON" = true ]; then cat "$ROWS"; exit 0; fi

# ── render markdown ──
render() {
  local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '# Claude Review — cost & yield snapshot\n\n'
  printf -- '_Generated %s · window %s → %s · rate $%s/runner-min_\n\n' "$now_iso" "$SINCE_ISO" "$now_iso" "$RATE"

  jq -s -r --argjson rate "$RATE" '
    def money(x): "$" + (x * 100 | round / 100 | tostring);
    {
      runs: length,
      review_runs: ([.[] | select(.event=="pull_request" or .event=="workflow_dispatch")] | length),
      warm_runs:   ([.[] | select(.event=="pull_request_target")] | length),
      billed_min:  ([.[] | .billed_min] | add // 0),
      cancelled:   ([.[] | select(.conclusion=="cancelled")] | length),
      with_usage:  ([.[] | select(.has_usage)] | length),
      claude_known:([.[] | select(.claude_cost_usd != null)] | length),
      claude_sum:  ([.[] | (.claude_cost_usd // 0)] | add // 0),
      zero_find:   ([.[] | select(.has_usage and (.findings_count // 0) == 0)] | length),
      tot_find:    ([.[] | (.findings_count // 0)] | add // 0),
      functional:  ([.[] | select(.functional_strategy=="functional")] | length),
      skip:        ([.[] | select(.functional_strategy=="skip")] | length)
    }
    | "## Spend\n"
    + "- Runs: **\(.runs)** (\(.review_runs) review + \(.warm_runs) warm-cache; \(.cancelled) cancelled)\n"
    + "- **Actions: \(.billed_min) runner-min ≈ \(money(.billed_min * $rate))**\n"
    + "- **Claude: \(money(.claude_sum))** across \(.claude_known)/\(.runs) runs with cost data"
    + (if .claude_known < .runs then "  ⚠️ partial — runs predate `claude_cost_usd` instrumentation" else "" end) + "\n"
    + "- Combined (known): **\(money(.billed_min * $rate + .claude_sum))**\n\n"
    + "## Yield\n"
    + "- Runs with a usage record: \(.with_usage)\n"
    + "- **Zero-findings runs: \(.zero_find)/\(.with_usage)" + (if .with_usage>0 then " (\(.zero_find*100/.with_usage|floor)%)" else "" end) + "**\n"
    + "- Findings raised: \(.tot_find)\n"
    + "- Strategy: functional \(.functional) · skip \(.skip)\n"
  ' "$ROWS"

  # Latency — wall-clock per REVIEW run. This is the "reviews take too long"
  # metric (distinct from runner-min, which is aggregate spend). Tracks how
  # long an author waits, and how many reviews blow past 10 min.
  jq -s -r '
    [.[] | select((.event=="pull_request" or .event=="workflow_dispatch") and ((.duration_ms // 0) > 0)) | (.duration_ms/60000)]
    | sort as $d | ($d | length) as $n
    | if $n == 0 then "## Review latency\n- (no completed review runs in window)\n"
      else
        ($d[($n*0.5|floor)]) as $med
        | ($d[([$n-1,($n*0.9|floor)] | min)]) as $p90
        | ($d[$n-1]) as $max
        | "## Review latency (wall-clock per review)\n"
        + "- median **\(($med*10|round)/10) min** · p90 **\(($p90*10|round)/10) min** · max **\(($max*10|round)/10) min**\n"
        + "- reviews over 10 min: **\([$d[] | select(. > 10)] | length)/\($n)**\n"
      end
  ' "$ROWS"

  printf '\n## Per-repo\n\n'
  printf '%s\n' '| Repo | Runs | Cancelled | Runner-min | Actions $ | Claude $ | Zero-find | Findings |'
  printf '%s\n' '|---|---:|---:|---:|---:|---:|---:|---:|'
  jq -s -r --argjson rate "$RATE" '
    def money(x): "$" + (x * 100 | round / 100 | tostring);
    group_by(.repo) | map({
      repo: .[0].repo, runs: length,
      cancelled: ([.[]|select(.conclusion=="cancelled")]|length),
      min: ([.[]|.billed_min]|add // 0),
      claude: ([.[]|(.claude_cost_usd // 0)]|add // 0),
      zero: ([.[]|select(.has_usage and (.findings_count//0)==0)]|length),
      find: ([.[]|(.findings_count//0)]|add // 0)
    }) | sort_by(-.min) | .[] |
    "| \(.repo) | \(.runs) | \(.cancelled) | \(.min) | \(money(.min*$rate)) | \(money(.claude)) | \(.zero) | \(.find) |"
  ' "$ROWS"

  # A PR is re-reviewed once per push, so its true cost is the sum across all
  # its runs. Group pull_request runs by branch (≈ one PR) and total the spend.
  printf '\n## Most expensive PRs (Σ across all of a PR'\''s runs)\n\n'
  printf '%s\n' '| Repo · branch | Runs | Σ runner-min | Σ Actions $ | Σ Claude $ |'
  printf '%s\n' '|---|---:|---:|---:|---:|'
  jq -s -r --argjson rate "$RATE" '
    def money(x): "$" + (x * 100 | round / 100 | tostring);
    [.[] | select(.event=="pull_request")] | group_by(.repo + " " + .branch)
    | map({k: (.[0].repo + " · " + .[0].branch), n: length,
           min: ([.[] | .billed_min] | add // 0),
           claude: ([.[] | (.claude_cost_usd // 0)] | add // 0)})
    | sort_by(-(.claude + .min * $rate)) | .[0:10][] |
    "| \(.k) | \(.n) | \(.min) | \(money(.min * $rate)) | \(money(.claude)) |"
  ' "$ROWS"

  printf '\n## Re-run amplification (top branches by run count)\n\n'
  printf '%s\n' '| Repo / branch | Runs in window |'
  printf '%s\n' '|---|---:|'
  jq -s -r '
    [.[] | select(.event=="pull_request")] | group_by(.repo + " " + .branch)
    | map({k: (.[0].repo + " · " + .[0].branch), n: length}) | sort_by(-.n) | .[0:10][] |
    "| \(.k) | \(.n) |"
  ' "$ROWS"
  printf '\n'
}

if [ -n "$WRITE_PATH" ]; then
  mkdir -p "$(dirname "$WRITE_PATH")"
  render > "$WRITE_PATH"
  echo "Wrote $WRITE_PATH" >&2
  cat "$WRITE_PATH"
else
  render
fi
