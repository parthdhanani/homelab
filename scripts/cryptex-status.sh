#!/bin/bash
# cryptex-status — one-command read-only status of the whole box (evolution WP 5.1).
# Always exits 0. Problems are lines prefixed '!!'. Live numbers live HERE, not in docs.
W(){ echo "!! $*"; }

echo "== containers =="
DISABLED=$( { docker compose -f /opt/cryptex/docker-compose.yml --profile disabled config --services 2>/dev/null | sort; docker compose -f /opt/cryptex/docker-compose.yml config --services 2>/dev/null | sort; } | sort | uniq -u )
RUNNING=$(docker ps --format '{{.Names}}' | wc -l)
UNHEALTHY=$(docker ps --format '{{.Names}} {{.Status}}' | command grep -i 'unhealthy' | awk '{print $1}')
echo "running: $RUNNING (intentionally disabled: $(echo $DISABLED | wc -w))"
[ -n "$UNHEALTHY" ] && W "unhealthy: $UNHEALTHY"

echo "== backup =="
# backup pipeline migrated to /backup-stage; /backups kept as legacy fallback so a
# future path change can't silently blind this check — take whichever is newest.
SNAP_STAGE=$(docker exec cryptex-kopia kopia snapshot list /backup-stage --max-results=1 --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['startTime'])" 2>/dev/null)
SNAP_LEGACY=$(docker exec cryptex-kopia kopia snapshot list /backups --max-results=1 --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['startTime'])" 2>/dev/null)
LAST_SNAP=$(printf '%s\n%s\n' "$SNAP_STAGE" "$SNAP_LEGACY" | sort -r | head -1)
if [ -n "$LAST_SNAP" ]; then
    AGE_H=$(python3 -c "
from datetime import datetime,timezone
import re
t=re.sub(r'\.\d+','', '$LAST_SNAP').replace('Z','+00:00')
print(int((datetime.now(timezone.utc)-datetime.fromisoformat(t)).total_seconds()/3600))" 2>/dev/null)
    echo "newest kopia snapshot: ${AGE_H}h old"
    [ "${AGE_H:-99}" -gt 26 ] && W "backup snapshot older than 26h"
else
    W "could not read kopia snapshot list"
fi

echo "== units/timers =="
FAILED=$(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')
[ -n "${FAILED// /}" ] && W "failed units: $FAILED" || echo "no failed units"
for j in news monitor jobhunt ops digest github deepdive movies; do
    ST=$(systemctl show "claude-agent@${j}.service" -p ExecMainStatus --value 2>/dev/null)
    [ "${ST:-0}" != "0" ] && W "claude-agent@${j} last exit ${ST}"
done

echo "== disk/mem =="
df -h / | awk 'NR==2 {print "disk: "$3" / "$2" ("$5")"}'
free -h | awk '/^Mem:/ {print "mem:  "$3" / "$2}'
OOM=$(sudo -n journalctl -u earlyoom --since '-24h' --no-pager 2>/dev/null | command grep -ciE 'SIG(TERM|KILL) to process')
[ "${OOM:-0}" -gt 0 ] && W "earlyoom killed ${OOM} process(es) in 24h"
MEMUSE=$(free | awk '/^Mem:/{printf "%d", $3/$2*100}')
if [ "${MEMUSE:-0}" -ge 85 ]; then
    TOP3=$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null | sort -k2 -h | tail -3 | tr '\n' ';')
    W "host RAM at ${MEMUSE}% (top: $TOP3)"
fi
EXITED=$(docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' 2>/dev/null | command grep -v 'Exited (0' | head -5)
[ -n "$EXITED" ] && W "exited containers: $EXITED"
CERT_EXP=$(echo | timeout 10 openssl s_client -servername psidex.com -connect psidex.com:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$CERT_EXP" ]; then
    CERT_DAYS=$(( ($(date -d "$CERT_EXP" +%s) - $(date +%s)) / 86400 ))
    [ "$CERT_DAYS" -lt 14 ] && W "TLS cert psidex.com expires in ${CERT_DAYS}d"
fi

echo "== ob1 =="
H=$(curl -sf --max-time 3 http://172.18.0.52:8000/health || curl -sf --max-time 3 http://127.0.0.1:8000/health)
[ -n "$H" ] && echo "$H" || W "OB1 unreachable"

echo "== repos =="
for R in /home/ubuntu/.claude /home/ubuntu/AI_Space /home/ubuntu/pkm-mirror /home/ubuntu/skill-library; do
    N=$(git -C "$R" status --porcelain 2>/dev/null | wc -l); U=$(git -C "$R" rev-list @{u}..HEAD --count 2>/dev/null || echo 0)
    [ "$N" -gt 0 ] || [ "${U:-0}" -gt 0 ] && W "dirty: $R (${N} changed, ${U} unpushed)"
done
echo "(clean unless listed)"

echo "== listeners on 0.0.0.0 =="
KNOWN=''   # all five audit-flagged services rebound off 0.0.0.0 2026-07-14 — any 0.0.0.0 listener now warns
sudo -n ss -tlnp 2>/dev/null | awk '{print $4}' | command grep '^0\.0\.0\.0:' | command grep -vE ":($KNOWN)$" | command grep -v ':22$' | while read -r l; do W "unscoped listener: $l"; done
echo "(scoped/known unless listed)"

# Expected-active custom daemons that are dead (plan 2026-07-18 §2.1; catches crg-daemon-class silent deaths)
# Scope: top-level custom units in /etc/systemd/system, enabled, long-running (not oneshot), not templates.
for U in /etc/systemd/system/*.service; do
    B=$(basename "$U"); case "$B" in *@*) continue;; esac
    [ "$(systemctl is-enabled "$B" 2>/dev/null)" = "enabled" ] || continue
    [ "$(systemctl show -p Type --value "$B" 2>/dev/null)" = "oneshot" ] && continue
    systemctl is-active --quiet "$B" || W "expected-active unit dead: $B"
done
exit 0
