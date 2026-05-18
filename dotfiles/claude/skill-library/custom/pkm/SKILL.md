---
name: pkm
description: Capture and process PKM notes. Use when saving notes/TILs/references/movies to Obsidian vault, or processing inbox items. Modes — /pkm save <text>, /pkm til <insight>, /pkm save url <description>, /pkm add movie <title>, /pkm process inbox.
argument-hint: "[save|til|add|process] [text|url|movie <title>|inbox]"
---

# PKM — Personal Knowledge Management

Captures and manages notes in your Obsidian vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/`.

Vault root: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/`
Inbox folder: `00 Capture/`
Today's date: Use YYYY-MM-DD format for all dates.

---

## Mode 1: Save a Quick Note

**Usage:** `/pkm save <text>`

### Steps
1. Generate a timestamped filename: `YYYY-MM-DD_HHmm_note.md`
2. Create note in `00 Capture/` with this structure:

```markdown
---
date: YYYY-MM-DD
type: note
status: inbox
---

<text>
```

3. Report: "✓ Saved to `00 Capture/YYYY-MM-DD_HHmm_note.md`"

---

## Mode 2: Save a TIL (Today I Learned)

**Usage:** `/pkm til <insight>`

### Steps
1. Generate filename: `YYYY-MM-DD_til.md`
2. Create note in `00 Capture/`:

```markdown
---
date: YYYY-MM-DD
type: til
status: inbox
tags: [til, learning]
---

## Today I Learned

<insight>
```

3. Report: "✓ TIL saved to inbox"

---

## Mode 3: Save a URL Reference

**Usage:** `/pkm save url <description>`

The URL should be provided by the user in their message. Extract it.

### Steps
1. Generate filename: `YYYY-MM-DD_ref.md`
2. Create note in `00 Capture/`:

```markdown
---
date: YYYY-MM-DD
type: reference
status: inbox
tags: [reference, url]
source_url: <URL>
---

## <description>

[Visit source](<URL>)

<optional: brief description of content>
```

3. Report: "✓ Reference saved to inbox"

---

## Mode 4: Save & Enrich a Movie

**Usage:** `/pkm add movie "<Title>"` OR `/pkm save url "<title>" type:movie`

This saves a movie to vault AND automatically enriches it with TMDB + OMDb data.

### Steps
1. Extract movie title from user input
2. Create note in `00 Capture/` with basic info:
```markdown
---
date: YYYY-MM-DD
type: movie
status: inbox
title: <title>
tags: [movie, to-watch]
---

Movie to watch.
```

3. **Auto-trigger enrichment:**
   - Call `/pkm-enrich movie "<Title>"`
   - This will move note from Capture → 50 Collections/Movies/
   - And populate with TMDB/OMDb data (poster, ratings, cast, runtime, etc.)

4. Report: "✓ Saved and enriching '<Title>'... (check 50 Collections/Movies/ in a moment)"

**Alternative (manual):** User saves with `/pkm save url`, then later calls `/pkm-enrich movie` manually.

---

## Mode 5: Process Inbox (With Auto-Suggest)

**Usage:** `/pkm process inbox`

### Steps
1. List all files in `00 Capture/`:
   ```bash
   ls ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/PKM/00\ Capture/
   ```

2. For each file:
   - Read frontmatter (`date`, `type`, `tags`, content)
   - **Auto-suggest target folder** based on:
     - `type: til` → 40 Synthesis/
     - `type: movie` → (should be auto-enriched; skip if not)
     - `type: reference` → 50 Collections/
     - `type: note` + tags like `#project-X` → 10 Projects/
     - `type: note` + tags like `#moodle` or `#vps` → 20 Areas/
     - No clear match → Ask user

   - Display suggestion: "Suggested folder: 40 Synthesis/. Proceed? (yes/no/change)"
   - User response options:
     - **yes**: Move to suggested folder
     - **no**: Move to archive instead
     - **change**: Ask user which folder
     - **skip**: Leave in inbox for next time

   - Update `status: processed` and move file

3. Summary: Report X processed, Y archived, Z skipped

**Example Workflow:**
```
Processing inbox (3 items)...

1. 2026-03-17_til.md
   Content: "Today learned about SCORM suspend_data limits"
   Type: til
   → Suggested: 40 Synthesis/
   → User: "yes"
   → Moved ✓

2. 2026-03-17_ref.md
   Content: "iptables configuration reference"
   Type: reference
   → Suggested: 50 Collections/
   → User: "yes"
   → Moved ✓

3. 2026-03-17_note.md
   Content: "Notes from Moodle deployment"
   Type: note, tags: [#moodle, #deployment]
   → Suggested: 20 Areas/
   → User: "yes"
   → Moved ✓

Summary: 3 processed, 0 archived, 0 skipped ✓
```

---

## Rules

- **Vault path**: Always use `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/` (with escape chars if in shell)
- **Date format**: Always YYYY-MM-DD
- **Never delete**: Mark as archived, don't delete files
- **Filename safety**: Use alphanumeric, hyphens, underscores only; no spaces or special chars
- **Always create `00 Capture/` if it doesn't exist** (though it should already exist)

---

## Error Handling

**If file creation fails:**
- Report: "✗ Failed to save to vault. Reason: [vault inaccessible | permission denied | path invalid]"
- Suggest recovery: "Check if iCloud sync is active" or "Verify path exists"
- Do NOT silently fail

**If frontmatter is invalid:**
- Report: "✗ Note saved but frontmatter may be incomplete. Check manually."

**If path doesn't exist:**
- Report: "✗ Vault path not found. Expected: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/"
- Suggest: "Verify iCloud sync is enabled. Vault may be offline."
