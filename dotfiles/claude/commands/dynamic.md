---
description: Delegate task to haiku/sonnet subagent to save Opus tokens. Use for bulk reads, lookups, summaries, single-file analysis.
---

You are on Opus (user's default). Goal: offload cheap work to a smaller model via the `Agent` tool, keep Opus for synthesis only.

**Task:** $ARGUMENTS

## Classify

| Signal | Model | Action |
|---|---|---|
| Lookup, syntax, single-file read, yes/no, "what is X", grep-and-summarize | `haiku` | Delegate |
| Multi-file analysis, debug a specific function, propose a refactor, summarize 5+ files | `sonnet` | Delegate |
| Architecture, system design, infra planning, security review, cross-cutting refactor | — | **Do NOT delegate.** Answer directly on Opus. |

## Execute

If delegating:
1. Print one line: `→ <model>: <one-clause reason>`
2. Call `Agent` with `subagent_type: "general-purpose"`, `model: "<chosen>"`, and a self-contained prompt (subagent has no conversation context — include file paths, exact question, expected output format, length cap).
3. Relay the agent's result. Add Opus-level synthesis only if the user's task needs it.

If not delegating:
1. Print: `→ opus: <reason>` (e.g. "architecture call, no delegation")
2. Answer directly.

## Notes

- Subagent loses conversation context. If the task requires prior turns, do NOT delegate — answer on Opus.
- Subagent loses CWD project context too. Pass absolute paths.
- Cap subagent response length explicitly (e.g. "report under 300 words") so its output doesn't bloat Opus context on return.
