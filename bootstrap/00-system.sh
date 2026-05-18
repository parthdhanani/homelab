#!/usr/bin/env bash
# 00-system.sh — base system: packages, docker, firewall, fail2ban, sysctl, nginx
# Idempotent. Safe to re-run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
require_root

log "============ 00-system: base system layer ============"

# -------- apt prereqs --------
log "-- apt update --"
DEBIAN_FRONTEND=noninteractive apt-get update -qq

ensure_apt_batch \
  ca-certificates curl gnupg lsb-release \
  iptables iptables-persistent netfilter-persistent \
  fail2ban \
  nginx \
  rsync \
  jq \
  git \
  pwgen \
  unzip \
  htop \
  net-tools \
  dnsutils \
  cron \
  logrotate \
  auditd \
  sudo

# -------- docker --------
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker-ce"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  ensure_apt_batch docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "docker installed"
else
  skip "docker already installed: $(docker --version)"
fi

# Add ubuntu to docker group
if id -nG ubuntu | grep -qw docker; then
  skip "ubuntu already in docker group"
else
  usermod -aG docker ubuntu
  ok "added ubuntu to docker group (re-login required for it to take effect)"
fi

# Optional docker daemon config
if [ -f "$REPO_ROOT/system/docker-daemon.json" ]; then
  install_file "$REPO_ROOT/system/docker-daemon.json" /etc/docker/daemon.json 644 root:root
  systemctl restart docker || warn "docker restart failed"
fi

# -------- sysctl hardening --------
if [ -d "$REPO_ROOT/system/sysctl/sysctl.d" ]; then
  for f in "$REPO_ROOT/system/sysctl/sysctl.d"/99-cryptex*.conf; do
    [ -f "$f" ] && install_file "$f" "/etc/sysctl.d/$(basename "$f")" 644 root:root
  done
  sysctl --system >/dev/null 2>&1 && ok "sysctl reloaded"
fi

# -------- iptables --------
# Restore base ruleset. f2b will add its own chains on top.
if [ -f "$REPO_ROOT/system/iptables/rules.v4" ]; then
  if iptables-save | diff -q - "$REPO_ROOT/system/iptables/rules.v4" >/dev/null 2>&1; then
    skip "iptables: rules already match"
  else
    log "loading iptables rules from system/iptables/rules.v4"
    iptables-restore < "$REPO_ROOT/system/iptables/rules.v4"
    ok "iptables rules loaded"
  fi
  # Persist for next boot via netfilter-persistent
  install -d /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  ok "iptables rules persisted to /etc/iptables/rules.v4"
fi

# -------- fail2ban --------
if [ -d "$REPO_ROOT/system/fail2ban/jail.d" ]; then
  for f in "$REPO_ROOT/system/fail2ban/jail.d"/*; do
    [ -f "$f" ] && install_file "$f" "/etc/fail2ban/jail.d/$(basename "$f")" 644 root:root
  done
fi
if [ -f "$REPO_ROOT/system/fail2ban/jail.local" ]; then
  install_file "$REPO_ROOT/system/fail2ban/jail.local" /etc/fail2ban/jail.local 644 root:root
fi
systemctl enable --quiet fail2ban
systemctl restart fail2ban || warn "fail2ban restart failed"
ok "fail2ban configured"

# -------- nginx (host, for non-tunneled local proxies like zellij/code-server) --------
if [ -d "$REPO_ROOT/system/nginx/sites-enabled" ]; then
  for f in "$REPO_ROOT/system/nginx/sites-enabled"/*; do
    [ -f "$f" ] && install_file "$f" "/etc/nginx/sites-enabled/$(basename "$f")" 644 root:root
  done
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl start nginx
    ok "nginx reloaded"
  else
    warn "nginx config test failed; skipping reload"
  fi
fi

# -------- auditd --------
systemctl enable --quiet auditd || true
systemctl start auditd 2>/dev/null || true

log "============ 00-system: complete ============"
