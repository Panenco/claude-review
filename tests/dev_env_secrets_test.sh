#!/usr/bin/env bash
set -uo pipefail

# dev_env_secrets_test.sh — covers export_kv_secrets in scripts/kv-secrets.sh,
# the ONE parser behind both DEV_ENV_SECRETS (setup-dev-env.sh → dev-start.sh)
# and TRACKER_SECRETS (build-spec.sh → fetch-issue.sh). Consumers rely on
# identical semantics across the two, which is why there is only one of it.

cd "$(dirname "$0")/.."

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — want '$want', got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# The parser is a side-effect-free library, so it is sourced directly —
# no more awk-extracting a function out of a script whose top level runs
# curl, file IO and GITHUB_OUTPUT writes.
# shellcheck source=scripts/kv-secrets.sh
. scripts/kv-secrets.sh

run_parser() {
  # Subshell so each case starts with a clean env. stdout = `name=value`
  # lines for every var we care about, sorted; stderr = swallowed.
  local input="$1" probe="$2"
  (
    unset DEV_ENV_SECRETS
    DEV_ENV_SECRETS="$input"
    export_kv_secrets DEV_ENV_SECRETS
    eval "$probe"
  )
}

# Both call sites must resolve to this one parser. A second copy of the loop
# anywhere is the drift this file exists to prevent.
for caller in scripts/setup-dev-env.sh scripts/build-spec.sh; do
  if grep -q 'export_kv_secrets' "$caller"; then
    echo "OK:   $caller uses the shared parser"
  else
    echo "FAIL: $caller does not call export_kv_secrets"
    fail=$((fail + 1))
  fi
done

# 1. Unset / empty input is a no-op (no error, no exports).
RESULT=$(run_parser "" 'echo "rc=$?"')
assert_eq "Empty input is a no-op" "rc=0" "$RESULT"

# 2. Single KEY=VALUE pair exports correctly.
RESULT=$(run_parser "FOO=bar" 'echo "FOO=$FOO"')
assert_eq "Single KEY=VALUE export" "FOO=bar" "$RESULT"

# 3. Multiple lines, including blank lines and comments, all parsed.
INPUT=$'FOO=bar\n\n# comment line\nBAZ=qux\n'
RESULT=$(run_parser "$INPUT" 'echo "FOO=$FOO"; echo "BAZ=$BAZ"')
assert_eq "Multi-line parse (FOO)" "FOO=bar" "$(echo "$RESULT" | grep '^FOO=')"
assert_eq "Multi-line parse (BAZ)" "BAZ=qux" "$(echo "$RESULT" | grep '^BAZ=')"

# 4. Values containing `=` are preserved verbatim (only the FIRST `=` is
#    the separator). Tokens like JWTs and base64 padding need this.
RESULT=$(run_parser "TOKEN=abc=def==" 'echo "TOKEN=$TOKEN"')
assert_eq "Value with embedded =" "TOKEN=abc=def==" "$RESULT"

# 5. Lines without `=` are skipped silently (mirrors TRACKER_SECRETS).
INPUT=$'JUST_A_KEY\nGOOD=ok'
RESULT=$(run_parser "$INPUT" 'echo "GOOD=$GOOD"; echo "MISSING=${JUST_A_KEY:-unset}"')
assert_eq "Line without = is skipped (good var still set)" "GOOD=ok" "$(echo "$RESULT" | grep '^GOOD=')"
assert_eq "Line without = is skipped (no spurious export)" "MISSING=unset" "$(echo "$RESULT" | grep '^MISSING=')"

# 6. Comment lines are skipped; a `=` inside a comment never leaks.
INPUT=$'# SECRET=should-not-export\nREAL=visible'
RESULT=$(run_parser "$INPUT" 'echo "REAL=$REAL"; echo "SECRET=${SECRET:-unset}"')
assert_eq "Comment with = does not leak" "SECRET=unset" "$(echo "$RESULT" | grep '^SECRET=')"
assert_eq "Real var after comment exports" "REAL=visible" "$(echo "$RESULT" | grep '^REAL=')"

# 7. Empty value is allowed (KEY=).
RESULT=$(run_parser "EMPTY=" 'echo "EMPTY=[$EMPTY]"')
assert_eq "Empty value" "EMPTY=[]" "$RESULT"

if [ "$fail" -gt 0 ]; then
  echo ""
  echo "FAILED: $fail assertion(s)"
  exit 1
fi
echo ""
echo "PASSED: all assertions"
