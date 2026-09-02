#!/usr/bin/env bash
# run-breakdown.sh — Where one review run's money and minutes actually went.
#
# The before/after ruler for a pipeline optimisation: run it on a baseline run
# id, land the change, run it on the new run id, diff the two tables.
#
# It answers two questions the usage artifact cannot:
#
#   1. WHICH STAGE spent the money — orchestrator vs review-scan vs
#      review-functional-tester vs review-native vs review-verify. usage.json
#      records one `claude_cost_usd` for the whole session; the per-stage split
#      only exists in the session transcript (`orchestrator-output.txt` in the
#      `claude-review-<pr>` artifact), where every subagent message carries a
#      `parent_tool_use_id` pointing back at the `Agent` call that dispatched it.
#
#   2. WHERE THE WALL CLOCK WENT — runner bring-up and installs (workflow step
#      timings, from the runs API) versus model time (transcript timestamps),
#      and inside model time, how much elapsed before the first subagent was
#      even dispatched. That pre-dispatch window is the orchestrator's turn-1
#      bash: spec assembly plus the dev-environment wait.
#
# Three things the transcript does NOT give you straight, and what this does:
#
#   * DUPLICATE MESSAGES. The stream emits one `assistant` entry per content
#     block, each repeating the SAME `message.usage`. Summing them naively
#     over-counts input tokens by ~40%. Deduped by `message.id`.
#   * TRUNCATED OUTPUT COUNTS. The usage on an assistant entry is the one from
#     `message_start`, whose `output_tokens` is a placeholder (1-17), not the
#     final count. Per-model output totals are read from the result entry's
#     `modelUsage` instead and split across that model's stages in proportion
#     to the characters each actually emitted. Output tokens are therefore
#     marked `~` — every other column is exact.
#   * HIDDEN SUBAGENTS. The `code-review` plugin behind `review-native` fans out
#     to ~10 of its own subagents, and some runs do not carry their messages at
#     all. Their spend still lands in `modelUsage`, so the per-model shortfall
#     is credited to the stage that owns the missing children (detected via
#     `task_started` ids that never appear as a parent). If the owner is
#     ambiguous the shortfall gets its own `(unattributed)` row rather than
#     being smeared over innocent stages.
#
# The attributed total is printed next to the session's own `total_cost_usd`;
# they should agree within ~1%. A wider gap means the pricing table below has
# drifted from the models actually used — fix the table, don't trust the split.
#
# Usage:
#   bash scripts/run-breakdown.sh <run-id> <repo>        # downloads the artifacts
#   bash scripts/run-breakdown.sh 33300467953 my-org/my-repo
#   bash scripts/run-breakdown.sh --transcript path/to/orchestrator-output.txt
#   bash scripts/run-breakdown.sh --transcript t.json --jobs jobs.json
#   bash scripts/run-breakdown.sh 33300467953 my-org/my-repo --json
#
# Requires: jq. `gh` only when you pass a run id rather than --transcript.

set -uo pipefail

TRANSCRIPT=""
JOBS_JSON=""
RUN_ID=""
REPO=""
EMIT_JSON=false

print_help() {
  sed -n '1,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

require_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ] || [[ "$value" == -* ]]; then
    echo "::error::$flag requires a value" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) require_value --transcript "${2:-}"; TRANSCRIPT="$2"; shift 2 ;;
    --jobs)       require_value --jobs "${2:-}";       JOBS_JSON="$2";  shift 2 ;;
    --json)       EMIT_JSON=true; shift ;;
    -h|--help)    print_help; exit 0 ;;
    -*)           echo "::error::unknown flag $1" >&2; exit 2 ;;
    *)
      if   [ -z "$RUN_ID" ]; then RUN_ID="$1"
      elif [ -z "$REPO" ];   then REPO="$1"
      else echo "::error::unexpected argument $1" >&2; exit 2
      fi
      shift ;;
  esac
done

if [ -z "$TRANSCRIPT" ] && { [ -z "$RUN_ID" ] || [ -z "$REPO" ]; }; then
  print_help >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "::error::jq is required" >&2; exit 2; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ── fetch, when we were given a run id ──
