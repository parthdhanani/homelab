#!/usr/bin/env bash
# Gemini SessionStart hook — injects PKM memory as first-turn context.
# Output goes to Gemini as the opening system context.

set +e

MEMORY="/home/ubuntu/pkm/_Meta/AI/memory/MEMORY.md"
INBOX="/home/ubuntu/pkm/00 Capture/Inbox.md"

echo "=== PKM Memory Index ==="
[ -f "$MEMORY" ] && cat "$MEMORY" || echo "(not found)"

echo ""
echo "=== Recent Session History (last 10 entries) ==="
[ -f "$INBOX" ] && grep -n "^## " "$INBOX" | tail -10 | while IFS= read -r line; do
    LINENUM=$(echo "$line" | cut -d: -f1)
    HEADER=$(echo "$line" | cut -d: -f2-)
    BODY=$(sed -n "$((LINENUM+1)),$((LINENUM+3))p" "$INBOX" 2>/dev/null)
    echo "$HEADER"
    echo "$BODY"
    echo ""
done

exit 0
