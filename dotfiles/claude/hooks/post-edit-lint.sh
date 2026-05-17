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

# shellcheck on .sh
if [[ "$FILE" == *.sh ]]; then
    if command -v shellcheck &>/dev/null && [[ -f "$FILE" ]]; then
        OUT=$(shellcheck -S warning "$FILE" 2>&1)
        [[ -n "$OUT" ]] && echo "[shellcheck] $FILE" && echo "$OUT"
    fi
fi

# Network config reminder — no curl, just flag it
if echo "$FILE" | grep -qE '(nginx|code-server|caddy|zellij-proxy|socat)'; then
    echo "[net-reminder] $FILE touches network/proxy config — verify public URL still resolves via CF tunnel before declaring done."
fi

exit 0
