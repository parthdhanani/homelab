#!/bin/bash
# CRYPTEX — Update all containers
# Run on VPS: ./scripts/update.sh
# Can also update a single service: ./scripts/update.sh moodle

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
cd "$COMPOSE_DIR"

# Trap: ensure containers are restarted even if update is interrupted
_UPDATE_INTERRUPTED=0
trap '_UPDATE_INTERRUPTED=1; echo ""; echo "WARNING: Update interrupted — restarting containers to restore service"; docker compose up -d 2>/dev/null || true' ERR INT TERM

# shellcheck disable=SC1090
source "${COMPOSE_DIR}/.env"

SERVICE="${1:-}"

echo ""
echo "CRYPTEX Update"
echo "────────────────────────────"

# Regenerate PgBouncer userlist.txt (idempotent — keeps passwords in sync)
# Plaintext passwords for scram-sha-256 auth (postgres 16 default; MD5 is broken)
_pgb_conf="${COMPOSE_DIR}/configs/pgbouncer"
if [ -f "${_pgb_conf}/pgbouncer.ini" ]; then
    cat > "${_pgb_conf}/userlist.txt" <<USERLIST
"${N8N_DB_USER}" "${N8N_DB_PASSWORD}"
"${TRAXLRS_DB_USER}" "${TRAXLRS_DB_PASSWORD}"
"${MINIFLUX_DB_USER:-miniflux_user}" "${MINIFLUX_DB_PASSWORD}"
"${UMAMI_DB_USER}" "${UMAMI_DB_PASSWORD}"
"pgbouncer_admin" "${POSTGRES_PASSWORD}"
USERLIST
    chmod 644 "${_pgb_conf}/userlist.txt"
fi

# Backup first
echo "Running backup before update..."
./scripts/backup.sh

if [ -n "$SERVICE" ]; then
    # ── Single service update ──
    echo ""
    echo "Updating: ${SERVICE}"

    # Save rollback image (before pulling new one)
    ROLLBACK_DIR="${COMPOSE_DIR}/.rollback"
    mkdir -p "$ROLLBACK_DIR"
    CONTAINER_NAME="cryptex-${SERVICE}"
    CURRENT_IMAGE=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    if [ -n "$CURRENT_IMAGE" ]; then
        docker tag "$CURRENT_IMAGE" "rollback/${SERVICE}:prev" 2>/dev/null || true
        echo "$CURRENT_IMAGE" > "${ROLLBACK_DIR}/${SERVICE}"
        echo "  Saved rollback image: ${CURRENT_IMAGE:0:20}..."
    fi

    # Check if it's a custom-built image
    case "$SERVICE" in
        moodle|traxlrs)
            echo "Rebuilding custom image (pulling fresh base)..."
            docker compose build --pull "$SERVICE"
            ;;
        n8n)
            echo "Pulling n8n image and refreshing tools volume..."
            docker compose pull "$SERVICE"
            # Force re-run of init container to update tools before starting n8n
            docker compose stop n8n 2>/dev/null || true
            docker compose rm -f n8n-tools 2>/dev/null || true
            docker volume rm cryptex_n8n_tools 2>/dev/null || true
            docker compose up -d n8n-tools
            echo "  Waiting for n8n-tools init container to finish..."
            timeout 300 docker wait cryptex-n8n-tools 2>/dev/null || true
            ;;
        *)
            echo "Pulling latest image..."
            docker compose pull "$SERVICE"
            ;;
    esac

    echo "Recreating container..."
    docker compose up -d --no-deps "$SERVICE"

    echo ""
    echo "Waiting 30s for health check..."
    sleep 30

    STATE=$(docker inspect --format='{{.State.Status}}' "cryptex-${SERVICE}" 2>/dev/null || echo "unknown")
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "cryptex-${SERVICE}" 2>/dev/null || echo "none")

    if [ "$STATE" = "running" ]; then
        echo "✅ ${SERVICE} is running (health: ${HEALTH})"
        curl -sf --max-time 10 -X POST "http://cryptex-n8n:5678/webhook/backup-status" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"success\",\"file\":\"update:${SERVICE}\",\"size\":\"single\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
            >/dev/null 2>&1 || true
    else
        echo "❌ ${SERVICE} failed (state: ${STATE})"
        echo "Last 20 log lines:"
        docker logs "cryptex-${SERVICE}" --tail 20
        curl -sf --max-time 5 -X POST "http://cryptex-n8n:5678/webhook/health-alert" \
            -H "Content-Type: application/json" \
            -d "{\"pass\":0,\"warn\":0,\"fail\":1,\"failed\":\"cryptex-${SERVICE} ${STATE} after update\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
            >/dev/null 2>&1 || true
        exit 1
    fi
