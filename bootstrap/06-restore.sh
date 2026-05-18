#!/usr/bin/env bash
# 06-restore.sh — optionally restore stateful volumes from Kopia backups.
# DESTRUCTIVE if invoked: will overwrite data/ directories from the latest snapshot.
# Refuses to run unless --confirm flag passed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CONFIRM="${1:-}"
if [ "$CONFIRM" != "--confirm" ]; then
  cat <<EOF
06-restore.sh — restore data volumes from Kopia.

This is a DESTRUCTIVE operation: it overwrites /opt/cryptex/data/* from the
latest snapshot of your Kopia repository. Only run on a FRESH VPS during
disaster recovery, never on a live stack.

Re-run with:   ./06-restore.sh --confirm

Prerequisites:
  - Kopia container running ( docker ps | grep cryptex-kopia )
  - .env contains valid KOPIA_PASSWORD and B2 credentials
  - You know which snapshot to restore (latest by default)

What it does:
  1. Stops all containers (compose down)
  2. Connects to the Kopia repo
  3. Restores latest snapshot of /opt/cryptex/data into place
  4. Restarts the stack

EOF
  exit 0
fi

require_user
log "============ 06-restore: kopia restore ============"

cd "$REPO_ROOT"

# Sanity: ensure kopia container is reachable
if ! docker ps --format '{{.Names}}' | grep -q '^cryptex-kopia$'; then
  fail "cryptex-kopia container not running. Start the stack first (04-stack.sh) so kopia is up."
fi

# List available snapshots
log "available snapshots:"
docker exec cryptex-kopia kopia snapshot list --json 2>/dev/null \
  | jq -r '.[] | "\(.startTime)  \(.id)  \(.source.path)"' \
  | tail -20 || warn "could not list snapshots"

read -r -p "Snapshot ID to restore (or 'latest'): " SNAP
[ -z "$SNAP" ] && SNAP="latest"

log "stopping stack..."
docker compose down

log "restoring..."
if [ "$SNAP" = "latest" ]; then
  docker exec cryptex-kopia kopia snapshot restore \
    --shallow=0 \
    "$(docker exec cryptex-kopia kopia snapshot list --json | jq -r '.[-1].id')" \
    /opt/cryptex/data
else
  docker exec cryptex-kopia kopia snapshot restore --shallow=0 "$SNAP" /opt/cryptex/data
fi

log "restarting stack..."
docker compose up -d

log "============ 06-restore: complete ============"