if [ -z "$TRANSCRIPT" ]; then
  command -v gh >/dev/null 2>&1 || { echo "::error::gh is required to download a run" >&2; exit 2; }
  WORK=$(mktemp -d)
  if ! gh run download "$RUN_ID" --repo "$REPO" -D "$WORK" >/dev/null 2>&1; then
    echo "::error::could not download artifacts for run $RUN_ID in $REPO" >&2
    exit 1
  fi
  # The transcript ships inside claude-review-<pr>; find it wherever it landed.
  TRANSCRIPT=$(find "$WORK" -name orchestrator-output.txt -print 2>/dev/null | head -1)
  if [ -z "$TRANSCRIPT" ]; then
    echo "::error::run $RUN_ID has no orchestrator-output.txt — a short-circuited or failed run has no transcript to break down" >&2
    exit 1
  fi
  if [ -z "$JOBS_JSON" ]; then
    JOBS_JSON="$WORK/jobs.json"
    gh run view "$RUN_ID" --repo "$REPO" --json jobs > "$JOBS_JSON" 2>/dev/null || JOBS_JSON=""
  fi
fi

[ -r "$TRANSCRIPT" ] || { echo "::error::cannot read transcript $TRANSCRIPT" >&2; exit 1; }

# ── prices, USD per million tokens: input, output, cache-read, cache-write-5m, cache-write-1h ──
# A model missing here is a hard error, not a zero: a silently unpriced stage
# would read as "free" and send the optimisation at the wrong target.
PRICES='{
  "claude-opus-5":    {"in":5,"out":25,"cr":0.5,"cw5":6.25,"cw1":10},
  "claude-sonnet-5":  {"in":3,"out":15,"cr":0.3,"cw5":3.75,"cw1":6},
  "claude-haiku-4-5": {"in":1,"out":5, "cr":0.1,"cw5":1.25,"cw1":2}
}'

