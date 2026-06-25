#!/bin/bash
# github.sh — weekly OSS digest (Tue evening IST). Tier 1: hidden-gem self-hosting tools
# for your stack. Tier 2: what's genuinely trending this week. Cross-run deduped.
JOB=github
source "$(dirname "$0")/../lib/common.sh"

SEEN="$AGENT_STATE/github-seen.tsv"   # DATE<tab>REPO_URL<tab>NAME — memory of what we've shown
touch "$SEEN"

cutoff60=$(date -u -d '60 days ago' +%F 2>/dev/null || date -u -v-60d +%F)
EXCLUDE=$(awk -F'\t' -v c="$cutoff60" '$1>=c{print "- "$3" ("$2")"}' "$SEEN" | tail -200)
DEDUP_BLOCK=""
[ -n "$EXCLUDE" ] && DEDUP_BLOCK="

ALREADY SHOWN in the last 60 days — do NOT repeat these repos unless something major changed (e.g. a big new release), in which case lead with what's NEW:
$EXCLUDE"

PROMPT="You are curating my weekly GitHub digest. Build ONE ranked pool across these two categories, ordering by genuine interest/quality — Hidden Gems & Self-Hosting leads by default:

Hidden Gems & Self-Hosting: underrated, well-built self-hosted/infra tools relevant to my stack
(Docker, Cloudflare Tunnel, nginx, Oracle Cloud VPS, JavaScript/TypeScript, Python, AI/LLM tooling,
e-learning/SCORM/xAPI). Doesn't need to be NEW — just genuinely good and worth knowing about that I'd
plausibly have missed. Explain briefly why it's a hidden gem, not just what it does.

Trending This Week: what's actually trending/new on GitHub right now, including outside my
stack if it's significant.

Rules:
- SKIP a category entirely if it genuinely has nothing worth including — no placeholder line, no sentence explaining why.
- Cap the WHOLE digest at ~10-12 repos total combined — signal over coverage, never pad.
- Output one '## ' markdown section per category you're including, only for categories with content. Heading text = the category name exactly as given above (\"Hidden Gems & Self-Hosting\" or \"Trending This Week\"), nothing else added.
- Format every item EXACTLY as:  - **[owner/repo](https://github.com/owner/repo)** — one sentence on what it does and why it matters to me specifically. (★ star count if known)
- Consolidate forks/mirrors of the same project into one entry.
- No trailing \"Sources:\"/links list — every item already links its own repo. Do not repeat those links in a separate list at the end.
- No preamble, no closing remarks, no \"here's my final list\" or similar framing line. Your response must begin with the literal characters \"## \" — nothing before it, not even one sentence.$DEDUP_BLOCK"

log "curating weekly GitHub digest (excluding $(printf '%s' "$EXCLUDE" | grep -c .) recently-seen)..."
BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

today=$(date -u +%F)
printf '%s' "$BRIEF" | grep -oE '\[[^]]+\]\(https://github\.com/[^)]+\)' | while read -r pair; do
    n=$(printf '%s' "$pair" | sed -E 's/^\[([^]]*)\].*/\1/')
    u=$(printf '%s' "$pair" | sed -E 's/.*\((https:\/\/github\.com\/[^)]+)\)$/\1/')
    printf '%s\t%s\t%s\n' "$today" "$u" "$n" >> "$SEEN"
done
cutoff90=$(date -u -d '90 days ago' +%F 2>/dev/null || date -u -v-90d +%F)
awk -F'\t' -v c="$cutoff90" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

write_pkm "00 Capture/Daily/Agents/github-trending.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "GitHub Weekly" "$(date -u '+%A, %d %B %Y')")
require_links "$HTML" || exit 1
send_mail "GitHub Weekly — $(date -u '+%a %d %b')" "$HTML" html
log "done"
