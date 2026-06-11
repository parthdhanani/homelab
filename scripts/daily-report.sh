#!/bin/bash
# Daily health + container audit report writer.
# Calls health-check.sh (source of truth) — any future additions propagate automatically.
# Writes /var/log/cryptex-daily-report.json and stores summary in OB1.
# Called by cron at 06:00 UTC.

set +e

REPORT=/var/log/cryptex-daily-report.json
OB1=http://172.18.0.52:8000
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date -u +%Y-%m-%d)
HEALTH_SCRIPT=/opt/cryptex/scripts/health-check.sh

# ── Run health-check.sh (canonical per-service checks) ────────────────────────
HC_OUTPUT=$(bash "$HEALTH_SCRIPT" 2>&1)
HC_RC=$?

# Parse Results line: "Results: N OK, N WARN, N FAIL"
HC_PASS=$(echo "$HC_OUTPUT" | grep -oP 'Results: \K[0-9]+(?= OK)')
HC_WARN=$(echo "$HC_OUTPUT" | grep -oP '[0-9]+(?= WARN)')
HC_FAIL=$(echo "$HC_OUTPUT" | grep -oP '[0-9]+(?= FAIL)')
HC_PASS=${HC_PASS:-0}; HC_WARN=${HC_WARN:-0}; HC_FAIL=${HC_FAIL:-0}

# Extract failed service names ("ServiceName    FAIL" lines)
HC_FAILED=$(echo "$HC_OUTPUT" | awk '/FAIL/ && !/Results:/ {print $1}' | tr '\n' ',' | sed 's/,$//')

# ── System resources ──────────────────────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
DISK_HUMAN=$(df -h / | awk 'NR==2 {printf "%s/%s(%s)", $3, $2, $5}')
MEM_FREE=$(free -m | awk '/^Mem:/ {print $7}')
MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
TOTAL=$(docker ps -q | wc -l)

# ── High restart-rate containers (>1.0 restarts/day) ─────────────────────────
HIGH_RESTART=""
NOW_TS=$(date +%s)
while IFS= read -r line; do
    cname=$(echo "$line" | awk '{print $1}' | sed 's|^/||')
    restarts=$(echo "$line" | awk '{print $2}')
    created=$(echo "$line" | awk '{print $3}')
    [ "${restarts:-0}" -le 3 ] 2>/dev/null && continue
    created_ts=$(date -d "$created" +%s 2>/dev/null) || continue
    age_days=$(( (NOW_TS - created_ts) / 86400 ))
    [ "$age_days" -lt 1 ] && age_days=1
    # flag if restarts > age_days (i.e. rate > 1/day)
    if [ "$restarts" -gt "$age_days" ]; then
        HIGH_RESTART+="${cname}(${restarts}r/${age_days}d),"
    fi
done < <(docker inspect --format '{{.Name}} {{.RestartCount}} {{.Created}}' $(docker ps -aq) 2>/dev/null)
HIGH_RESTART=${HIGH_RESTART%,}

# ── Dockhand pending updates ──────────────────────────────────────────────────
DOCKHAND_UPDATES=$(docker logs cryptex-dockhand --tail 30 2>/dev/null \
    | grep -i "update available\|newer image" | tail -5 | tr '\n' '|')

# ── System services ───────────────────────────────────────────────────────────
AUDITD=$(systemctl is-active auditd 2>/dev/null)
IPTABLES_RULES=$(sudo iptables -L INPUT -n --line-numbers 2>/dev/null | wc -l)

# ── Backup recency ────────────────────────────────────────────────────────────
BACKUP_STATUS=$(tail -3 /var/log/cryptex-backup-verify.log 2>/dev/null | tr '\n' '|')

# ── Determine overall verdict ─────────────────────────────────────────────────
ISSUES=0
ISSUE_LIST=""

[ "$HC_FAIL" -gt 0 ]          && { ISSUES=$((ISSUES+1)); ISSUE_LIST+="services_failed:${HC_FAILED} "; }
[ "$DISK_PCT" -gt 80 ]         && { ISSUES=$((ISSUES+1)); ISSUE_LIST+="disk@${DISK_PCT}% "; }
[ "$MEM_FREE" -lt 200 ]        && { ISSUES=$((ISSUES+1)); ISSUE_LIST+="low_mem@${MEM_FREE}MB "; }
[ -n "$HIGH_RESTART" ]         && { ISSUES=$((ISSUES+1)); ISSUE_LIST+="high_restart:${HIGH_RESTART} "; }
[ "$IPTABLES_RULES" -gt 50 ]   && { ISSUES=$((ISSUES+1)); ISSUE_LIST+="iptables_bloat@${IPTABLES_RULES}rules "; }

if [ "$ISSUES" -eq 0 ]; then
    VERDICT="HEALTHY"
else
    VERDICT="NEEDS_ATTENTION"
fi

