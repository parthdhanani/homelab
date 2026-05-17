#!/bin/bash
# CRYPTEX — MkDocs PKM build (change-aware)
# Only rebuilds if vault files changed since last successful build.
# Force rebuild: bash notes-build.sh --force

set -euo pipefail

VAULT="/opt/cryptex/data/pkm"
OUTPUT="/opt/cryptex/data/notes-output"
STAMP="${OUTPUT}/.last-build"
CONFIG="/opt/cryptex/configs/mkdocs/mkdocs.yml"

if [ "${1:-}" != "--force" ] && [ -f "$STAMP" ] && [ -z "$(find "$VAULT" -newer "$STAMP" -type f 2>/dev/null)" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) notes: no changes, skipping build"
    exit 0
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) notes: changes detected, building..."
python3 -m mkdocs build --config-file "$CONFIG" --quiet
touch "$STAMP"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) notes: build complete"
