#!/usr/bin/env bash
# PKM file watcher — embeds new/modified notes into OB1 on save
# Runs as pkm-watcher.service via systemd

set +e
PKM_DIR="/home/ubuntu/pkm"
OB1_URL="http://172.18.0.52:8000/api/remember"

[ -d "$PKM_DIR" ] || { echo "PKM dir not found: $PKM_DIR"; exit 1; }

echo "PKM watcher started — watching $PKM_DIR"

inotifywait -m -r -e close_write,moved_to --format '%w%f' "$PKM_DIR" 2>/dev/null | while read -r FILEPATH; do
    # Only process markdown files
    [[ "$FILEPATH" != *.md ]] && continue

    # Skip temp/hidden files
    BASENAME=$(basename "$FILEPATH")
    [[ "$BASENAME" == .* ]] && continue

    # Skip the capture inbox — session summaries are POSTed to OB1 directly
    # by the Stop hook; embedding the inbox here would duplicate them.
    [[ "$FILEPATH" == *"00 Capture/Inbox.md" ]] && continue

    # Skip the entire _Private/ tree — financial/personal notes (Finance, Ledger,
    # Archive backups with card/account data) must never enter a searchable index.
    [[ "$FILEPATH" == *"/_Private/"* ]] && continue

    # Derive relative path as source label
    REL="${FILEPATH#$PKM_DIR/}"

    # For append-only growing logs (news-feed.md etc), a fixed head-cap means the
    # SAME oldest ~8000 chars gets re-sent forever while genuinely new content
    # appended at the bottom never reaches OB1 at all. Track a byte-position per
    # file instead: send only what's newly appended since last time. Falls back
    # to a plain head-cap for files that shrank/were rewritten in place.
    POS_FILE="$HOME/.claude/cache/pkm-watcher-positions"
    mkdir -p "$(dirname "$POS_FILE")"
    CUR_SIZE=$(stat -c '%s' "$FILEPATH" 2>/dev/null || echo 0)
    LAST_POS=$(grep "^${REL}|" "$POS_FILE" 2>/dev/null | tail -1 | cut -d'|' -f2)
    LAST_POS="${LAST_POS:-0}"

    if [ "$CUR_SIZE" -gt "$LAST_POS" ]; then
        # New bytes appended since last send - grab just those (capped at 8000 chars)
        CONTENT=$(tail -c "+$((LAST_POS + 1))" "$FILEPATH" 2>/dev/null | head -c 8000)
    elif [ "$CUR_SIZE" -lt "$LAST_POS" ]; then
        # File shrank/was rewritten - treat as a fresh file, send the head
        CONTENT=$(head -c 8000 "$FILEPATH" 2>/dev/null)
    else
        CONTENT=""
    fi
    [ -z "$CONTENT" ] && continue

    sed -i "/^${REL}|/d" "$POS_FILE" 2>/dev/null
    echo "${REL}|${CUR_SIZE}" >> "$POS_FILE"

    PAYLOAD=$(python3 -c "
import json, sys
content, source = sys.argv[1], sys.argv[2]
print(json.dumps({
    'content': content,
    'source': 'pkm-note',
    'tags': ['pkm', 'note', source.split('/')[0] if '/' in source else 'root']
}))
" "$CONTENT" "$REL" 2>/dev/null)

    [ -z "$PAYLOAD" ] && continue

    OB1_TOKEN=$(cat /home/ubuntu/.claude/secrets/ob1.token 2>/dev/null)
    curl -sf --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        ${OB1_TOKEN:+-H "Authorization: Bearer $OB1_TOKEN"} \
        -d "$PAYLOAD" \
        "$OB1_URL" 2>/dev/null || true

    echo "$(date '+%H:%M:%S') embedded: $REL"
done
