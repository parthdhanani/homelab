#!/bin/bash
# monitor.sh — semantic change monitor. Replaces Visualping/Distill + Mention.
# Deterministic diff gate (curl+hash) first; claude judges ONLY real changes (token-cheap).
# config/watchlist.txt: one per line  ->  URL | short label
JOB=monitor
source "$(dirname "$0")/../lib/common.sh"

WATCH="$AGENT_CONFIG/watchlist.txt"
[ -f "$WATCH" ] || { log "no watchlist"; exit 0; }

CHANGES=""        # accumulates labelled diffs for a single claude call
FIRSTRUN_NOTE=""

while IFS='|' read -r url label; do
    url=$(echo "$url" | xargs); label=$(echo "${label:-$url}" | xargs)
    [ -z "$url" ] || [[ "$url" == \#* ]] && continue

    raw=$(fetch_url "$url") || { log "FETCH FAILED: $label ($url)"; continue; }
    new=$(printf '%s' "$raw" | normalize)
    s=$(slug "$url"); hashfile="$AGENT_STATE/$s.txt"

    if [ ! -f "$hashfile" ]; then
        printf '%s' "$new" > "$hashfile"
        FIRSTRUN_NOTE+="• baselined: $label"$'\n'
        log "baselined $label"
        continue
    fi

    old=$(cat "$hashfile")
    if [ "$(printf '%s' "$old" | md5sum)" != "$(printf '%s' "$new" | md5sum)" ]; then
        # capture a compact textual diff to feed claude (cheap, bounded)
        d=$(diff <(printf '%s' "$old" | tr ' ' '\n') <(printf '%s' "$new" | tr ' ' '\n') \
              | grep -E '^[<>]' | head -120)
        CHANGES+="### SOURCE: $label ($url)"$'\n'"$d"$'\n\n'
        printf '%s' "$new" > "$hashfile"
        log "CHANGED: $label"
    fi
done < "$WATCH"

[ -n "$FIRSTRUN_NOTE" ] && log "first-run baselines:"$'\n'"$FIRSTRUN_NOTE"

if [ -z "$CHANGES" ]; then
    log "no changes — nothing to report (no tokens spent)"
    exit 0
fi

PROMPT="I monitor these web pages for changes that affect my work (self-hosted infra, SCORM/xAPI/Moodle e-learning, accessibility/EAA, and the APIs my tools depend on). Below are the raw diffs ('<' = removed, '>' = added) detected since last check. For each source, tell me in 1-2 sentences WHAT changed and whether it MATTERS to me, with a severity tag [HIGH]/[MED]/[LOW]/[NOISE]. Ignore cosmetic/nav/ad noise. If a change is pure noise, say so in one line. Be terse.

$CHANGES"

log "judging $(grep -c '^### SOURCE' <<<"$CHANGES") changed source(s)..."
REPORT=$(run_agy "$PROMPT") || { log "claude failed"; exit 1; }

# Only alert on something above noise
if echo "$REPORT" | grep -qiE '\[(HIGH|MED|LOW)\]'; then
    write_pkm "00 Capture/Daily/Agents/monitor.md" "$REPORT"
    BODY="## Changes Detected

$REPORT"
    HTML=$(printf '%s' "$BODY" | python3 "$AGENT_HOME/lib/render_email.py" \
            "Web Monitor" "$(date -u '+%a %d %b')")
    send_mail "[Monitor] Web changes detected — $(date -u '+%a %d %b')" "$HTML" html
else
    log "changes were noise-only — not alerting"
fi
log "done"
