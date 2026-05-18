#!/bin/bash
# CRYPTEX — Backup critical data
# Run on VPS: ./scripts/backup.sh

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
BACKUP_DIR="/opt/cryptex/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"

# shellcheck disable=SC1090
source "${COMPOSE_DIR}/.env"

echo ""
echo "CRYPTEX Backup — ${TIMESTAMP}"
echo "────────────────────────────"

# Pre-flight: ensure sufficient disk space (require ≥5GB free)
DISK_FREE_KB=$(df -k "${BACKUP_DIR%/*}" | awk 'NR==2 {print $4}')
DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
if [ "$DISK_FREE_GB" -lt 5 ]; then
    echo "ERROR: Insufficient disk space — ${DISK_FREE_GB}GB free, need ≥5GB"
    # Alert even though backup is aborted
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -sf --max-time 5 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}&text=🚨 CRYPTEX: Backup aborted — disk full (${DISK_FREE_GB}GB free)" \
            >/dev/null 2>&1 || true
    fi
    exit 1
fi

mkdir -p "$BACKUP_PATH"

# PostgreSQL dump (all databases)
echo "Dumping PostgreSQL..."
docker exec cryptex-postgres pg_dumpall -U "${POSTGRES_USER}" > "${BACKUP_PATH}/postgres_all.sql"

# Validate dump is non-trivial and contains expected content
DUMP_SIZE=$(wc -c < "${BACKUP_PATH}/postgres_all.sql")
if [ "$DUMP_SIZE" -lt 10000 ]; then
    echo "  ERROR: PostgreSQL dump suspiciously small (${DUMP_SIZE} bytes) — aborting"
    exit 1
fi
if ! head -100 "${BACKUP_PATH}/postgres_all.sql" | grep -qE "^-- PostgreSQL|^\\\\connect|^CREATE"; then
    echo "  ERROR: PostgreSQL dump missing expected SQL headers — aborting"
    exit 1
fi
# Confirm all expected databases appear in dump (error if missing — partial backup is unusable)
_MISSING_DBS=()
for _db in moodle n8n tianji forgejo miniflux traxlrs; do
    grep -q "\\\\connect ${_db}" "${BACKUP_PATH}/postgres_all.sql" \
        || _MISSING_DBS+=("$_db")
