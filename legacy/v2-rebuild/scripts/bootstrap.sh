#!/bin/bash
# CRYPTEX — Bootstrap for existing Ubuntu 22.04/24.04 servers
# Replicates everything cloud-init does on a fresh Oracle VPS
#
# Modular: asks before each step — skip anything already done
# Idempotent: safe to re-run, each step checks current state first
#
# Usage: sudo ./scripts/bootstrap.sh

set -euo pipefail

# ── Must be root ──
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo: sudo ./scripts/bootstrap.sh"
    exit 1
fi

# ── Flags ──
# --yes / -y : non-interactive mode — run all steps without prompting
NONINTERACTIVE=0
for _arg in "$@"; do
    [[ "$_arg" == "--yes" || "$_arg" == "-y" ]] && NONINTERACTIVE=1
done

CRYPTEX_USER="${SUDO_USER:-ubuntu}"
CRYPTEX_DIR="/opt/cryptex"
LOG_FILE="/var/log/cryptex-bootstrap.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "CRYPTEX — Bootstrap (Existing System)"
echo "────────────────────────────────────────"
echo "Target user : ${CRYPTEX_USER}"
echo "Target dir  : ${CRYPTEX_DIR}"
echo "Log         : ${LOG_FILE}"
if [ "$NONINTERACTIVE" -eq 1 ]; then
    echo "Mode        : NON-INTERACTIVE (--yes)"
else
    echo ""
    echo "Each step will ask for confirmation. Press Enter to accept [Y]."
    echo "Type 'n' to skip a step (if already configured)."
fi
echo ""

# ── Helper: ask before running a step ──
# Usage: run_step "Step title" "description" <function_name>
run_step() {
    local title="$1"
    local desc="$2"
    local fn="$3"

    echo ""
    echo "┌─ ${title}"
    echo "│  ${desc}"
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        echo "└─ Running (--yes)..."
    else
        read -rp "└─ Run this step? [Y/n]: " choice
        if [[ "$choice" == "n" || "$choice" == "N" ]]; then
            echo "   → Skipped."
            return 0
        fi
        echo "   → Running..."
    fi
    "$fn"
    echo "   → Done."
}

# ────────────────────────────────────────
# Step functions
# ────────────────────────────────────────

step_timezone() {
    timedatectl set-timezone UTC
    echo "   Timezone: $(timedatectl show -p Timezone --value)"
}

step_swap() {
    if [ -f /swapfile ] || swapon --show | grep -q .; then
        echo "   Swap already active:"
        swapon --show
        if [ "$NONINTERACTIVE" -eq 0 ]; then
            read -rp "   Re-create swap? (y/N): " redo
            [[ "$redo" != "y" && "$redo" != "Y" ]] && return 0
        else
            echo "   Swap exists — skipping re-creation."
            return 0
        fi
    fi
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo "   4GB swap created and enabled."
}

step_packages() {
    export DEBIAN_FRONTEND=noninteractive
    # Force-purge Oracle Cloud agents before any apt operations.
    # These packages are injected at VPS provisioning time and are not in standard
    # Ubuntu repos. If dpkg interrupted their install they block all apt-get upgrade
    # calls regardless of dpkg --configure -a. Safe to remove — Oracle re-injects
    # them on reprovision; we don't use them.
    for _oracle_pkg in unified-monitoring-agent oracle-cloud-agent oracle-cloud-agent-updater; do
        if dpkg -l "$_oracle_pkg" 2>/dev/null | grep -qE '^[a-z][A-Z]|^ii|^iU|^iF'; then
            echo "   Purging Oracle agent: ${_oracle_pkg}"
            dpkg --purge --force-all "$_oracle_pkg" 2>/dev/null || true
        fi
    done
    # Recover from any remaining interrupted dpkg state
    echo "   Repairing any interrupted dpkg state..."
    dpkg --configure -a 2>/dev/null || true
    echo "   Updating package lists..."
    apt-get update -qq
    echo "   Upgrading existing packages..."
    apt-get upgrade -y -qq
    echo "   Installing dependencies..."
    apt-get install -y -qq \
        curl git htop vim net-tools fail2ban unattended-upgrades \
        apache2-utils uuid-runtime sqlite3 rclone \
        iptables-persistent debconf-utils
    # Pre-seed iptables-persistent (suppress prompts)
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
}

