#!/usr/bin/env bash
# PKM file watcher — embeds new/modified notes into OB1 on save
# Runs as pkm-watcher.service via systemd

set +e
PKM_DIR="/home/ubuntu/pkm"
OB1_URL="http://127.0.0.1:8000/api/remember"

[ -d "$PKM_DIR" ] || { echo "PKM dir not found: $PKM_DIR"; exit 1; }

echo "PKM watcher started — watching $PKM_DIR"

inotifywait -m -r -e close_write,moved_to --format '%w%f' "$PKM_DIR" 2>/dev/null | while read -r FILEPATH; do
    # Only process markdown files
    [[ "$FILEPATH" != *.md ]] && continue

    # Skip temp/hidden files
    BASENAME=$(basename "$FILEPATH")
    [[ "$BASENAME" == .* ]] && continue

    # Read content (cap at 2000 chars to avoid OB1 overload)
    CONTENT=$(head -c 2000 "$FILEPATH" 2>/dev/null)
    [ -z "$CONTENT" ] && continue

    # Derive relative path as source label
    REL="${FILEPATH#$PKM_DIR/}"

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

    curl -sf --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$OB1_URL" 2>/dev/null || true

    echo "$(date '+%H:%M:%S') embedded: $REL"
done
