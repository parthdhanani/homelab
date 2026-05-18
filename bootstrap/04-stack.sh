#!/usr/bin/env bash
# 04-stack.sh — bring up the Docker Compose stack.
# Idempotent. `docker compose up -d` is naturally idempotent: containers already
# matching the spec are left alone, only changed/missing ones recreate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

# Run as ubuntu (docker group); allow root only if explicitly forced.
if [ "$EUID" -eq 0 ] && [ "${ALLOW_ROOT:-0}" != "1" ]; then
  fail "do not run as root; run as ubuntu (member of docker group). Set ALLOW_ROOT=1 to override."
fi

log "============ 04-stack: docker compose ============"

cd "$REPO_ROOT"
[ -f docker-compose.yml ] || fail "missing $REPO_ROOT/docker-compose.yml"
[ -f .env ] || fail "missing $REPO_ROOT/.env (run 03-secrets.sh first)"

# Regenerate pgbouncer userlist from .env (idempotent)
if [ -f "$REPO_ROOT/scripts/gen-pgbouncer-userlist.sh" ]; then
  chmod +x "$REPO_ROOT/scripts/gen-pgbouncer-userlist.sh"
  REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/gen-pgbouncer-userlist.sh" || warn "pgbouncer userlist regen failed (ok on first deploy if pgbouncer not used yet)"
fi

# Validate compose file before bringing up
if docker compose config -q 2>/dev/null; then
  ok "compose config valid"
else
  fail "compose config invalid; fix before retrying"
fi

# Ensure host volume dirs exist (containers will create most via 'data/' bind mounts)
mkdir -p data backups

# Pull updates without forcing recreate
log "pulling images..."
docker compose pull --quiet 2>&1 | tail -5 || warn "pull had warnings"

log "bringing stack up..."
docker compose up -d --remove-orphans

# Wait for core services
log "waiting for core services..."
for svc in cryptex-postgres cryptex-redis cryptex-cloudflared; do
  wait_for_container "$svc" 60 || true
done

# Status summary
log "stack status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}"

log "============ 04-stack: complete ============"
