---
description: Full automated pipeline — skill load, project context, targeted Gemini/NotebookLM routing, execute, review. Use for complex tasks, large codebases, or when external intelligence is needed.
context: fork
---

# /flow — $ARGUMENTS

Silent until Step 5. Stop only if critical info is missing.

## Step 1 — Classify

| Signal in $ARGUMENTS | Flag |
|---|---|
| Unfamiliar codebase, "map this", "migrate", repo you don't know | `GEMINI_MAP` |
| "latest", "current", "2026", "best practice", post-2024 API | `GEMINI_SEARCH` |
| Doc/PDF/spec mentioned, "according to", dropped files | `NLM_RAG` |
| Podcast, audio, video, slides, quiz, flashcards, infographic, mind map, report | `NLM_GEN` |
| None | `DEFAULT` |

## Step 2 — Load skill

```bash
python3 ~/.claude/skill-library/.router/search.py "$ARGUMENTS"
echo "$ARGUMENTS" > /tmp/.sk-last-query
```

## Step 3 — Project context

```bash
[ -f ".claude/CLAUDE.md" ] && cat ".claude/CLAUDE.md"
[ -f ".gemini-plan.md" ] && cat ".gemini-plan.md"
[ -f ".gemini-docs.md" ] && cat ".gemini-docs.md"
```

Contract files >48h old: flag before using.

## Step 4 — External intelligence (skip if DEFAULT)

**GEMINI_MAP**
```bash
gemini -p "@. Map codebase for: $ARGUMENTS
Output: exact files to change, current patterns, constraints, numbered steps. No code." \
| tee .gemini-plan.md
sed -i "1i <!-- $(date '+%Y-%m-%d %H:%M') | $ARGUMENTS -->" .gemini-plan.md
```

**GEMINI_SEARCH**
```bash
gemini -p "$ARGUMENTS — 2026, cite sources, flag deprecated since 2024." \
| tee .gemini-docs.md
sed -i "1i <!-- $(date '+%Y-%m-%d %H:%M') | $ARGUMENTS -->" .gemini-docs.md
```

**NLM_RAG** — pick notebook: SCORM/Moodle→`a98d244a` | Docker/VPS→`17c052d5` | other→`1d65852b`
```bash
notebooklm ask --json "[targeted question]" -n [id-prefix]
```

**NLM_GEN** — defer to Step 8.

## Step 5 — Plan

Output: what+why (2 sentences) · approach · numbered steps · risks table.

| Risk | Severity | Detect | Rollback |
|------|----------|--------|----------|

Ask only if genuinely ambiguous. Otherwise proceed.

## Step 6 — Execute

Follow skill guidelines. VPS: iptables `-I INPUT 6`, never DROP port 22.

## Step 7 — Review

```bash
git diff --name-only 2>/dev/null | xargs -I{} cat {} 2>/dev/null | \
gemini -p "Review for bugs, security issues, edge cases. Format: FINDING / FILE:LINE / SEVERITY / WHY. Max 8."
```

Fix HIGH auto. Ask MEDIUM/LOW. Fallback if gemini unavailable: self-review security→logic→edges.

## Step 8 — Generate (NLM_GEN only)

| Requested | Command | Timeout | Output |
|-----------|---------|---------|--------|
| podcast/audio | `generate audio` | 1200s | .mp3 |
| video | `generate video` | 2700s | .mp4 |
| slides | `generate slide-deck` | 900s | .pdf/.pptx |
| infographic | `generate infographic` | 900s | .png |
| mind map | `generate mind-map` | 60s | .json |
| quiz | `generate quiz` | 900s | .json/.md |
| flashcards | `generate flashcards` | 900s | .json/.md |
| report | `generate report` | 900s | .md |
| data table | `generate data-table` | 900s | .csv |

Mind-map and report: run inline.

All others — spawn background Task subagent:
```
notebooklm generate [type] '[instructions]' -n [notebook-id] --json → get artifact_id
notebooklm artifact wait [artifact_id] -n [notebook-id] --timeout [N]
notebooklm download [type] ~/Downloads/[slug].[ext] -a [artifact_id] -n [notebook-id]
On timeout: report and check notebooklm artifact list
```

Tell user output path and ~duration. Continue immediately.

## Step 9 — Persist

Prompt: `/save [description]`

If complete: `rm -f .gemini-plan.md .gemini-docs.md`