ROWS=$(jq -c --argjson P "$PRICES" '
  # Walk a parent_tool_use_id up to the dispatch the orchestrator itself made.
  def rootof($owner; $p):
    if $p == null then null
    else {c: $p} | until(($owner[.c] // null) == null; .c = $owner[.c]) | .c
    end;
  def stageof($owner; $label; $p):
    (rootof($owner; $p)) as $r
    | if $r == null then "orchestrator"
      else (($label[$r] // "orchestrator") | if . == "bash" then "orchestrator" else . end)
      end;

  . as $T
  | ($T[-1]) as $res

  # id -> label / owner, for every Agent or Task dispatch in the session.
  | ( [ $T[] | select(.type=="assistant") as $e
        | ($e.parent_tool_use_id // null) as $p
        | (($e.message.content // [])[] | select(type=="object" and .type=="tool_use"
                                                 and (.name=="Agent" or .name=="Task")))
        | {id: .id, label: (.input.subagent_type // "bash"), owner: $p} ]
    ) as $tasks
  | (reduce $tasks[] as $t ({}; .[$t.id] = $t.owner)) as $owner
  | (reduce $tasks[] as $t ({}; .[$t.id] = $t.label)) as $label

  # Stages that dispatched a subagent whose messages never reached the
  # transcript — that is where a per-model shortfall belongs.
  | ( [ $T[] | select(.type=="assistant") | .parent_tool_use_id // "ORCH" ] | unique ) as $seenparents
  | ( [ $T[] | select(.subtype=="task_started" and .task_type=="local_agent")
        | select(([.tool_use_id] | inside($seenparents)) | not)
        | stageof($owner; $label; $owner[.tool_use_id]) ] | unique ) as $hidden

  # Deduped per-API-call usage. One assistant entry per content block repeats
  # the same message.usage, so dedupe by message.id or input is ~40% too high.
  | ( [ $T[] | select(.type=="assistant") | select(.message.usage != null)
        | {mid: .message.id, model: .message.model,
           stage: stageof($owner; $label; .parent_tool_use_id), u: .message.usage} ]
      | unique_by(.mid) ) as $calls

  # Emitted characters, the weight for splitting a model output total.
  | ( [ $T[] | select(.type=="assistant")
        | {mid: .message.id, stage: stageof($owner; $label; .parent_tool_use_id), model: .message.model}
          + {b: ((.message.content // [])[] | select(type=="object")
                 | (.text // .thinking // (if .type=="tool_use" then (.input|tostring) else "" end)))}
      ] | unique_by([.mid, .b]) ) as $blocks

  | ( [ $calls[].model ] | unique ) as $models
  | ( [ $models[] | select($P[.] == null) ] ) as $unpriced
  | if ($unpriced | length) > 0 then
      {error: ("no price for model(s): " + ($unpriced | join(", ")))}
    else

  ( [ $calls[]
      | {stage, model, calls: 1,
         inp: (.u.input_tokens // 0),
         cr:  (.u.cache_read_input_tokens // 0),
         cw5: (.u.cache_creation.ephemeral_5m_input_tokens // 0),
         cw1: (.u.cache_creation.ephemeral_1h_input_tokens // 0)} ]
    | group_by([.stage, .model])
    | map({stage: .[0].stage, model: .[0].model,
           calls: (map(.calls)|add), inp: (map(.inp)|add), cr: (map(.cr)|add),
           cw5: (map(.cw5)|add), cw1: (map(.cw1)|add), out: 0, outknown: false}) ) as $agg0

  # The result entry carries the TOP-LEVEL session usage exactly, output included.
  | ( $res.usage // {} ) as $ru
  | ( $agg0 | map(if .stage == "orchestrator"
                  then .inp = ($ru.input_tokens // 0)
                     | .cr  = ($ru.cache_read_input_tokens // 0)
                     | .cw5 = ($ru.cache_creation.ephemeral_5m_input_tokens // 0)
                     | .cw1 = ($ru.cache_creation.ephemeral_1h_input_tokens // 0)
                     | .out = ($ru.output_tokens // 0) | .outknown = true
                  else . end) ) as $agg1

  # Per model: credit the modelUsage shortfall, then split the output total.
  | ( reduce $models[] as $m ($agg1;
        . as $a
        | ($res.modelUsage[$m] // {}) as $mu
        | ([ $a[] | select(.model == $m) ]) as $mine
        | ([ $mine[] | select([.stage] | inside($hidden)) | .stage ]) as $owners
        | ((($mu.inputTokens // 0)          - (([$mine[].inp] | add) // 0))) as $dIn
        | ((($mu.cacheReadInputTokens // 0) - (([$mine[].cr]  | add) // 0))) as $dCr
        | ((($mu.cacheCreationInputTokens // 0) - (([$mine[] | .cw5 + .cw1] | add) // 0))) as $dCw
        | (if ($owners | length) == 1
           then map(if .model == $m and .stage == $owners[0]
                    then .inp += $dIn | .cr += $dCr | .cw5 += $dCw else . end)
           elif ($dIn + $dCr + $dCw) > 0
           then . + [{stage: "(unattributed)", model: $m, calls: 0,
                      inp: $dIn, cr: $dCr, cw5: $dCw, cw1: 0, out: 0, outknown: false}]
           else . end)
        | . as $b
        | ((($mu.outputTokens // 0) - (([ $b[] | select(.model == $m and .outknown) | .out ] | add) // 0))) as $rem
        | ([ $blocks[] | select(.model == $m) ]) as $mb
        | (reduce ($b[] | select(.model == $m and (.outknown | not)) | .stage) as $s
             ({}; .[$s] = (([ $mb[] | select(.stage == $s) | (.b | length) ] | add) // 0))) as $w
        | ((([$w[]] | add) // 0)) as $tw
        | map(if .model == $m and (.outknown | not) and $tw > 0
              then .out = ($rem * ($w[.stage] // 0) / $tw) else . end)
      ) ) as $agg

  # Wall clock per stage, from message timestamps.
  | ( [ $T[] | select(.type=="assistant" or .type=="user") | select(.timestamp != null)
        | {stage: stageof($owner; $label; .parent_tool_use_id), t: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)} ]
      | group_by(.stage)
      | map({stage: .[0].stage, t0: (map(.t) | min), t1: (map(.t) | max)}) ) as $spans
  | (([ $spans[].t0 ] | min) // 0) as $base

  | ( $agg | map(. as $r | ($P[.model]) as $p
        | . + {cost: (($r.inp*$p.in + $r.out*$p.out + $r.cr*$p.cr + $r.cw5*$p.cw5 + $r.cw1*$p.cw1) / 1000000)}
        | . + ((([ $spans[] | select(.stage == $r.stage) ] | first) // {t0: $base, t1: $base})
               | {t0: (.t0 - $base), t1: (.t1 - $base), wall: (.t1 - .t0)}) )
      | sort_by(-.cost) ) as $out

  | {reported: ($res.total_cost_usd // 0),
     attributed: (([$out[].cost] | add) // 0),
     span: ((([ $spans[].t1 ] | max) // $base) - $base),
     hidden: $hidden,
     stages: $out}
    end
' "$TRANSCRIPT")

if [ -z "$ROWS" ]; then
  echo "::error::could not parse $TRANSCRIPT as a session transcript (expected a JSON array)" >&2
  exit 1
fi
ERR=$(printf '%s' "$ROWS" | jq -r '.error // empty')
if [ -n "$ERR" ]; then
  echo "::error::$ERR — add it to the PRICES table in scripts/run-breakdown.sh" >&2
  exit 1
fi

# ── step timings, when we have them ──
STEPS=""
if [ -n "$JOBS_JSON" ] && [ -r "$JOBS_JSON" ]; then
  STEPS=$(jq -c '
    [ .jobs[]? | .steps[]?
      | select(.startedAt != null and .completedAt != null)
      | {name, sec: ((.completedAt|fromdateiso8601) - (.startedAt|fromdateiso8601))} ]
    | {total: (map(.sec)|add // 0), steps: [ .[] | select(.sec > 0) ]}' "$JOBS_JSON" 2>/dev/null)
fi

if [ "$EMIT_JSON" = true ]; then
  printf '%s' "$ROWS" | jq --argjson s "${STEPS:-null}" '. + {job_steps: $s}'
  exit 0
fi

# ── render ──
printf '%s' "$ROWS" | jq -r '
  "Reported $\(.reported*1000|round/1000)   attributed $\(.attributed*1000|round/1000)   model span \(.span|floor)s" +
  (if (.hidden|length) > 0 then "   hidden-subagent spend credited to: \(.hidden|join(", "))" else "" end)'
echo

printf '%-26s %-17s %5s %9s %10s %9s %9s %8s %6s %7s %6s\n' \
  stage model calls input cache-read cache-wr "out~" '$' '%' wall_s 'wall%'
printf '%s' "$ROWS" | jq -r '
  (.attributed) as $t | (.span) as $sp
  | .stages[]
  | [.stage, .model, .calls, .inp, .cr, (.cw5 + .cw1), (.out|floor),
     (.cost*1000|round/1000), ((.cost*1000/$t)|round/10),
     (.wall|floor), ((.wall*1000/(if $sp > 0 then $sp else 1 end))|round/10)]
  | @tsv' | while IFS=$'\t' read -r a b c d e f g h i j k; do
    printf '%-26s %-17s %5s %9s %10s %9s %9s %8s %6s %7s %6s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j" "$k"
  done
printf '%-26s %-17s %5s %9s %10s %9s %9s %8s\n' TOTAL '' '' '' '' '' '' \
  "$(printf '%s' "$ROWS" | jq -r '.attributed*1000|round/1000')"

echo
echo "Stage timeline (seconds from first model message)"
printf '%s' "$ROWS" | jq -r '.stages | sort_by(.t0)[]
  | "  \(.stage)\(" " * (26 - (.stage|length)))\(.t0|floor)s -> \(.t1|floor)s  (\(.wall|floor)s)"'

if [ -n "$STEPS" ]; then
  echo
  printf '%s' "$STEPS" | jq -r '"Workflow steps (job \(.total|floor)s)"'
  printf '%s' "$STEPS" | jq -r '(.total) as $t | .steps | sort_by(-.sec)[]
    | "  \(.sec|floor)s\("\t")\((.sec*1000/(if $t > 0 then $t else 1 end))|round/10)%\("\t")\(.name)"'
fi
