---
name: pkm-note
version: 0.1.0
description: >
  Append a quick capture line to the PKM Inbox. Use this skill whenever the user wants to
  jot down a thought, save a URL, add an idea, capture a quote, note a movie/show/book,
  or generally "remember this for later" — even if they don't say "note" or "capture"
  explicitly. Triggers on phrases like "add to inbox", "note this", "remember", "jot
  down", "capture this", "save this idea", "add to my notes", "watchlist", or any
  free-floating fact the user wants to preserve in the PKM vault. Do NOT use for full
  note creation in PARA folders (that's pkm-triage's job at filing time) — this is for
  the dump-now-sort-later workflow.
category: tools
tags: [pkm, vault, capture, inbox, obsidian, notes]
recommended_skills: [pkm-triage]
platforms: [claude-code]
license: MIT
---

# pkm-note — capture to PKM Inbox

Single purpose: append one timestamped line to `00 Capture/Inbox.md` in the user's PKM vault. **Never** opens Obsidian. **Never** decides where the note "really belongs." That's the explicit point of capture: zero filing decisions at write time.

## Inputs

- **text** (required): the note body, free-form
- **source** (optional): short tag like `manual`, `claude`, `pwa`, `alfred`, `cli`. Default `claude`.

## How to invoke

Three execution paths, pick whichever is available.

### Path A — Direct file append (preferred when on VPS / vault is locally accessible)

```bash
VAULT="/opt/cryptex/data/pkm"   # VPS path
# Mac: VAULT="$HOME/PKM"
TS=$(date "+%Y-%m-%d %H:%M")
echo "- [$TS] (claude) <USER_TEXT>" >> "$VAULT/00 Capture/Inbox.md"
```

Escape `<USER_TEXT>` properly — no shell injection. Quote-safe.

### Path B — HTTP capture endpoint (when off-vault, e.g., remote machine)

```bash
TOKEN=$(bw get password "Notes Capture Token" 2>/dev/null || echo "$NOTES_CAPTURE_TOKEN")
curl -sS -X POST https://notes.psidex.com/c \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"<USER_TEXT>\",\"source\":\"claude\"}"
```

### Path C — User explicitly wants the PWA

Just print: `https://notes.psidex.com/c?t=$TOKEN` — they capture in the browser themselves.

## Auto-routing helpers

Before plain append, scan `<USER_TEXT>` for these patterns and route to the right collection instead of Inbox:

- Movie title hint (e.g., "watch X", "movie X") → append to `50 Collections/Movies/📋 Watchlist.md`
- Show title hint ("series", "show", "TV") → `50 Collections/TV Shows/📋 Watchlist.md`
- Anime hint → `50 Collections/Anime/📋 Watchlist.md`
- Book hint ("read X", "book X") → `50 Collections/Books/📚 Reading List.md`
- Bare URL → `50 Collections/ReadLater/urls.md`
- TIL pattern ("today I learned", "TIL", "learned that") → create `50 Collections/TIL/YYYY-MM-DD-<slug>.md` AND add line to `50 Collections/TIL/TIL.md`

If pattern is unclear, default to Inbox. **Bias toward Inbox** — pkm-triage will sort later. Capture should never block on classification.

## Output

Echo the appended line back to the user as confirmation. One line, no preamble. Example:
```
✓ Inbox: 2026-05-03 12:34 — note text here
```

## Failure modes

- Vault path doesn't exist → fall back to Path B
- Token missing → tell user to set `NOTES_CAPTURE_TOKEN` env or save it in Vaultwarden as "Notes Capture Token"
- Network error on Path B → fall back to writing to local `~/.cache/pkm-inbox-pending.md` and note it for later sync
