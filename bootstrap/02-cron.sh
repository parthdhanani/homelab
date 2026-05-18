#!/usr/bin/env bash
# 02-cron.sh — install cryptex-managed crontabs for root + ubuntu.
# Idempotent. Re-installing the same crontab is a no-op.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
require_root

log "============ 02-cron: scheduled jobs ============"

if [ -f "$REPO_ROOT/system/cron/root.crontab" ]; then
  install_cron root "$REPO_ROOT/system/cron/root.crontab"
fi

if [ -f "$REPO_ROOT/system/cron/ubuntu.crontab" ]; then
  install_cron ubuntu "$REPO_ROOT/system/cron/ubuntu.crontab"
fi

# Ensure log targets exist so first cron run doesn't fail on missing logs
for log_path in \
  /var/log/cryptex-backup.log \
  /var/log/cryptex-backup-verify.log \
  /var/log/cryptex-update.log \
  /var/log/cryptex-updates.log \
  /var/log/cryptex-prune.log \
  /var/log/cryptex-notes.log \
  /var/log/cryptex-moodle-cron.log
do
  touch "$log_path"
  chown ubuntu:ubuntu "$log_path" 2>/dev/null || true
done
ok "log files ensured"

systemctl enable --quiet cron
systemctl start cron 2>/dev/null || true

log "============ 02-cron: complete ============"
