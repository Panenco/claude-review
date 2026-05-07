#!/usr/bin/env bash
set -uo pipefail

# install_functional_tester_agent_test.sh — fixture test for the
# `$AGENT_FILE` writer.
#
# Background. The first iteration of PR #31 wrote the subagent file with
# `mcpServers:` as a YAML dict. Claude Code's subagent schema (per
# https://code.claude.com/docs/en/sub-agents → "Scope MCP servers to a
# subagent") requires `mcpServers:` to be a YAML LIST where each entry is
# either a string (referencing an already-configured server) or a
# single-key mapping (`- name:` with the inline config below). The dict
# form parses to a different shape and is silently ignored — the
# Playwright server would never spawn even though `claude mcp list`
# shows it as "configured".
#
# This test asserts that the helper produces:
#   - YAML frontmatter that's parseable by ruby/psych or python/pyyaml
#   - `mcpServers` is an Array of length >= 1
#   - mcpServers[0] is a single-key Hash whose key is "playwright"
#   - playwright config has type=stdio, command=npx, args includes
#     "--headless" + "--output-dir" + "/tmp/screenshots"
#   - tools is a comma-separated string with all 16 mcp__playwright__*
#     tools listed (smoke check that the orchestrator dispatch will
#     have access to the right tool space)
#
# Without this test, dict-vs-list regressions would only surface during a
# real consumer review (when the functional tester silently falls back to
# curl/psql and admits "MCP not available" in uncertain_observations).

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

# ── Run the helper in a sandbox HOME so we don't pollute the developer's
#    real ~/.claude/agents/. The helper writes to $HOME/.claude/agents/
#    (user scope, intentional — claude-code-action's restore-config.ts
#    wipes workspace .claude/ on PR-head jobs as an RCE prevention,
#    so project scope can't be used). ──
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HELPER="$(pwd)/scripts/install-functional-tester-agent.sh"
AGENT_FILE="$TMP/.claude/agents/review-functional-tester.md"

HOME="$TMP" \
PR_NUMBER=12345 \
MODEL_FUNCTIONAL=claude-sonnet-4-6 \
PIPELINE_DIR=/tmp/test-pipeline \
  bash "$HELPER" >/tmp/install-out.log 2>&1 \
  || { echo "FAIL: helper exited non-zero"; cat /tmp/install-out.log; exit 1; }

assert_eq "file written to \$HOME/.claude/agents/review-functional-tester.md" \
  "true" \
  "$([ -f "$AGENT_FILE" ] && echo true || echo false)"

# Belt-and-braces: the helper must NOT also write to project scope
# (./.claude/agents/) — that's the path claude-code-action wipes, and
# writing there would have been the bug that motivated this whole PR.
# Run the helper a SECOND time from a controlled cwd inside its own
# scratch dir, then assert the cwd has no `.claude/` directory after
# the run. This actually exercises the SUT (running the helper from
# that cwd), unlike a tautology that just checks "fresh empty dir is
# still empty".
SCOPE_TEST_DIR=$(mktemp -d)
SCOPE_TEST_HOME=$(mktemp -d)
(
  cd "$SCOPE_TEST_DIR" && \
  HOME="$SCOPE_TEST_HOME" \
  PR_NUMBER=99999 \
  MODEL_FUNCTIONAL=claude-sonnet-4-6 \
  PIPELINE_DIR=/tmp/test-pipeline \
    bash "$HELPER" >/dev/null 2>&1
)
PROJECT_SCOPE_LEAKED=false
[ -e "$SCOPE_TEST_DIR/.claude" ] && PROJECT_SCOPE_LEAKED=true
USER_SCOPE_WRITTEN=false
[ -f "$SCOPE_TEST_HOME/.claude/agents/review-functional-tester.md" ] && USER_SCOPE_WRITTEN=true
rm -rf "$SCOPE_TEST_DIR" "$SCOPE_TEST_HOME"
assert_eq "helper writes ONLY to user scope (not ./.claude/ in cwd)" "false" "$PROJECT_SCOPE_LEAKED"
assert_eq "helper writes to user scope (\$HOME/.claude/agents/...)"  "true"  "$USER_SCOPE_WRITTEN"

