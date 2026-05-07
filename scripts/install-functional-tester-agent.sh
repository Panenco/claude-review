#!/usr/bin/env bash
# install-functional-tester-agent.sh
#
# Writes `.claude/agents/review-functional-tester.md` into the runner's
# checkout cwd. Claude Code auto-discovers `.claude/agents/*.md` at session
# start, so this file MUST exist before claude-code-action launches.
#
# This is the load-bearing workaround for the "Playwright MCP stays in
# `status: pending`" silent failure: the subagent definition's inline
# `mcpServers` block forces the server to spawn when the subagent starts,
# rather than relying on the parent orchestrator's `--mcp-config` (which
# leaves the server unspawned because the orchestrator itself never calls
# Playwright tools, and the subagent's ToolSearch query can't discover
# tools that aren't yet registered).
#
# Schema notes (verified against
# https://code.claude.com/docs/en/sub-agents → "Scope MCP servers to a
# subagent"):
#
#   - `tools:` is a comma-separated single-line string. YAML lists also
#     parse but the comma form matches every existing subagent file in
#     the official plugin packs.
#   - `mcpServers:` is a YAML LIST. Each item is either a bare string
#     (referencing an already-configured server) or a single-key
#     mapping (`- name:` followed by the inline server config). The dict
#     form `mcpServers: {playwright: {...}}` parses to a different shape
#     and is silently ignored — first iteration of PR #31 shipped the
#     dict form and would have left MCP unwired despite passing review.
#   - The body (after the second `---`) becomes the subagent's system
#     prompt. We keep it minimal — a one-line redirect to the full
#     skill file — because the orchestrator's Task call also passes a
#     user prompt with the full instructions (functional-prompt.txt).
#
# Required env vars (set by the calling workflow step):
#   PR_NUMBER         — for the prompt body
#   MODEL_FUNCTIONAL  — model alias for the subagent
#   PIPELINE_DIR      — absolute path to the installed pipeline dir
#                       (where skills/review-functional-tester.md lives)
#
# Caller is expected to chdir to the runner's workspace BEFORE invoking
# (we write to ./.claude/agents/ relative to cwd, matching Claude Code's
# project-level subagent discovery convention).

set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER must be set}"
: "${MODEL_FUNCTIONAL:?MODEL_FUNCTIONAL must be set}"
: "${PIPELINE_DIR:?PIPELINE_DIR must be set}"

mkdir -p .claude/agents

cat > .claude/agents/review-functional-tester.md <<EOF
---
name: review-functional-tester
description: QA agent that validates PR functionality end-to-end with Playwright MCP. Spawned by the review orchestrator to test user flows, take targeted screenshots tied to findings, and write /tmp/functional-meta.json + /tmp/functional-findings.json.
model: ${MODEL_FUNCTIONAL}
tools: Bash, Read, Write, Glob, Grep, ToolSearch, mcp__playwright__browser_navigate, mcp__playwright__browser_take_screenshot, mcp__playwright__browser_snapshot, mcp__playwright__browser_console_messages, mcp__playwright__browser_click, mcp__playwright__browser_fill_form, mcp__playwright__browser_wait_for, mcp__playwright__browser_close, mcp__playwright__browser_select_option, mcp__playwright__browser_press_key, mcp__playwright__browser_type, mcp__playwright__browser_hover, mcp__playwright__browser_resize, mcp__playwright__browser_tabs, mcp__playwright__browser_navigate_back, mcp__playwright__browser_evaluate
mcpServers:
  - playwright:
      type: stdio
      command: npx
      args: ["--yes", "@playwright/mcp@latest", "--headless", "--output-dir", "/tmp/screenshots"]
---

Read ${PIPELINE_DIR}/skills/review-functional-tester.md and follow it exactly. The orchestrator spawned you for PR ${PR_NUMBER}. test-plan.md and context.md are at the repo root. Your first turn MUST be the MCP smoke check described in the skill — do not silently fall back to curl/psql when MCP is unavailable.
EOF

