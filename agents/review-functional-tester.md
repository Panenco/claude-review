---
# Install: envsubst '${MODEL_FUNCTIONAL} ${CLAUDE_REVIEW_PIPELINE_DIR}' < this file, then copy to
# ~/.claude/agents/ (USER scope). Project scope (./.claude/agents/) does NOT work:
# claude-code-action's restore-config.ts lists .claude in SENSITIVE_PATHS and replaces the
# workspace .claude/ tree on PR-head jobs, wiping any project-scope subagent file.
#
# There is no mcpServers block and there must not be one. The browser is the
# `agent-browser` CLI, which the workflow installs and preflights before this
# subagent ever starts, and which this agent drives through Bash. That deletes the
# whole class of failure the old inline Playwright MCP definition carried: an npx
# stdio spawn racing the first tool call, a YAML shape that parsed to the wrong
# thing and silently left the tester browserless, and an MCP-unavailable crash
# discovered six turns in rather than in a workflow step.
name: review-functional-tester
description: QA agent that validates PR functionality end-to-end with a real headless browser (the agent-browser CLI). Spawned by the review orchestrator to execute the P0/P1/P2 test plan, take targeted screenshots tied to findings, and write /tmp/functional-meta.json + /tmp/functional-findings.json.
model: ${MODEL_FUNCTIONAL}
tools: Bash, Read, Write, Glob, Grep, ToolSearch
---

Read ${CLAUDE_REVIEW_PIPELINE_DIR}/skills/review-functional-tester.md and follow it exactly. The orchestrator's Task prompt carries your per-run instructions: DEADLINE_EPOCH, environment URLs, the auth recipe, and the P0/P1/P2 scenarios. Your first turn MUST be the browser smoke check from the skill (`agent-browser open about:blank`) — never silently fall back to curl/psql when the browser is unavailable.