# ── YAML structure assertions via ruby+psych (always present on the
#    Shell tests + lint runner). ──
RUBY_OUT=$(AGENT_FILE="$AGENT_FILE" ruby -ryaml -e '
  text = File.read(ENV.fetch("AGENT_FILE"))
  fm_str = text.split("---", 3)[1]
  data = YAML.safe_load(fm_str)
  puts "name=#{data["name"]}"
  puts "model=#{data["model"]}"
  puts "tools_class=#{data["tools"].class}"
  puts "mcpServers_class=#{data["mcpServers"].class}"
  puts "mcpServers_length=#{data["mcpServers"].length}"
  first = data["mcpServers"][0]
  puts "first_class=#{first.class}"
  puts "first_keys=#{first.keys.inspect}"
  puts "playwright_type=#{first["playwright"]["type"]}"
  puts "playwright_command=#{first["playwright"]["command"]}"
  puts "playwright_args=#{first["playwright"]["args"].inspect}"
  puts "body_first_line=#{text.split("---", 3)[2].lines.find { |l| l.strip.length > 0 }.strip}"
' 2>&1)

get() { echo "$RUBY_OUT" | grep -E "^$1=" | sed -E "s/^$1=//"; }

assert_eq "frontmatter.name"        "review-functional-tester"            "$(get name)"
assert_eq "frontmatter.model"       "claude-sonnet-4-6"                   "$(get model)"
assert_eq "frontmatter.tools type"  "String"                              "$(get tools_class)"
assert_eq "mcpServers IS a list"    "Array"                               "$(get mcpServers_class)"
assert_eq "mcpServers length"       "1"                                   "$(get mcpServers_length)"
assert_eq "mcpServers[0] is a Hash" "Hash"                                "$(get first_class)"
assert_eq "mcpServers[0] single key 'playwright'" '["playwright"]'        "$(get first_keys)"
assert_eq "playwright.type"         "stdio"                               "$(get playwright_type)"
assert_eq "playwright.command"      "npx"                                 "$(get playwright_command)"

# args list contains the --output-dir /tmp/screenshots pair (load-bearing
# — without --output-dir the MCP server writes screenshots to a session
# tmpdir that the upload step never finds).
ARGS=$(get playwright_args)
assert_eq "playwright.args includes --headless" "true" \
  "$(echo "$ARGS" | grep -qE '"--headless"' && echo true || echo false)"
assert_eq "playwright.args includes --output-dir /tmp/screenshots" "true" \
  "$(echo "$ARGS" | grep -qE '"--output-dir".*"/tmp/screenshots"' && echo true || echo false)"
assert_eq "playwright.args includes @playwright/mcp@latest" "true" \
  "$(echo "$ARGS" | grep -qE '"@playwright/mcp@latest"' && echo true || echo false)"

# ── tools field MUST list every Playwright MCP tool the skill uses, or
#    the subagent's tool list is incomplete and Claude Code will refuse
#    those calls even with MCP connected. ──
EXPECTED_PLAYWRIGHT_TOOLS=(
  mcp__playwright__browser_navigate
  mcp__playwright__browser_take_screenshot
  mcp__playwright__browser_snapshot
  mcp__playwright__browser_console_messages
  mcp__playwright__browser_click
  mcp__playwright__browser_fill_form
  mcp__playwright__browser_wait_for
  mcp__playwright__browser_close
  mcp__playwright__browser_select_option
  mcp__playwright__browser_press_key
  mcp__playwright__browser_type
  mcp__playwright__browser_hover
  mcp__playwright__browser_resize
  mcp__playwright__browser_tabs
  mcp__playwright__browser_navigate_back
  mcp__playwright__browser_evaluate
)
# Pull the comma-separated value off the `tools:` line, split, and trim
# each token so the membership test is exact. A regex with anchors is
# fragile around the `: ` separator and the trailing newline; iterating
# tokens is the boring-correct version.
TOOLS_VALUE=$(grep -E '^tools:' "$AGENT_FILE" | sed -E 's/^tools:[[:space:]]*//')
declare -A TOOLS_SET
while IFS= read -r tok; do
  tok="$(echo "$tok" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -n "$tok" ] && TOOLS_SET["$tok"]=1
done < <(echo "$TOOLS_VALUE" | tr ',' '\n')

for t in "${EXPECTED_PLAYWRIGHT_TOOLS[@]}"; do
  assert_eq "tools list contains $t" "true" \
    "$([ "${TOOLS_SET[$t]:-}" = "1" ] && echo true || echo false)"
done

# Bash + Read + Write must also be there or the subagent can't run
# scenarios at all.
for t in Bash Read Write Glob Grep ToolSearch; do
  assert_eq "tools list contains base tool $t" "true" \
    "$([ "${TOOLS_SET[$t]:-}" = "1" ] && echo true || echo false)"
done

# ── Body smoke: must include the smoke-check directive so the subagent
#    knows to fail loud rather than fall back to curl. ──
BODY_HAS_SMOKE_CHECK=$(grep -qE 'first turn MUST be the MCP smoke check' $AGENT_FILE && echo true || echo false)
assert_eq "body contains MCP smoke-check directive" "true" "$BODY_HAS_SMOKE_CHECK"

BODY_REFERENCES_SKILL=$(grep -qE '/skills/review-functional-tester\.md' $AGENT_FILE && echo true || echo false)
assert_eq "body references the full skill file" "true" "$BODY_REFERENCES_SKILL"

# Substituted env vars actually substituted (not literal $PR_NUMBER).
NO_LITERAL_VARS=$(grep -qE '\$(PR_NUMBER|PIPELINE_DIR|MODEL_FUNCTIONAL)' $AGENT_FILE && echo true || echo false)
assert_eq "no literal '\$VAR' tokens (heredoc substituted env vars)" "false" "$NO_LITERAL_VARS"

if [ "$fail" -eq 0 ]; then
  echo
  echo "All install-functional-tester-agent tests passed."
  exit 0
else
  echo
  echo "$fail install-functional-tester-agent test assertion(s) failed."
  exit 1
fi