# ── Write JSON report ─────────────────────────────────────────────────────────
python3 -c "
import json
report = {
    'timestamp': '$TS',
    'date': '$DATE',
    'verdict': '$VERDICT',
    'issues': $ISSUES,
    'issue_list': '${ISSUE_LIST}'.strip(),
    'health_check': {
        'pass': $HC_PASS,
        'warn': $HC_WARN,
        'fail': $HC_FAIL,
        'failed_services': '${HC_FAILED}'.rstrip(','),
    },
    'system': {
        'disk_pct': $DISK_PCT,
        'disk_human': '$DISK_HUMAN',
        'mem_free_mb': $MEM_FREE,
        'mem_total_mb': $MEM_TOTAL,
        'containers_running': $TOTAL,
        'auditd': '$AUDITD',
        'iptables_rules': $IPTABLES_RULES,
    },
    'containers': {
        'high_restart': '${HIGH_RESTART}'.rstrip(','),
    },
    'dockhand_updates': '${DOCKHAND_UPDATES}'.rstrip('|'),
    'backup_status': '${BACKUP_STATUS}'.rstrip('|'),
}
print(json.dumps(report, indent=2))
" > "$REPORT" 2>/dev/null

# ── Notify n8n on NEEDS_ATTENTION (secondary alert path) ─────────────────────
if [ "$VERDICT" = "NEEDS_ATTENTION" ]; then
    curl -sf --max-time 5 -X POST "http://172.18.0.8:5678/webhook/health-alert" \
        -H "Content-Type: application/json" \
        -d "{\"source\":\"daily-report\",\"verdict\":\"${VERDICT}\",\"issues\":\"${ISSUE_LIST}\",\"hc_fail\":${HC_FAIL},\"timestamp\":\"${TS}\"}" \
        >/dev/null 2>&1 || true
fi

# ── Store compact summary in OB1 ──────────────────────────────────────────────
if [ "$VERDICT" = "HEALTHY" ]; then
    SUMMARY="VPS daily check ${DATE}: HEALTHY. ${HC_PASS} services OK, ${HC_WARN} warn. Disk ${DISK_HUMAN}, mem free ${MEM_FREE}MB, ${TOTAL} containers."
    [ -n "$DOCKHAND_UPDATES" ] && SUMMARY+=" Pending image updates available."
else
    SUMMARY="VPS daily check ${DATE}: NEEDS_ATTENTION. Issues: ${ISSUE_LIST}. Services: ${HC_PASS} OK, ${HC_WARN} warn, ${HC_FAIL} fail."
fi

OB1_TOKEN=$(cat /home/ubuntu/.claude/secrets/ob1.token 2>/dev/null)
curl -sf --max-time 5 -X POST "${OB1}/api/remember" \
    -H "Content-Type: application/json" \
    ${OB1_TOKEN:+-H "Authorization: Bearer $OB1_TOKEN"} \
    -d "{\"content\": \"${SUMMARY}\", \"source\": \"daily-report\", \"tags\": [\"vps\", \"health\", \"automated\"]}" \
    >/dev/null 2>&1 || true

# ── Graphify summary → OB1 (so the code graph is semantically findable) ──────
GRAPH=/opt/cryptex/graphify-out/graph.json
if [ -f "$GRAPH" ]; then
    G_SUMMARY=$(python3 -c "
import json
g = json.load(open('$GRAPH'))
nodes, edges = g.get('nodes', []), g.get('edges', [])
kinds = {}
for n in nodes:
    k = n.get('type') or n.get('kind') or '?'
    kinds[k] = kinds.get(k, 0) + 1
top = ', '.join(f'{k}:{v}' for k, v in sorted(kinds.items(), key=lambda x: -x[1])[:6])
print(f'Cryptex container knowledge graph (graphify): {len(nodes)} nodes, {len(edges)} edges. Node types: {top}. Query: /graphify query. Canonical: /opt/cryptex/graphify-out/graph.json')
" 2>/dev/null)
    # change-aware: only ingest when the graph differs from last ingest
    G_HASH=$(printf '%s' "$G_SUMMARY" | md5sum | cut -d' ' -f1)
    G_LAST=$(cat /opt/cryptex/graphify-out/.ob1-last-hash 2>/dev/null)
    [ "$G_HASH" = "$G_LAST" ] && G_SUMMARY=""
    [ -n "$G_SUMMARY" ] && echo "$G_HASH" > /opt/cryptex/graphify-out/.ob1-last-hash
    [ -n "$G_SUMMARY" ] && curl -sf --max-time 5 -X POST "${OB1}/api/remember" \
        -H "Content-Type: application/json" \
        ${OB1_TOKEN:+-H "Authorization: Bearer $OB1_TOKEN"} \
        -d "{\"content\": \"${G_SUMMARY}\", \"source\": \"graphify\", \"tags\": [\"graphify\", \"infrastructure\", \"automated\"]}" \
        >/dev/null 2>&1 || true
fi

# ── Log outcome ───────────────────────────────────────────────────────────────
echo "${TS} [${VERDICT}] hc=${HC_PASS}ok/${HC_WARN}warn/${HC_FAIL}fail disk=${DISK_PCT}% mem_free=${MEM_FREE}MB containers=${TOTAL}" \
    >> /var/log/cryptex-daily-report.log

# Exit non-zero on issues so cron-notify.sh can catch failures
[ "$VERDICT" = "NEEDS_ATTENTION" ] && exit 1
exit 0
