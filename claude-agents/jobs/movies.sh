#!/bin/bash
# movies.sh — weekly hidden-gem pick from your own to-watch list (Sat evening IST).
# Single purpose: one pick, taste-matched from your watched genres, with poster + best-effort
# OTT/subtitle info (verify before pressing play — streaming availability changes fast).
#
# Takes an optional collection argument: movies (default) | tv | anime. Parameterised rather
# than copied because the pick logic is identical across all three — only the directory, the
# noun in the prompt, and the seen-list differ. TV and Anime had no picker at all until
# 2026-07-26; they were unpickable before that because 31/42 and 41/43 of their notes were
# metadata-less stubs, which enrich.py has now filled in.
# Invoked either directly with an argument (`movies.sh tv`) or via run.sh through the
# movies-tv.sh / movies-anime.sh symlinks — run.sh derives the script path from the job name,
# so the symlink name is what carries the collection when there is no argument. Keeping the
# job names distinct is what gives each collection its own lockfile and log.
ARG="${1:-}"
if [ -z "$ARG" ]; then
    case "$(basename "$0" .sh)" in
        movies-tv)    ARG=tv ;;
        movies-anime) ARG=anime ;;
        *)            ARG=movies ;;
    esac
fi

case "$ARG" in
    movies) JOB=movies;       COLL="Movies";   NOUN="movie";     LABEL="Saturday Watch";  WHEN="Saturday evening"; SEENF="movie-seen.tsv" ;;
    tv)     JOB=movies-tv;    COLL="TV Shows"; NOUN="TV series"; LABEL="Midweek Series"; WHEN="week ahead";      SEENF="tv-seen.tsv" ;;
    anime)  JOB=movies-anime; COLL="Anime";    NOUN="anime";     LABEL="Midweek Anime";  WHEN="week ahead";      SEENF="anime-seen.tsv" ;;
    *)      echo "unknown collection '$ARG' (movies|tv|anime)" >&2; exit 1 ;;
esac
source "$(dirname "$0")/../lib/common.sh"

MOVIES_DIR="$PKM/50 Collections/$COLL"
[ -d "$MOVIES_DIR" ] || { log "no $COLL dir"; exit 0; }

SEEN="$AGENT_STATE/$SEENF"   # DATE<tab>TITLE — per-collection, so a film pick doesn't
touch "$SEEN"                # suppress a same-named series and vice versa

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

PROMPT="From my $NOUN to-watch catalog below, pick ONE genuine hidden gem for the $WHEN — not the most obvious/popular pick, something a bit underrated relative to its quality. My most-watched genres historically (taste signal, not a hard filter): $LIKED_GENRES.

CATALOG:
$CATALOG

Then research the pick: which OTT platforms it's currently available on (best-effort — note that streaming availability changes, so flag this as 'verify before pressing play'), and whether subtitles are available (language itself is not a barrier for me, only platform/subtitle availability matters).

Output EXACTLY this format, no preamble, no closing remarks:
## This Week's Pick
- ![](POSTER_URL) **TITLE (YEAR)** — GENRES
- **Why you'd like it:** one or two sentences connecting it to your taste/watched history, specific not generic.
- **Synopsis:** one short sentence, no spoilers.
- **Where to watch:** platform(s) found, or 'not found on major Indian OTT platforms — check JustWatch' if unclear. Note subtitle availability if known. Add: (verify before pressing play — availability changes)."

log "picking weekly $NOUN from $(printf '%s' "$CATALOG" | grep -c TITLE) to-watch candidates..."
BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

# The year is a RANGE for series -- "(2014-2017)", en-dash, sometimes open-ended "(2019- )".
# A single-year-only regex silently matched nothing on TV, so no pick was ever recorded and
# the 60-day repeat suppression was dead for that collection. Character class covers the
# en-dash/em-dash the model emits.
YEARPAT='\([0-9]{4}([–—-] *[0-9]{0,4})?\)'
PICK=$(printf '%s' "$BRIEF" | grep -oE "\*\*[^(]+$YEARPAT\*\*" | head -1 | sed -E "s/\*\*//g;s/ *$YEARPAT *\$//")
today=$(date -u +%F)
[ -n "$PICK" ] && printf '%s\t%s\n' "$today" "$PICK" >> "$SEEN"
cutoff180=$(date -u -d '180 days ago' +%F 2>/dev/null || date -u -v-180d +%F)
awk -F'\t' -v c="$cutoff180" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

write_pkm "00 Capture/Daily/Agents/$JOB.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "$LABEL" "$(date -u '+%A, %d %B %Y')")
send_mail "$LABEL — $(date -u '+%a %d %b')" "$HTML" html
log "done"
