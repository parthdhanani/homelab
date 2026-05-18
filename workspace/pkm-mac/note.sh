#!/usr/bin/env bash
# note.sh — Alfred-callable PKM capture (Mac)
# Reads note text from $1 (Alfred {query}) or stdin
# POSTs to <your-notes-endpoint>/c with bearer token from Vaultwarden (bw)
# Falls back to env var NOTES_CAPTURE_TOKEN if bw unavailable

set -euo pipefail

TEXT="${1:-}"
[ -z "$TEXT" ] && TEXT="$(cat)"
[ -z "$TEXT" ] && { echo "empty"; exit 1; }

# Token resolution: bw first, then env, then keychain
TOKEN=""
if command -v bw >/dev/null 2>&1 && bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
  TOKEN=$(bw get password "Notes Capture Token" 2>/dev/null || true)
fi
[ -z "$TOKEN" ] && TOKEN="${NOTES_CAPTURE_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN=$(security find-generic-password -s "notes-capture-token" -w 2>/dev/null || true)
[ -z "$TOKEN" ] && { echo "no token — set NOTES_CAPTURE_TOKEN env, save 'Notes Capture Token' in Bitwarden, or add to keychain via: security add-generic-password -s notes-capture-token -a notes -w"; exit 2; }

# Escape for JSON
JSON_TEXT=$(printf '%s' "$TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

NOTES_ENDPOINT="${NOTES_ENDPOINT:-https://<your-domain>/c}"
RESP=$(curl -sS -w "\n%{http_code}" -X POST "$NOTES_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"text\":${JSON_TEXT},\"source\":\"alfred\"}")

CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -n -1)

if [ "$CODE" = "200" ]; then
  echo "✓ captured"
  # macOS notification
  command -v osascript >/dev/null && osascript -e "display notification \"$TEXT\" with title \"Inbox ✓\"" 2>/dev/null
else
  echo "✗ HTTP $CODE: $BODY"
  command -v osascript >/dev/null && osascript -e "display notification \"HTTP $CODE\" with title \"Capture failed\"" 2>/dev/null
  exit 1
fi
