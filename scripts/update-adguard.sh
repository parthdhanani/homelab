#!/bin/bash
# CRYPTEX — Update AdGuard Home config from template
# Safe to run on a live VPS: preserves admin users + custom rewrites
# Applies: filter lists, user_rules, dns settings, filtering settings
#
# Usage: ./scripts/update-adguard.sh
# Note: requires sudo access (adguard conf dir is owned by root)

set -euo pipefail

COMPOSE_DIR="/opt/cryptex"
# shellcheck disable=SC1090
[ -f "${COMPOSE_DIR}/.env" ] && source "${COMPOSE_DIR}/.env"
DOMAIN="${DOMAIN:-psidex.com}"
TEMPLATE="${COMPOSE_DIR}/configs/adguard/AdGuardHome.yaml"
LIVE="${COMPOSE_DIR}/data/adguard/conf/AdGuardHome.yaml"
BACKUP="${LIVE}.bak.$(date +%Y%m%d_%H%M%S)"

echo ""
echo "AdGuard Config Update"
echo "──────────────────────"

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found at $TEMPLATE"
    exit 1
fi

# Fresh install path (no live config yet)
if [ ! -f "$LIVE" ] && ! sudo test -f "$LIVE" 2>/dev/null; then
    sudo mkdir -p "$(dirname "$LIVE")"
    sudo cp "$TEMPLATE" "$LIVE"
    echo "Fresh install: template copied as-is"
    exit 0
fi

# Ensure python3 + PyYAML available
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "Installing python3-yaml..."
    sudo apt-get install -y python3-yaml -qq
fi

# Backup live config (needs sudo — adguard conf owned by root)
sudo cp "$LIVE" "$BACKUP"
echo "Backed up: $BACKUP"

# Merge: apply template but preserve users + rewrites from live config
# Write to a temp file first (no sudo needed for /tmp), then sudo move into place
TMPFILE=$(mktemp /tmp/adguard-merged-XXXXXX.yaml)

python3 - "$TEMPLATE" "$BACKUP" "$TMPFILE" << 'PYEOF'
import yaml, sys

template_path, backup_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(template_path) as f:
    template = yaml.safe_load(f)

# Read backup via stdin content (passed from sudo cat)
with open(backup_path) as f:
    live = yaml.safe_load(f)

# Preserve admin accounts (MUST — template has users: [] which triggers setup wizard)
template['users'] = live.get('users', [])

# Preserve any custom DNS rewrites added via UI (not in template by default)
if live.get('filtering', {}).get('rewrites'):
    template['filtering']['rewrites'] = live['filtering']['rewrites']

with open(out_path, 'w') as f:
    yaml.dump(template, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print("  Config merged (users and rewrites preserved)")
PYEOF

# Move merged file into place with correct ownership
sudo cp "$TMPFILE" "$LIVE"
sudo chown root:root "$LIVE"
rm -f "$TMPFILE"

echo ""
echo "Restarting AdGuard..."
cd "$COMPOSE_DIR"
docker compose up -d --no-deps --force-recreate adguard

echo ""
echo "Waiting for AdGuard to be healthy..."
HEALTHY=0
for i in $(seq 1 30); do
    STATUS=$(docker inspect cryptex-adguard --format='{{.State.Health.Status}}' 2>/dev/null || echo "starting")
    if [ "$STATUS" = "healthy" ]; then
        printf "\r%-40s\n" "  AdGuard: healthy"
        HEALTHY=1
        break
    fi
    if [ "$i" -eq 30 ]; then
        printf "\r%-40s\n" ""
        echo "WARNING: AdGuard not healthy after 60s — check logs:"
        echo "  docker logs cryptex-adguard --tail 30"
    fi
    printf "  waiting... (%s/30)\r" "$i"
    sleep 2
done

echo ""
echo "Done. Verify:"
echo "  https://dns.${DOMAIN} → Filters → DNS Blocklists (should show 6 lists)"
echo "  https://dns.${DOMAIN} → Filters → Custom Filtering Rules"
echo ""
echo "To rollback: sudo cp $BACKUP $LIVE && docker compose restart adguard"
