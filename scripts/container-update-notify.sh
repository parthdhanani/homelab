#!/bin/bash
# Daily container update check — sends email if any semver-pinned image has a newer version
# Added to cron by infra-cleanup-2026-05-17
set +e

TO="parth1707ster@gmail.com"
UPDATES=()

while IFS=' ' read -r CNAME IMAGE; do
    # Skip digest-pinned images (stable, no version drift possible)
    [[ "$IMAGE" == *"@sha256:"* ]] && continue
    # Skip :latest (not pinned, Dockhand handles these visually)
    [[ "$IMAGE" == *":latest"* ]] && continue

    # Pull manifest only (no layer download) — compares remote manifest digest with local
    LOCAL_DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$CNAME" 2>/dev/null \
        | grep -o 'sha256:[a-f0-9]*')
    [ -z "$LOCAL_DIGEST" ] && continue

    REMOTE_INFO=$(docker manifest inspect "$IMAGE" 2>/dev/null)
    [ -z "$REMOTE_INFO" ] && continue

    # For multi-arch manifests, find the arm64 entry; else use first entry
    REMOTE_DIGEST=$(echo "$REMOTE_INFO" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'manifests' in d:
        for m in d['manifests']:
            if m.get('platform', {}).get('architecture') == 'arm64':
                print(m['digest']); break
        else:
            print(d['manifests'][0]['digest'])
    elif 'config' in d:
        print(d['config']['digest'])
except: pass
" 2>/dev/null)

    [ -z "$REMOTE_DIGEST" ] && continue

    if [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
        UPDATES+=("  $CNAME  →  $IMAGE")
    fi
done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)

[ ${#UPDATES[@]} -eq 0 ] && exit 0

{
    echo "To: $TO"
    echo "From: parth1707ster@gmail.com"
    echo "Subject: [Cryptex] Container updates available ($(date +%Y-%m-%d))"
    echo "Content-Type: text/plain"
    echo ""
    echo "The following containers have newer images available:"
    echo ""
    printf '%s\n' "${UPDATES[@]}"
    echo ""
    echo "Review at https://docker.psidex.com"
    echo "Run update: bash /opt/cryptex/update.sh"
} | msmtp "$TO" 2>/dev/null

echo "$(date '+%Y-%m-%d %H:%M') update-notify: ${#UPDATES[@]} update(s) found, email sent" >> /var/log/cryptex-updates.log
