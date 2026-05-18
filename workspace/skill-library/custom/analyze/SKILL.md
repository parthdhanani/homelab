---
name: analyze
description: Gemini code review after making changes. Use after completing implementation to catch bugs, security issues, and edge cases before committing. Passes changed files to Gemini for a structured findings report.
disable-model-invocation: true
---

# Analyze — Gemini Code Review

Run a targeted review on what was just built or changed.

## Steps

1. Get changed files: `git diff --name-only HEAD` or ask user which files to review
2. Read their actual contents
3. Use **gemini-cli MCP tool** — pass full file contents, not just filenames
4. Prompt Gemini: "Review this code. Find: bugs, security issues, unhandled edge cases, anything that violates standard conventions. Format each finding as: FINDING / FILE:LINE / SEVERITY (high|medium|low) / WHY. Max 8 findings. Skip style nitpicks."
5. Show findings clearly
6. Ask: "Which should I fix now? Which can wait?"

**Fix nothing until user confirms priority.**

**If gemini-cli MCP is unavailable:** Do the review yourself — security first, then logic, then edge cases.
