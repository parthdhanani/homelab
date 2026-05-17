#!/bin/bash
# PreCompact hook — injects state summary before context is compressed

echo "=== Pre-compaction snapshot ==="

# Recent git activity if in a repo
if git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Recent commits: $(git log --oneline -3 2>/dev/null | tr '\n' ' ')"
    MODIFIED=$(git diff --name-only 2>/dev/null | tr '\n' ' ')
    [[ -n "$MODIFIED" ]] && echo "Modified files: $MODIFIED"
fi

# Contract files — preserve active task context across compaction
if [ -f ".gemini-plan.md" ]; then
    echo "Active contract: .gemini-plan.md — $(head -1 .gemini-plan.md)"
fi
if [ -f ".gemini-docs.md" ]; then
    echo "Active contract: .gemini-docs.md — $(head -1 .gemini-docs.md)"
fi

echo "Instruction: Preserve task context, modified files, any pending commands, and key decisions made this session."
source "${HOME}/.claude/hooks/managed_pre_compact.sh"
exit 0
