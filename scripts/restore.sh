#!/bin/bash
# CRYPTEX — Disaster Recovery Restore Script
# Use after fresh VPS provision to restore from backup.
#
# Usage:
#   ./scripts/restore.sh                         # interactive: pick backup from local /opt/cryptex/backups/
#   ./scripts/restore.sh <path-to-backup.tar.gz> # explicit backup file
#
# Prerequisites:
#   - Fresh VPS with Docker + Compose installed (run deploy.sh first, then this)
#   - OR: run this before deploy.sh, then deploy.sh will skip first-run steps
#   - .env must exist (restore it manually from backup or re-run setup-env.sh)

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
cd "$COMPOSE_DIR"

# shellcheck disable=SC1090
source "${COMPOSE_DIR}/.env"

echo ""
echo "CRYPTEX Disaster Recovery Restore"
echo "────────────────────────────────"
echo ""

# ── Select backup file ──

if [ -n "${1:-}" ]; then
    BACKUP_FILE="$1"
else
    # List available local backups
    mapfile -t BACKUPS < <(ls -t "${COMPOSE_DIR}/backups"/cryptex-*.tar.gz 2>/dev/null || true)
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "ERROR: No local backups found in ${COMPOSE_DIR}/backups/"
        echo ""
        echo "To restore from B2 (Kopia):"
        echo "  docker exec cryptex-kopia kopia snapshot list /backups"
        echo "  docker exec cryptex-kopia kopia restore <snapshot-id> /backups/restored/"
        echo "  Then extract and run: ./scripts/restore.sh /opt/cryptex/backups/cryptex-YYYYMMDD_HHMMSS.tar.gz"
        exit 1
    fi

    echo "Available backups:"
    for i in "${!BACKUPS[@]}"; do
        SIZE=$(du -h "${BACKUPS[$i]}" | cut -f1)
        printf "  [%d] %s (%s)\n" "$((i+1))" "$(basename "${BACKUPS[$i]}")" "$SIZE"
    done
    echo ""
    read -rp "Select backup [1]: " sel
    sel="${sel:-1}"
    BACKUP_FILE="${BACKUPS[$((sel-1))]}"
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "Restoring from: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
echo ""

# ── Validate backup integrity ──

echo "Validating backup integrity..."
if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "ERROR: Backup tarball is corrupt"
    exit 1
fi
echo "  Tarball: OK"

# ── Extract backup ──

RESTORE_TMP=$(mktemp -d)
trap 'rm -rf "$RESTORE_TMP"' EXIT

