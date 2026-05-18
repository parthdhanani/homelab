---
name: brief
description: Build context before a complex task using Gemini's 1M context window. Use before starting work on unfamiliar code or large codebases — Gemini reads all relevant files in one pass, Claude uses the summary instead of re-reading files repeatedly.
disable-model-invocation: true
---

# Brief

1. Ask: what's the task? Which files/directories are relevant?
2. Run:
   ```bash
   # Directory:
   gemini -p "@[dir] What patterns, constraints, and decisions exist here relevant to [task]? What to avoid? 5 bullets max."
   # Files:
   cat [file1] [file2] | gemini -p "Same question for [task]. 5 bullets max."
   ```
3. Report findings. Do not re-read the files.
4. Ask: anything to add?

Fallback if gemini unavailable: Read the key files directly.
