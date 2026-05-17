#!/bin/bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Project context:"
if [ -f ".claude/CLAUDE.md" ]; then
    LINE_COUNT=$(wc -l < ".claude/CLAUDE.md" | tr -d ' ')
    if [ "$LINE_COUNT" -gt 100 ]; then
        echo "  ⚠ CLAUDE.md is ${LINE_COUNT} lines (large — showing first 20):"
        head -20 ".claude/CLAUDE.md"
        echo "  ... (truncated — run: cat .claude/CLAUDE.md)"
    else
        cat ".claude/CLAUDE.md"
    fi
else
    cat "${HOME}/.claude/CLAUDE.md"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MEMORY=".claude/MEMORY.md"
if [ -f "$MEMORY" ]; then
    echo ""
    echo "  Recent project memory:"
    tail -5 "$MEMORY"
    echo ""
fi
# Memory index summary
VPS_MEM="${HOME}/.claude/projects/-home-ubuntu-AI-Space/memory/MEMORY.md"
MEM_PARTS=""
[ -f "$VPS_MEM" ] && MEM_PARTS="vps:$(grep -c '^-' "$VPS_MEM" 2>/dev/null || echo 0)"
[ -n "$MEM_PARTS" ] && echo "  Memory loaded — $MEM_PARTS"
