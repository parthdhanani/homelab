#!/bin/bash
# Monthly true-restore spot check (plan 6.1, from ops-architecture.md): restore one
# random file from the latest Kopia snapshot to a scratch dir and prove it has bytes.
# Complements weekly backup-verify.sh (hash verify) with an actual restore path test.
set -u
SNAP_ID=$(docker exec cryptex-kopia kopia snapshot list /backup-stage --max-results=1 --json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
[ -z "${SNAP_ID:-}" ] && { /home/ubuntu/.claude/scripts/notify.sh "restore spot-check FAILED" "No kopia snapshot found — backups may be broken." critical; exit 1; }

# Serialize runs: a fixed scratch path + concurrent runs = false "0 bytes" alarm (hit 2026-07-12)
exec 9>/var/lock/restore-spot-check.lock
flock -n 9 || exit 0

# kopia ls -r already prints "<snapid>/<path>" — restore that path directly
FILE=$(docker exec cryptex-kopia kopia ls -r "$SNAP_ID" 2>/dev/null | grep "^${SNAP_ID}/" | grep -v '/$' | shuf -n1)
[ -z "${FILE:-}" ] && { /home/ubuntu/.claude/scripts/notify.sh "restore spot-check FAILED" "Snapshot $SNAP_ID listed no files." critical; exit 1; }

RC_DIR="/tmp/restore-check-$$-$(date +%s)"
docker exec cryptex-kopia sh -c "mkdir -p '$RC_DIR' && kopia restore '$FILE' '$RC_DIR/f'" >/dev/null 2>&1
SIZE=$(docker exec cryptex-kopia sh -c "wc -c < '$RC_DIR/f' 2>/dev/null" | tr -d ' ')
docker exec cryptex-kopia rm -rf "$RC_DIR" 2>/dev/null

if [ "${SIZE:-0}" -gt 0 ] 2>/dev/null; then
    echo "$(date -u +%F) OK $FILE ($SIZE bytes)" >> /var/log/cryptex-restore-check.log
else
    /home/ubuntu/.claude/scripts/notify.sh "restore spot-check FAILED" "Restored '$FILE' from $SNAP_ID but got ${SIZE:-0} bytes — remote data may be corrupt. Investigate before trusting backups." critical
    exit 1
fi
