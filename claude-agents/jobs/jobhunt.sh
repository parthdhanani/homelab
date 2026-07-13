#!/bin/bash
# jobhunt.sh — job-application engine. Replaces LoopCV/Sonara/Teal.
# Reads config/jobhunt.md (your profile+prefs), searches, drafts tailored notes into a
# review QUEUE (never auto-sends), nags you with the count.
JOB=jobhunt
source "$(dirname "$0")/../lib/common.sh"

PROFILE=$(cat "$AGENT_CONFIG/jobhunt.md" 2>/dev/null)
[ -z "$PROFILE" ] && { log "no jobhunt profile configured"; exit 0; }
QUEUE="10 Projects/job-queue.md"

# filter_dead_links "<result markdown>"  — drops numbered role entries whose application
# link 404s/410s/fails to connect. Only known-dead codes are dropped; 403/999/5xx are kept
# (LinkedIn and other boards routinely bot-block curl with these — can't distinguish that
# from a real dead link, so err toward keeping and let you judge).
filter_dead_links() {
    local input="$1" dir kept=0 dropped=0 kept_text=""
    dir=$(mktemp -d)
    awk -v d="$dir" '/^[0-9]+\. \*\*/ { n++ } n>0 { print > (d "/" n) }' <<<"$input"

    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        block=$(cat "$f")
        url=$(printf '%s' "$block" | grep -oE 'https?://[^ )>\]]+' | head -1)
        if [ -z "$url" ]; then
            kept_text+="$block"$'\n'; kept=$((kept + 1)); continue
        fi
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --max-redirs 5 -L \
               -A 'Mozilla/5.0 (claude-agents jobhunt)' "$url" 2>/dev/null)
        if [ "$code" = "404" ] || [ "$code" = "410" ] || [ "$code" = "000" ]; then
            log "dropping dead link ($code): $url"
            dropped=$((dropped + 1))
        else
            kept_text+="$block"$'\n'; kept=$((kept + 1))
        fi
    done
    rm -rf "$dir"

    [ "$dropped" -gt 0 ] && kept_text+=$'\n'"_(link check: $kept kept, $dropped dropped as dead)_"
    printf '%s' "$kept_text"
}

SEEN="$AGENT_STATE/jobhunt-seen.tsv"   # DATE<tab>ROLE @ COMPANY — avoids re-mailing the same listing daily
touch "$SEEN"
cutoff10=$(date -u -d '10 days ago' +%F 2>/dev/null || date -u -v-10d +%F)
EXCLUDE=$(awk -F'\t' -v c="$cutoff10" '$1>=c{print "- "$2}' "$SEEN" | tail -60)
DEDUP_BLOCK=""
[ -n "$EXCLUDE" ] && DEDUP_BLOCK="

ALREADY DRAFTED in the last 10 days — do NOT include these again unless something material changed (e.g. they reposted with new terms):
$EXCLUDE"

PROMPT="You are my job-search agent. Here is my profile and what I want:

$PROFILE

Search the web for CURRENT openings (posted within ~2 weeks) that genuinely fit. Return the 3-5 BEST matches only — quality over quantity, no stretches. For each, format EXACTLY as:
1. A bold line with the ACTUAL job title and company you found, substituted in — e.g. **Enablement Content Developer @ Wiz** (never write the literal words \"Role\" or \"Company\") — followed by location/remote and the direct application link.
2. Why it fits me (1 line) + which resume variant to use if I have one.
3. A tailored 3-4 sentence cover note I could paste and send today.

If genuinely nothing new fits beyond what's already been drafted, say exactly: NOTHING NEW TODAY — and nothing else.
End with one blunt line: how many you found, and a reminder that drafting is not sending. Plain markdown, no preamble.$DEDUP_BLOCK"

log "searching for roles (excluding $(printf '%s' "$EXCLUDE" | grep -c .) recently-drafted)..."
RESULT=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

if printf '%s' "$RESULT" | grep -qi 'NOTHING NEW TODAY'; then
    log "nothing new — not mailing (avoids re-nagging with stale drafts)"
    exit 0
fi

RESULT=$(filter_dead_links "$RESULT")
if [ -z "$(printf '%s' "$RESULT" | grep -oE '\*\*[^*]+@[^*]+\*\*')" ]; then
    log "all drafted roles had dead links — nothing valid to send"
    exit 0
fi

today=$(date -u +%F)
printf '%s' "$RESULT" | grep -oE '\*\*[^*]+@[^*]+\*\*' | sed 's/\*\*//g' | while read -r role; do
    printf '%s\t%s\n' "$today" "$role" >> "$SEEN"
done
awk -F'\t' -v c="$cutoff10" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

write_pkm "$QUEUE" "$RESULT"
HTML=$(printf '%s' "$RESULT" | python3 "$AGENT_HOME/lib/render_email.py" \
        "Job Drafts — Send Them" "$(date -u '+%A, %d %B %Y') · drafting is not sending")
send_mail "Job Drafts ready — SEND them — $(date -u '+%a %d %b')" "$HTML" html
log "done"
