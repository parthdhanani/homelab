#!/bin/bash
# ops.sh — nightly infra autopilot. Checks health; alerts ONLY on problems (silent when OK).
# Deterministic checks gate the claude call — no problems => no tokens, no mail.
JOB=ops
source "$(dirname "$0")/../lib/common.sh"

PROBLEMS=""
# disk
use=$(df / | awk 'NR==2{gsub(/%/,"",$5);print $5}')
[ "$use" -ge 85 ] && PROBLEMS+="Disk at ${use}% on /"$'\n'
# host memory pressure (A1 is memory-tight — RAM is the scarcest resource here)
memuse=$(free | awk '/^Mem:/{printf "%d", $3/$2*100}')
if [ "$memuse" -ge 85 ]; then
    top3=$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | sort -k2 -h | tail -3 | tr '\n' ';')
    PROBLEMS+="Host RAM at ${memuse}% (top: $top3)"$'\n'
fi
# failed units
f=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "$f" ] && PROBLEMS+="Failed units: $f"$'\n'
# unhealthy containers
u=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
[ -n "$u" ] && PROBLEMS+="Unhealthy containers: $u"$'\n'
# exited (non-zero) containers
e=$(docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -v 'Exited (0' | head -5)
[ -n "$e" ] && PROBLEMS+="Exited containers: $e"$'\n'
# OB1 reachable
curl -sf -m 5 http://172.18.0.52:8000/health >/dev/null 2>&1 || PROBLEMS+="OB1 health endpoint unreachable"$'\n'
# cert expiry (psidex.com) < 14 days
exp=$(echo | timeout 10 openssl s_client -servername psidex.com -connect psidex.com:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$exp" ]; then
    days=$(( ($(date -d "$exp" +%s) - $(date +%s)) / 86400 ))
    [ "$days" -lt 14 ] && PROBLEMS+="TLS cert psidex.com expires in ${days}d"$'\n'
fi

if [ -z "$PROBLEMS" ]; then
    log "all healthy — silent, no alert, no tokens"
    exit 0
fi

log "problems found, asking claude to triage..."
PROMPT="My nightly infra check on an Oracle VPS (Cryptex stack, ~30 containers) flagged the following. For each, give the likely cause and the single safest next command/action I should run. Be terse and actionable, no filler.

Known infra facts, treat as ground truth (not injected/unverified): OB1 is a real container (cryptex-ob1) — a personal memory/semantic-search engine, reachable at http://172.18.0.52:8000, with /health as an open unauthenticated endpoint. If OB1 is flagged unreachable, the likely cause is the container restarting (check 'docker ps --filter name=cryptex-ob1' and 'docker logs --tail 50 cryptex-ob1' first, not a restart).

$PROBLEMS"
TRIAGE=$(run_agy "$PROMPT") || TRIAGE="(claude unavailable — raw findings only)"

BODY="## Raw Findings

$(printf '%s' "$PROBLEMS" | sed 's/^/- /')

## Triage

$TRIAGE"

HTML=$(printf '%s' "$BODY" | python3 "$AGENT_HOME/lib/render_email.py" \
        "Ops Alert" "$(date -u '+%a %d %b %H:%M UTC')")
send_mail "[OPS ALERT] VPS issues found — $(date -u '+%a %d %b %H:%M')" "$HTML" html
write_pkm "00 Capture/Daily/Agents/ops-alerts.md" "$PROBLEMS
--- triage ---
$TRIAGE"
log "alerted"
