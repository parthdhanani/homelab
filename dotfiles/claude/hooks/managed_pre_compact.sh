#!/bin/bash
LAST_SK=""
[ -f "/tmp/.sk-last-query" ] && LAST_SK=$(cat /tmp/.sk-last-query)
[ -n "$LAST_SK" ] && echo "POST-COMPACT: reload skill with /sk \"${LAST_SK}\""

# Inject last 3 memory entries so they survive compaction
VPS_MEM="${HOME}/.claude/projects/-home-ubuntu-AI-Space/memory/MEMORY.md"
if [ -f "$VPS_MEM" ]; then
    echo ""
    echo "=== Last 3 memory entries (preserve across compaction) ==="
    grep '^-' "$VPS_MEM" | tail -3
fi
