#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): every step below carries an explicit guard.

# probe-score.sh — score the reviewer against a LABELLED corpus of real PRs.
#
#   scripts/probe-score.sh score  [--corpus F] [--results DIR] [--label L] [--json]
#   scripts/probe-score.sh fetch  --corpus F --results DIR [--label L] [--run-map F]
#   scripts/probe-score.sh run    --corpus F --results DIR --entry <repo#pr>
#   scripts/probe-score.sh plan   [--corpus F]
#
# WHY THIS EXISTS. Every live probe of this reviewer so far has been a large,
# complex PR. The owner's quality target is about the OTHER end of the corpus:
# "relatively simple pr's ... should not get any check comments and those should
# be approved without findings, I'd estimate around 30 to 50% of our pr's would
# be like this". Nothing in the repo could measure that. This does.
#
# THE DEFAULT MODE IS OFFLINE AND FREE. `score` runs no model. It reads outcomes
# that a run ALREADY produced — either a CI artifact (`gh run download … -n
# claude-review-<pr>`) or a `scripts/review-local.sh` results directory — and
# compares them to the corpus label. `run` is the expensive one and it does a
# single PR at a time, on purpose (see COST below).
#
# ── the corpus ───────────────────────────────────────────────────────────────
# A JSON array; see tests/fixtures/probe-corpus.example.json for the schema and
# for placeholder entries. The REAL corpus is git-ignored, exactly like
# `.eval.env` and `docs/metrics/`, because this repo is PUBLIC and the corpus
# names private client repositories and PR titles. Never commit it.
#
# Labels and what each one EXPECTS the reviewer to do:
#
#   simple         CRUD or straightforward logic, mistakes unlikely.
#                  -> APPROVE, zero findings, zero checks.
#   needs-eyes     real logic, non-obvious behaviour, or blast radius.
#                  -> not APPROVE, or at least one finding/check.
#   docs-slice     docs-only, pure slicing on an already-merged architecture/PRD.
#                  -> APPROVE, zero findings, zero checks.
#   docs-baseline  docs-only, and it sets or changes direction.
#                  -> not APPROVE, or at least one finding/check.
#
# So the four labels collapse to one binary — APPROVABLE vs NEEDS-A-HUMAN — and
# the two error rates that matter are named separately in the scorecard:
#   false alarm  an approvable PR that was not approved  (the noise complaint)
#   miss         a needs-a-human PR that was approved    (the dangerous one)
#
# ── where an outcome is read from ────────────────────────────────────────────
# For each entry the results directory is searched, in order:
#   <results>/<repo-basename>-<pr>/   <results>/<pr>/   <results>/
# and inside it, in order:
#   posted/         the POST-poster outcome (review-local.sh). Preferred: this
#                   is what a human would actually have seen, after
#                   post-review.sh deduped body bullets against inline comments,
#                   applied REVIEW_COMMENT_LIMIT and re-anchored what it could.
#   review.json     the PRE-poster outcome (the CI artifact). The verdict is
#                   identical; the counts are the model's, before the cap.
# `source` in the per-entry output says which one was used, so a mixed sweep is
# still readable.
#
# Counts come from `meta`, never from the comment list, whenever `meta` has
# them: an unanchored check falls back into the body under "### What a human
# should review" and would vanish from a comments-only count. When `meta` is
# absent (a degraded run), the comment list is counted instead — `**worth a look**`
# prefix for checks, everything else a finding — and `source` gains `+approx`.
#
# ── COST, so a sweep is chosen and never stumbled into ───────────────────────
# A live review is ~$2-6 and ~12-20 min. `plan` prints the arithmetic for the
# loaded corpus. `score` and `fetch` cost nothing and take seconds. `run` does
# ONE entry, and there is deliberately no `run --all`: a full sweep is a
# `for` loop the operator writes themselves, having read `plan` first.

usage() {
  sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd) || { echo "cannot resolve repo root" >&2; exit 1; }

