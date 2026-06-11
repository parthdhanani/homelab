#!/bin/bash
# cron-notify.sh <script> [args...]
# Thin wrapper: runs a script, emails on non-zero exit via msmtp.
# Usage in crontab: cron-notify.sh /opt/cryptex/scripts/foo.sh >> /var/log/foo.log 2>&1

# cron has a bare env — pull ADMIN_EMAIL/DOMAIN from the stack .env
source /opt/cryptex/.env 2>/dev/null || true

SCRIPT="$1"
TO="${ADMIN_EMAIL:-admin@${DOMAIN:-yourdomain.com}}"
LABEL=$(basename "${SCRIPT:-unknown}")

output=$("$@" 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    (
        printf "To: %s\n" "$TO"
        printf "Subject: [Cryptex FAIL] %s (%s)\n" "$LABEL" "$TS"
        printf "Content-Type: text/plain\n\n"
        printf "Script:    %s\n" "$SCRIPT"
        printf "Exit code: %s\n" "$rc"
        printf "Time:      %s\n\n" "$TS"
        printf "%s\n" "$output"
    ) | msmtp --from=default "$TO" 2>/dev/null || true
fi

# Echo output so cron log still captures it
[ -n "$output" ] && echo "$output"

exit $rc
