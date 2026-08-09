#!/bin/bash
# news.sh — personalized categorized "Discover" feed. Replaces Perplexity/ChatGPT discover.
# Categories from config/news-topics.txt -> ~10 linked items each. Markdown to PKM, HTML email.
JOB=news
source "$(dirname "$0")/../lib/common.sh"

TOPICS=$(grep -vE '^\s*#|^\s*$' "$AGENT_CONFIG/news-topics.txt" 2>/dev/null)
[ -z "$TOPICS" ] && { log "no topics configured"; exit 0; }

SEEN="$AGENT_STATE/news-seen.tsv"   # DATE<tab>URL<tab>HEADLINE — memory of what we've shown
touch "$SEEN"

# already-covered in the last 5 days -> tell claude to skip them (cross-run dedup)
cutoff5=$(date -u -d '5 days ago' +%F 2>/dev/null || date -u -v-5d +%F)
EXCLUDE=$(awk -F'\t' -v c="$cutoff5" '$1>=c{print "- "$3" ("$2")"}' "$SEEN" | tail -80)
DEDUP_BLOCK=""
[ -n "$EXCLUDE" ] && DEDUP_BLOCK="

ALREADY COVERED in my recent digests — do NOT repeat these stories or minor follow-ups to them. Only re-include one if there is a genuinely MAJOR new development since, and if so, lead the line with what is NEW:
$EXCLUDE"

PROMPT="You are my personal news editor — replacing Perplexity Discover. These are the categories I care about (the lines in [brackets] are the category names — use them VERBATIM, with no prefix or numbering, as your '## ' section headings; text under them is steering):

$TOPICS

Rules:
- Build ONE ranked pool of stories across ALL categories, then decide section order by today's actual significance — Stack & Career leads by default since it's directly relevant to my work, but a dramatically bigger World Context story can lead instead. Do not force the listed order.
- SKIP a category entirely if it genuinely has nothing significant today — no placeholder, no \"nothing notable\" line, no sentence explaining WHY it's thin or what searches turned up. Just omit the section completely, as if it were never in the list. A thin day is not an error and does not need justifying.
- Cap the WHOLE digest at ~10-12 items total across all sections combined — this is about signal, not coverage. Never pad any section to hit a count.
- Consolidate duplicate coverage of the same event into ONE item.
- Prefer genuinely NEW stories; do not resurface days-old news just to fill a slot.
- Write like Axios Smart Brevity: lead with the takeaway/conclusion, not the topic — the reader should get the point from the bolded headline alone, with the one-sentence description adding the 'so what,' not restating the headline.
- Format every item EXACTLY as:  - **[Headline](https://full-article-url)** — one sentence on why it matters, in a direct conversational voice. (source-domain)
  The headline MUST be a markdown link to the actual article URL you found via search.
- Output one '## ' markdown section per category you're including, only for categories with content. Heading text = the category name exactly as given above, nothing else added.
- Recent and real only. Never invent a story or URL.
- No trailing \"Sources:\"/citations list — every item already cites its source inline via the headline link and the (source-domain) tag. Do not repeat those links in a separate list at the end.
- No preamble, no closing remarks, no \"here's my final list\" or similar framing line. Your response must begin with the literal characters \"## \" — nothing before it, not even one sentence.$DEDUP_BLOCK"

log "curating ranked-pool news digest (excluding $(printf '%s' "$EXCLUDE" | grep -c . ) recently-seen)..."
BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

# best-effort thumbnail on the top 2 stories only (keep it light, never blocks the send)
top_urls=$(printf '%s' "$BRIEF" | grep -oE '\]\(https?://[^)]+\)' | sed 's/^](//;s/)$//' | head -2)
while IFS= read -r u; do
    [ -z "$u" ] && continue
    img=$(og_image "$u")
    [ -z "$img" ] && continue
    # use substr(), not sub(): og:image URLs routinely contain literal "&" (query params),
    # which awk's sub() replacement string treats as "insert the matched text" — corrupting the line.
    BRIEF=$(printf '%s' "$BRIEF" | awk -v url="$u" -v img="$img" '
        index($0, "](" url ")") > 0 && $0 ~ /^- \*\*\[/ { print "- ![](" img ") **[" substr($0, 6); next }
        { print }')
done <<<"$top_urls"

# record what we showed today, then prune memory older than 7 days
today=$(date -u +%F)
printf '%s' "$BRIEF" | grep -oE '\[[^]]+\]\([^)]+\)' | while read -r pair; do
    t=$(printf '%s' "$pair" | sed -E 's/^\[([^]]*)\].*/\1/')
    u=$(printf '%s' "$pair" | sed -E 's/.*\(([^)]+)\)$/\1/')
    printf '%s\t%s\t%s\n' "$today" "$u" "$t" >> "$SEEN"
done
cutoff7=$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)
awk -F'\t' -v c="$cutoff7" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

# "Today's Line" — one real quote/lesson from an unread book, rotating so it doesn't repeat too soon
BOOKS_DIR="$PKM/50 Collections/Books"
QSEEN="$AGENT_STATE/book-quote-seen.tsv"   # DATE<tab>TITLE
touch "$QSEEN"
if [ -d "$BOOKS_DIR" ]; then
    ALL_BOOKS=""
    for f in "$BOOKS_DIR"/*.md; do
        [ -f "$f" ] || continue
        t=$(grep -m1 -E '^title:' "$f" | sed -E 's/^title:\s*"?//;s/"?\s*$//')
        a=$(grep -m1 -E '^author:' "$f" | sed -E 's/^author:\s*"?//;s/"?\s*$//')
        [ -n "$t" ] && ALL_BOOKS+="$t — $a"$'\n'
    done
    cutoff30=$(date -u -d '30 days ago' +%F 2>/dev/null || date -u -v-30d +%F)
    RECENT_BOOKS=$(awk -F'\t' -v c="$cutoff30" '$1>=c{print $2}' "$QSEEN")
    CANDIDATES=$(comm -23 <(printf '%s\n' "$ALL_BOOKS" | sort -u) <(printf '%s\n' "$RECENT_BOOKS" | sort -u))
    [ -z "$CANDIDATES" ] && CANDIDATES="$ALL_BOOKS"
    PICK=$(printf '%s\n' "$CANDIDATES" | shuf -n1)
    if [ -n "$PICK" ]; then
        QPROMPT="Give me one real, accurate quote or key lesson from the book \"$PICK\" — something that would help me learn or improve, in 1-2 sentences max. Format EXACTLY as:
- **$PICK** — the quote or lesson itself.
No preamble, no closing remarks, no markdown links, just that one line."
        LINE=$(run_agy "$QPROMPT") || LINE=""
        if [ -n "$LINE" ]; then
            BRIEF="## Today's Line
$LINE

$BRIEF"
            printf '%s\t%s\n' "$today" "$PICK" >> "$QSEEN"
            awk -F'\t' -v c="$cutoff30" '$1>=c' "$QSEEN" > "$QSEEN.tmp" && mv "$QSEEN.tmp" "$QSEEN"
        fi
    fi
fi

write_pkm "00 Capture/Daily/Agents/news-feed.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "Daily Digest" "$(date -u '+%A, %d %B %Y')")
require_links "$HTML" || exit 1
send_mail "Daily Digest — $(date -u '+%a %d %b')" "$HTML" html
log "done"