CMD="${1:-score}"
case "$CMD" in
  score|fetch|run|plan) shift ;;
  -h|--help) usage ;;
  *) CMD=score ;;
esac

CORPUS="$ROOT/tests/fixtures/probe-corpus.json"
RESULTS=""
ONLY_LABEL=""
ENTRY=""
RUN_MAP=""
AS_JSON=false
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)  CORPUS="${2:-}"; shift 2 ;;
    --results) RESULTS="${2:-}"; shift 2 ;;
    --label)   ONLY_LABEL="${2:-}"; shift 2 ;;
    --entry)   ENTRY="${2:-}"; shift 2 ;;
    --run-map) RUN_MAP="${2:-}"; shift 2 ;;
    --json)    AS_JSON=true; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq not on PATH" >&2; exit 1; }
[ -f "$CORPUS" ] || {
  echo "corpus not found: $CORPUS" >&2
  echo "  copy tests/fixtures/probe-corpus.example.json and fill it in (the real one is git-ignored)" >&2
  exit 1
}
jq -e 'type == "array"' "$CORPUS" >/dev/null 2>&1 \
  || { echo "corpus is not a JSON array: $CORPUS" >&2; exit 1; }

# ── the label contract, in exactly one place ─────────────────────────────────
# Every other read of "what does this label expect" goes through here, so a new
# label cannot be half-added.
expects_approval() { # expects_approval <label> -> 0 approvable, 1 needs a human, 2 unknown
  case "$1" in
    simple|docs-slice)        return 0 ;;
    needs-eyes|docs-baseline) return 1 ;;
    *)                        return 2 ;;
  esac
}