step_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "   Docker already installed: $(docker --version)"
        read -rp "   Re-configure daemon only (skip install)? [Y/n]: " skip_install
        if [[ "$skip_install" != "n" && "$skip_install" != "N" ]]; then
            _configure_docker_daemon
            return 0
        fi
    fi
    echo "   Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    _configure_docker_daemon
    systemctl enable docker
    systemctl restart docker
    usermod -aG docker "${CRYPTEX_USER}"
    echo "   Added ${CRYPTEX_USER} to docker group (re-login required)."
}

_configure_docker_daemon() {
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "no-new-privileges": true,
  "userland-proxy": false,
  "iptables": false,
  "live-restore": true
}
EOF
    systemctl restart docker
    echo "   Docker daemon configured (iptables: false)."
}

step_iptables() {
    echo ""
    echo "   WARNING: This sets INPUT policy to DROP."
    echo "   Only SSH (port 22), ICMP, and Docker bridge traffic will be allowed."
    echo "   Confirm you are connected via SSH on port 22."
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        read -rp "   Continue with iptables setup? [Y/n]: " ipt_confirm
        [[ "$ipt_confirm" == "n" || "$ipt_confirm" == "N" ]] && echo "   Skipped iptables." && return 0
    fi

    cat > /etc/iptables/rules.v4 <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT
-A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
-A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
-A INPUT -s 172.17.0.0/16 -j ACCEPT
-A INPUT -s 172.18.0.0/16 -j ACCEPT
-A INPUT -i tailscale0 -d 172.18.0.0/16 -j ACCEPT
-A FORWARD -s 172.17.0.0/16 -j ACCEPT
-A FORWARD -s 172.18.0.0/16 -j ACCEPT
-A FORWARD -i tailscale0 -d 172.18.0.0/16 -j ACCEPT
-A FORWARD -d 172.17.0.0/16 -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -d 172.18.0.0/16 -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -o tailscale0 -m state --state ESTABLISHED,RELATED -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 172.17.0.0/16 ! -d 172.17.0.0/16 -j MASQUERADE
-A POSTROUTING -s 172.18.0.0/16 ! -d 172.18.0.0/16 -j MASQUERADE
COMMIT
EOF

    cat > /etc/iptables/rules.v6 <<'EOF'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
COMMIT
EOF

    iptables-restore < /etc/iptables/rules.v4
    ip6tables-restore < /etc/iptables/rules.v6
    systemctl enable netfilter-persistent 2>/dev/null || true
    echo "   iptables rules applied and persisted."
}

step_sysctl() {
    cat > /etc/sysctl.d/99-cryptex.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
EOF
    sysctl --system 2>/dev/null | grep -E 'ip_forward|disable_ipv6|inotify' || true
    echo "   Kernel parameters written to /etc/sysctl.d/99-cryptex.conf"
}

step_dns() {
    echo "   This will disable systemd-resolved and set static DNS (1.1.1.1 / 8.8.8.8)."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
EOF
    chattr +i /etc/resolv.conf
    echo "   DNS set to 1.1.1.1 / 1.0.0.1 / 8.8.8.8 (immutable file)."
}

step_ssh() {
    echo "   Writing /etc/ssh/sshd_config.d/99-cryptex.conf"
    echo "   Disables: root login, password auth, X11. Max tries: 3."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-cryptex.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    systemctl restart sshd
    echo "   SSH hardened and restarted."
}

step_fail2ban() {
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
maxretry = 5
bantime = 1w
findtime = 1d
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo "   fail2ban configured: SSH jail + recidive (1-week ban)."
}

step_autoupgrades() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|g' \
        /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
    sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "03:00";|g' \
        /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
    echo "   Unattended upgrades enabled (auto-reboot at 03:00 UTC)."
}

step_logrotate() {
    cat > /etc/logrotate.d/cryptex <<'EOF'
/var/log/cryptex-*.log {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  create 0640 root root
}
EOF

    # Clear static /etc/motd — dynamic script below handles it
    echo "" > /etc/motd

    # Disable Ubuntu's inconsistent landscape-sysinfo (shows randomly based on throttle)
    chmod -x /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
    chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true

    # Dynamic MOTD — runs on every SSH login, always shows fresh info
    cat > /etc/update-motd.d/99-cryptex <<'MOTD'
#!/bin/bash
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
CONTAINERS=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
UPTIME=$(uptime -p | sed 's/up //')

echo ""
echo "  CRYPTEX VPS"
echo "  ────────────────────────────────"
echo "  Memory  : ${MEM_USED} / ${MEM_TOTAL}"
echo "  Disk    : ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
echo "  Load    : ${LOAD}"
echo "  Uptime  : ${UPTIME}"
echo "  Docker  : ${CONTAINERS} containers running"
echo "  ────────────────────────────────"
echo "  cd /opt/cryptex && docker compose ps"
echo ""
MOTD
    chmod +x /etc/update-motd.d/99-cryptex

    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd
    echo "   logrotate, dynamic MOTD, time sync configured."
}

