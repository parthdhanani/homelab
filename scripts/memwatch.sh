#!/bin/bash
# Lightweight 1-min memory-history logger — added 2026-07-05 after a
# multi-hour swap-thrashing freeze left zero forensic trail.
# Not a fix by itself (earlyoom handles that); this exists purely so
# a future incident has an actual "who did it" answer instead of a blackout.
LOG=/var/log/cryptex-memwatch/mem.log
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    echo "=== $TS ==="
    free -m
    docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null
} >> "$LOG"
# keep last ~2 days at 1-min resolution before rotating (~3k lines/day * 2)
tail -n 12000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
