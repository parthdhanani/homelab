#!/bin/bash
# CRYPTEX — Quartz PKM build (change-aware)
# Only rebuilds if vault files changed since last successful build.

set -euo pipefail

VAULT="/opt/cryptex/data/pkm"
OUTPUT="/opt/cryptex/data/quartz-output"
APP="/opt/cryptex/data/quartz-app"
STAMP="/opt/cryptex/data/quartz-output/.last-build"

# Skip if no changes since last successful build
if [ -f "$STAMP" ] && [ -z "$(find "$VAULT" -newer "$STAMP" -type f 2>/dev/null)" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) quartz: no changes, skipping build"
    exit 0
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) quartz: changes detected, building..."

docker run --rm \
    -v "${VAULT}:/vault:ro" \
    -v "${OUTPUT}:/output" \
    -v "${APP}:/app" \
    -w /app \
    node:22-alpine \
    sh -c 'apk add --no-cache coreutils > /dev/null 2>&1 && node --no-deprecation /app/quartz/bootstrap-cli.mjs build --directory /vault --output /output/site && chown -R 1001:1001 /output/site'

touch "$STAMP"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) quartz: build complete"
