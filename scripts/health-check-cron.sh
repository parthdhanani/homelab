#!/bin/bash
# Wrapper: runs health-check.sh and only logs output on failure.
# Called from cron — prevents log spam on clean runs.

output=$(/opt/cryptex/scripts/health-check.sh 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    {
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [FAIL]"
        echo "$output"
        echo "---"
    } >> /var/log/cryptex-health.log
fi
