#!/bin/bash
# CRYPTEX — Disable signups after first account creation
# Run once on VPS after you've created your accounts in Vaultwarden and Open WebUI
# Usage: ./scripts/disable-signups.sh

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
ENV_FILE="${COMPOSE_DIR}/.env"

echo ""
echo "CRYPTEX — Disable Signups"
echo "────────────────────────────"
echo ""

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env not found at ${ENV_FILE}"
    exit 1
fi

# ── Vaultwarden ──
echo "Disabling Vaultwarden signups..."
sed -i 's/VAULTWARDEN_SIGNUPS_ALLOWED="true"/VAULTWARDEN_SIGNUPS_ALLOWED="false"/' "$ENV_FILE"
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --no-deps vaultwarden
echo "  ✓ Vaultwarden signups disabled"

# ── Forgejo ──
echo "Disabling Forgejo registration..."
if grep -q 'FORGEJO_DISABLE_REGISTRATION' "$ENV_FILE"; then
    sed -i 's/FORGEJO_DISABLE_REGISTRATION=.*/FORGEJO_DISABLE_REGISTRATION="true"/' "$ENV_FILE"
else
    echo 'FORGEJO_DISABLE_REGISTRATION="true"' >> "$ENV_FILE"
fi
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --no-deps forgejo
echo "  ✓ Forgejo registration disabled"

echo ""
echo "────────────────────────────"
echo "Done. New signups are now blocked."
echo "To re-enable: edit VAULTWARDEN_SIGNUPS_ALLOWED / FORGEJO_DISABLE_REGISTRATION in .env"
