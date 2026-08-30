#!/usr/bin/env bash
set -uo pipefail
# No `set -e` (repo rule, bugbot.md): every step below carries an explicit guard.

# review-local.sh — run the real v4 review against a real PR, on this machine,
# and POST NOTHING.
#
# usage: scripts/review-local.sh <pr-number> [--spec-only]
#
# It composes the same steps pr-review.yml composes, in the same order, with the
# same skills, the same `--agents`, and the same `--allowedTools` /
# `--disallowedTools` sandbox: prior-review-state.sh, prior-findings.sh,
# guard.sh, build-spec.sh, one `claude -p` orchestrator session, then
# post-review.sh with REVIEW_OUT_DIR set — which turns every GitHub WRITE into an
# artifact instead of a call (see the seam's rationale in post-review.sh). The
# only GitHub calls this script makes are reads.
#
# `--spec-only` stops after build-spec.sh. No model runs, so a sweep of the whole
# corpus costs nothing and still answers "which document governed this PR?".
#
# ── the two things that are not just "the workflow, locally" ──
#
# ORIGIN/<BASE> IS PINNED TO THE FORK POINT. In CI, actions/checkout leaves
# origin/<base> at the base tip as it was when the PR was open, so
# `git merge-base origin/<base> HEAD` is the fork point. Locally origin/<base> is
# the tip TODAY, and for a merged PR that makes the merge-base HEAD itself — an
# empty diff. `gh api compare` gives the true fork point and the ref is pinned to
# it, which reproduces build-spec.sh route (a) exactly.
#
# EVERY RUN IS ISOLATED, IN BOTH DIRECTIONS IT CAN COLLIDE.
#
#   /tmp — the pipeline names `/tmp/...` in prose the models read, so the paths
#   cannot be parameterised without templating every skill (a slice of its own).
#   Instead each run works from a COPY of the pipeline with the literal `/tmp/`
#   rewritten to its own directory. Logic is untouched; only the directory moves.
#   Without this, two concurrent runs — or any other agent session on the same
#   machine — clobber each other's review.json mid-flight.
#
#   git — the checkout is a per-run `--shared` CLONE, not a worktree. Worktrees
#   share `refs/remotes/*` with their parent, so pinning `origin/<base>` (above)
#   is a GLOBAL write: two concurrent runs silently gave each other the wrong
#   base, and with it the wrong diff scope, the wrong changed-doc set and the
#   wrong answer from review-verify's absence-claim lookup.
#
# ── known deviations from CI, so results are read honestly ──
#   * no dev-env, so RUN_FUNCTIONAL=false and the functional tester never runs
#   * no vendored plugin marketplace, so RUN_NATIVE=false and the second
#     opinion never runs
#   * `--setting-sources project`, not `user`
#   * no Stop hook (require-review-json.sh), so a stalled session is not nudged
#   * ROUND is derived from the PR's real review list, which on an already-merged
#     PR may count rounds whose fixes are already in the head being reviewed
#
# Config, from the environment or a git-ignored `.eval.env` at the repo root
# (see .eval.env.example):
#   EVAL_REPO    owner/repo to review against          (required)
#   EVAL_ROOT    working root for clones and results   (default $TMPDIR/claude-review-eval)
#   EVAL_MODEL   the REVIEWING model, i.e. the subagents  (default claude-opus-5)
#   EVAL_ORCH_MODEL  the orchestrator session's own model (default claude-sonnet-5)

usage() { echo "usage: ${0##*/} <pr-number> [--spec-only]" >&2; }

PR="${1:-}"
MODE="${2:-full}"
case "$PR" in
  ''|*[!0-9]*) usage; exit 2 ;;
esac
case "$MODE" in
  full|--spec-only) ;;
  *) usage; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd) || { echo "cannot resolve repo root" >&2; exit 1; }

