#!/bin/bash
# jobhunt-status-sync.sh — auto-detects real application/interview/offer signals from Gmail
# (read-only IMAP, never deletes/modifies mail) and logs them into job-queue.md so sends that
# happen outside the drafting flow (e.g. direct LinkedIn applies) get tracked without manual
# entry. Companion to jobs/jobhunt.sh, run on the same schedule but does not draft anything.
JOB=jobhunt-status-sync
source "$(dirname "$0")/../lib/common.sh"

QUEUE="10 Projects/job-queue.md"
SEEN="$AGENT_STATE/jobhunt-mail-seen.tsv"   # MESSAGE_ID<tab>DATE — dedup across runs
STATE="$AGENT_STATE/jobhunt-mail-lastcheck" # last successful scan window, in days-back
touch "$SEEN"

# how far back to scan: first-ever run does the full agreed backfill, subsequent runs
# only need to cover since the last run (a few days) — read from state, default to backfill.
SINCE_DAYS="${1:-}"
if [ -z "$SINCE_DAYS" ]; then
    if [ -f "$STATE" ]; then
        SINCE_DAYS=5   # routine run: last run + slack for late-arriving mail
    else
        SINCE_DAYS=1500   # first-ever run: full backfill (real signal found back to 2023)
        log "no state file — running full backfill (since_days=$SINCE_DAYS)"
    fi
fi

RAW=$(python3 "$AGENT_HOME/lib/mail_scan.py" --since-days "$SINCE_DAYS" --kind all 2>>"$AGENT_LOG/mail_scan.err") \
    || { log "mail_scan.py failed (see logs/mail_scan.err)"; exit 1; }

if [ -z "$RAW" ]; then
    log "no application/status signal emails found"
    date -u +%F > "$STATE"
    exit 0
fi

QUEUE_TEXT=$(cat "$PKM/$QUEUE" 2>/dev/null || true)
NEW_LINES=""
count=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    msgid=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message_id',''))" 2>/dev/null)
    date_hdr=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('date',''))" 2>/dev/null)
    subject=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('subject',''))" 2>/dev/null)
    # no reliable Message-ID (rare, some senders omit it) — fall back to stable parsed fields,
    # NOT the raw JSON line (serialization order / added metadata would silently break dedup).
    key="${msgid:-${subject}|${date_hdr}}"
    grep -qF "$key" "$SEEN" 2>/dev/null && continue   # already logged in a prior run

    kind=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null)
    company=$(printf '%s' "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('company_guess',''))" 2>/dev/null)

    # best-effort: does this company show up anywhere in job-queue.md already? (case-insensitive
    # substring) — tells you if this was a role the agent drafted vs. one you sent on your own.
    match="not in drafted queue — sent directly"
    if [ -n "$company" ] && printf '%s' "$QUEUE_TEXT" | grep -qi -- "$company"; then
        match="matches a drafted queue entry — verify below"
    fi

    label="Applied"
    [ "$kind" = "status" ] && label="Status update"
    NEW_LINES+="- **$label** — $company ($match) — \"$subject\" — $date_hdr"$'\n'
    printf '%s\t%s\n' "$key" "$(date -u +%F)" >> "$SEEN"
    count=$((count + 1))
done <<< "$RAW"

if [ "$count" -gt 0 ]; then
    write_pkm "$QUEUE" "### Application status (auto-detected from Gmail, read-only scan)

$NEW_LINES"
    log "logged $count new application/status signal(s) to job-queue.md"
else
    log "signals found but all already logged (no new Message-IDs)"
fi

date -u +%F > "$STATE"
