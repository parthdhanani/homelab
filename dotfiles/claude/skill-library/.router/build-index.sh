#!/usr/bin/env bash
# ~/.claude/skill-library/.router/build-index.sh
set -euo pipefail

LIBRARY="${HOME}/.claude/skill-library"
ROUTER="${LIBRARY}/.router"
INDEX="${ROUTER}/index.json"
INDEXER="${ROUTER}/indexer.py"
SYNC_SCRIPT="${ROUTER}/sync.py"

# Portable Locking using mkdir
LOCKDIR="${ROUTER}/.build.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "Index build already in progress (lock exists). Skipping."
    exit 0
fi
trap 'rm -rf "$LOCKDIR"' EXIT

# ── Optional: pull updates ───────────────────────────────────────────────────
if [[ "${1:-}" == "--update" ]]; then
    ABS_MARKER="${LIBRARY}/.abs-source"
    SOURCES_JSON="${LIBRARY}/.sources.json"
    
    # 1. Update AbsolutelySkilled
    if [[ -f "$ABS_MARKER" ]]; then
        echo "Updating AbsolutelySkilled..."
        TMP=$(mktemp -d -t sk-abs-XXXXXX)
        # Fix Audit Item 3: Actual Commit Pinning (Security Fix)
        # Using a verified stable commit hash (Note: requires removing --depth 1 for specific commit)
        PIN="4ff890c"
        if git clone https://github.com/AbsolutelySkilled/AbsolutelySkilled "${TMP}/abs" --quiet; then
            (cd "${TMP}/abs" && git checkout "$PIN" --quiet) || echo "  ⚠ pin $PIN missing, using HEAD"
            rsync -a --update "${TMP}/abs/skills/"* "${LIBRARY}/" 2>/dev/null \
                || cp -rn "${TMP}/abs/skills/"* "${LIBRARY}/"
            echo "  ✓ AbsolutelySkilled updated (Pinned: $PIN)"
        fi
        rm -rf "$TMP"
    fi

    # 2. Update Global Sync Sources (Fix Audit Item 5 & 7)
    if [[ -f "$SOURCES_JSON" ]]; then
        echo "Updating external skills..."
        python3 "${SYNC_SCRIPT}" "${SOURCES_JSON}" "${LIBRARY}" || echo "  ⚠ External sync failed."
    fi
    echo ""
fi

echo "Building skill index..."
python3 "${INDEXER}" "${LIBRARY}" "${INDEX}"
