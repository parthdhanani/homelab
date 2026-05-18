#!/bin/bash
# sync-pkm.sh — Sync PKM vault from iCloud to VPS (Mac-side, run via launchd)
#
# Direction: iCloud (Mac) → VPS /opt/cryptex/data/pkm
# VPS is the source of truth. This script pushes Mac iCloud copy to VPS.
# WebDAV edits (iPhone/Finder) write directly to VPS — no sync needed from VPS back.
#
# Install:
#   1. Copy sync-pkm.plist to ~/Library/LaunchAgents/
#   2. launchctl load ~/Library/LaunchAgents/com.cryptex.sync-pkm.plist
#   3. Runs every 15 minutes automatically

set -euo pipefail

VAULT_LOCAL="${HOME}/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM"
VPS_HOST="oracle"   # SSH alias from ~/.ssh/config
VPS_PATH="/opt/cryptex/data/pkm"
LOG="${HOME}/.local/log/cryptex-pkm-sync.log"
LOCK="/tmp/cryptex-pkm-sync.lock"

mkdir -p "$(dirname "$LOG")"

# Prevent overlapping runs
if [ -f "$LOCK" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: previous sync still running" >> "$LOG"
    exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing PKM to VPS..." >> "$LOG"

if rclone sync \
    "${VAULT_LOCAL}" \
    "${VPS_HOST}:${VPS_PATH}" \
    --sftp-host oracle \
    --transfers 4 \
    --checkers 8 \
    --filter "- .DS_Store" \
    --filter "- .obsidian/workspace.json" \
    --filter "- .obsidian/workspace-mobile.json" \
    --filter "- *.tmp" \
    --conflict-resolve newer \
    --log-file "$LOG" \
    --log-level INFO \
    2>>"$LOG"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync complete" >> "$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: sync failed (exit $?)" >> "$LOG"
fi
