#!/bin/bash
# status-alert.sh — scheduled detector for dead/unhealthy units.
# Runs cryptex-status.sh; emails only if warnings found (prefixed '!! ').
# Always logs result with timestamp; always exits 0.
set -uo pipefail

# Run cryptex-status and capture stdout+stderr
output=$(/opt/cryptex/scripts/cryptex-status.sh 2>&1)

# Check for warning lines (starting with '!! ')
if echo "$output" | grep -q '^!! '; then
    # Found warnings, send email with full output as body
    /home/ubuntu/.claude/scripts/notify.sh "VPS status warnings" "$output"
    result="ALERT"
else
    # No warnings, exit silently
    result="OK"
fi

# Log result with timestamp (both success and alert paths)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $result" >> /var/log/cryptex-status-alert.log

exit 0
