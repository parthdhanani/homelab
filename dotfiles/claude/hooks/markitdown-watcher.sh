#!/usr/bin/env bash
# markitdown watcher — converts dropped documents to Markdown for the PKM vault.
# Runs as markitdown-watcher.service via systemd.
#
# Flow: user drops a PDF/docx/pptx/xlsx/etc into 00 Capture/Docs/ →
#       this watcher converts it to <name>.md (with frontmatter) in the same folder →
#       the existing pkm-watcher.service sees the new .md and embeds it into OB1.
# This script deliberately does NOT touch OB1 — pkm-watcher owns that.

set +e
WATCH_DIR="/home/ubuntu/pkm/00 Capture/Docs"
MARKITDOWN="/home/ubuntu/.local/bin/markitdown"

[ -d "$WATCH_DIR" ] || { echo "Docs dir not found: $WATCH_DIR"; exit 1; }
[ -x "$MARKITDOWN" ] || { echo "markitdown not found: $MARKITDOWN"; exit 1; }

echo "markitdown watcher started — watching $WATCH_DIR"

inotifywait -m -r -e close_write,moved_to --format '%w%f' "$WATCH_DIR" 2>/dev/null | while read -r FILEPATH; do
    BASENAME=$(basename "$FILEPATH")

    # Skip our own output, hidden/temp files, and the keep-marker
    [[ "$FILEPATH" == *.md ]] && continue
    [[ "$BASENAME" == .* ]] && continue

    DIR=$(dirname "$FILEPATH")
    STEM="${BASENAME%.*}"
    OUT="$DIR/$STEM.md"

    # Convert to a temp file first, then assemble the final note atomically
    TMP=$(mktemp) || continue
    if ! "$MARKITDOWN" "$FILEPATH" -o "$TMP" 2>/dev/null; then
        echo "$(date '+%H:%M:%S') convert FAILED: $BASENAME"
        rm -f "$TMP"
        continue
    fi

    # Prepend YAML frontmatter so it reads as a proper vault note
    {
        echo "---"
        echo "title: \"$STEM\""
        echo "source: \"$BASENAME\""
        echo "converted: $(date '+%Y-%m-%d %H:%M')"
        echo "via: markitdown"
        echo "tags: [capture, converted-doc]"
        echo "---"
        echo ""
        cat "$TMP"
    } > "$OUT"
    rm -f "$TMP"

    echo "$(date '+%H:%M:%S') converted: $BASENAME -> $STEM.md"
done