done
if [ ${#_MISSING_DBS[@]} -gt 0 ]; then
    echo "  ERROR: databases missing from dump: ${_MISSING_DBS[*]}"
    echo "  Partial backup is not trustworthy — aborting"
    exit 1
fi
echo "  postgres_all.sql validated ($(du -h "${BACKUP_PATH}/postgres_all.sql" | cut -f1))"

# Vaultwarden (safe SQLite backup via .backup command)
echo "Backing up Vaultwarden..."
if [ -f /opt/cryptex/data/vaultwarden/db.sqlite3 ]; then
    sqlite3 /opt/cryptex/data/vaultwarden/db.sqlite3 ".backup '${BACKUP_PATH}/vaultwarden.sqlite3'"
    echo "  vaultwarden.sqlite3"
else
    cp -r /opt/cryptex/data/vaultwarden "${BACKUP_PATH}/vaultwarden"
    echo "  vaultwarden/ (directory copy)"
fi

# n8n encryption keys (data is in PostgreSQL)
echo "Backing up n8n config..."
if [ -f /opt/cryptex/data/n8n/config ]; then
    cp /opt/cryptex/data/n8n/config "${BACKUP_PATH}/n8n-config"
fi
echo "  n8n config"

# Moodle uploaded files (courses, SCORM packages, user uploads)
echo "Backing up Moodle data..."
if [ -d /opt/cryptex/data/moodledata ]; then
    tar -czf "${BACKUP_PATH}/moodledata.tar.gz" -C /opt/cryptex/data moodledata
    echo "  moodledata.tar.gz"
fi

# AdGuard Home config (modified by admin UI after first run)
echo "Backing up AdGuard config..."
if [ -d /opt/cryptex/data/adguard/conf ]; then
    cp -r /opt/cryptex/data/adguard/conf "${BACKUP_PATH}/adguard-conf"
    echo "  adguard-conf/"
fi

# Forgejo (repos + config — DB is in PostgreSQL dump)
echo "Backing up Forgejo data..."
if [ -d /opt/cryptex/data/forgejo ]; then
    tar -czf "${BACKUP_PATH}/forgejo.tar.gz" -C /opt/cryptex/data forgejo
    echo "  forgejo.tar.gz"
fi

# TRAX LRS storage (file attachments in Laravel storage dir — xAPI statements in PostgreSQL)
echo "Backing up TRAX LRS storage..."
if [ -d /opt/cryptex/data/traxlrs ]; then
    tar -czf "${BACKUP_PATH}/traxlrs.tar.gz" -C /opt/cryptex/data traxlrs
    echo "  traxlrs.tar.gz"
fi

# Kopia repository connection config (needed to reconnect to B2 if VPS is rebuilt)
echo "Backing up Kopia config..."
if [ -d /opt/cryptex/data/kopia/config ]; then
    cp -r /opt/cryptex/data/kopia/config "${BACKUP_PATH}/kopia-config"
    echo "  kopia-config/"
fi

# SCORM import PHP script (lives in moodle-uploads, backed up separately)
echo "Backing up SCORM import script..."
if [ -f /opt/cryptex/data/moodle-uploads/scorm-import.php ]; then
    cp /opt/cryptex/data/moodle-uploads/scorm-import.php "${BACKUP_PATH}/scorm-import.php"
    echo "  scorm-import.php"
fi

# PKM vault (personal knowledge base — Claude R/W)
echo "Backing up PKM vault..."
if [ -d /opt/cryptex/data/pkm ] && [ "$(ls -A /opt/cryptex/data/pkm 2>/dev/null)" ]; then
    tar -czf "${BACKUP_PATH}/pkm.tar.gz" -C /opt/cryptex/data pkm
    echo "  pkm.tar.gz"
else
    echo "  (pkm directory empty or missing — skipping)"
fi

# rclone config (cloud provider tokens — critical, hard to recreate)
echo "Backing up rclone config..."
if [ -f /opt/cryptex/data/rclone/config/rclone.conf ]; then
    cp /opt/cryptex/data/rclone/config/rclone.conf "${BACKUP_PATH}/rclone.conf"
    echo "  rclone.conf (contains cloud OAuth tokens)"
else
    echo "  (rclone.conf not found — skipping)"
fi

# Vault git bundle (monthly — only on 1st of month to avoid bloat)
if [ "$(date +%d)" = "01" ]; then
    echo "Creating monthly vault git bundle..."
    if [ -d /opt/cryptex/data/workstation/vault/.git ]; then
        git -C /opt/cryptex/data/workstation/vault bundle create \
            "${BACKUP_PATH}/vault-$(date +%Y-%m).bundle" --all \
            && echo "  vault-$(date +%Y-%m).bundle" \
            || echo "  (vault bundle failed — vault may not be a git repo yet)"
    fi
fi

# n8n workflows (stored in PostgreSQL, but export readable JSON copies)
# n8n export:workflow --all outputs JSON to stdout; redirect to host file via docker exec.
# Cannot pass a host path to --output since that path is inside the container context.
echo "Exporting n8n workflows..."
mkdir -p "${BACKUP_PATH}/n8n-workflows"
if docker exec cryptex-n8n n8n export:workflow --all 2>/dev/null \
    > "${BACKUP_PATH}/n8n-workflows/all-workflows.json"; then
    echo "  n8n-workflows/all-workflows.json"
else
    rm -f "${BACKUP_PATH}/n8n-workflows/all-workflows.json" 2>/dev/null || true
    echo "  (n8n export skipped — container may not be running)"
fi

# ActualBudget (budget database)
echo "Backing up ActualBudget..."
if [ -d /opt/cryptex/data/actualbudget ]; then
    tar -czf "${BACKUP_PATH}/actualbudget.tar.gz" -C /opt/cryptex/data actualbudget
    echo "  actualbudget.tar.gz"
fi

# Obsidian config (vault plugins, themes, workspace settings — vault notes are in PKM backup above)
echo "Backing up Obsidian config..."
if [ -d /opt/cryptex/data/obsidian ] && [ "$(ls -A /opt/cryptex/data/obsidian 2>/dev/null)" ]; then
    tar -czf "${BACKUP_PATH}/obsidian.tar.gz" -C /opt/cryptex/data obsidian
    echo "  obsidian.tar.gz (plugins, themes, workspace — vault notes in pkm.tar.gz)"
else
    echo "  (obsidian config empty or missing — skipping)"
fi

# .env
cp "${COMPOSE_DIR}/.env" "${BACKUP_PATH}/dot-env"
echo "  dot-env"

# Compress
echo "Compressing..."
tar -czf "${BACKUP_DIR}/cryptex-${TIMESTAMP}.tar.gz" -C "$BACKUP_DIR" "$TIMESTAMP"
rm -rf "$BACKUP_PATH"

FINAL="${BACKUP_DIR}/cryptex-${TIMESTAMP}.tar.gz"

# Validate tarball integrity before declaring success
if ! tar -tzf "$FINAL" >/dev/null 2>&1; then
    echo "ERROR: Backup tarball failed integrity check — aborting"
    rm -f "$FINAL"
    exit 1
fi

echo ""
echo "Backup: ${FINAL} ($(du -h "$FINAL" | cut -f1))"

# Cleanup old backups (keep last 14)
echo "Cleaning old backups (keeping 14)..."
ls -t "${BACKUP_DIR}"/cryptex-*.tar.gz 2>/dev/null | tail -n +15 | xargs rm -f 2>/dev/null || true

# Notify n8n (Telegram backup status)
BACKUP_SIZE=$(du -h "$FINAL" | cut -f1)
curl -sf --max-time 10 -X POST "http://cryptex-n8n:5678/webhook/backup-status" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"success\",\"file\":\"${FINAL}\",\"size\":\"${BACKUP_SIZE}\",\"timestamp\":\"${TIMESTAMP}\"}" \
    >/dev/null 2>&1 || true

# ── Kopia snapshot (deduplication + compression + B2 offsite if configured) ──
# Kopia snapshots the /backups directory (mounted read-only inside the kopia container).
# If kopia is connected to B2, the snapshot is stored there (encrypted + deduplicated).
# If local filesystem, the snapshot is stored in /opt/cryptex/data/kopia/repository.

echo "Creating Kopia snapshot..."
if docker exec cryptex-kopia kopia repository status >/dev/null 2>&1; then
    docker exec cryptex-kopia kopia snapshot create /backups 2>/dev/null \
        && echo "  Kopia snapshot: /backups" \
        || echo "  WARNING: Kopia snapshot failed"
    # Show latest snapshot summary
    docker exec cryptex-kopia kopia snapshot list /backups --max-results=1 2>/dev/null \
        | grep -v "^$" | tail -1 || true
else
    echo "  Kopia skipped (repository not initialized — run deploy.sh to configure)"
fi

echo "Done."
