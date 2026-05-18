#!/usr/bin/env bash
# replicate.sh — one-command bootstrap of a fresh Oracle VPS to a running Cryptex stack.
#
# Modes:
#   ./replicate.sh                  full run (00 → 05). Interactive .env step.
#   ./replicate.sh --skip-secrets   useful when .env already exists (cloud-init etc.)
#   ./replicate.sh --skeleton-env   write placeholder .env, do not prompt (you fill in later)
#   ./replicate.sh --check-only     verify state of system/.env without changing anything
#   ./replicate.sh --restore        run 06-restore.sh after 04-stack.sh
#
# Re-running this script is safe: every step is idempotent.
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"
export REPO_ROOT

# Args
SKIP_SECRETS=0
SKELETON_ENV=0
CHECK_ONLY=0
DO_RESTORE=0
for arg in "$@"; do
  case "$arg" in
    --skip-secrets) SKIP_SECRETS=1 ;;
    --skeleton-env) SKELETON_ENV=1 ;;
    --check-only)   CHECK_ONLY=1 ;;
    --restore)      DO_RESTORE=1 ;;
    --help|-h)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $arg"; exit 2 ;;
  esac
done

. "$REPO_ROOT/bootstrap/lib.sh"

banner() {
  printf '\n\033[1;36m=========================================================\033[0m\n'
  printf '\033[1;36m  %s\033[0m\n' "$1"
  printf '\033[1;36m=========================================================\033[0m\n\n'
}

# Privilege check: we need both root and ubuntu phases. The simplest pattern
# is: invoke this script as ubuntu, escalate per-step with sudo.
if [ "$EUID" -eq 0 ] && [ "${ALLOW_ROOT:-0}" != "1" ]; then
  fail "run as the ubuntu user; sudo will be invoked per-step. Set ALLOW_ROOT=1 to override."
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  banner "CHECK-ONLY"
  log "docker:"; docker --version 2>/dev/null || warn "docker not installed"
  log ".env keys check:"; "$REPO_ROOT/bootstrap/03-secrets.sh" --check || warn ".env incomplete"
  log "compose validate:"; (cd "$REPO_ROOT" && docker compose config -q && ok "valid") || warn "compose invalid"
  log "system services:"
  for s in docker fail2ban nginx auditd cron; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then ok "$s active"; else warn "$s not active"; fi
  done
  exit 0
fi

banner "Phase 00 — base system (sudo)"
sudo -E REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bootstrap/00-system.sh"

banner "Phase 01 — systemd units (sudo)"
sudo -E REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bootstrap/01-systemd.sh"

banner "Phase 02 — cron jobs (sudo)"
sudo -E REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/bootstrap/02-cron.sh"

banner "Phase 03 — secrets"
if [ "$SKIP_SECRETS" -eq 1 ]; then
  skip "skipping 03-secrets (--skip-secrets)"
elif [ "$SKELETON_ENV" -eq 1 ]; then
  "$REPO_ROOT/bootstrap/03-secrets.sh" --skeleton
else
  "$REPO_ROOT/bootstrap/03-secrets.sh" --interactive
fi

banner "Phase 04 — docker stack"
"$REPO_ROOT/bootstrap/04-stack.sh"

banner "Phase 05 — user dotfiles"
"$REPO_ROOT/bootstrap/05-dotfiles.sh"

if [ "$DO_RESTORE" -eq 1 ]; then
  banner "Phase 06 — restore from Kopia (you will be prompted)"
  "$REPO_ROOT/bootstrap/06-restore.sh" --confirm
fi

banner "DONE"
cat <<EOF
Next steps:
  - Verify containers:           docker ps --format 'table {{.Names}}\t{{.Status}}'
  - Tail unhealthy logs:         docker compose logs --tail=50 <service>
  - Cloudflare Tunnel:           ensure TUNNEL_TOKEN is set in .env; confirm in CF dashboard
  - Backups:                     /opt/cryptex/scripts/backup.sh once, then check Kopia
  - Re-run this script anytime — it is fully idempotent.
EOF
