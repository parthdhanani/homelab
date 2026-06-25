#!/usr/bin/env bash
# 06-restore.sh — restore stateful data from the latest Kopia/B2 snapshot on a
# fresh VPS, then hand off to scripts/restore.sh for the actual per-artifact
# unpack (postgres, vaultwarden, moodledata, etc.).
#
# DESTRUCTIVE if invoked: overwrites live data/ directories. Refuses to run
# unless --confirm is passed.
#
# Why this can't just `docker exec cryptex-kopia kopia snapshot restore ... /opt/cryptex/data`:
#   - cryptex-kopia mounts /opt/cryptex/data and /opt/cryptex/backups :ro — the
#     running server container cannot write a restore anywhere on the host.
#   - the Kopia snapshot source is /backups (rotated cryptex-*.tar.gz archives),
#     not a live data/ tree — restoring it "into" data/ is the wrong shape even
#     if it could write.
# So: run a throwaway `docker run` against the kopia image with a writable
# staging mount, restore there, then feed the recovered cryptex-*.tar.gz into
# scripts/restore.sh, which already has the correct per-artifact unpack logic.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

CONFIRM="${1:-}"
if [ "$CONFIRM" != "--confirm" ]; then
  cat <<EOF
06-restore.sh — restore data from the latest Kopia/B2 snapshot.

This is a DESTRUCTIVE operation: it overwrites /opt/cryptex/data/* via
scripts/restore.sh. Only run on a FRESH VPS during disaster recovery, never
on a live stack.

Re-run with:   ./06-restore.sh --confirm

Prerequisites:
  - .env contains valid KOPIA_PASSWORD and B2 credentials (03-secrets.sh)
  - cryptex-kopia's repository config already exists at
    /opt/cryptex/data/kopia/config (run 04-stack.sh once so the container
    creates it, or restore kopia-config/ from a local cryptex-*.tar.gz first)

What it does:
  1. Restores the latest Kopia snapshot of /backups into a writable staging
     dir (via a throwaway kopia container, not the read-only server mount)
  2. Locates the recovered cryptex-*.tar.gz inside the staging dir
  3. Hands off to scripts/restore.sh, which does the real per-artifact
     restore (postgres, vaultwarden, moodledata, forgejo, traxlrs, etc.)
  4. Restarts the stack

EOF
  exit 0
fi

require_user
log "============ 06-restore: kopia restore ============"

cd "$REPO_ROOT"

KOPIA_IMAGE="kopia/kopia:0.23.1"
KOPIA_CONFIG="$REPO_ROOT/data/kopia/config"
KOPIA_CACHE="$REPO_ROOT/data/kopia/cache"
STAGING_DIR="$REPO_ROOT/restore-staging"

[ -f "$KOPIA_CONFIG/repository.config" ] || fail "no kopia repository config at $KOPIA_CONFIG/repository.config — run 04-stack.sh first so kopia connects, or manually 'kopia repository connect b2' with values from .env"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$KOPIA_CACHE"

log "listing available snapshots..."
docker run --rm \
  -e KOPIA_PASSWORD="${KOPIA_PASSWORD}" \
  -e KOPIA_CONFIG_PATH=/app/config/repository.config \
  -e KOPIA_CACHE_DIRECTORY=/app/cache \
  -v "$KOPIA_CONFIG:/app/config:ro" \
  -v "$KOPIA_CACHE:/app/cache" \
  "$KOPIA_IMAGE" snapshot list --json 2>/dev/null \
  | jq -r '.[] | "\(.startTime)  \(.id)  \(.source.path)"' \
  | tail -20 || warn "could not list snapshots"

read -r -p "Snapshot ID to restore (or 'latest'): " SNAP
[ -z "$SNAP" ] && SNAP="latest"

if [ "$SNAP" = "latest" ]; then
  SNAP=$(docker run --rm \
    -e KOPIA_PASSWORD="${KOPIA_PASSWORD}" \
    -e KOPIA_CONFIG_PATH=/app/config/repository.config \
    -e KOPIA_CACHE_DIRECTORY=/app/cache \
    -v "$KOPIA_CONFIG:/app/config:ro" \
    -v "$KOPIA_CACHE:/app/cache" \
    "$KOPIA_IMAGE" snapshot list --json 2>/dev/null | jq -r '.[-1].id')
  [ -n "$SNAP" ] && [ "$SNAP" != "null" ] || fail "could not resolve latest snapshot id"
fi

log "restoring snapshot $SNAP into staging dir (writable, host-side)..."
docker run --rm \
  -e KOPIA_PASSWORD="${KOPIA_PASSWORD}" \
  -e KOPIA_CONFIG_PATH=/app/config/repository.config \
  -e KOPIA_CACHE_DIRECTORY=/app/cache \
  -v "$KOPIA_CONFIG:/app/config:ro" \
  -v "$KOPIA_CACHE:/app/cache" \
  -v "$STAGING_DIR:/restore" \
  "$KOPIA_IMAGE" snapshot restore "$SNAP" /restore   # no --shallow: full restore (--shallow=0 writes .kopia-entry placeholders, breaking DR)

RESTORED_ARCHIVE=$(ls -t "$STAGING_DIR"/cryptex-*.tar.gz 2>/dev/null | head -1)
[ -n "$RESTORED_ARCHIVE" ] || fail "no cryptex-*.tar.gz found in restored snapshot at $STAGING_DIR — inspect manually"
log "recovered: $RESTORED_ARCHIVE"

log "handing off to scripts/restore.sh for per-artifact unpack..."
"$REPO_ROOT/scripts/restore.sh" "$RESTORED_ARCHIVE"

rm -rf "$STAGING_DIR"

log "============ 06-restore: complete ============"
