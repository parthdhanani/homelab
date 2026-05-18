---
name: notebooklm
description: Query Google NotebookLM notebooks via CLI. Use when you need grounded, source-backed answers from curated notebooks — SCORM/Moodle docs, Docker/VPS references, research sources. Commands: list, source add, ask, generate, download. Requires prior login with `notebooklm login`.
date: 2026-04-04
---

# NotebookLM CLI

## Auth
```bash
notebooklm login          # once — opens browser OAuth
notebooklm list           # verify auth works (shows notebooks)
```

## Notebook IDs (Parth's notebooks)

| Name | Full ID |
|------|---------|
| scorm-docs | a98d244a |
| cryptex-docs | 17c052d5 |
| research-inbox | 1d65852b |

Note: use full notebook ID (not `-n` flag — v0.1.0 uses positional args).

## Core Commands (v0.1.0)

```bash
# List notebooks
notebooklm list

# Ask a question
notebooklm ask <notebookId> "question"
notebooklm chat ask <notebookId> "question"

# Source management
notebooklm source list <notebookId>
notebooklm source add <notebookId> "https://url"
notebooklm source add-file <notebookId> ./file.pdf
notebooklm source add-text <notebookId> "title"   # reads from stdin

# Generate content
notebooklm generate report <notebookId>
notebooklm generate audio <notebookId>
notebooklm generate quiz <notebookId>
notebooklm generate flashcards <notebookId>
notebooklm generate status <notebookId> <artifactId>

# Notebook management
notebooklm notebook info <notebookId>
notebooklm notebook create "Title"
notebooklm notebook rename <notebookId> "New Title"
notebooklm notebook delete <notebookId>
```

## Routing
- SCORM/Moodle/xAPI → `a98d244a`
- Docker/VPS/Cloudflare → `17c052d5`
- Everything else → `1d65852b`

## Error Handling
- `Not authenticated` → `notebooklm login`
- `notebooklm not found` → check `~/.local/bin` is in PATH; `export PATH="$HOME/.local/bin:$PATH"`
- Version: 0.1.0 at `~/.local/bin/notebooklm`
