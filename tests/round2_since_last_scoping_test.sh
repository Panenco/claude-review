#!/usr/bin/env bash
set -uo pipefail

# round2_since_last_scoping_test.sh — fixture test for the PR-file
# scoping in the round-2 since-last computation (review-context-builder).
#
# Scenario reproduces Panenco/qiv#350 round 3: the author merged `main`
# into the PR branch between prior review and the new push. The target
# merge brought in changes to files the PR doesn't touch (the Gemini
# bump). Before the fix, `git diff PRIOR..HEAD` swept those in and the
# judges reviewed them as if they were the PR's own work.
#
# This test simulates the same shape with a tiny synthetic repo:
#   - PR branch touches app.ts
#   - target branch independently touches unrelated.ts
#   - author merges target into PR
# and verifies the awk-based PR-file extraction + the resulting scoped
# since-last only describes the PR's own files.

cd "$(dirname "$0")/.."

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    printf 'FAIL: %s\n  want: %q\n  got:  %q\n' "$label" "$want" "$got"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Synthetic repo ──
(
  cd "$TMP"
  git init -q -b main
  git config user.email t@t.t
  git config user.name t

  echo "v1" > app.ts
  echo "v1" > unrelated.ts
  git add . && git commit -qm "initial"

  # PR branch: author commits one round-2 edit to app.ts
  git checkout -q -b pr
  echo "v2-pr" > app.ts
  git commit -qam "pr: round-1 work"

  # Prior review captured this commit
  PRIOR_HEAD=$(git rev-parse HEAD)
  echo "$PRIOR_HEAD" > "$TMP/prior-head"

  # Target branch moves on independently — touches unrelated.ts only
  git checkout -q main
  echo "v2-main" > unrelated.ts
  git commit -qam "main: gemini bump (target-only)"

  # Author merges target back into PR branch (the qiv#350 trigger)
  git checkout -q pr
  git merge -q --no-edit main

  # /tmp/pr.diff simulation: GitHub's PR diff is base..head, target-merge
  # noise already filtered. We compute it the same way `gh pr diff` does.
  PR_BASE=$(git merge-base main HEAD)
  git diff "$PR_BASE..HEAD" > "$TMP/pr.diff"
)

PRIOR_HEAD=$(cat "$TMP/prior-head")

# ── PR_FILES extraction (mirrors the skill exactly) ──
mapfile -t PR_FILES_ARR < <(awk '/^diff --git / { sub(/^a\//,"",$3); sub(/^b\//,"",$4); print $3; print $4 }' "$TMP/pr.diff" | sort -u)

assert_eq "PR_FILES extraction: only app.ts (target-merge noise excluded)" "app.ts" "${PR_FILES_ARR[*]}"

# ── since-last scoping ──
cd "$TMP"

UNSCOPED_NAMES=$(git diff --name-only "$PRIOR_HEAD..HEAD" | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "unscoped since-last DOES include target-merge file (regression baseline)" \
  "unrelated.ts" "$UNSCOPED_NAMES"

SCOPED_NAMES=$(git diff --name-only "$PRIOR_HEAD..HEAD" -- "${PR_FILES_ARR[@]}" | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "scoped since-last EXCLUDES target-merge file" "" "$SCOPED_NAMES"

git diff "$PRIOR_HEAD..HEAD" -- "${PR_FILES_ARR[@]}" > "$TMP/since-last.diff"
SCOPED_BYTES=$(wc -c < "$TMP/since-last.diff" | tr -d ' ')
assert_eq "scoped since-last.diff is empty when only target-merge happened" "0" "$SCOPED_BYTES"

# ── PR did real round-2 work — scoping keeps it ──
(
  cd "$TMP"
  echo "v3-pr" > app.ts
  git commit -qam "pr: round-2 work"
)

# pr.diff doesn't change (same file set), so PR_FILES_ARR stays the same.
NEW_SCOPED_NAMES=$(git -C "$TMP" diff --name-only "$PRIOR_HEAD..HEAD" -- "${PR_FILES_ARR[@]}" | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "scoped since-last keeps PR's own round-2 edit" "app.ts" "$NEW_SCOPED_NAMES"

git -C "$TMP" diff "$PRIOR_HEAD..HEAD" -- "${PR_FILES_ARR[@]}" > "$TMP/since-last.diff"
NEW_SCOPED_BYTES=$(wc -c < "$TMP/since-last.diff" | tr -d ' ')
[ "$NEW_SCOPED_BYTES" -gt 0 ] \
  && echo "OK:   scoped since-last.diff is non-empty when author edited a PR file" \
  || { echo "FAIL: scoped since-last.diff should be non-empty"; fail=$((fail + 1)); }

# ── Empty pr.diff (merge-only PR with no own files) ──
: > "$TMP/empty-pr.diff"
mapfile -t EMPTY_ARR < <(awk '/^diff --git / { sub(/^a\//,"",$3); sub(/^b\//,"",$4); print $3; print $4 }' "$TMP/empty-pr.diff" | sort -u)
assert_eq "empty /tmp/pr.diff yields empty PR_FILES_ARR (no fatal)" "0" "${#EMPTY_ARR[@]}"

# ── Rename: PR diff captures both `a/old` and `b/new` ──
RENAME_DIFF=$(cat <<'EOF'
diff --git a/old.ts b/new.ts
similarity index 90%
rename from old.ts
rename to new.ts
index 0000000..0000001
--- a/old.ts
+++ b/new.ts
@@ -1 +1 @@
-foo
+bar
EOF
)
echo "$RENAME_DIFF" > "$TMP/rename-pr.diff"
mapfile -t RENAME_ARR < <(awk '/^diff --git / { sub(/^a\//,"",$3); sub(/^b\//,"",$4); print $3; print $4 }' "$TMP/rename-pr.diff" | sort -u)
assert_eq "rename captures both old and new paths" "new.ts old.ts" "${RENAME_ARR[*]}"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All round-2 since-last scoping tests passed."
  exit 0
else
  echo "$fail round-2 since-last scoping test(s) failed."
  exit 1
fi
