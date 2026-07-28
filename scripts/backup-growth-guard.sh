#!/bin/bash
# CRYPTEX — Backup growth guard
#
# Why this exists: on 2026-07-13/14 a deleted Uptime Kuma push monitor (id 36)
# wrote 6.5M orphaned heartbeat rows in a millisecond loop. kuma.db went
# 17 MB -> 1.1 GB (64x) and every nightly tarball carried it to Backblaze B2.
# Nothing alerted. It was found only when the B2 free tier hit 74%.
#
# The multiplier that makes this dangerous: kopia retains 7 daily + 4 weekly
# + 2 monthly snapshots, each capturing the whole /backups dir (7 tarballs).
# Because the tarballs are gzipped, kopia cannot dedup them, so ~55 distinct
# tarballs are referenced at any time. Every 1 MB the daily tarball grows costs
# roughly 55 MB in B2. A silent 190 MB/day regression eats the entire 10 GB tier.
#
# Read-only. Alerts, never deletes.

set -uo pipefail

STATE_DIR="/var/lib/cryptex"
STATE="${STATE_DIR}/growth-guard.state"
BACKUP_DIR="/opt/cryptex/backups"
mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source /opt/cryptex/.env 2>/dev/null || true

ALERTS=()

# ── 1. Nightly tarball size, vs the last run ───────────────────────────────
LATEST=$(ls -t "${BACKUP_DIR}"/cryptex-*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    CUR_MB=$(( $(stat -c%s "$LATEST") / 1024 / 1024 ))
    PREV_MB=$(awk -F= '/^tarball_mb=/{print $2}' "$STATE" 2>/dev/null)
    PREV_MB=${PREV_MB:-0}

    # Absolute ceiling. Steady state after the 2026-07-28 cleanup is ~40 MB.
    if [ "$CUR_MB" -gt 400 ]; then
        ALERTS+=("Nightly tarball ${CUR_MB}MB exceeds 400MB ceiling (~$(( CUR_MB * 55 / 1024 ))GB of B2 pressure)")
    fi
    # Sudden jump. Catches a runaway on day one rather than at quota.
    if [ "$PREV_MB" -gt 20 ] && [ "$CUR_MB" -gt $(( PREV_MB * 2 )) ]; then
        ALERTS+=("Nightly tarball doubled: ${PREV_MB}MB -> ${CUR_MB}MB")
    fi
else
    CUR_MB=0
    ALERTS+=("No nightly tarball found in ${BACKUP_DIR}")
fi

# ── 2. Backup freshness — a stalled backup is as bad as a bloated one ──────
if [ -n "$LATEST" ]; then
    AGE_H=$(( ( $(date +%s) - $(stat -c%Y "$LATEST") ) / 3600 ))
    [ "$AGE_H" -gt 36 ] && ALERTS+=("Newest backup is ${AGE_H}h old (expected <36h)")
fi

# ── 3. The specific 2026-07-28 failure mode: orphaned heartbeat rows ───────
# Rows whose monitor was deleted. These grow without bound and no Kuma
# retention setting removes them (they are dense, not old).
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx cryptex-uptime-kuma; then
    ORPHANS=$(docker exec cryptex-uptime-kuma sqlite3 /app/data/kuma.db \
        "SELECT COUNT(*) FROM heartbeat h LEFT JOIN monitor m ON m.id=h.monitor_id WHERE m.id IS NULL;" 2>/dev/null)
    if [ -n "${ORPHANS:-}" ] && [ "$ORPHANS" -gt 50000 ]; then
        ALERTS+=("Uptime Kuma has ${ORPHANS} orphaned heartbeat rows (deleted monitors) — delete by monitor_id, retention will NOT clear these")
    fi
    KUMA_MB=$(( $(stat -c%s /opt/cryptex/data/uptime-kuma/kuma.db 2>/dev/null || echo 0) / 1024 / 1024 ))
    [ "$KUMA_MB" -gt 200 ] && ALERTS+=("kuma.db is ${KUMA_MB}MB (steady state ~5MB)")
fi

# ── 4. B2 headroom — the actual resource that runs out ─────────────────────
B2_BYTES=$(docker exec cryptex-kopia kopia blob stats --raw 2>/dev/null | awk '/Total:/{print $2}')
if [ -n "${B2_BYTES:-}" ] && [ "$B2_BYTES" -gt 0 ] 2>/dev/null; then
    B2_PCT=$(( B2_BYTES * 100 / 10737418240 ))   # 10 GB free tier
    [ "$B2_PCT" -ge 80 ] && ALERTS+=("Backblaze B2 at ${B2_PCT}% of the 10GB free tier")
fi

# ── Persist state for next run's delta comparison ──────────────────────────
printf 'tarball_mb=%s\nchecked=%s\n' "$CUR_MB" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE"

# ── Report ────────────────────────────────────────────────────────────────
if [ ${#ALERTS[@]} -eq 0 ]; then
    echo "growth-guard OK — tarball ${CUR_MB}MB, B2 ${B2_PCT:-?}%"
    exit 0
fi

MSG="CRYPTEX backup growth guard:"
for a in "${ALERTS[@]}"; do MSG="${MSG}"$'\n'"- ${a}"; done
echo "$MSG"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -sf --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=⚠️ ${MSG}" >/dev/null 2>&1 || true
fi
exit 1
