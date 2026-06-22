#!/bin/bash
# PostToolUse hook: lint YAML/shell files, remind on network config changes
# Receives JSON on stdin: { "tool_name": "...", "tool_input": { "file_path": "..." } }

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

[[ -z "$FILE" ]] && exit 0

# yamllint on .yml/.yaml
if [[ "$FILE" == *.yml || "$FILE" == *.yaml ]]; then
    YAMLLINT="$HOME/.local/bin/yamllint"
    if [[ -x "$YAMLLINT" ]] && [[ -f "$FILE" ]]; then
        OUT=$("$YAMLLINT" -d '{extends: relaxed, rules: {line-length: {max: 120}}}' "$FILE" 2>&1)
        [[ -n "$OUT" ]] && echo "[yamllint] $FILE" && echo "$OUT"
    fi
fi

# Run shellcheck against .sh files
if [[ "$FILE" == *.sh ]]; then
    if command -v shellcheck &>/dev/null && [[ -f "$FILE" ]]; then
        OUT=$(shellcheck -S warning "$FILE" 2>&1)
        [[ -n "$OUT" ]] && echo "[shellcheck] $FILE" && echo "$OUT"
    fi
fi

# slop_lint on frontend/UI files — flags AI tells (em-dashes, numbered eyebrows,
# scroll cues, etc). Silent unless something is found. Advisory, never blocks.
if [[ "$FILE" =~ \.(html|htm|jsx|tsx|vue|svelte|astro)$ ]] && [[ -f "$FILE" ]]; then
    python3 "$HOME/.claude/hooks/slop_lint.py" "$FILE" --quiet 2>/dev/null
fi

# Network config reminder — no curl, just flag it
if echo "$FILE" | grep -qE '(nginx|code-server|caddy|zellij-proxy|socat)'; then
    echo "[net-reminder] $FILE touches network/proxy config — verify public URL still resolves via CF tunnel before declaring done."
fi

exit 0
