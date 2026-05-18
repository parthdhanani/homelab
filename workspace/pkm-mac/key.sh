#!/usr/bin/env bash
# key.sh — Alfred snippet helper: fetch secret from Vaultwarden, paste at cursor, auto-clear in 30s
# Usage from Alfred snippet:
#   Trigger: ;ok    → ./key.sh openai
#   Trigger: ;an    → ./key.sh anthropic
#   Trigger: ;gh    → ./key.sh github
#   Trigger: ;cf    → ./key.sh cloudflare
#
# Bitwarden item naming convention: store password in items named exactly as the arg.

set -euo pipefail

NAME="${1:-}"
[ -z "$NAME" ] && { echo "usage: key.sh <item-name>"; exit 1; }

if ! command -v bw >/dev/null 2>&1; then
  echo "bw CLI not installed — brew install bitwarden-cli"
  exit 2
fi

if ! bw status 2>/dev/null | grep -q '"status":"unlocked"'; then
  echo "bw locked — run: export BW_SESSION=\$(bw unlock --raw)"
  command -v osascript >/dev/null && osascript -e "display notification \"Run: export BW_SESSION=\\\$(bw unlock --raw)\" with title \"Bitwarden locked\""
  exit 3
fi

SECRET=$(bw get password "$NAME" 2>/dev/null) || { echo "not found: $NAME"; exit 4; }

# Copy + paste at cursor + auto-clear
echo -n "$SECRET" | pbcopy
osascript -e 'tell application "System Events" to keystroke "v" using command down'

# Clear clipboard after 30s
( sleep 30 && pbcopy </dev/null ) &
disown

# Notify
osascript -e "display notification \"$NAME pasted, clipboard clears in 30s\" with title \"🔑\""
