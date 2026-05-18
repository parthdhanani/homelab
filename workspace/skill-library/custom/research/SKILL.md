---
name: research
description: Web research via Gemini's Google Search. Use when you need current information — library comparisons, latest versions, best practices, VPS configuration guides, or anything where "as of today" matters. Gemini has native Google Search grounding; use this over Claude's WebSearch for deep multi-source research.
disable-model-invocation: true
---

# Research

1. Ask: what needs researching? Be specific.
2. Run:
   ```bash
   gemini -p "[question] — 2026, cite sources, flag deprecated since 2024"
   ```
3. Return findings as bullets with sources. Flag relevance to current task.
4. Ask: save to memory or act on it now?