# ── corpus validation ────────────────────────────────────────────────────────
# A typo'd label would otherwise be scored as "unknown" and quietly excluded
# from every rate in the scorecard, which is the one failure this tool must not
# have.
BAD=$(jq -r '
  to_entries[]
  | select((.value.label // "") as $l
           | ($l | IN("simple","needs-eyes","docs-slice","docs-baseline")) | not)
  | "index \(.key): label=\(.value.label // "<missing>") repo=\(.value.repo // "?") pr=\(.value.number // "?")"
' "$CORPUS")
if [ -n "$BAD" ]; then
  echo "corpus has entries with an unknown label:" >&2
  printf '%s\n' "$BAD" >&2
  exit 1
fi
MISSING_KEY=$(jq -r '
  to_entries[]
  | select((.value | has("repo") and has("number")) | not)
  | "index \(.key)"
' "$CORPUS")
if [ -n "$MISSING_KEY" ]; then
  echo "corpus has entries missing repo/number:" >&2
  printf '%s\n' "$MISSING_KEY" >&2
  exit 1
fi

corpus_rows() { # -> repo \t number \t label \t borderline \t head_sha \t base_sha
  jq -r --arg only "$ONLY_LABEL" '
    .[]
    | select($only == "" or .label == $only)
    | [ .repo, (.number|tostring), .label, ((.borderline // false)|tostring),
        (.head_sha // ""), (.base_sha // "") ] | @tsv
  ' "$CORPUS"
}

# ── plan ─────────────────────────────────────────────────────────────────────
if [ "$CMD" = "plan" ]; then
  N=$(corpus_rows | wc -l | tr -d ' ')
  echo "corpus:  $CORPUS"
  echo "entries: $N${ONLY_LABEL:+ (label=$ONLY_LABEL)}"
  echo
  jq -r --arg only "$ONLY_LABEL" '
    [ .[] | select($only == "" or .label == $only) ]
    | group_by(.label) | map({label: .[0].label, n: length})
    | sort_by(-.n)[] | "  \(.label)\t\(.n)"
  ' "$CORPUS"
  echo
  # The per-review figures are the operator's measured range for this pipeline
  # (see the Makefile's `eval` target and docs/metrics/); they move with model
  # and diff size, so they are stated as a range and never as a single number.
  echo "a LIVE sweep of these $N entries:"
  echo "  cost  \$$((N * 2)) - \$$((N * 6))   (at \$2-6 per review)"
  echo "  time  $((N * 12))min - $((N * 20))min sequential (~$((N * 12 / 60))h - ~$((N * 20 / 60))h)"
  echo
  echo "offline scoring of the same $N entries costs \$0 and takes seconds."
  echo "run one entry live:  scripts/probe-score.sh run --results DIR --entry <repo#pr>"
  exit 0
fi

# ── fetch: pull CI artifacts into the results layout ─────────────────────────
if [ "$CMD" = "fetch" ]; then
  [ -n "$RESULTS" ] || { echo "fetch needs --results DIR" >&2; exit 2; }
  command -v gh >/dev/null 2>&1 || { echo "gh not on PATH" >&2; exit 1; }
  mkdir -p "$RESULTS" || { echo "could not create $RESULTS" >&2; exit 1; }
  # A run id per entry cannot be derived — a PR can have many review runs and
  # only the operator knows which one is the one under test. So `fetch` takes a
  # map file of `<repo>#<pr> <run-id>` lines, and without one it just says which
  # entries have no outcome yet, which is the question you actually have.
  rc=0
  while IFS=$'\t' read -r repo num label _bl _h _b; do
    [ -n "$repo" ] || continue
    dest="$RESULTS/${repo##*/}-$num"
    if [ -f "$dest/review.json" ] || [ -f "$dest/posted/verdict" ]; then
      echo "have    $repo#$num ($label)"
      continue
    fi
    run_id=""
    if [ -n "$RUN_MAP" ] && [ -f "$RUN_MAP" ]; then
      run_id=$(awk -v k="$repo#$num" '$1 == k { print $2; exit }' "$RUN_MAP")
    fi
    if [ -z "$run_id" ]; then
      echo "MISSING $repo#$num ($label) — no run id in ${RUN_MAP:-<no --run-map>}"
      rc=1
      continue
    fi
    mkdir -p "$dest" || { echo "could not create $dest" >&2; rc=1; continue; }
    if gh run download "$run_id" --repo "$repo" -n "claude-review-$num" -D "$dest" >/dev/null 2>&1; then
      echo "fetched $repo#$num ($label) from run $run_id"
    else
      echo "FAILED  $repo#$num ($label) — run $run_id / artifact claude-review-$num"
      rc=1
    fi
  done < <(corpus_rows)
  exit "$rc"
fi

# ── run: ONE entry, live, through the existing local harness ─────────────────
if [ "$CMD" = "run" ]; then
  [ -n "$ENTRY" ]   || { echo "run needs --entry <repo#pr>" >&2; exit 2; }
  [ -n "$RESULTS" ] || { echo "run needs --results DIR" >&2; exit 2; }
  case "$ENTRY" in
    */*\#*) ;;
    *) echo "--entry must look like owner/repo#123, got '$ENTRY'" >&2; exit 2 ;;
  esac
  E_REPO="${ENTRY%%#*}"
  E_PR="${ENTRY##*#}"
  case "$E_PR" in ''|*[!0-9]*) echo "--entry PR number is not numeric: '$E_PR'" >&2; exit 2 ;; esac
  FOUND=$(jq -r --arg r "$E_REPO" --argjson n "$E_PR" \
    '[ .[] | select(.repo == $r and .number == $n) ] | length' "$CORPUS")
  [ "$FOUND" = "1" ] || { echo "$ENTRY is not in $CORPUS (matched $FOUND entries)" >&2; exit 1; }

  # review-local.sh is the harness; this does NOT reimplement it. It reads
  # EVAL_REPO from the environment or .eval.env, so the repo is passed the same
  # way, and it posts nothing.
  LOCAL="$ROOT/scripts/review-local.sh"
  [ -x "$LOCAL" ] || [ -f "$LOCAL" ] || { echo "$LOCAL not found" >&2; exit 1; }
  EVAL_ROOT="${EVAL_ROOT:-${TMPDIR:-/tmp}/claude-review-eval}"
  echo "LIVE run: $ENTRY — this costs ~\$2-6 and takes ~12-20 min, and posts nothing"
  EVAL_REPO="$E_REPO" bash "$LOCAL" "$E_PR"
  LRC=$?
  SRC="$EVAL_ROOT/results/$E_PR"
  DEST="$RESULTS/${E_REPO##*/}-$E_PR"
  mkdir -p "$DEST" || { echo "could not create $DEST" >&2; exit 1; }
  if [ -d "$SRC" ]; then
    cp -R "$SRC/." "$DEST/" || { echo "could not copy $SRC into $DEST" >&2; exit 1; }
    echo "collected -> $DEST"
  else
    echo "review-local.sh left no results at $SRC" >&2
    exit 1
  fi
  [ "$LRC" -eq 0 ] || echo "note: review-local.sh exited $LRC — scoring what it did leave"
  # Narrow the fall-through to the entry that just ran. Without this, one live
  # run scores the whole corpus and reports the other N-1 entries as no-result,
  # which exits non-zero and reads as a failure of the run you just paid for.
  NARROW="${TMPDIR:-/tmp}/probe-corpus-$E_PR.$$.json"
  jq --arg r "$E_REPO" --argjson n "$E_PR" \
    '[ .[] | select(.repo == $r and .number == $n) ]' "$CORPUS" > "$NARROW" \
    || { echo "could not narrow the corpus to $ENTRY" >&2; exit 1; }
  CORPUS="$NARROW"
  trap 'rm -f "$NARROW"' EXIT
  echo
  # fall through to score
fi

# ── score ────────────────────────────────────────────────────────────────────
[ -n "$RESULTS" ] || { echo "score needs --results DIR" >&2; exit 2; }
[ -d "$RESULTS" ] || { echo "results directory not found: $RESULTS" >&2; exit 1; }

# The bare results root is only a legal location when the selection is a SINGLE
# entry. With more than one, a loose review.json at the root would be handed to
# every entry that has no directory of its own — scoring B against A's outcome,
# silently. That is the one way this tool could report a confident lie.
SELECTED=$(corpus_rows | wc -l | tr -d ' ')

# outcome_dir <repo> <pr> -> the directory holding this entry's outcome, or ""
outcome_dir() {
  local repo="$1" pr="$2" d
  local candidates="$RESULTS/${repo##*/}-$pr"$'\n'"$RESULTS/$pr"
  [ "$SELECTED" = "1" ] && candidates="$candidates"$'\n'"$RESULTS"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -f "$d/posted/verdict" ] || [ -f "$d/review.json" ]; then printf '%s' "$d"; return 0; fi
  done <<<"$candidates"
  return 1
}

# read_outcome <dir> -> verdict \t findings \t checks \t source
# Emits nothing and returns 1 when the directory holds no readable outcome.
read_outcome() {
  local d="$1" verdict="" findings=-1 checks=-1 source="" json="" approx=""
  if [ -f "$d/posted/verdict" ]; then
    source=posted
    verdict=$(head -1 "$d/posted/verdict" 2>/dev/null | tr -d '[:space:]')
    json="$d/posted/meta.json"
    if [ -f "$json" ]; then
      IFS=$'\t' read -r findings checks < <(jq -r '
        def n(x): if (x|type) == "array" then (x|length) else -1 end;
        [ n(.findings), n(.human_review) ] | @tsv' "$json" 2>/dev/null) || { findings=-1; checks=-1; }
    fi
    if [ "${findings:--1}" -lt 0 ] && [ -f "$d/posted/comments.json" ]; then
      IFS=$'\t' read -r findings checks < <(jq -r '
        (if type == "array" then . else (.comments // []) end) as $c
        | [ ([ $c[] | select(((.body // "") | test("^[[:space:]]*\\*\\*worth a look\\*\\*"; "i")) | not) ] | length),
            ([ $c[] | select( (.body // "") | test("^[[:space:]]*\\*\\*worth a look\\*\\*"; "i")) ] | length)
          ] | @tsv' "$d/posted/comments.json" 2>/dev/null) || { findings=-1; checks=-1; }
      approx="+approx"
    fi
  elif [ -f "$d/review.json" ]; then
    source=review.json
    json="$d/review.json"
    IFS=$'\t' read -r verdict findings checks < <(jq -r '
      def n(x): if (x|type) == "array" then (x|length) else -1 end;
      [ (.verdict // ""), n(.meta.findings), n(.meta.human_review) ] | @tsv' "$json" 2>/dev/null) \
      || { verdict=""; findings=-1; checks=-1; }
    if [ "${findings:--1}" -lt 0 ]; then
      IFS=$'\t' read -r findings checks < <(jq -r '
        (.comments // []) as $c
        | [ ([ $c[] | select(((.body // "") | test("^[[:space:]]*\\*\\*worth a look\\*\\*"; "i")) | not) ] | length),
            ([ $c[] | select( (.body // "") | test("^[[:space:]]*\\*\\*worth a look\\*\\*"; "i")) ] | length)
          ] | @tsv' "$json" 2>/dev/null) || { findings=-1; checks=-1; }
      approx="+approx"
    fi
  else
    return 1
  fi
  # A results directory that exists but holds an unparseable outcome is a
  # DIFFERENT thing from one that holds none, and scoring it as "no findings"
  # would silently manufacture a pass. Refuse it instead.
  case "${verdict:-}" in
    APPROVE|COMMENT|REQUEST_CHANGES) ;;
    *) return 1 ;;
  esac
  [ "${findings:--1}" -ge 0 ] || findings=0
  [ "${checks:--1}"   -ge 0 ] || checks=0
  printf '%s\t%s\t%s\t%s\n' "$verdict" "$findings" "$checks" "$source$approx"
}

TOTAL=0; SCORED=0; NO_RESULT=0; PASS=0; FAIL=0
APPROVED=0; FALSE_ALARM=0; MISS=0
ROWS=""
JSON_ROWS=""

while IFS=$'\t' read -r repo num label borderline _h _b; do
  [ -n "$repo" ] || continue
  TOTAL=$((TOTAL + 1))
  dir=$(outcome_dir "$repo" "$num") || dir=""
  outcome=""
  [ -n "$dir" ] && outcome=$(read_outcome "$dir")
  if [ -z "$outcome" ]; then
    NO_RESULT=$((NO_RESULT + 1))
    ROWS="$ROWS$repo#$num\t$label\t-\t-\t-\tno-result\n"
    JSON_ROWS="$JSON_ROWS$(jq -cn --arg r "$repo" --argjson n "$num" --arg l "$label" \
      '{repo:$r, number:$n, label:$l, status:"no-result"}')
"
    continue
  fi
  IFS=$'\t' read -r verdict findings checks source <<<"$outcome"
  SCORED=$((SCORED + 1))
  [ "$verdict" = "APPROVE" ] && APPROVED=$((APPROVED + 1))

  expects_approval "$label"; want=$?
  result=fail
  if [ "$want" -eq 0 ]; then
    # approvable: APPROVE, and clean — zero findings AND zero checks
    if [ "$verdict" = "APPROVE" ] && [ "$findings" -eq 0 ] && [ "$checks" -eq 0 ]; then
      result=pass
    else
      FALSE_ALARM=$((FALSE_ALARM + 1))
    fi
  else
    # needs a human: anything that is not a silent clean approval
    if [ "$verdict" != "APPROVE" ] || [ "$((findings + checks))" -gt 0 ]; then
      result=pass
    else
      MISS=$((MISS + 1))
    fi
  fi
  if [ "$result" = pass ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

  mark="$label"
  [ "$borderline" = "true" ] && mark="$label*"
  ROWS="$ROWS$repo#$num\t$mark\t$verdict\t$findings\t$checks\t$result ($source)\n"
  JSON_ROWS="$JSON_ROWS$(jq -cn --arg r "$repo" --argjson n "$num" --arg l "$label" \
    --argjson bl "$borderline" --arg v "$verdict" --argjson f "$findings" \
    --argjson c "$checks" --arg s "$source" --arg res "$result" \
    '{repo:$r, number:$n, label:$l, borderline:$bl, verdict:$v,
      findings:$f, checks:$c, source:$s, result:$res, status:"scored"}')
"
  # per-label tallies, held in shell vars named after the label
  key=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '_')
  eval "L_${key}_n=\$(( \${L_${key}_n:-0} + 1 ))"
  [ "$result" = pass ] && eval "L_${key}_p=\$(( \${L_${key}_p:-0} + 1 ))"
done < <(corpus_rows)

pct() { # pct <num> <den> -> integer percent, or "-" when den is 0
  if [ "${2:-0}" -eq 0 ]; then printf '%s' "-"; else printf '%d' $(( $1 * 100 / $2 )); fi
}

if [ "$AS_JSON" = true ]; then
  printf '%s' "$JSON_ROWS" | jq -s --argjson t "$TOTAL" --argjson s "$SCORED" \
    --argjson nr "$NO_RESULT" --argjson p "$PASS" --argjson f "$FAIL" \
    --argjson ap "$APPROVED" --argjson fa "$FALSE_ALARM" --argjson ms "$MISS" '
    {
      entries: .,
      totals: {corpus: $t, scored: $s, no_result: $nr, pass: $p, fail: $f,
               approved: $ap, false_alarm: $fa, miss: $ms},
      rates: {
        accuracy_pct:     (if $s > 0 then ($p * 100 / $s | floor) else null end),
        approve_rate_pct: (if $s > 0 then ($ap * 100 / $s | floor) else null end)
      },
      by_label: (. | group_by(.label) | map({
        label: .[0].label,
        n: length,
        scored: ([.[] | select(.status == "scored")] | length),
        pass:   ([.[] | select(.result == "pass")] | length)
      }))
    }'
  exit 0
fi

echo "corpus:  $CORPUS"
echo "results: $RESULTS"
echo
printf '%-22s %-16s %-16s %5s %6s %s\n' PR LABEL VERDICT FIND CHECKS RESULT
printf '%b' "$ROWS" | while IFS=$'\t' read -r a b c d e f; do
  printf '%-22s %-16s %-16s %5s %6s %s\n' "$a" "$b" "$c" "$d" "$e" "$f"
done
echo
echo "── per-label accuracy ───────────────────────────────"
for label in simple needs-eyes docs-slice docs-baseline; do
  key=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '_')
  eval "n=\${L_${key}_n:-0}; p=\${L_${key}_p:-0}"
  [ "$n" -eq 0 ] && continue
  printf '  %-16s %2d/%-2d  %s%%\n' "$label" "$p" "$n" "$(pct "$p" "$n")"
done
echo
echo "── headline ─────────────────────────────────────────"
printf '  corpus entries      %d\n' "$TOTAL"
printf '  scored              %d   (no result yet: %d)\n' "$SCORED" "$NO_RESULT"
printf '  overall accuracy    %s%%  (%d/%d)\n' "$(pct "$PASS" "$SCORED")" "$PASS" "$SCORED"
printf '  APPROVE rate        %s%%  (%d/%d)\n' "$(pct "$APPROVED" "$SCORED")" "$APPROVED" "$SCORED"
printf '  false alarms        %d   (approvable, not cleanly approved)\n' "$FALSE_ALARM"
printf '  misses              %d   (needs a human, silently approved)\n' "$MISS"
echo
echo "  * next to a label = the corpus marked that entry borderline"

# Exit non-zero when anything failed, so a sweep is usable in CI as a gate.
[ "$FAIL" -eq 0 ] && [ "$NO_RESULT" -eq 0 ] && exit 0
exit 1