echo "Extracting..."
tar -xzf "$BACKUP_FILE" -C "$RESTORE_TMP"
# The backup contains a timestamped subdirectory
RESTORE_PATH=$(find "$RESTORE_TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
echo "  Extracted to: $RESTORE_PATH"
echo ""

# ── Restore the full .env from the snapshot ──
# DR only needs a skeleton .env (B2 + Kopia creds) to PULL the snapshot; the
# snapshot's dot-env is the complete 106-key .env. Apply it so the restarted
# stack gets every secret, not just the bootstrap subset. (.env.pre-restore.bak
# is gitignored.)
if [ -f "${RESTORE_PATH}/dot-env" ]; then
    echo "Restoring full .env from backup..."
    cp "${COMPOSE_DIR}/.env" "${COMPOSE_DIR}/.env.pre-restore.bak" 2>/dev/null || true
    cp "${RESTORE_PATH}/dot-env" "${COMPOSE_DIR}/.env"
    # shellcheck disable=SC1090
    source "${COMPOSE_DIR}/.env"
    echo "  .env: restored full (skeleton saved to .env.pre-restore.bak)"
fi

# ── Stop running containers (except postgres — restore directly) ──

echo "Stopping containers for restore..."
docker compose stop moodle traxlrs n8n vaultwarden forgejo miniflux actualbudget uptime-kuma 2>/dev/null || true

# ── Restore PostgreSQL ──

if [ -f "${RESTORE_PATH}/postgres_all.sql" ]; then
    echo "Restoring PostgreSQL..."
    # Validate SQL before loading
    DUMP_SIZE=$(wc -c < "${RESTORE_PATH}/postgres_all.sql")
    if [ "$DUMP_SIZE" -lt 10000 ]; then
        echo "  ERROR: SQL dump too small (${DUMP_SIZE} bytes) — skipping"
    else
        # Drop and recreate databases (pg_dumpall creates them)
        docker exec cryptex-postgres psql -U "${POSTGRES_USER}" -c "
            SELECT pg_terminate_backend(pid) FROM pg_stat_activity
            WHERE pid <> pg_backend_pid() AND datname IN ('moodle','n8n','tianji','traxlrs','forgejo','miniflux');
        " 2>/dev/null || true
        docker exec -i cryptex-postgres psql -U "${POSTGRES_USER}" < "${RESTORE_PATH}/postgres_all.sql"
        echo "  PostgreSQL: restored"
    fi
else
    echo "  WARNING: postgres_all.sql not found in backup — skipping DB restore"
fi

# ── Restore OB1 pgvector ──

if [ -f "${RESTORE_PATH}/pgvector_ob1.sql" ]; then
    echo "Restoring OB1 pgvector..."
    DUMP_SIZE=$(wc -c < "${RESTORE_PATH}/pgvector_ob1.sql")
    if [ "$DUMP_SIZE" -lt 1000 ]; then
        echo "  ERROR: pgvector dump too small (${DUMP_SIZE} bytes) — skipping"
    elif docker inspect cryptex-pgvector >/dev/null 2>&1; then
        docker exec -i cryptex-pgvector psql -U ob1 ob1 < "${RESTORE_PATH}/pgvector_ob1.sql"
        echo "  OB1 pgvector: restored"
    else
        echo "  WARNING: cryptex-pgvector container not found — skipping pgvector restore"
    fi
else
    echo "  WARNING: pgvector_ob1.sql not found in backup — skipping OB1 memory restore"
fi

# ── Restore Vaultwarden ──

if [ -d "${RESTORE_PATH}/vaultwarden" ]; then
    echo "Restoring Vaultwarden..."
    mkdir -p "${COMPOSE_DIR}/data/vaultwarden"
    cp -r "${RESTORE_PATH}/vaultwarden/." "${COMPOSE_DIR}/data/vaultwarden/"
    echo "  Vaultwarden: restored (db + keys + attachments)"
elif [ -f "${RESTORE_PATH}/vaultwarden.sqlite3" ]; then
    # Legacy backups stored only the bare DB file. Restore it so the vault isn't lost;
    # rsa_key/attachments weren't captured in that format (re-login required after restore).
    echo "Restoring Vaultwarden (legacy db-only backup)..."
    mkdir -p "${COMPOSE_DIR}/data/vaultwarden"
    cp "${RESTORE_PATH}/vaultwarden.sqlite3" "${COMPOSE_DIR}/data/vaultwarden/db.sqlite3"
    echo "  Vaultwarden: db restored (legacy format — rsa_key/attachments not present)"
fi

# ── Restore Moodle data ──

if [ -f "${RESTORE_PATH}/moodledata.tar.gz" ]; then
    echo "Restoring Moodle data..."
    tar -xzf "${RESTORE_PATH}/moodledata.tar.gz" -C "${COMPOSE_DIR}/data/"
    sudo chown -R 33:33 "${COMPOSE_DIR}/data/moodledata" 2>/dev/null || true
    echo "  Moodle data: restored"
fi

# ── Restore Forgejo repos ──

if [ -f "${RESTORE_PATH}/forgejo.tar.gz" ]; then
    echo "Restoring Forgejo..."
    tar -xzf "${RESTORE_PATH}/forgejo.tar.gz" -C "${COMPOSE_DIR}/data/"
    echo "  Forgejo: restored"
fi

# ── Restore TRAX LRS storage ──

if [ -f "${RESTORE_PATH}/traxlrs.tar.gz" ]; then
    echo "Restoring TRAX LRS storage..."
    tar -xzf "${RESTORE_PATH}/traxlrs.tar.gz" -C "${COMPOSE_DIR}/data/"
    echo "  TRAX LRS: restored"
fi

# ── Restore AdGuard config ──

if [ -d "${RESTORE_PATH}/adguard-conf" ]; then
    echo "Restoring AdGuard config..."
    mkdir -p "${COMPOSE_DIR}/data/adguard/conf"
    cp -r "${RESTORE_PATH}/adguard-conf/." "${COMPOSE_DIR}/data/adguard/conf/"
    echo "  AdGuard: restored"
fi

# ── Restore Kopia connection config ──

if [ -d "${RESTORE_PATH}/kopia-config" ]; then
    echo "Restoring Kopia config (B2 connection)..."
    mkdir -p "${COMPOSE_DIR}/data/kopia/config"
    cp -r "${RESTORE_PATH}/kopia-config/." "${COMPOSE_DIR}/data/kopia/config/"
    echo "  Kopia: restored (reconnects to B2 on next start)"
fi

# ── Restore n8n encryption key ──

if [ -f "${RESTORE_PATH}/n8n-config" ]; then
    echo "Restoring n8n config..."
    mkdir -p "${COMPOSE_DIR}/data/n8n"
    cp "${RESTORE_PATH}/n8n-config" "${COMPOSE_DIR}/data/n8n/config"
    echo "  n8n encryption key: restored"
fi

# ── Restore ActualBudget ──

if [ -f "${RESTORE_PATH}/actualbudget.tar.gz" ]; then
    echo "Restoring ActualBudget..."
    tar -xzf "${RESTORE_PATH}/actualbudget.tar.gz" -C "${COMPOSE_DIR}/data/"
    sudo chown -R 1000:1000 "${COMPOSE_DIR}/data/actualbudget" 2>/dev/null || true
    echo "  ActualBudget: restored"
fi

# ── Restore PKM vault ──

if [ -f "${RESTORE_PATH}/pkm.tar.gz" ]; then
    echo "Restoring PKM vault..."
    tar -xzf "${RESTORE_PATH}/pkm.tar.gz" -C "${COMPOSE_DIR}/data/"
    echo "  PKM: restored"
fi

# rclone.conf (OpenList cloud drive tokens) lives at ~/.config/rclone/rclone.conf on the
# host, not under /opt/cryptex — not captured by backup.sh. Re-add drives manually after
# restore (tracked as a pending OpenList reconfiguration item regardless).

# ── Restore Uptime Kuma (monitors, history, alerts) ──

if [ -f "${RESTORE_PATH}/uptime-kuma.tar.gz" ]; then
    echo "Restoring Uptime Kuma..."
    tar -xzf "${RESTORE_PATH}/uptime-kuma.tar.gz" -C "${COMPOSE_DIR}/data/"
    echo "  Uptime Kuma: restored"
fi

# ── Restore SCORM import script ──

if [ -f "${RESTORE_PATH}/scorm-import.php" ]; then
    echo "Restoring SCORM import script..."
    mkdir -p "${COMPOSE_DIR}/data/moodle-uploads"
    cp "${RESTORE_PATH}/scorm-import.php" "${COMPOSE_DIR}/data/moodle-uploads/scorm-import.php"
    sudo chown 1000:33 "${COMPOSE_DIR}/data/moodle-uploads/scorm-import.php" 2>/dev/null || true
    echo "  scorm-import.php: restored"
fi

# ── Restart containers ──

echo ""
echo "Restarting containers..."
docker compose up -d

echo ""
echo "Waiting 30s for containers to stabilize..."
sleep 30

echo ""
echo "Running health check..."
./scripts/health-check.sh || true

echo ""
echo "════════════════════════════════════════════════════"
echo "RESTORE COMPLETE"
echo "════════════════════════════════════════════════════"
echo ""
echo "Post-restore checklist:"
echo "  [ ] Verify Vaultwarden at https://vault.\${DOMAIN}"
echo "  [ ] Verify Moodle at https://learn.\${DOMAIN}"
echo "  [ ] Verify Forgejo repos at https://git.\${DOMAIN}"
echo "  [ ] Re-authenticate Claude Code: claude login"
echo "  [ ] If vault was git-bundled: cd /root/vault && git clone <forgejo-url>"
echo "  [ ] Run ./scripts/disable-signups.sh"
echo ""
echo "n8n workflows were restored via PostgreSQL. They should auto-activate."
echo "If workflows are missing, re-run: ./scripts/deploy.sh (imports from JSON files)"
echo ""
