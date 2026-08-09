#!/bin/bash
# cartographer.sh — map the collections. One-shot by default, re-runnable.
#
# Why: 273 notes across Movies/TV/Anime/Books sit as orphan files with no connective
# tissue — no cross-links, no themes, and a Cinema MOC hand-written in March from a raw
# bulk list. This is the one job whose cost is tokens and whose cost to Parth is zero
# minutes, which is exactly what a large pending quota is for.
#
# Writes exactly two files: 40 Synthesis/taste-map.md (the argument — clusters, the
# watched-vs-queued gap, blind spots, recommendations) and _Meta/MOC/Cinema-and-Arts.md
# (the navigable index, previous version backed up alongside as a dotfile). Never edits
# the individual collection notes — a bad pass must be revertible by deleting two files.
JOB=cartographer
source "$(dirname "$0")/../lib/common.sh"

MOC="$PKM/_Meta/MOC"
SYN="$PKM/40 Synthesis"
mkdir -p "$MOC" "$SYN"
STAMP=$(date -u +%Y%m%d-%H%M)

# ---- build the corpus ---------------------------------------------------------------
# One line per note: status, year, genres, director/author, and the overview. Compact on
# purpose — the full bodies are mostly empty templates and would be pure token cost.
corpus() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || return 0
    echo "### $label"
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in 🏆*|📋*|📚*|to-watch-bulk*|to-read-bulk*) continue ;; esac
        python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8", errors="replace").read()
h = t[3:t.find("\n---", 3)] if t.startswith("---") else ""
def g(k):
    m = re.search(rf"^{k}:[^\S\n]*(.*)$", h, re.M)
    return (m.group(1).strip().strip('"') if m else "")
def lst(k):
    m = re.search(rf"^{k}:[^\S\n]*(.*)$", h, re.M)
    if not m: return ""
    v = m.group(1).strip()
    if v.startswith("["): return v.strip("[]").replace('"', "")
    out = []
    for line in h[m.end():].splitlines():
        if re.match(r"^\s+-\s+", line): out.append(re.sub(r"^\s+-\s+", "", line).strip().strip('"'))
        elif line.strip(): break
    return ", ".join(out)
import os
name = os.path.basename(p)[:-3]
title = g("title") or name
by = g("director") or g("author")
ov = g("overview")[:220]
print(f"- {title} ({g('year')}) [{g('status') or '?'}] {lst('genres')}"
      + (f" · {by}" if by else "") + (f" — {ov}" if ov else ""))
PY
    done
}

CORPUS=$(
    corpus "$PKM/50 Collections/Movies" "FILMS"
    corpus "$PKM/50 Collections/TV Shows" "TV"
    corpus "$PKM/50 Collections/Anime" "ANIME"
    corpus "$PKM/50 Collections/Books" "BOOKS"
)
LINES=$(printf '%s' "$CORPUS" | grep -c '^- ' || true)
log "corpus built: $LINES entries, ${#CORPUS} chars"
[ "$LINES" -lt 50 ] && { log "corpus too small — aborting"; exit 1; }