echo "Functional-tester subagent installed:"
ls -la .claude/agents/

# Schema validation. Two paths:
#   1. ruby+psych (always present on macOS + ubuntu-latest GitHub runners)
#   2. python+pyyaml fallback (some runners).
# A simple `grep -E` line-pattern check is the third fallback.
validate_with_ruby() {
  ruby -ryaml -e '
    text = File.read(".claude/agents/review-functional-tester.md")
    fm = text.split("---", 3)[1]
    abort "::error::no frontmatter" unless fm
    data = YAML.safe_load(fm)
    %w[name description tools mcpServers].each do |k|
      abort "::error::missing required field \"#{k}\"" unless data.key?(k)
    end
    abort "::error::mcpServers must be a YAML list per Claude Code subagent schema; got #{data["mcpServers"].class}" unless data["mcpServers"].is_a?(Array)
    abort "::error::mcpServers list is empty" if data["mcpServers"].empty?
    first = data["mcpServers"][0]
    abort "::error::mcpServers[0] must be a single-key mapping (server-name to inline config); got #{first.inspect}" unless first.is_a?(Hash) && first.size == 1
    server_name, config = first.first
    abort "::error::expected mcpServers[0] key \"playwright\"; got \"#{server_name}\"" unless server_name == "playwright"
    %w[type command args].each do |k|
      abort "::error::playwright config missing \"#{k}\"" unless config.key?(k)
    end
    abort "::error::playwright.type must be \"stdio\"; got \"#{config["type"]}\"" unless config["type"] == "stdio"
    puts "OK: subagent frontmatter valid (ruby/psych); mcpServers list has #{data["mcpServers"].length} entry, playwright = #{config["command"]} #{config["args"].inspect}."
  '
}

validate_with_python() {
  python3 - <<'PYEOF'
import sys, re, yaml
text = open('.claude/agents/review-functional-tester.md').read()
fm_match = re.match(r'^---\n(.*?)\n---\n', text, re.S)
if not fm_match:
    sys.exit("::error::no frontmatter")
fm = yaml.safe_load(fm_match.group(1))
for required in ('name', 'description', 'tools', 'mcpServers'):
    if required not in fm:
        sys.exit(f"::error::missing required field '{required}'")
if not isinstance(fm['mcpServers'], list):
    sys.exit(f"::error::mcpServers must be a YAML list; got {type(fm['mcpServers']).__name__}")
if len(fm['mcpServers']) == 0:
    sys.exit("::error::mcpServers list is empty")
first = fm['mcpServers'][0]
if not isinstance(first, dict) or len(first) != 1:
    sys.exit(f"::error::mcpServers[0] must be a single-key mapping; got {first!r}")
server_name, config = next(iter(first.items()))
if server_name != 'playwright':
    sys.exit(f"::error::expected mcpServers[0] key 'playwright'; got '{server_name}'")
for required in ('type', 'command', 'args'):
    if required not in config:
        sys.exit(f"::error::playwright config missing '{required}'")
if config['type'] != 'stdio':
    sys.exit(f"::error::playwright.type must be 'stdio'; got '{config['type']}'")
print(f"OK: subagent frontmatter valid (python/yaml); mcpServers list has {len(fm['mcpServers'])} entry, playwright = {config['command']} {config['args']}.")
PYEOF
}

validate_with_grep() {
  grep -qE '^mcpServers:[[:space:]]*$' .claude/agents/review-functional-tester.md \
    || { echo "::error::mcpServers field not on its own line — schema may be malformed"; return 1; }
  grep -qE '^[[:space:]]+- playwright:[[:space:]]*$' .claude/agents/review-functional-tester.md \
    || { echo "::error::mcpServers must contain '  - playwright:' (YAML list with single-key mapping); dict form is silently ignored"; return 1; }
  echo "OK: subagent frontmatter passes line-pattern validation (no YAML parser available for full schema check)."
}

if command -v ruby >/dev/null 2>&1; then
  validate_with_ruby
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  validate_with_python
else
  validate_with_grep
fi
