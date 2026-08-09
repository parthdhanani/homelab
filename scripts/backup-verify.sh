#!/bin/bash
# CRYPTEX — Weekly backup verification
# Runs kopia snapshot verify to confirm B2 backup integrity.

set -euo pipefail

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

source /opt/cryptex/.env 2>/dev/null || true

echo ""
echo "CRYPTEX Backup Verify — ${TS}"
echo "────────────────────────────"

if ! docker exec cryptex-kopia kopia repository status >/dev/null 2>&1; then
    echo "ERROR: kopia repository not connected"
    exit 1
fi

# Show last 3 snapshots
echo "Recent snapshots:"
docker exec cryptex-kopia kopia snapshot list /backup-stage --max-results=3 2>/dev/null || true

# Verify integrity of the most recent snapshot
SNAP_ID=$(docker exec cryptex-kopia kopia snapshot list /backup-stage --max-results=1 --json 2>/dev/null \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

if [ -z "$SNAP_ID" ]; then
    echo "WARNING: no snapshots found"
    exit 1
fi

echo "Verifying snapshot ${SNAP_ID} (10% sample — weekly run)..."
docker exec cryptex-kopia kopia snapshot verify --verify-files-percent=10 "${SNAP_ID}" 2>&1 \
    && echo "Verification: PASS" \
    || { echo "Verification: FAIL"; exit 1; }

# Alert success via Uptime Kuma push
curl -sf "http://172.18.0.41:3001/api/push/backup-verify-ping-2026?status=up&msg=Verify+OK" \
    >/dev/null 2>&1 || true

echo "Done."