# Elo ranking, if the duel has produced any — the strongest available taste signal.
RANKED=""
[ -f /opt/cryptex/duel/state/ratings.json ] && RANKED=$(python3 -c "
import json
r=json.load(open('/opt/cryptex/duel/state/ratings.json'))
rows=sorted(((k,v) for k,v in r.items() if v.get('n',0)>0), key=lambda kv:-kv[1]['elo'])
print('\n'.join(f'{i}. {k} ({v[\"elo\"]:.0f}, {v[\"n\"]} votes)' for i,(k,v) in enumerate(rows,1)))
" 2>/dev/null)

# ---- 1. taste map -------------------------------------------------------------------
P1="Below is one person's complete media collection: films, TV, anime and books, each with
status (watched/to-watch), year, genres and a synopsis. Some films also carry an Elo
ranking derived from head-to-head 'which would you rather rewatch' votes — that ranking is
the strongest signal of actual preference, stronger than the genre tags.

Write a MAP of this taste. Not a summary, not a list — an argument about what this person
is drawn to, with the evidence sitting right there in the collection.

Cover:
1. **The real clusters.** Not genre labels — the actual recurring obsessions. Name 5-7,
   give each a short name and the specific titles that make the case. If two nominal
   genres are really one obsession, say so.
2. **Watched vs queued.** What do they actually finish versus what do they only collect?
   This gap is usually the most honest thing in a collection — name it precisely.
3. **The through-line between books and films.** These were built as separate lists. Find
   what they share.
4. **Blind spots.** What is conspicuously absent given everything else here? Be specific
   and non-obvious — 'no documentaries' is only interesting if you say why that's strange
   for THIS collection.
5. **Five recommendations** not already in the collection, each justified by a specific
   cluster above, not by general acclaim.

Direct engineer voice. No filler, no 'as an AI', no restating the brief. Markdown with ##
headings. Be specific and willing to make a real claim — a bland map is worthless.

$( [ -n "$RANKED" ] && printf 'ELO RANKING (head-to-head votes, strongest signal):\n%s\n' "$RANKED" )

COLLECTION:
$CORPUS"

log "requesting taste map…"
MAP=$(run_agy "$P1") || { log "taste map failed"; exit 1; }
[ "${#MAP}" -lt 800 ] && { log "taste map too short (${#MAP}) — refusing to write"; exit 1; }

{
    printf -- '---\ndate: %s\ntype: synthesis\ntags: [taste, cinema, reading, generated]\n---\n\n' "$(date -u +%F)"
    printf '# Taste Map\n\n> Generated by the cartographer pass over %s collection notes.\n' "$LINES"
    printf '> Regenerate with `~/claude-agents/run.sh cartographer`.\n\n'
    printf '%s\n' "$MAP"
} > "$SYN/taste-map.md"
log "wrote 40 Synthesis/taste-map.md"

# ---- 2. cinema MOC ------------------------------------------------------------------
P2="Rewrite this person's Cinema Map of Content from their actual collection below.

The existing MOC was hand-written months ago from a raw bulk list and is now stale. Replace
it with something driven by what is actually in the collection.

Structure:
- A short opening paragraph stating what this viewer is, in two or three sentences. A claim,
  not a hedge.
- **Thematic sections** (5-7), each with a heading, one line of framing, and the films that
  belong to it as Obsidian wikilinks in the form [[Exact File Name]]. The file name is the
  title as given at the start of each line — use it EXACTLY, including odd punctuation, or
  the link breaks.
- A **Watched** section listing what they've actually seen, and what that reveals.
- A **Start here** section: if they only watched five from the queue, which five and why.

Only reference titles that appear in the collection below. Never invent one. Markdown.
No preamble.

$( [ -n \"\$RANKED\" ] && printf 'Elo ranking of watched films (head-to-head votes):\n%s\n' \"\$RANKED\" )

COLLECTION:
$CORPUS"

log "requesting cinema MOC…"
CIN=$(run_agy "$P2") || { log "cinema MOC failed (taste map already written)"; exit 1; }
if [ "${#CIN}" -gt 800 ]; then
    # Hand-written sections from the previous MOC that the model cannot regenerate: the
    # Dataview/bulk watchlist pointers, the Research cross-link, the "To explore" notes.
    # These are Parth's own additions, not derivable from the collection — carried forward
    # verbatim under a Kept heading rather than clobbered. Everything above them is
    # regenerated each run.
    KEEP=""
    if [ -f "$MOC/Cinema-and-Arts.md" ]; then
        cp "$MOC/Cinema-and-Arts.md" "$MOC/.Cinema-and-Arts.$STAMP.bak"
        KEEP=$(awk '/^## (Watchlists|Design in Film|To explore)/{p=1} /^## (Taste profile)/{p=0} p' \
            "$MOC/.Cinema-and-Arts.$STAMP.bak")
    fi
    {
        printf -- '---\ndate: %s\ntype: moc\ntags: [moc, cinema, film, generated]\nlast_reviewed: %s\n---\n\n' \
            "$(date -u +%F)" "$(date -u +%F)"
        printf '# MOC — Cinema & Arts\n\n'
        printf 'Generated from the %s notes in `50 Collections`. The argument behind these\n' "$LINES"
        printf 'groupings — why these clusters, what the queue reveals — is in [[taste-map]].\n\n'
        printf '%s\n' "$CIN"
        [ -n "$KEEP" ] && printf '\n---\n\n%s\n' "$KEEP"
    } > "$MOC/Cinema-and-Arts.md"
    log "wrote MOC/Cinema-and-Arts.md (backup: .Cinema-and-Arts.$STAMP.bak)"
else
    log "cinema MOC too short — kept the existing one"
fi

# ---- 3. link repair -----------------------------------------------------------------
# The model is told to use exact filenames and reliably doesn't — it appends the year,
# normalises ALL-CAPS titles, keeps a subtitle the filename drops. Measured on the first
# run: 159 of 203 links dead. Re-prompting does not fix this class of error; resolving it
# mechanically does, and unlike a re-prompt the result is verifiable. Unresolvable links
# are left visible rather than deleted — that is the signal a title was hallucinated.
# Indexed against the vault root, not just 50 Collections: the MOC also links out to
# 40 Synthesis/taste-map and Research notes, and a narrower root reported those as broken.
BROKEN=$(python3 "$(dirname "$0")/../lib/fixlinks.py" "$MOC/Cinema-and-Arts.md" "$PKM")
log "link repair: $(printf '%s' "$BROKEN" | head -1)"

# ---- email --------------------------------------------------------------------------
# Light-theme tokens — kept identical to lib/render_email.py's palette so this reads
# as the same system as the digest emails, not a slightly-off one-off.
INK="#161616"; MUTED="#5c5c5c"; FAINT="#8a8a8a"; RULE="#e6e3dd"
BODY="<div style=\"font-family:-apple-system,sans-serif;max-width:620px;margin:0 auto\">
<div style=\"font:13px sans-serif;letter-spacing:.14em;text-transform:uppercase;color:$FAINT\">Cartographer</div>
<div style=\"font:600 20px sans-serif;color:$INK;margin:6px 0 16px\">Your collection, mapped</div>
<div style=\"font:14px/1.6 sans-serif;color:$MUTED\">Read $LINES notes across films, TV, anime and books.</div>
<div style=\"font:13px/1.8 sans-serif;color:$MUTED;margin-top:16px\">
<b>40 Synthesis/taste-map.md</b> — the argument: real clusters, the watched-vs-queued gap, blind spots, 5 recommendations<br>
<b>_Meta/MOC/Cinema-and-Arts.md</b> — rebuilt from the actual collection (old version backed up)<br>
</div>
<div style=\"font:12px sans-serif;color:$FAINT;margin-top:14px\">Link integrity: $(printf '%s' "$BROKEN" | head -1)</div>
<div style=\"font:13px sans-serif;margin-top:18px\">
<a href=\"https://watch.psidex.com/notes/taste-map\" style=\"color:$INK\">Read the full map →</a>
&nbsp;·&nbsp;<a href=\"https://watch.psidex.com/notes/cinema\" style=\"color:$INK\">Cinema MOC</a>
&nbsp;·&nbsp;<a href=\"https://watch.psidex.com/list/movies\" style=\"color:$INK\">Collection</a></div>
<div style=\"font:14px/1.7 sans-serif;color:$INK;margin-top:22px;border-top:1px solid $RULE;padding-top:16px\">
$(printf '%s' "$MAP" | head -60 | md_to_html)
</div></div>"

send_mail "🗺️ Taste map — $LINES notes read" "$BODY" html
log "cartographer complete"
