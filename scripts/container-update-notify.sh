#!/bin/bash
# Daily container update check — sends email if any semver-pinned image has a newer version
# Added to cron by infra-cleanup-2026-05-17
set +e

TO="${ADMIN_EMAIL:-admin@${DOMAIN:-yourdomain.com}}"
UPDATES=()

while IFS=' ' read -r CNAME IMAGE; do
    # Skip digest-pinned images (stable, no version drift possible)
    [[ "$IMAGE" == *"@sha256:"* ]] && continue
    # Skip :latest (not pinned, Dockhand handles these visually)
    [[ "$IMAGE" == *":latest"* ]] && continue

    # Pull manifest only (no layer download) — compares remote manifest digest with local.
    # Bug fixed 2026-07-09: .RepoDigests is an image-level field, not a container-level one —
    # querying $CNAME here always returned empty, so this check silently never fired since
    # it was added (infra-cleanup-2026-05-17).
    LOCAL_DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null \
        | grep -o 'sha256:[a-f0-9]*')
    [ -z "$LOCAL_DIGEST" ] && continue

    # Bug fixed 2026-07-09: `docker manifest inspect` + drilling into the arm64 platform entry
    # returns a per-platform manifest digest, not the manifest-LIST digest stored in RepoDigests —
    # comparing the two always mismatched even when fully up to date. imagetools --raw + sha256sum
    # reproduces the exact digest a `docker pull` would record, so it's directly comparable.
    REMOTE_DIGEST="sha256:$(docker buildx imagetools inspect --raw "$IMAGE" 2>/dev/null | sha256sum | awk '{print $1}')"

    [ "$REMOTE_DIGEST" = "sha256:" ] && continue

    if [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
        UPDATES+=("  $CNAME  →  $IMAGE")
    fi
done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)

[ ${#UPDATES[@]} -eq 0 ] && exit 0

{
    echo "To: $TO"
    echo "From: ${ADMIN_EMAIL:-admin@${DOMAIN:-yourdomain.com}}"
    echo "Subject: [Cryptex] Container updates available ($(date +%Y-%m-%d))"
    echo "Content-Type: text/plain"
    echo ""
    echo "The following containers have newer images available:"
    echo ""
    printf '%s\n' "${UPDATES[@]}"
    echo ""
    echo "Review at https://docker.${DOMAIN:-yourdomain.com}"
    echo "Run update: bash /opt/cryptex/update.sh"
} | msmtp "$TO" 2>/dev/null

echo "$(date '+%Y-%m-%d %H:%M') update-notify: ${#UPDATES[@]} update(s) found, email sent" >> /var/log/cryptex-updates.log
