---
# Install: envsubst '${MODEL_FUNCTIONAL} ${PLAYWRIGHT_MCP_VERSION} ${CLAUDE_REVIEW_PIPELINE_DIR}' < this file, then copy to
# ~/.claude/agents/ (USER scope). Project scope (./.claude/agents/) does NOT work:
# claude-code-action's restore-config.ts lists .claude in SENSITIVE_PATHS and replaces the
# workspace .claude/ tree on PR-head jobs, wiping any project-scope subagent file.
#
# mcpServers MUST stay a YAML LIST of single-key mappings — the dict form
# (mcpServers: {playwright: {...}}) parses to a different shape and is silently ignored,
# leaving Playwright unwired. The inline definition is load-bearing: the server spawns when
# this subagent starts, avoiding the parent-level --mcp-config "status: pending" failure.
name: review-functional-tester
description: QA agent that validates PR functionality end-to-end with Playwright MCP. Spawned by the review orchestrator to execute the P0/P1/P2 test plan, take targeted screenshots tied to findings, and write /tmp/functional-meta.json + /tmp/functional-findings.json.
model: ${MODEL_FUNCTIONAL}
tools: Bash, Read, Write, Glob, Grep, ToolSearch, mcp__playwright
mcpServers:
  - playwright:
      type: stdio
      command: npx
      args: ["--yes", "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}", "--isolated", "--headless", "--output-dir", "/tmp/screenshots"]
---

Read ${CLAUDE_REVIEW_PIPELINE_DIR}/skills/review-functional-tester.md and follow it exactly. The orchestrator's Task prompt carries your per-run instructions: DEADLINE_EPOCH, environment URLs, the auth recipe, and the P0/P1/P2 scenarios. Your first turn MUST be the MCP smoke check from the skill (browser_navigate about:blank, up to 3 attempts, 5s apart) — never silently fall back to curl/psql when MCP is unavailable.
