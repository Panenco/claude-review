#!/usr/bin/env bash
set -uo pipefail

# build_spec_test.sh — fixture test for scripts/build-spec.sh, the whole spec
# seam as a pure function: PR/issue JSON + a repo on disk in, /tmp/spec.md and
# /tmp/external-issue-candidates.json out. No model, no network, no GitHub.
#
# It exists because the two things this script restores were BOTH lost as
# "unused wiring": the external-tracker hook and in-repo spec documents. Prose
# assertions cannot tell you a regex stopped matching; these can.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/build-spec.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
has()    { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 — no '$2' in ${3##*/}"; fi; }
hasnt()  { if grep -qF -- "$2" "$3"; then bad "$1 — unexpected '$2' in ${3##*/}"; else ok "$1"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# run <pr-json> <issue-json-stream> — fresh workspace-independent invocation.
run() {
  rm -f /tmp/spec.md /tmp/external-issue.md /tmp/external-issue-candidates.json
  printf '%s' "$1" > /tmp/pr.json
  printf '%s' "$2" > /tmp/issue.json
  ( cd "$WS" && GITHUB_WORKSPACE="$WS" PR_NUMBER=7 GITHUB_REPOSITORY=o/r \
      TRACKER_SECRETS="${TRACKER_SECRETS:-}" "$SCRIPT" ) > /tmp/build-spec.out 2>&1
}

new_repo() {
  WS=$(mktemp -d "$WORK/ws.XXXXXX")
  git -C "$WS" init -q 2>/dev/null
  git -C "$WS" config user.email t@t; git -C "$WS" config user.name t
}
track() { # track <relpath> <content>
  mkdir -p "$WS/$(dirname "$1")"; printf '%s\n' "$2" > "$WS/$1"; git -C "$WS" add -f "$1" >/dev/null 2>&1
}

echo "── nothing resolves → an empty spec.md, and scan behaves as it does today ──"
new_repo
run '{"title":"chore: bump","body":"","headRefName":"chore/bump"}' ''
if [ -f /tmp/spec.md ] && [ ! -s /tmp/spec.md ]; then ok "spec.md exists and is empty"; else bad "spec.md must exist and be empty"; fi
has "…and the run log says so" "no spec source resolved" /tmp/build-spec.out

echo ""
echo "── source 1: the linked GitHub issue ──"
new_repo
run '{"title":"feat: x","body":"closes #4","headRefName":"feat/x"}' \
    '{"number":4,"title":"Add widget","body":"AC: the widget must persist"}'
has "issue section is headed by its origin" "## Spec source — linked GitHub issue" /tmp/spec.md
has "…and carries the issue body" "the widget must persist" /tmp/spec.md
has "…under a banner marking the whole file untrusted" "UNTRUSTED DATA" /tmp/spec.md

echo ""
echo "── source 2: the external tracker hook ──"
new_repo
mkdir -p "$WS/.github/claude-review"
cat > "$WS/.github/claude-review/fetch-issue.sh" <<'HOOK'
#!/usr/bin/env bash
echo "# LIN-9 from the tracker"
echo "key=${LINEAR_API_KEY:-MISSING} pr=${PR_NUMBER:-} repo=${REPO:-}"
jq -c . /tmp/external-issue-candidates.json
HOOK
chmod +x "$WS/.github/claude-review/fetch-issue.sh"
TRACKER_SECRETS=$'LINEAR_API_KEY=lin_secret\n# comment\nBAD_LINE' \
  run '{"title":"LIN-9: ship it","body":"see https://linear.app/team/issue/LIN-9/x and https://example.com/nope","headRefName":"lin-9-ship"}' ''
unset TRACKER_SECRETS
has "hook output is included" "LIN-9 from the tracker" /tmp/spec.md
has "…under a header naming the hook" "fetch-issue.sh" /tmp/spec.md
has "…flagged as untrusted tool output" "UNTRUSTED TOOL OUTPUT" /tmp/spec.md
has "TRACKER_SECRETS reaches the hook as a named env var" "key=lin_secret" /tmp/spec.md
has "…and so do PR_NUMBER/REPO" "pr=7 repo=o/r" /tmp/spec.md
has "JIRA-style id extracted from the title" '"LIN-9"' /tmp/external-issue-candidates.json
has "tracker-host URL extracted from the body" "linear.app/team/issue/LIN-9/x" /tmp/external-issue-candidates.json
hasnt "…and a non-tracker URL is not" "example.com" /tmp/external-issue-candidates.json

echo ""
echo "── a failing hook is non-fatal and never poisons the spec ──"
new_repo
mkdir -p "$WS/.github/claude-review"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$WS/.github/claude-review/fetch-issue.sh"
chmod +x "$WS/.github/claude-review/fetch-issue.sh"
run '{"title":"feat: x","body":"","headRefName":"f"}' '{"number":4,"title":"T","body":"AC: still here"}'
has "the review still gets the issue spec" "AC: still here" /tmp/spec.md
has "…and the failure is a warning, not an exit" "::warning::fetch-issue.sh failed (rc=3)" /tmp/build-spec.out
hasnt "…and stderr does not leak into the spec" "boom" /tmp/spec.md

echo ""
echo "── source 3: spec documents at ANY repo path, not one hardcoded directory ──"
new_repo
track "product/specs/checkout.md" "SPEC: checkout must charge once"
track "README.md" "readme text that is not a spec"
run '{"title":"feat: checkout","body":"Implements product/specs/checkout.md — see README.md too","headRefName":"f"}' ''
has "an explicit repo-relative path resolves" "must charge once" /tmp/spec.md
has "…under a header naming the file" 'in-repo spec document `product/specs/checkout.md`' /tmp/spec.md
hasnt "…and README.md is never treated as a spec" "readme text that is not a spec" /tmp/spec.md

echo ""
echo "── …including a doc referenced by URL, resolved on its basename ──"
new_repo
track "rfcs/0007-rate-limit.md" "SPEC: 100 requests per minute"
run '{"title":"feat: limits","body":"https://github.com/o/r/blob/main/rfcs/0007-rate-limit.md","headRefName":"f"}' ''
has "URL to a tracked doc resolves" "100 requests per minute" /tmp/spec.md

echo ""
echo "── …and a bare <name>-prd mention, searched repo-wide ──"
new_repo
track "planning/2026/billing-prd.md" "SPEC: invoices are immutable"
run '{"title":"feat: billing","body":"per the billing-prd","headRefName":"f"}' ''
has "a -prd mention resolves without a configured directory" "invoices are immutable" /tmp/spec.md

echo ""
echo "── source 4: the PR body, and ONLY when nothing else resolved ──"
new_repo
run '{"title":"feat: x","body":"## Acceptance criteria\n- must retry twice","headRefName":"f"}' ''
has "PR body is the last resort" "## Spec source — the PR body (fallback)" /tmp/spec.md
has "…and says a bot summary is not a spec" "not a spec" /tmp/spec.md
new_repo
run '{"title":"feat: x","body":"some body prose","headRefName":"f"}' '{"number":4,"title":"T","body":"AC: from the issue"}'
hasnt "…suppressed once a higher-priority source resolved" "the PR body (fallback)" /tmp/spec.md

echo ""
echo "── priority order is stable when several sources resolve ──"
new_repo
track "docs/thing-prd.md" "SPEC: prd content"
mkdir -p "$WS/.github/claude-review"
printf '#!/usr/bin/env bash\necho "tracker content"\n' > "$WS/.github/claude-review/fetch-issue.sh"
chmod +x "$WS/.github/claude-review/fetch-issue.sh"
run '{"title":"feat","body":"see docs/thing-prd.md","headRefName":"f"}' '{"number":4,"title":"T","body":"issue content"}'
ORDER=$(grep -n '^## Spec source' /tmp/spec.md | tr '\n' ' ')
case "$ORDER" in
  *"linked GitHub issue"*"external tracker"*"in-repo spec document"*) ok "issue → tracker → doc" ;;
  *) bad "priority order wrong: $ORDER" ;;
esac

echo ""
echo "── repo rules ──"
for f in "$SCRIPT" "$ROOT/scripts/kv-secrets.sh"; do
  if grep -qE '^set -e|^set -[a-z]*e[a-z]*o' "$f"; then
    bad "${f##*/} uses set -e (banned, bugbot.md)"
  else
    ok "${f##*/} does not use set -e"
  fi
done

echo ""
if [ "$fail" -eq 0 ]; then echo "All build-spec tests passed."; exit 0; fi
echo "$fail build-spec test(s) failed."; exit 1
