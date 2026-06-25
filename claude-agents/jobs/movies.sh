#!/bin/bash
# movies.sh — weekly hidden-gem movie pick from your own to-watch list (Sat evening IST).
# Single purpose: one pick, taste-matched from your watched genres, with poster + best-effort
# OTT/subtitle info (verify before pressing play — streaming availability changes fast).
JOB=movies
source "$(dirname "$0")/../lib/common.sh"

MOVIES_DIR="$PKM/50 Collections/Movies"
[ -d "$MOVIES_DIR" ] || { log "no movies dir"; exit 0; }

SEEN="$AGENT_STATE/movie-seen.tsv"   # DATE<tab>TITLE
touch "$SEEN"

TOWATCH=$(grep -l '^status: to-watch' "$MOVIES_DIR"/*.md 2>/dev/null)
[ -z "$TOWATCH" ] && { log "no to-watch entries"; exit 0; }

cutoff60=$(date -u -d '60 days ago' +%F 2>/dev/null || date -u -v-60d +%F)
RECENT=$(awk -F'\t' -v c="$cutoff60" '$1>=c{print $2}' "$SEEN")

# build a compact catalog: title | year | genres | poster_url, skipping recently-shown
CATALOG=""
for f in "$MOVIES_DIR"/*.md; do
    [ -f "$f" ] || continue
    grep -q '^status: to-watch' "$f" || continue
    t=$(grep -m1 '^title:' "$f" | sed -E 's/^title:\s*"?//;s/"?\s*$//')
    [ -z "$t" ] && continue
    printf '%s\n' "$RECENT" | grep -qxF "$t" && continue
    y=$(grep -m1 '^year:' "$f" | sed -E 's/^year:\s*//')
    g=$(grep -m1 '^genres:' "$f" | sed -E 's/^genres:\s*//')
    p=$(grep -m1 '^poster_url:' "$f" | sed -E 's/^poster_url:\s*"?//;s/"?\s*$//')
    o=$(grep -m1 '^overview:' "$f" | sed -E 's/^overview:\s*"?//;s/"?\s*$//')
    CATALOG+="TITLE: $t | YEAR: $y | GENRES: $g | POSTER: $p | OVERVIEW: $o"$'\n'
done
[ -z "$CATALOG" ] && { log "all to-watch entries recently shown, nothing fresh"; exit 0; }

LIKED_GENRES=$(for f in "$MOVIES_DIR"/*.md; do grep -q '^status: watched' "$f" 2>/dev/null && grep -m1 '^genres:' "$f"; done | sed -E 's/^genres:\s*//' | tr -d '[]"' | tr ',' '\n' | sed 's/^\s*//;s/\s*$//' | sort | uniq -c | sort -rn | head -8 | awk '{$1="";print}')

PROMPT="From my movie to-watch catalog below, pick ONE genuine hidden gem for a Saturday evening watch — not the most obvious/popular pick, something a bit underrated relative to its quality. My most-watched genres historically (taste signal, not a hard filter): $LIKED_GENRES.

CATALOG:
$CATALOG

Then research the pick: which OTT platforms it's currently available on (best-effort — note that streaming availability changes, so flag this as 'verify before pressing play'), and whether subtitles are available (language itself is not a barrier for me, only platform/subtitle availability matters).

Output EXACTLY this format, no preamble, no closing remarks:
## This Week's Pick
- ![](POSTER_URL) **TITLE (YEAR)** — GENRES
- **Why you'd like it:** one or two sentences connecting it to your taste/watched history, specific not generic.
- **Synopsis:** one short sentence, no spoilers.
- **Where to watch:** platform(s) found, or 'not found on major Indian OTT platforms — check JustWatch' if unclear. Note subtitle availability if known. Add: (verify before pressing play — availability changes)."

log "picking weekly movie from $(printf '%s' "$CATALOG" | grep -c TITLE) to-watch candidates..."
BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

PICK=$(printf '%s' "$BRIEF" | grep -oE '\*\*[^(]+\([0-9]{4}\)\*\*' | head -1 | sed -E 's/\*\*//g;s/\s*\([0-9]{4}\)\s*$//')
today=$(date -u +%F)
[ -n "$PICK" ] && printf '%s\t%s\n' "$today" "$PICK" >> "$SEEN"
cutoff180=$(date -u -d '180 days ago' +%F 2>/dev/null || date -u -v-180d +%F)
awk -F'\t' -v c="$cutoff180" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

write_pkm "00 Capture/Daily/Agents/movies.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "Saturday Watch" "$(date -u '+%A, %d %B %Y')")
send_mail "Saturday Watch — $(date -u '+%a %d %b')" "$HTML" html
log "done"
