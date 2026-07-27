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

# Generic pass: install EVERY unit mirrored by backup.sh (the hardcoded list above
# is kept for must-haves; this catches everything else so new units survive DR).
shopt -s nullglob
for src in "$REPO_ROOT"/system/systemd/*.service "$REPO_ROOT"/system/systemd/*.timer; do
  u="$(basename "$src")"
  dst="/etc/systemd/system/$u"
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    install -m 644 "$src" "$dst"
    log "installed $u"
  fi
done
shopt -u nullglob
systemctl daemon-reload

# Re-enable exactly what was enabled on the source box (captured nightly by backup.sh)
if [ -f "$REPO_ROOT/system/systemd/enabled.list" ]; then
  while read -r u; do
    case "$u" in
      *.timer|*.service)
        [ -f "/etc/systemd/system/$u" ] && systemctl enable "$u" 2>/dev/null || true
        ;;
    esac
  done < "$REPO_ROOT/system/systemd/enabled.list"
  log "re-enabled units from enabled.list"
fi

log "============ 01-systemd: complete ============"