step_directories() {
    mkdir -p "${CRYPTEX_DIR}"/{configs,scripts,dockerfiles,data,backups}
    mkdir -p "${CRYPTEX_DIR}/data"/{postgres,moodle,moodledata,vaultwarden,n8n,adguard/work,adguard/conf,tianji,kopia/repository,kopia/config,kopia/cache,kopia/logs,traxlrs,tailscale,portfolio,forgejo,aquasoul,actualbudget,moodle-uploads,openwebui,searxng,pkm,quartz-output,quartz-app,rclone/config}
    chown -R "${CRYPTEX_USER}:${CRYPTEX_USER}" "${CRYPTEX_DIR}"
    chmod -R 750 "${CRYPTEX_DIR}"
    chmod -R 700 "${CRYPTEX_DIR}/data"
    echo "   /opt/cryptex directory tree created."
    echo "   Owner: ${CRYPTEX_USER}"
}

step_verify() {
    echo "   Running Docker hello-world test..."
    docker run --rm hello-world > /tmp/docker-test.log 2>&1 \
        && echo "   Docker: OK" \
        || echo "   Docker: FAILED — check /tmp/docker-test.log"
    echo ""
    echo "   Service status:"
    systemctl is-active fail2ban  && echo "   fail2ban    : active" || echo "   fail2ban    : INACTIVE"
    systemctl is-active docker    && echo "   docker      : active" || echo "   docker      : INACTIVE"
    echo ""
    echo "   iptables INPUT rules:"
    iptables -L INPUT --line-numbers -n 2>/dev/null | head -10
}

# ────────────────────────────────────────
# Run all steps
# ────────────────────────────────────────

run_step "Timezone"           "Set system timezone to UTC"                                          step_timezone
run_step "Swap"               "Create 4GB swap file (for Moodle peak usage)"                        step_swap
run_step "Packages"           "Install Docker deps, fail2ban, rclone, iptables-persistent, etc."   step_packages
run_step "Docker"             "Install Docker + Compose plugin, configure daemon (iptables:false)"  step_docker
run_step "iptables"           "DROP all inbound except SSH:22, ICMP, Docker bridges"               step_iptables
run_step "Kernel (sysctl)"    "ip_forward, disable IPv6, bridge-nf-call, inotify limits"           step_sysctl
run_step "Static DNS"         "Disable systemd-resolved, set immutable resolv.conf (1.1.1.1)"      step_dns
run_step "SSH hardening"      "No root login, no password auth, max 3 tries"                       step_ssh
run_step "fail2ban"           "SSH jail + recidive (1-week ban for repeat offenders)"              step_fail2ban
run_step "Auto-upgrades"      "Unattended security upgrades, auto-reboot at 03:00 UTC"             step_autoupgrades
run_step "Logrotate + MOTD"   "cryptex log rotation, MOTD, time sync"                             step_logrotate
run_step "Directories"        "Create /opt/cryptex/{configs,scripts,data/...} tree"                step_directories
run_step "Verify"             "Docker hello-world test, service status check"                      step_verify

# ── Cleanup ──
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo ""
echo "════════════════════════════════════════════════════"
echo "Bootstrap complete — $(date -u)"
echo "════════════════════════════════════════════════════"
echo ""
echo "IMPORTANT: ${CRYPTEX_USER} must re-login for docker group."
echo "           Run: exit  → then SSH back in"
echo "           Or:  newgrp docker  (current session only)"
echo ""
echo "Next steps (from your Mac):"
echo "  ./scripts/transfer-to-vps.sh YOUR_VPS_IP"
echo "  → SSH in: cd /opt/cryptex && ./scripts/setup-env.sh"
echo "  → Then:   sudo ./scripts/deploy.sh"
echo ""
echo "Full log: ${LOG_FILE}"
