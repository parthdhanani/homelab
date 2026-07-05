#!/bin/bash
# CRYPTEX — Unhealthy container watchdog + disk exhaustion guard
# Runs every 5 minutes via cron.

set -euo pipefail

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source /opt/cryptex/.env 2>/dev/null || true

_alert() {
    local msg="$1"
    echo "${TS} WATCHDOG: ${msg}" >> /var/log/cryptex-watchdog.log
    if [ -n "${ADMIN_EMAIL:-}" ]; then
        printf "To: %s\nSubject: [Cryptex Watchdog] %s\nContent-Type: text/plain\n\n%s\n" \
            "$ADMIN_EMAIL" "$msg" "$msg" | msmtp --from=default "$ADMIN_EMAIL" 2>/dev/null || true
    fi
}

# ── 0. earlyoom kill detector ─────────────────────────────────
# earlyoom (installed 2026-07-05 after a 3hr memory-thrash freeze forced a
# hard reboot) SIGKILLs the worst memory hog before the whole box locks up.
# Report each new kill since last check so the culprit is never a mystery again.
EARLYOOM_MARK=/var/lib/earlyoom-watchdog.lastline
LAST_LINE=$(cat "$EARLYOOM_MARK" 2>/dev/null || echo 0)
CUR_LINE=$(journalctl -u earlyoom --no-pager -q | wc -l)
if [ "$CUR_LINE" -gt "$LAST_LINE" ]; then
    NEW_KILLS=$(journalctl -u earlyoom --no-pager -q | tail -n +$((LAST_LINE + 1)) | grep -i "sending SIGKILL" || true)
    if [ -n "$NEW_KILLS" ]; then
        _alert "🚨 earlyoom killed a process to prevent a full freeze: ${NEW_KILLS}"
    fi
fi
echo "$CUR_LINE" > "$EARLYOOM_MARK"

# ── 1. Restart unhealthy containers ──────────────────────────
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
if [ -n "$UNHEALTHY" ]; then
    for container in $UNHEALTHY; do
        docker restart "$container" >> /var/log/cryptex-watchdog.log 2>&1 || true
    done
    _alert "⚠️ Watchdog restarted: ${UNHEALTHY// /, }"
fi

# ── 2. Disk exhaustion guard ──────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

if [ "$DISK_PCT" -ge 95 ]; then
    _alert "🚨 DISK CRITICAL ${DISK_PCT}% — pruning Docker"
    docker system prune -f --filter "until=24h" >> /var/log/cryptex-watchdog.log 2>&1 || true
    # Prune old backup archives (keep last 3)
    ls -t /opt/cryptex/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    _alert "🔧 Disk prune complete — now $(df / | awk 'NR==2 {print $5}')"
elif [ "$DISK_PCT" -ge 85 ]; then
    _alert "⚠️ Disk warning ${DISK_PCT}% — manual action needed"
fi

# ── 3. Prune oversized cryptex logs (>50MB each) ─────────────
find /var/log -name "cryptex-*.log" -size +50M -exec truncate -s 10M {} \; 2>/dev/null || true
