#!/bin/bash
# CRYPTEX — Unhealthy container watchdog + disk exhaustion guard
# Runs every 5 minutes via cron.

set -euo pipefail

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source /opt/cryptex/.env 2>/dev/null || true

_alert() {
    local msg="$1"
    echo "${TS} WATCHDOG: ${msg}" >> /var/log/cryptex-watchdog.log
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -sf --max-time 5 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}&text=${msg}" \
            >/dev/null 2>&1 || true
    fi
}

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