# `.eval.env` has TWO readers: `make` (-include) and this script. Make wants an
# unquoted, space-separated EVAL_PRS; the shell reads that as a command and its
# arguments (`EVAL_PRS=101 102 103` runs `102`). Quoting it fixes the shell and
# breaks `make eval` instead — one call with three arguments. So neither form
# satisfies a blanket `.`, and sourcing an operator-edited file executes whatever
# is in it anyway. Read only the four keys this script actually uses, as data.
unquote() { local s="$1"; s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; printf '%s' "$s"; }
read_eval_env() {
  local f="$ROOT/.eval.env" val
  [ -f "$f" ] || return 0
  # last assignment wins and the file beats the environment — both exactly as a
  # `.` of the file behaved, so only the executing stops, not the semantics.
  val=$(sed -n 's/^[[:space:]]*EVAL_REPO[[:space:]]*=[[:space:]]*//p'  "$f" | tail -1); [ -n "$val" ] && EVAL_REPO=$(unquote "$val")
  val=$(sed -n 's/^[[:space:]]*EVAL_ROOT[[:space:]]*=[[:space:]]*//p'  "$f" | tail -1); [ -n "$val" ] && EVAL_ROOT=$(unquote "$val")
  val=$(sed -n 's/^[[:space:]]*EVAL_MODEL[[:space:]]*=[[:space:]]*//p' "$f" | tail -1); [ -n "$val" ] && EVAL_MODEL=$(unquote "$val")
  val=$(sed -n 's/^[[:space:]]*EVAL_ORCH_MODEL[[:space:]]*=[[:space:]]*//p' "$f" | tail -1); [ -n "$val" ] && EVAL_ORCH_MODEL=$(unquote "$val")
  return 0
}
read_eval_env

REPO="${EVAL_REPO:-}"
if [ -z "$REPO" ]; then
  echo "EVAL_REPO is unset — set it in $ROOT/.eval.env (see .eval.env.example) or in the environment" >&2
  exit 2
fi
EVAL_ROOT="${EVAL_ROOT:-${TMPDIR:-/tmp}/claude-review-eval}"
MODEL="${EVAL_MODEL:-claude-opus-5}"
# The orchestrator reviews nothing — it dispatches and copies one file — so it
# runs the cheap model in CI (`model_orchestrator`). Mirrored here, else a local
# sweep measures a cost this pipeline no longer pays.
ORCH_MODEL="${EVAL_ORCH_MODEL:-claude-sonnet-5}"

for bin in gh jq git claude; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not on PATH" >&2; exit 1; }
done

RUNDIR="$EVAL_ROOT/run/$PR"
OUT="$EVAL_ROOT/results/$PR"
CLONE="$EVAL_ROOT/clone/${REPO##*/}"
# The checkout lives INSIDE the run directory and is a clone, not a worktree.
# Worktrees share `refs/remotes/*` with the parent (only HEAD and the index are
# per-worktree), so two concurrent runs both pointing `origin/<base>` at their
# own fork point clobbered each other — corrupting the review scope, the
# changed-doc detection and review-verify's base lookup, silently. `--shared`
# keeps the object store, so this costs no disk and no refetch.
WT="$RUNDIR/repo"
# The `/tmp/` rewrite below goes through sed, where `|` ends the expression and
# `&` means "the whole match". A path carrying either would corrupt the copy.
case "$RUNDIR" in
  *[\|\&\\]*) echo "EVAL_ROOT contains a character sed would misread: $EVAL_ROOT" >&2; exit 1 ;;
esac

rm -rf "$RUNDIR" "$OUT"
mkdir -p "$RUNDIR" "$OUT" "$EVAL_ROOT/clone" || { echo "could not create $EVAL_ROOT" >&2; exit 1; }

# ── the private pipeline copy ────────────────────────────────────────────────
PIPE="$RUNDIR/pipeline"
SCRIPTS="$PIPE/scripts"
mkdir -p "$PIPE"
cp -R "$ROOT/skills" "$ROOT/scripts" "$ROOT/agents" "$PIPE/" || { echo "could not copy the pipeline" >&2; exit 1; }
while IFS= read -r f; do
  [ -n "$f" ] || continue
  sed "s|/tmp/|$RUNDIR/|g" "$f" > "$f.rewritten" && mv "$f.rewritten" "$f" \
    || { echo "could not rewrite /tmp/ in $f" >&2; exit 1; }
