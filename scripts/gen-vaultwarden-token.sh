#!/usr/bin/env bash
# Generate a Vaultwarden admin token (argon2id hash).
# Output goes to stdout — paste into .env as VAULTWARDEN_ADMIN_TOKEN.
# Requires: docker (uses the official vaultwarden image to run argon2)

set -euo pipefail

RAW=$(openssl rand -base64 48)
echo "Raw password (save this — you'll type it to log in): $RAW"
echo ""

HASH=$(docker run --rm vaultwarden/server:latest \
    /vaultwarden hash --preset owasp "$RAW" 2>/dev/null | tail -1)

echo "Argon2id hash (put this in .env → VAULTWARDEN_ADMIN_TOKEN):"
echo "$HASH"
