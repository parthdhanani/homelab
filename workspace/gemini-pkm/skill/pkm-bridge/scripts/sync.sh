#!/usr/bin/env bash
# gemini-sync — Appends Gemini session summary to PKM Inbox.md
# Usage: gemini-sync "Summary of changes..."

INBOX="/home/ubuntu/pkm/00 Capture/Inbox.md"
DATE=$(date +"%Y-%m-%d %H:%M")

{
  echo ""
  echo "### Gemini Session: $DATE"
  echo "$1"
  echo ""
} >> "$INBOX"

echo "✓ Session synced to PKM Inbox."