done < <(grep -rl '/tmp/' "$PIPE" 2>/dev/null)
chmod +x "$SCRIPTS"/*.sh 2>/dev/null

# ── the PR, its base, and the true fork point ────────────────────────────────
PR_META=$(gh pr view "$PR" --repo "$REPO" --json headRefOid,baseRefName) \
  || { echo "gh pr view $PR failed" >&2; exit 1; }
SHA=$(jq -r '.headRefOid // empty' <<<"$PR_META")
BASE=$(jq -r '.baseRefName // empty' <<<"$PR_META")
[ -n "$SHA" ] && [ -n "$BASE" ] || { echo "could not resolve head sha / base ref for PR $PR" >&2; exit 1; }
FORK_POINT=$(gh api "repos/$REPO/compare/$BASE...$SHA" --jq '.merge_base_commit.sha' 2>/dev/null)
[ -n "$FORK_POINT" ] || { echo "could not resolve the fork point of $BASE...$SHA" >&2; exit 1; }

if [ ! -d "$CLONE/.git" ]; then
  echo "Cloning $REPO into $CLONE (once)"
  gh repo clone "$REPO" "$CLONE" -- --no-checkout >/dev/null 2>&1 \
    || { echo "clone of $REPO failed" >&2; exit 1; }
fi
# The head of a merged or deleted-branch PR only exists under pull/<n>/head.
git -C "$CLONE" fetch -q origin "$BASE" "+refs/pull/$PR/head:refs/eval/pr-$PR" \
  || { echo "could not fetch PR $PR head from $REPO" >&2; exit 1; }

# Left behind by the worktree-based layout this replaced; harmless once gone.
git -C "$CLONE" worktree prune >/dev/null 2>&1

git clone -q --shared --no-checkout "$CLONE" "$WT" >/dev/null 2>&1 \
  || { echo "could not create the per-run clone at $WT" >&2; exit 1; }
git -C "$WT" checkout -q --detach "$SHA" >/dev/null 2>&1 \
  || { echo "could not check out $SHA" >&2; exit 1; }
# Pinned in THIS clone only, so a concurrent run cannot move it.
git -C "$WT" update-ref "refs/remotes/origin/$BASE" "$FORK_POINT" \
  || { echo "could not pin origin/$BASE to $FORK_POINT" >&2; exit 1; }
echo "PR $PR — head $SHA, origin/$BASE pinned to fork point $FORK_POINT"

export GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
export GITHUB_REPOSITORY="$REPO" GH_REPO="$REPO" PR_NUMBER="$PR" GITHUB_WORKSPACE="$WT"
export CLAUDE_REVIEW_PIPELINE_DIR="$PIPE" CLAUDE_REVIEW_SCRIPTS="$SCRIPTS"
export OUT_DIR="$RUNDIR"
export REVIEW_BOT_USER="${REVIEW_BOT_USER:-github-actions[bot]}"

# ── turn-1 inputs the real orchestrator writes for itself ────────────────────
# Written here as well as by the model so build-spec.sh and the guard can run
# before the session starts, exactly as the workflow's own steps do.
gh pr view "$PR" --repo "$REPO" \
  --json title,body,headRefName,baseRefName,closingIssuesReferences,files > "$RUNDIR/pr.json" \
  || { echo "could not write pr.json" >&2; exit 1; }
for n in $(jq -r '.closingIssuesReferences[]?.number' "$RUNDIR/pr.json"); do
  gh issue view "$n" --repo "$REPO" --json number,title,body
done > "$RUNDIR/issue.json"

# ── round state ──────────────────────────────────────────────────────────────
STATE=$("$SCRIPTS"/prior-review-state.sh) || STATE=""
if ! grep -qE '^round=[0-9]+$' <<<"$STATE"; then
  echo "prior-review-state.sh produced no usable state — refusing to review as an unknown round" >&2
  exit 1
fi
ROUND=$(sed -n 's/^round=//p' <<<"$STATE")
PRIOR_HEAD_SHA=$(sed -n 's/^prior_head_sha=//p' <<<"$STATE")
PRIOR_VERDICT=$(sed -n 's/^prior_verdict=//p' <<<"$STATE")
ROUND="$ROUND" "$SCRIPTS"/prior-findings.sh > "$OUT/prior-findings.out" 2>&1
echo "Round $ROUND (prior head '${PRIOR_HEAD_SHA:-none}', prior verdict '${PRIOR_VERDICT:-none}')"

# ── guard ────────────────────────────────────────────────────────────────────
# GATE_HUMAN_REQUESTED=true: a local run is always somebody asking, and the
# `unchanged` gate must never answer an explicit request with silence.
GUARD_PR=$(gh pr view "$PR" --repo "$REPO" --json files,labels) || GUARD_PR='{"files":[],"labels":[]}'
GATE_FILES_TSV=$(jq -r '.files[] | "\(.path)\t\(.additions)\t\(.deletions)"' <<<"$GUARD_PR")
GATE_LABELS=$(jq -r '.labels[].name' <<<"$GUARD_PR")
GATE_DELTA_FILES=""
if [ -n "$PRIOR_HEAD_SHA" ]; then
  GATE_DELTA_FILES=$(git -C "$WT" diff --name-only "$PRIOR_HEAD_SHA..HEAD" 2>/dev/null) || PRIOR_HEAD_SHA=""
fi
export GATE_FILES_TSV GATE_LABELS GATE_DELTA_FILES
export GATE_PRIOR_HEAD_SHA="$PRIOR_HEAD_SHA" GATE_HUMAN_REQUESTED=true
DECISION=$("$SCRIPTS"/guard.sh) || DECISION=""
printf '%s\n' "$DECISION" > "$OUT/guard.out"
if ! grep -qE '^proceed=(true|false)$' <<<"$DECISION"; then
  echo "guard.sh produced no usable decision" >&2
  exit 1
fi
PROCEED=$(sed -n 's/^proceed=//p' <<<"$DECISION")
echo "Guard: proceed=$PROCEED"

# ── spec assembly ────────────────────────────────────────────────────────────
( cd "$WT" && "$SCRIPTS"/build-spec.sh ) > "$OUT/build-spec.out" 2>&1
cat "$OUT/build-spec.out"
cp "$RUNDIR/spec.md" "$OUT/spec.md" 2>/dev/null

if [ "$MODE" = "--spec-only" ]; then
  echo "spec-only — artifacts in $OUT"
  exit 0
fi
if [ "$PROCEED" != "true" ]; then
  echo "Guard short-circuited this PR — no model runs. See $OUT/guard.out"
  exit 0
fi

# ── the orchestrator session ─────────────────────────────────────────────────
export ROUND PRIOR_HEAD_SHA PRIOR_VERDICT
export MODEL_HIGH="$MODEL" MODEL_FUNCTIONAL=claude-sonnet-5
export RUN_FUNCTIONAL=false FUNCTIONAL_BUDGET_SECONDS=480 DEV_ENV_TIMEOUT_SECONDS=360
# The second opinion needs the plugin marketplace the WORKFLOW vendors at a
# pinned SHA (ADR 0005); a local sweep installs no plugin, so the pass cannot
# run here. Exported explicitly rather than left unset: the orchestrator
# `printenv`s it in turn 1, and an absent var reads as "not decided yet".
export RUN_NATIVE=false NATIVE_REVIEW_SCOPE=""
DOCS_ONLY=$(sed -n 's/^docs_only=//p' <<<"$DECISION")
# Both halves of the depth scale come off the SAME guard run the review used, so
# a local eval measures the caps production would have applied, not defaults.
REVIEW_DEPTH_SCALE=$(sed -n 's/^depth_scale=//p' <<<"$DECISION")
REVIEW_COMMENT_LIMIT=$(sed -n 's/^comment_limit=//p' <<<"$DECISION")
export DOCS_ONLY REVIEW_DEPTH_SCALE PR_AUTHOR_IS_BOT=false

# `effort` is NOT optional here. In CI the subagents are installed from
# agents/*.md, whose frontmatter carries `effort: medium` (scan) and
# `effort: low` (verify); an --agents JSON that omits the key runs them at the
# session's own --effort instead. review-scan is the finding-producing stage, so
# omitting it measured recall against a SHALLOWER scan than production runs —
# silently biasing the one number this harness exists to produce. Read from the
# frontmatter so the two can never drift.
agent_effort() { # agent_effort <agent name> → the effort in its frontmatter
  local e
  e=$(sed -n '/^---$/,/^---$/p' "$ROOT/agents/$1.md" 2>/dev/null \
      | sed -n 's/^effort:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)
  case "$e" in
    low|medium|high) printf '%s' "$e" ;;
    *) echo "could not read 'effort:' from agents/$1.md — refusing to run at an unknown depth" >&2; exit 1 ;;
  esac
}
SCAN_EFFORT=$(agent_effort review-scan) || exit 1
VERIFY_EFFORT=$(agent_effort review-verify) || exit 1

AGENTS=$(jq -n --arg pd "$PIPE" --arg m "$MODEL" \
  --arg se "$SCAN_EFFORT" --arg ve "$VERIFY_EFFORT" '{
  "review-scan": {
    description: "Stage 1 of the review. Reads the PR diff itself, self-scales its depth, and writes /tmp/scan.json with candidate findings, model-chosen human-review items, and an argued approve position. Never posts anything.",
    prompt: "Read \($pd)/skills/review-scan.md and follow it exactly. The orchestrator'"'"'s Task prompt carries the PR number and repository. Your single deliverable is `/tmp/scan.json` — write it on every exit path, including a diff you decide needs no findings at all (an empty `findings` array is the expected output for a clean PR).",
    model: $m, effort: $se, tools: ["Bash","Read","Write","Glob","Grep"]},
  "review-verify": {
    description: "Stage 2 and final stage. Refutes every candidate finding in /tmp/scan.json against the source at HEAD, then decides the verdict and renders the posted body and inline comments into /tmp/verify.json.",
    prompt: "Read \($pd)/skills/review-verify.md and follow it exactly. Input: `/tmp/scan.json`. Your single deliverable is `/tmp/verify.json`, and its `body` is the review that gets posted verbatim — nothing downstream rewrites it. Your mandate is to refute: default to refuted whenever you are uncertain.",
    model: $m, effort: $ve, tools: ["Bash","Read","Write","Glob","Grep"]}}' \
  | sed "s|/tmp/|$RUNDIR/|g")

PROMPT="Read $PIPE/skills/review-orchestrator.md and follow it exactly. PR number: $PR. You are the single top-level agent for this review and you do NOT review the diff yourself. Dispatch \`review-scan\` (Task tool, pre-installed subagent type) and then \`review-verify\`; both are pre-installed and carry their own model and effort. The functional tester is pre-installed as \`review-functional-tester\` and is ADVISORY ONLY — dispatch it in the same response as review-scan, and only when RUN_FUNCTIONAL=true, the dev-env is up, and a linked issue supplies real acceptance criteria. Copy review-verify's verdict, body and comments into $RUNDIR/review.json VERBATIM — its \`{{LINK:path:line}}\` placeholders and its wording are deliberate and post-review.sh finishes them; do not rewrite, re-summarise or add sections. Your final artifact is $RUNDIR/review.json — ALWAYS write it before exiting, even degraded. Never end a turn with prose only (no tool calls): that terminates the session and crashes the pipeline — every message must contain a tool call until review.json is written."

# Byte-for-byte the workflow's deny list. It is the only thing standing between
# this session and the PR, and a local run holds the operator's own gh token —
# so it is copied, never relaxed.
DENY='Edit,WebFetch,WebSearch,Bash(gh api:*),Bash(gh pr comment:*),Bash(gh pr review:*),Bash(gh pr edit:*),Bash(gh pr close:*),Bash(gh pr merge:*),Bash(gh pr ready:*),Bash(gh issue comment:*),Bash(gh issue edit:*),Bash(gh issue close:*),Bash(gh release:*),Bash(git push:*)'

date +%s > "$RUNDIR/job-start"
echo "Running the orchestrator ($ORCH_MODEL; subagents $MODEL) — this takes minutes and posts nothing"
( cd "$WT" && claude -p "$PROMPT" \
    --model "$ORCH_MODEL" \
    --effort low \
    --permission-mode dontAsk \
    --setting-sources project \
    --strict-mcp-config \
    --add-dir "$RUNDIR" \
    --allowedTools Bash Read Write Glob Grep Task ToolSearch \
    --disallowedTools "$DENY" \
    --agents "$AGENTS" \
    --max-turns 100 \
    --output-format json --no-session-persistence \
) > "$OUT/session.json" 2> "$OUT/session.err"
SESSION_RC=$?
echo "Orchestrator exited $SESSION_RC after $(( $(date +%s) - $(cat "$RUNDIR/job-start") ))s"

for f in scan.json verify.json review.json spec.md prior-findings.json; do
  [ -f "$RUNDIR/$f" ] && cp "$RUNDIR/$f" "$OUT/$f"
done

# ── the poster, with the seam set: artifacts, not GitHub writes ──────────────
REVIEW_OUT_DIR="$OUT/posted" \
REVIEW_JSON="$RUNDIR/review.json" \
ORCH_LOG="$OUT/session.json" \
JOB_START="$RUNDIR/job-start" \
SPEC_STATUS="$RUNDIR/spec-status" \
PRIOR_FINDINGS_JSON="$RUNDIR/prior-findings.json" \
HEAD_SHA="$SHA" ROUND="$ROUND" \
REVIEW_COMMENT_LIMIT="$REVIEW_COMMENT_LIMIT" \
  "$SCRIPTS"/post-review.sh > "$OUT/post-review.out" 2>&1
RC=$?
cat "$OUT/post-review.out"
echo "post-review.sh exited $RC — nothing was posted; artifacts in $OUT/posted"
exit "$RC"
