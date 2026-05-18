#!/bin/bash
# CRYPTEX — Restore .env from encrypted backup
# Run on VPS: ./scripts/restore-env.sh

set -euo pipefail

ENV_FILE="/opt/cryptex/.env"
ENCRYPTED_FILE="${ENV_FILE}.encrypted"

if [ ! -f "$ENCRYPTED_FILE" ]; then
    echo "ERROR: No encrypted backup found at ${ENCRYPTED_FILE}"
    echo "Create one with: ./scripts/setup-env.sh (offers encryption at end)"
    exit 1
fi

if [ -f "$ENV_FILE" ]; then
    echo "WARNING: .env already exists at ${ENV_FILE}"
    read -rp "Overwrite with decrypted backup? (y/N): " confirm
    [[ "$confirm" != "y" ]] && echo "Aborted." && exit 0
fi

echo "Decrypting ${ENCRYPTED_FILE}..."
openssl aes-256-cbc -d -pbkdf2 -salt -in "$ENCRYPTED_FILE" -out "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "Restored: ${ENV_FILE}"
echo "Verify: head -5 ${ENV_FILE}"
