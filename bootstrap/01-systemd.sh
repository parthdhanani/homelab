#!/usr/bin/env bash
# 01-systemd.sh — install custom systemd units for cryptex/PKM/iptables-save
# Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
require_root

log "============ 01-systemd: custom units ============"

# Units that must always be present
UNITS=(
  iptables-save.service
  iptables-save.timer
  pkm-watcher.service
  cryptex-graphify-update.service
  cryptex-graphify-update.timer
)

for u in "${UNITS[@]}"; do
  if [ -f "$REPO_ROOT/system/systemd/$u" ]; then
    ensure_systemd_unit "$u"
  else
    warn "missing source for $u — skipping"
  fi
done

log "============ 01-systemd: complete ============"