else
    # ── Full update ──

    # Save current image digests for rollback
    ROLLBACK_DIR="${COMPOSE_DIR}/.rollback"
    mkdir -p "$ROLLBACK_DIR"
    ROLLBACK_SNAPSHOT="${ROLLBACK_DIR}/full-$(date -u +%Y%m%dT%H%M%S).txt"
    echo "Saving image snapshot for rollback → ${ROLLBACK_SNAPSHOT}"
    docker compose ps -q | xargs -r docker inspect --format='{{.Name}} {{.Image}} {{index .Config.Labels "com.docker.compose.service"}}' \
        2>/dev/null > "$ROLLBACK_SNAPSHOT" || true

    # Tag current images as rollback targets
    while IFS= read -r line; do
        SVC=$(echo "$line" | awk '{print $3}')
        IMG=$(echo "$line" | awk '{print $2}')
        [ -n "$SVC" ] && [ -n "$IMG" ] && docker tag "$IMG" "rollback/${SVC}:prev" 2>/dev/null || true
    done < "$ROLLBACK_SNAPSHOT"

    echo ""
    echo "Pulling latest images..."
    docker compose pull --ignore-buildable

    echo ""
    echo "Rebuilding custom images (pulling fresh base)..."
    if ! docker compose build --pull moodle traxlrs; then
        echo "ERROR: custom image build failed — aborting update to preserve running containers"
        exit 1
    fi

    echo ""
    echo "Refreshing n8n tools volume (qpdf + pdftotext)..."
    docker compose rm -f n8n-tools 2>/dev/null || true
    docker volume rm cryptex_n8n_tools 2>/dev/null || true
    docker compose up -d n8n-tools

    echo ""
    echo "Restarting containers with new images..."
    docker compose up -d --remove-orphans

    echo ""
    echo "Cleaning old images..."
    docker image prune -f

    echo ""
    echo "Running health check..."
    if ! ./scripts/health-check.sh; then
        echo ""
        echo "❌ Health check failed after full update — rolling back to previous images"
        while IFS= read -r line; do
            SVC=$(echo "$line" | awk '{print $3}')
            [ -n "$SVC" ] && docker image inspect "rollback/${SVC}:prev" &>/dev/null || continue
            echo "  Rolling back: ${SVC}"
            # Retag rollback image as the compose service image
            CURRENT_IMG=$(docker inspect --format='{{.Config.Image}}' "cryptex-${SVC}" 2>/dev/null || echo "")
            [ -n "$CURRENT_IMG" ] && docker tag "rollback/${SVC}:prev" "$CURRENT_IMG" 2>/dev/null || true
        done < "$ROLLBACK_SNAPSHOT"
        docker compose up -d --remove-orphans
        echo "Rollback complete. Manual inspection required."
        curl -sf --max-time 5 -X POST "http://cryptex-n8n:5678/webhook/health-alert" \
            -H "Content-Type: application/json" \
            -d "{\"pass\":0,\"warn\":0,\"fail\":1,\"failed\":\"full update rolled back — health check failed\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
            >/dev/null 2>&1 || true
        exit 1
    fi
fi

echo ""
echo "Update complete."
