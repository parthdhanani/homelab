#!/bin/bash
# cron-notify.sh <script> [args...]
# Thin wrapper: runs a script, emails on non-zero exit via msmtp.
# Usage in crontab: cron-notify.sh /opt/cryptex/scripts/foo.sh >> /var/log/foo.log 2>&1

# cron has a bare env — pull ADMIN_EMAIL/DOMAIN from the stack .env and export so
# the wrapped script (run via "$@" below) inherits them too, not just this shell
set -a
source /opt/cryptex/.env 2>/dev/null || true
set +a

SCRIPT="$1"
LABEL=$(basename "${SCRIPT:-unknown}")

output=$("$@" 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    BODY=$(printf "Script:    %s\nExit code: %s\nTime:      %s\n\n%s\n" "$SCRIPT" "$rc" "$TS" "$output")
    /home/ubuntu/.claude/scripts/notify.sh "$LABEL failed" "$BODY" critical \
        || echo "cron-notify.sh: FAILED to send failure-alert email for $LABEL (rc=$?)" >&2
fi

# Echo output so cron log still captures it
[ -n "$output" ] && echo "$output"

exit $rc
