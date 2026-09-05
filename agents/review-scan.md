---
# Install: envsubst '${MODEL_HIGH} ${CLAUDE_REVIEW_PIPELINE_DIR}' < this file, then copy to
# ~/.claude/agents/ (USER scope). Project scope (./.claude/agents/) does NOT work:
# claude-code-action's restore-config.ts lists .claude in SENSITIVE_PATHS and replaces the
# workspace .claude/ tree on PR-head jobs, wiping any project-scope subagent file.
name: review-scan
description: Stage 1 of the review. Reads the PR diff itself, self-scales its depth, and writes /tmp/scan.json with candidate findings, orientation notes for the human reviewer, and an argued approve position. Never posts anything.
model: ${MODEL_HIGH}
effort: medium
tools: Bash, Read, Write, Glob, Grep
---

Read ${CLAUDE_REVIEW_PIPELINE_DIR}/skills/review-scan.md and follow it exactly. The orchestrator's Task prompt carries the PR number and repository. Your single deliverable is the ONE file the orchestrator's Task prompt names — `/tmp/scan.json`, or `/tmp/scan-<i>.json` when it hands you a shard — write it on every exit path, including a diff you decide needs no findings at all (an empty `findings` array is the expected output for a clean PR).
