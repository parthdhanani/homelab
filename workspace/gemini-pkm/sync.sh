#!/usr/bin/env bash
# Gemini write-back to PKM Inbox.
# Usage: sync.sh "2-sentence summary of what was decided/changed"

set +e

INBOX="/home/ubuntu/pkm/00 Capture/Inbox.md"
SUMMARY="${1:-}"

[ -z "$SUMMARY" ] && { echo "Usage: sync.sh \"summary\"" >&2; exit 1; }
[ -d "$(dirname "$INBOX")" ] || { echo "PKM inbox dir not found" >&2; exit 1; }

TS=$(date '+%Y-%m-%d %H:%M')
{
  echo ""
  echo "## $TS — gemini @ $(basename "$PWD")"
  echo "$SUMMARY"
} >> "$INBOX"

echo "PKM updated."
