#!/bin/bash
# movies.sh — one weekly "Picks" email covering Movies, TV, Anime (Sat evening IST).
# Merged from three separate jobs/emails (movies.sh, movies-tv.sh, movies-anime.sh) on
# 2026-08-09 — three near-identical single-pick emails on different days added volume
# without adding distinct signal. Now one job, one email, one section per collection
# that actually has a fresh pick. Per-collection dedup/seen-list logic is unchanged.
JOB=movies
source "$(dirname "$0")/../lib/common.sh"

pick_for() {
    local coll="$1" noun="$2" when="$3" seenf="$4"
    local dir="$PKM/50 Collections/$coll"
    [ -d "$dir" ] || { log "no $coll dir"; return 0; }

    local seen="$AGENT_STATE/$seenf"
    touch "$seen"

    local towatch
    towatch=$(grep -l '^status: to-watch' "$dir"/*.md 2>/dev/null)
    [ -z "$towatch" ] && { log "no $coll to-watch entries"; return 0; }

    local cutoff60 recent
    cutoff60=$(date -u -d '60 days ago' +%F 2>/dev/null || date -u -v-60d +%F)
    recent=$(awk -F'\t' -v c="$cutoff60" '$1>=c{print $2}' "$seen")

    local catalog="" f t y g p o
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        grep -q '^status: to-watch' "$f" || continue
        t=$(grep -m1 '^title:' "$f" | sed -E 's/^title:\s*"?//;s/"?\s*$//')
        [ -z "$t" ] && continue
        printf '%s\n' "$recent" | grep -qxF "$t" && continue
        y=$(grep -m1 '^year:' "$f" | sed -E 's/^year:\s*//')
        g=$(grep -m1 '^genres:' "$f" | sed -E 's/^genres:\s*//')
        p=$(grep -m1 '^poster_url:' "$f" | sed -E 's/^poster_url:\s*"?//;s/"?\s*$//')
        o=$(grep -m1 '^overview:' "$f" | sed -E 's/^overview:\s*"?//;s/"?\s*$//')
        catalog+="TITLE: $t | YEAR: $y | GENRES: $g | POSTER: $p | OVERVIEW: $o"$'\n'
    done
    [ -z "$catalog" ] && { log "all $coll to-watch entries recently shown, nothing fresh"; return 0; }

    local liked
    liked=$(for f in "$dir"/*.md; do grep -q '^status: watched' "$f" 2>/dev/null && grep -m1 '^genres:' "$f"; done | sed -E 's/^genres:\s*//' | tr -d '[]"' | tr ',' '\n' | sed 's/^\s*//;s/\s*$//' | sort | uniq -c | sort -rn | head -8 | awk '{$1="";print}')

    local prompt="From my $noun to-watch catalog below, pick ONE genuine hidden gem for the $when — not the most obvious/popular pick, something a bit underrated relative to its quality. My most-watched genres historically (taste signal, not a hard filter): $liked.

CATALOG:
$catalog

Then research the pick: which OTT platforms it's currently available on (best-effort — note that streaming availability changes, so flag this as 'verify before pressing play'), and whether subtitles are available (language itself is not a barrier for me, only platform/subtitle availability matters).

Output EXACTLY this format, no preamble, no closing remarks:
- ![](POSTER_URL) **TITLE (YEAR)** — GENRES
- **Why you'd like it:** one or two sentences connecting it to your taste/watched history, specific not generic.
- **Synopsis:** one short sentence, no spoilers.
- **Where to watch:** platform(s) found, or 'not found on major Indian OTT platforms — check JustWatch' if unclear. Note subtitle availability if known. Add: (verify before pressing play — availability changes)."

    log "picking weekly $noun from $(printf '%s' "$catalog" | grep -c TITLE) to-watch candidates..."
    local brief
    brief=$(run_agy "$prompt") || { log "$coll pick failed"; return 0; }

    # Year is a RANGE for series -- "(2014-2017)", en-dash, sometimes open-ended "(2019- )".
    local yearpat='\([0-9]{4}([–—-] *[0-9]{0,4})?\)'
    local pk today
    pk=$(printf '%s' "$brief" | grep -oE "\*\*[^(]+$yearpat\*\*" | head -1 | sed -E "s/\*\*//g;s/ *$yearpat *\$//")
    today=$(date -u +%F)
    [ -n "$pk" ] && printf '%s\t%s\n' "$today" "$pk" >> "$seen"
    local cutoff180
    cutoff180=$(date -u -d '180 days ago' +%F 2>/dev/null || date -u -v-180d +%F)
    awk -F'\t' -v c="$cutoff180" '$1>=c' "$seen" > "$seen.tmp" && mv "$seen.tmp" "$seen"

    printf '%s\n' "$brief"
}

MOVIE_PICK=$(pick_for "Movies" "movie" "weekend" "movie-seen.tsv")
TV_PICK=$(pick_for "TV Shows" "TV series" "week ahead" "tv-seen.tsv")
ANIME_PICK=$(pick_for "Anime" "anime" "week ahead" "anime-seen.tsv")

BRIEF=""
[ -n "$MOVIE_PICK" ] && BRIEF+="## Movie
$MOVIE_PICK

"
[ -n "$TV_PICK" ] && BRIEF+="## TV
$TV_PICK

"
[ -n "$ANIME_PICK" ] && BRIEF+="## Anime
$ANIME_PICK

"

if [ -z "$BRIEF" ]; then
    log "no fresh picks in any collection — no email"
    exit 0
fi

write_pkm "00 Capture/Daily/Agents/movies.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "This Week's Picks" "$(date -u '+%A, %d %B %Y')")
send_mail "This Week's Picks — $(date -u '+%a %d %b')" "$HTML" html
log "done"
