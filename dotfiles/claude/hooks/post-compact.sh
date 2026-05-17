#!/bin/bash
# PostCompact hook — re-injects key state after compaction
# Runs after autoCompact, guarantees context survives the lossy summary

VPS_MEM="${HOME}/.claude/projects/-home-ubuntu-AI-Space/memory/MEMORY.md"

echo "=== Post-compaction context reload ==="

# Reload active skill if one was in use
if [ -f "/tmp/.sk-last-query" ]; then
    echo "Active skill: $(cat /tmp/.sk-last-query) — reload with /sk if needed"
fi

# Remind about OB1 MCP (easy to lose after compaction)
echo "OB1 memory MCP available — server name: ob1 (semantic search over session history)"

# Last 3 memory entries
if [ -f "$VPS_MEM" ]; then
    echo "Recent memory:"
    grep '^-' "$VPS_MEM" | tail -3
fi
