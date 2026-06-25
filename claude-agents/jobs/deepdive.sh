#!/bin/bash
# deepdive.sh — weekly deep-interest email (Sun morning IST). ONE topic only, alternating
# weekly between a research nugget (geopolitics/languages/design/math/biomimicry) and a
# backlog item from ReadLater — never both in the same email. Built to be an on-ramp: hook,
# ELI5/analogy first, then an opt-in deeper layer — not a wall of jargon assuming prior context.
JOB=deepdive
source "$(dirname "$0")/../lib/common.sh"

RESEARCH_DIR="$PKM/50 Collections/Research"
READLATER="$PKM/50 Collections/ReadLater/urls.md"
today=$(date -u +%F)
week=$(date -u +%V)
mode="research"; [ $((10#$week % 2)) -eq 0 ] && mode="backlog"

if [ "$mode" = "backlog" ]; then
    RL_LINE=$(grep -m1 '^- \[ \]' "$READLATER" 2>/dev/null)
    if [ -z "$RL_LINE" ]; then
        log "backlog empty — falling back to research mode this week"
        mode="research"
    fi
fi

if [ "$mode" = "backlog" ]; then
    rl_desc=$(printf '%s' "$RL_LINE" | sed -E 's/^- \[ \] [0-9-]+ \| //; s/ \| .*//')
    rl_url=$(printf '%s' "$RL_LINE" | grep -oE 'https?://\S+')

    PROMPT="This is a 'read later' item I saved but never read: \"$rl_desc\" ($rl_url). You have web access — actually look it up.

Write me ONE single-focus email about it, structured to build genuine curiosity, not dump facts:
1. A one-sentence hook — why this is worth 90 seconds of my attention.
2. An ELI5 explanation using a concrete analogy to something everyday — assume I know NOTHING about this topic yet, this is the on-ramp, not the deep layer.
3. A clearly-separated 'Go deeper' bit — one more layer of nuance, for if the hook worked and I want more, plus the actual source link so I can read the full thing.

Output EXACTLY this format, no preamble, no closing remarks:
## <a short, engaging, curiosity-driving title — NOT the raw filename>
**The hook:** ...
**In plain terms:** ... (the analogy)

**Go deeper:** ... ([read the source]($rl_url))"

    log "curating backlog item: $rl_desc"
    BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

    python3 - "$READLATER" "$RL_LINE" <<'PYEOF'
import sys
path, line = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
for i, l in enumerate(lines):
    if l.rstrip('\n') == line:
        lines[i] = l.replace('- [ ]', '- [x]', 1)
        break
with open(path, 'w') as f:
    f.writelines(lines)
PYEOF

else
    SEEN="$AGENT_STATE/deepdive-seen.tsv"   # DATE<tab>TOPIC
    touch "$SEEN"
    TOPICS_AVAIL=$(find "$RESEARCH_DIR" -maxdepth 1 -name '*.md' ! -name '🔬*' 2>/dev/null | xargs -I{} basename {} .md)
    if [ -z "$TOPICS_AVAIL" ]; then log "no research notes"; exit 0; fi

    cutoff90=$(date -u -d '90 days ago' +%F 2>/dev/null || date -u -v-90d +%F)
    RECENT=$(awk -F'\t' -v c="$cutoff90" '$1>=c{print $2}' "$SEEN")
    CANDIDATES=$(comm -23 <(printf '%s\n' "$TOPICS_AVAIL" | sort -u) <(printf '%s\n' "$RECENT" | sort -u))
    [ -z "$CANDIDATES" ] && CANDIDATES="$TOPICS_AVAIL"
    TOPIC=$(printf '%s\n' "$CANDIDATES" | shuf -n1)
    NOTE_CONTENT=$(cat "$RESEARCH_DIR/$TOPIC.md" 2>/dev/null | head -c 4000)

    PROMPT="This is one of my own research notes on a topic I'm genuinely into (geopolitics, constructed/sacred languages, design history, math puzzles, biomimicry, philosophy) but haven't revisited in a while — so don't assume I remember the details, even though the note itself does.

NOTE on \"$TOPIC\":
---
$NOTE_CONTENT
---

Write me ONE single-focus email built to make me curious enough to want the full read, not to replace it:
1. A one-sentence hook — the single most intriguing thing about this, in plain language.
2. An ELI5 explanation using a concrete analogy to something everyday. Assume zero prior context — this is the on-ramp.
3. A clearly-separated 'Go deeper' bit — one layer past the ELI5, for if the hook worked. You have web access — if there's a genuinely good short article/video explainer on this exact topic, link it; otherwise just go one level deeper into the note's own content.

Output EXACTLY this format, no preamble, no closing remarks:
## <a short, engaging, curiosity-driving title — NOT the raw topic slug>
**The hook:** ...
**In plain terms:** ... (the analogy)

**Go deeper:** ..."

    log "curating research nugget on \"$TOPIC\"..."
    BRIEF=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

    printf '%s\t%s\n' "$today" "$TOPIC" >> "$SEEN"
    awk -F'\t' -v c="$cutoff90" '$1>=c' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
fi

write_pkm "00 Capture/Daily/Agents/deepdive.md" "$BRIEF"

HTML=$(printf '%s' "$BRIEF" | python3 "$AGENT_HOME/lib/render_email.py" \
        "Sunday Deep Dive" "$(date -u '+%A, %d %B %Y')")
send_mail "Sunday Deep Dive — $(date -u '+%a %d %b')" "$HTML" html
log "done"
