#!/bin/bash
# CRYPTEX system monitor — run with: watch -n60 monitor
# Shows full system state in one screen. Safe to run anytime.

set +e

# ── Colors (tput, degrades gracefully if not a tty) ───────────────────────────
if [ -t 1 ]; then
    RED=$(tput setaf 1); YEL=$(tput setaf 3); GRN=$(tput setaf 2)
    CYN=$(tput setaf 6); BLD=$(tput bold); DIM=$(tput dim); RST=$(tput sgr0)
else
    RED=""; YEL=""; GRN=""; CYN=""; BLD=""; DIM=""; RST=""
fi

ok()   { printf "${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "${YEL}⚠${RST} %s\n" "$*"; }
fail() { printf "${RED}✗${RST} %s\n" "$*"; }
hdr()  { printf "\n${BLD}${CYN}%-20s${RST}\n" "$*"; }

age_str() {
    # age_str <epoch_seconds>  →  "3m" / "2h" / "4d"
    local secs=$(( $(date +%s) - $1 ))
    if   [ $secs -lt 3600 ];   then echo "$(( secs/60 ))m ago"
    elif [ $secs -lt 86400 ];  then echo "$(( secs/3600 ))h ago"
    else echo "$(( secs/86400 ))d ago"
    fi
}

NOW=$(date -u +%s)
printf "${BLD}CRYPTEX MONITOR${RST}  $(date -u '+%Y-%m-%d %H:%M UTC')\n"
printf '%.0s─' {1..60}; echo

# ── VPS daily report ──────────────────────────────────────────────────────────
hdr "VPS STATE"
REPORT=/var/log/cryptex-daily-report.json
if [ -f "$REPORT" ]; then
    TS_EPOCH=$(date -d "$(python3 -c "import json; print(json.load(open('$REPORT'))['timestamp'])" 2>/dev/null)" +%s 2>/dev/null || echo 0)
    AGE=$(age_str $TS_EPOCH)
    python3 - "$REPORT" "$AGE" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
age = sys.argv[2]
v = r['verdict']
hc = r.get('health_check', {})
s = r['system']
ok_sym  = '\033[32m✓\033[0m' if v == 'HEALTHY' else '\033[31m✗\033[0m'
color   = '\033[32m' if v == 'HEALTHY' else '\033[31m'
print(f"  {ok_sym} {color}{v}\033[0m  ({age})  disk {s['disk_human']}  mem {s['mem_free_mb']}MB free  {s['containers_running']} containers")
if hc:
    svc_line = f"  Services: {hc.get('pass',0)} ok"
    if hc.get('warn',0): svc_line += f"  \033[33m{hc['warn']} warn\033[0m"
    if hc.get('fail',0): svc_line += f"  \033[31m{hc['fail']} FAIL — {hc.get('failed_services','?')}\033[0m"
    print(svc_line)
if r.get('issue_list'):
    print(f"  Issues: \033[33m{r['issue_list']}\033[0m")
if r.get('dockhand_updates'):
    print(f"  \033[33m⚠ Image updates pending\033[0m")
PY
else
    fail "daily-report.json missing — cron may not have run"
fi

# ── OB1 ───────────────────────────────────────────────────────────────────────
hdr "TOOLING"
OB1_RESP=$(curl -sf --max-time 8 http://172.18.0.52:8000/health 2>/dev/null)
if [ -n "$OB1_RESP" ]; then
    MEM_COUNT=$(echo "$OB1_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('memories','?'))" 2>/dev/null)
    ok "OB1  ($MEM_COUNT memories)"
else
    fail "OB1  unreachable — context recall disabled"
fi

# PKM watcher
PKM_STATUS=$(systemctl is-active pkm-watcher.service 2>/dev/null)
if [ "$PKM_STATUS" = "active" ]; then
    PKM_PID=$(systemctl show pkm-watcher.service -p MainPID --value 2>/dev/null)
    PKM_SINCE=$(systemctl show pkm-watcher.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
    ok "PKM watcher  active"
else
    fail "PKM watcher  $PKM_STATUS"
fi

# Graphify index
GRAPH_PATHS=("graphify-out/graph.json" "/opt/cryptex/scripts/graphify-out/graph.json")
GRAPH_FOUND=0
for GP in "${GRAPH_PATHS[@]}"; do
    if [ -f "$GP" ]; then
        NODES=$(python3 -c "import json; g=json.load(open('$GP')); print(len(g.get('nodes',[])))" 2>/dev/null || echo "?")
        GRAPH_AGE=$(age_str $(stat -c %Y "$GP"))
        AGE_DAYS=$(( (NOW - $(stat -c %Y "$GP")) / 86400 ))
        if [ $AGE_DAYS -gt 7 ]; then
            warn "Graphify  $NODES nodes  ${GRAPH_AGE}  ${DIM}(stale — /graphify --update)${RST}"
        else
            ok "Graphify  $NODES nodes  ${GRAPH_AGE}"
        fi
        GRAPH_FOUND=1; break
    fi
done
[ $GRAPH_FOUND -eq 0 ] && printf "  ${DIM}Graphify  no index${RST}\n"

# understand-anything
if [ -f ".understand-anything/meta.json" ]; then
    UA_DATE=$(python3 -c "import json; print(json.load(open('.understand-anything/meta.json')).get('lastAnalyzedAt','?')[:10])" 2>/dev/null)
    UA_FILES=$(python3 -c "import json; print(json.load(open('.understand-anything/meta.json')).get('analyzedFiles','?'))" 2>/dev/null)
    ok "Understand  $UA_FILES files  $UA_DATE"
else
    printf "  ${DIM}Understand  no index in $(pwd)${RST}\n"
fi

# ── Cron last runs ────────────────────────────────────────────────────────────
hdr "CRON (last run)"

cron_age() {
    local logfile="$1" label="$2"
    if [ -f "$logfile" ]; then
        local mtime=$(stat -c %Y "$logfile")
        local age=$(age_str $mtime)
        local since=$(( (NOW - mtime) / 3600 ))
        if [ $since -gt 28 ]; then
            warn "$label  $age"
        else
            printf "  ${GRN}·${RST} %-24s %s\n" "$label" "$age"
        fi
    else
        printf "  ${DIM}· %-24s no log${RST}\n" "$label"
    fi
}

cron_age /var/log/cryptex-daily-report.log   "daily-report (6am)"
cron_age /var/log/cryptex-updates.log        "container-notify (9am)"
cron_age /var/log/cryptex-backup.log         "backup (3am)"
cron_age /var/log/cryptex-backup-verify.log  "backup-verify (monthly)"
cron_age /var/log/cryptex-notes.log          "notes-build (15min)"

# health-check: log only written on failure — infer from cron process or last crontab run
HC_LOG=/var/log/cryptex-health.log
HC_CRON_ALIVE=$(pgrep -f "health-check-cron.sh" >/dev/null 2>&1 && echo "running" || echo "idle")
if [ -f "$HC_LOG" ]; then
    HC_LAST=$(stat -c %Y "$HC_LOG")
    printf "  ${GRN}·${RST} %-24s last FAIL $(age_str $HC_LAST)\n" "health-check (5min)"
else
    printf "  ${GRN}·${RST} %-24s running — no failures recorded\n" "health-check (5min)"
fi

# ── Claude Code usage (today / this month) ───────────────────────────────────
hdr "CLAUDE USAGE"
if command -v ccusage >/dev/null 2>&1; then
    TODAY=$(ccusage claude daily --no-color 2>/dev/null | grep "│ $(date +%Y-%m-%d)" | awk -F'│' '{gsub(/ /,"",$9); print $9}')
    MONTH=$(ccusage claude monthly --no-color 2>/dev/null | grep "│ Total" | awk -F'│' '{gsub(/ /,"",$9); print $9}')
    [ -n "$TODAY" ] && printf "  ${CYN}·${RST} Today:  %s\n" "$TODAY"
    [ -n "$MONTH" ] && printf "  ${CYN}·${RST} Month:  %s\n" "$MONTH"
    [ -z "$TODAY" ] && [ -z "$MONTH" ] && printf "  ${DIM}· no usage data yet today${RST}\n"
    printf "  ${DIM}  run: ccusage  for full TUI${RST}\n"
else
    printf "  ${DIM}· ccusage not installed${RST}\n"
fi

# ── Recent failures ───────────────────────────────────────────────────────────
HC_FAILS=$(tail -20 /var/log/cryptex-health.log 2>/dev/null | grep "FAIL" | tail -3)
if [ -n "$HC_FAILS" ]; then
    hdr "RECENT FAILURES"
    echo "$HC_FAILS" | while read -r line; do
        printf "  ${RED}!${RST} %s\n" "$line"
    done
fi

echo ""
printf "${DIM}Run with: watch -n60 monitor   |   /monitor in Claude for analysis${RST}\n"
