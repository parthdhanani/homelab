#!/usr/bin/env bash
# =============================================================
#  Claude Code System — Doctor
# =============================================================

echo "🩺 Running Claude Code System Diagnostics..."
echo ""

# 1. Dependency Check
echo "[Dependencies]"
for cmd in python3 git node; do
    if command -v $cmd &>/dev/null; then
        echo "  ✓ $cmd is installed"
    else
        echo "  ✗ $cmd is NOT installed!"
    fi
done

# 2. Structure Check
echo ""
echo "[Directory Structure]"
for dir in ~/.claude/skill-library ~/.claude/commands ~/.claude/hooks; do
    if [ -d "$dir" ]; then
        echo "  ✓ $dir exists"
    else
        echo "  ✗ $dir is missing!"
    fi
done

# Fix Audit Item 10: Verify Router Scripts
echo ""
echo "[Router Integrity]"
ROUTER="$HOME/.claude/skill-library/.router"
for script in build-index.sh indexer.py search.py skimport.py; do
    if [ -f "$ROUTER/$script" ]; then
        echo "  ✓ $script exists"
    else
        echo "  ✗ $script is missing from .router!"
    fi
done

# 3. Context & Memory Health
echo ""
echo "[Context & Memory Health]"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    LINES=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
    if [ "$LINES" -le 60 ]; then
        echo -e "  \033[0;32m✓ CLAUDE.md is $LINES lines (Optimal)\033[0m"
    elif [ "$LINES" -le 100 ]; then
        echo -e "  \033[0;33m⚠ CLAUDE.md is $LINES lines (Warning: Context drift possible)\033[0m"
    else
        echo -e "  \033[0;31m✗ CLAUDE.md is $LINES lines (Critical: Over limits)\033[0m"
    fi
else
    echo "  ✗ ~/.claude/CLAUDE.md missing!"
fi

MEMORY_FILE=".claude/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
    M_LINES=$(wc -l < "$MEMORY_FILE" | tr -d ' ')
    if [ "$M_LINES" -gt 200 ]; then
        echo -e "  \033[0;33m⚠ MEMORY.md is $M_LINES lines. Re-ingest KB recommended.\033[0m"
    else
        echo "  ✓ MEMORY.md is $M_LINES lines."
    fi
else
    echo "  ⚠ No project-specific MEMORY.md found in current directory."
fi

# 4. Skill Index & Orphan Check
echo ""
echo "[Skill Index]"
INDEX="$HOME/.claude/skill-library/.router/index.json"
if [ -f "$INDEX" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        INDEX_AGE_SEC=$(stat -f %m "$INDEX")
    else
        INDEX_AGE_SEC=$(stat -c %Y "$INDEX")
    fi
    NOW=$(date +%s)
    DIFF=$(( (NOW - INDEX_AGE_SEC) / 86400 ))
    echo "  ✓ Index exists ($DIFF days old)"
else
    echo "  ✗ Index missing! Run 'skbuild'"
fi

if [ -d "$HOME/.claude/skill-library/custom" ]; then
    ORPHANS=0
    for d in "$HOME/.claude/skill-library/custom"/*/; do
        [ -d "$d" ] || continue
        if [ ! -f "${d}SKILL.md" ]; then
            echo "  ⚠ Orphaned skill folder: $(basename "$d")"
            ORPHANS=$((ORPHANS+1))
        fi
    done
    [ $ORPHANS -eq 0 ] && echo "  ✓ No orphaned skills found."
fi

echo ""
echo "🩺 Diagnostics complete."
