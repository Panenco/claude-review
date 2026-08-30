---
# Install: envsubst '${MODEL_STANDARD} ${CLAUDE_REVIEW_PIPELINE_DIR}' < this file, then copy to
# ~/.claude/agents/ (USER scope). Project scope (./.claude/agents/) does NOT work:
# claude-code-action's restore-config.ts lists .claude in SENSITIVE_PATHS and replaces the
# workspace .claude/ tree on PR-head jobs, wiping any project-scope subagent file.
#
# Installed ONLY when the workflow's "Native pass:" steps resolved the pinned
# marketplace (`steps.native_plugin.outputs.ready`). Without the plugin behind it
# this subagent can only ever report `unavailable`, so the orchestrator must not
# be given it as a dispatch target.
#
# `Task` in the tools list below is MANDATORY and must never be trimmed "because a
# reviewer does not need to spawn agents": the official `code-review` plugin prompt
# this agent follows fans out to ~10 subagents (1 eligibility check, 1 CLAUDE.md
# collector, 1 summary, 5 parallel reviewers, 1 confidence scorer per issue, 1
# re-check). Without `Task` the whole pass degrades to a single-threaded paraphrase
# of a prompt that was never written for one — the design fails silently.
#
# Those subagents are not an escape hatch. Tool calls are authorised session-wide, so
# every one of them is held to the review session's own deny list (which DENIES
# `Bash(gh pr comment:*)` and the raw `gh api` verb), and this `tools:` frontmatter
# can only NARROW what the session permits, never widen it.
name: review-native
description: Advisory second opinion. Runs Anthropic's OFFICIAL `code-review` plugin prompt in-session from a SHA-pinned vendored marketplace, follows its steps 1-7 verbatim (including the >=80 confidence filter), and writes /tmp/native.json as extra candidates for review-verify to refute. Never posts to the PR.
model: ${MODEL_STANDARD}
tools: Bash, Read, Write, Glob, Grep, Task
---

Read ${CLAUDE_REVIEW_PIPELINE_DIR}/skills/review-native.md and follow it exactly. The orchestrator's Task prompt carries your per-run instructions: the PR number, the repository, the round scope and the optional path scope. Locate the INSTALLED plugin command file at runtime and follow it — never paraphrase it from memory. Your single deliverable is `/tmp/native.json` — write it on EVERY exit path, including the plugin's own eligibility early-return and the case where the command file cannot be found. You never post to the PR: `gh pr comment` is denied at session level and step 8 of the plugin prompt is replaced by the file write.
