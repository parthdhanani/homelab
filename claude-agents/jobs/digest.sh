#!/bin/bash
# digest.sh — weekly "state of your world" brief. The unified world-state, pushed not built.
# Gathers facts deterministically, claude turns them into a readable digest.
JOB=digest
source "$(dirname "$0")/../lib/common.sh"

OB1=$(curl -s -m 5 http://172.18.0.52:8000/health 2>/dev/null | grep -oE '"memories":[0-9]+' || echo "ob1: unreachable")
DISK=$(df -h / | awk 'NR==2{print $5" used, "$4" free"}')
MEM=$(free -h | awk '/Mem:/{print $3" used / "$2" total"}')
FAILED=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' '); FAILED="${FAILED:-none}"
CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' '); UNHEALTHY="${UNHEALTHY:-none}"
JOBHUNT=$(python3 "$AGENT_HOME/lib/jobstats.py" --days 7 2>/dev/null || echo "unavailable")
# Drafted-but-unposted LinkedIn queue. Same failure mode as jobhunt: assets written,
# never shipped (4 posts sat unposted for 18 days). Reported, not auto-drafted —
# generating post 5 while 1-3 wait is the anti-pattern, not the fix.
LINKEDIN=$(python3 "$AGENT_HOME/lib/linkedin_queue.py" 2>/dev/null || echo "linkedin: unavailable")
# Memory index consistency. Flag-only — deletes and rewrites nothing.
MEMLINT=$(python3 /home/ubuntu/.claude/scripts/memory-lint.py --quiet 2>/dev/null || echo "unavailable")

# Stale-job detector. Reuses each job's own rotated log file mtime (already written by
# every job, no new mechanism) as its "last successfully ran" signal, compared against a
# threshold sized to that job's own timer cadence. Flag-only, like memlint — this job
# doesn't restart or fix anything, it just makes a silent failure visible on the one
# cadence (weekly) that already reaches the inbox regardless of any other job's state.
declare -A STALE_THRESHOLD=(
    [news]=3 [monitor]=3 [ops]=3
    [jobhunt]=7 [jobhunt-status-sync]=7
    [digest]=10 [deepdive]=10 [duel]=10 [til]=10 [github]=10 [movies]=10
    [movies-tv]=20 [movies-anime]=20
    [cartographer]=40
)
STALE=""
for job in "${!STALE_THRESHOLD[@]}"; do
    logf="$AGENT_LOG/${job}.log"
    [ -f "$logf" ] || { STALE+="$job: never run (no log)"$'\n'; continue; }
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$logf") ) / 86400 ))
    [ "$age_days" -gt "${STALE_THRESHOLD[$job]}" ] && STALE+="$job: last ran ${age_days}d ago (expected within ${STALE_THRESHOLD[$job]}d)"$'\n'
done

FACTS="OB1 $OB1
Disk: $DISK
Mem: $MEM
Failed systemd units: $FAILED
Containers running: $CONTAINERS | unhealthy: $UNHEALTHY
Job search this week: $JOBHUNT
LinkedIn queue: $LINKEDIN
Memory index: $MEMLINT
Stale jobs: ${STALE:-none}"

PROMPT="Here is the raw weekly state of my self-hosted system. Write me a short 'state of your world' digest: lead with anything that needs my attention (failures, disk pressure), then a one-line all-clear for what's healthy. Be honest and brief — no cheerleading. If everything's fine, say so in 2 lines.

Separately, always report the 'Job search this week' line plainly and without softening — it's drafted roles vs. Gmail-confirmed real applications sent. If applied is 0 or far below drafted, say that bluntly; do not spin it positively.

Apply the same rule to the 'LinkedIn queue' line: it is drafted posts vs. posted ones. If posts are sitting ready and unposted, say the number plainly in one line. Do not offer to write more posts — more drafts is the problem, not the fix. Posts marked blocked on a dependency are not a nag; mention them only if nothing else is ready.

The 'Memory index' line is housekeeping, not an alert. If it says clean, omit it entirely — do not spend a line telling me nothing is wrong. Mention it only when it reports issues.

The 'Stale jobs' line lists any scheduled automation that hasn't run recently enough (a job silently failing, or its timer broken). If it says none, omit it entirely. If it lists jobs, treat this as the lead item — a job that stopped running silently is worse than any of the health metrics above, since nothing else would ever surface it.

$FACTS"

log "generating weekly digest..."
DIGEST=$(run_agy "$PROMPT") || { log "claude failed, sending raw facts"; DIGEST="(claude unavailable — raw facts)\n\n$FACTS"; }

write_pkm "00 Capture/Daily/Agents/weekly-digest.md" "$DIGEST"
HTML=$(printf '%s' "$DIGEST" | python3 "$AGENT_HOME/lib/render_email.py" \
        "State of Your World" "Week of $(date -u '+%d %B %Y')")
send_mail "State of Your World — week of $(date -u '+%d %b')" "$HTML" html
log "done"
