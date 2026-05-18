---
name: pkm-triage
version: 0.1.0
description: >
  Process the PKM Inbox: move captured lines to their proper PARA destinations, regenerate
  the vault Index from filesystem, and log every move for provenance. Use this skill when
  the user says "triage inbox", "process notes", "clean up inbox", "sort captures",
  "weekly review", "file my notes", or asks to update/regenerate the vault index. This is
  a maintenance/curation skill — not for adding new content. Run weekly or on demand.
  Always asks before destructive moves; never deletes; uses move-not-copy semantics.
category: tools
tags: [pkm, vault, triage, maintenance, para, inbox, obsidian]
recommended_skills: [pkm-note]
platforms: [claude-code]
license: MIT
---

# pkm-triage — process PKM Inbox into PARA + regenerate Index

## Vault paths

- VPS: `/opt/cryptex/data/pkm/`
- Mac: `$HOME/PKM/`

Detect which by `[ -d /opt/cryptex/data/pkm ]` then `[ -d "$HOME/PKM" ]`.

## Pipeline

### 1. Read the Inbox

Read `00 Capture/Inbox.md` line by line. Each `- [TS] (source) text` line is one capture.

### 2. Auto-classify obvious cases (do without asking)

| Pattern in text | Destination |
|---|---|
| Bare URL (https?://...) | append to `50 Collections/ReadLater/urls.md` |
| "watch ", "movie:" | append to `50 Collections/Movies/📋 Watchlist.md` |
| "show:", "series:" | append to `50 Collections/TV Shows/📋 Watchlist.md` |
| "anime:" | append to `50 Collections/Anime/📋 Watchlist.md` |
| "read ", "book:" | append to `50 Collections/Books/📚 Reading List.md` |
| "TIL ", "today i learned" | create `50 Collections/TIL/YYYY-MM-DD-<slug>.md` |

### 3. Ask user about ambiguous lines

For everything else, present a short summary table to the user and ask: "Where should each go?" Offer choices: PARA folder, drop, defer (leave in Inbox).

Don't ask one-by-one. Batch into one message.

### 4. Move, don't delete

- Moved line is removed from `Inbox.md`
- Original full text + destination is appended to `_Meta/log.md` as one row:
  ```
  - [YYYY-MM-DD HH:MM] inbox L<n> "<first 60 chars>" → <destination path>
  ```
- This is the provenance log — every captured line is traceable to where it landed.

### 5. Regenerate Index from filesystem

After moves, rebuild `_Meta/Index.md`:

```bash
cd "$VAULT"
# Walk filesystem, group by folder, output Topic→Path table
# Pull frontmatter `title:` if present, else use filename
# DON'T preserve old narrative text — generate fresh from FS
```

Index is **derived state**. Treat it like a build artifact. Never trust manual edits to it.

### 6. Report

Output a tight summary:
```
Triage complete:
- 12 captures processed
- 8 auto-filed (3 URLs, 2 movies, 3 TIL)
- 4 routed by user
- Index regenerated: 452 → 460 entries
- Log: _Meta/log.md (4 new entries)
- Inbox: 0 lines remaining
```

## Hard rules

- **Never delete a captured line without logging it** — log first, then remove from Inbox.
- **Never overwrite an existing note** — if target exists, append; if title collision on a new note, suffix `-2`.
- **Index is regenerated, not edited** — overwrite full file from filesystem walk.
- **Don't touch `30 Archive/`, `_Meta/`, `50 Collections/_Private/`** — out of scope for triage.
- **Confirm before mass moves** — if Inbox has >20 unclassified lines, summarize and ask before processing.

## Edge cases

- Inbox is empty → say "Inbox already empty. Want me to regenerate Index anyway?"
- Inbox has duplicate captures → keep newest, log the dedup
- Capture spans multiple lines (rare) → treat first `- [TS]` to next `- [TS]` as one block
