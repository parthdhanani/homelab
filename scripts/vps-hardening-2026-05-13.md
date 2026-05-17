---
captured_at: 2026-05-13T17:30:00Z
author: Claude Code
contributor: Parth Dhanani
---

# VPS Hardening Session — 2026-05-13

## Security Fixes

### code-server bind restriction
- **Change:** `bind-addr: 0.0.0.0:8084` → `bind-addr: 127.0.0.1:8084` in `/home/ubuntu/.config/code-server/config.yaml`
- **Pattern:** CF tunnel (Docker) → nginx on `172.18.0.1:8084` → code-server on `127.0.0.1:8084`
- **nginx config:** `/etc/nginx/sites-enabled/code-server-proxy.conf` — listens on `172.18.0.1:8084`, proxies to `127.0.0.1:8084` with WebSocket upgrade headers
- **Cloudflare Tunnel routing:** Set service URL to `http://172.18.0.1:8084` in Zero Trust → Tunnels → Public Hostnames

### Kopia credentials removed from process args
- **Before:** `kopia server start ... --server-password=xxx --server-control-password=xxx` visible in `ps aux`
- **Fix:** Added `KOPIA_SERVER_USERNAME` and `KOPIA_SERVER_PASSWORD` env vars to docker-compose.yml kopia service
- **After:** `kopia server start --insecure --address=0.0.0.0:51515` (no credentials in cmdline)
- **Healthcheck fix:** Changed from `kopia server status` (picks up env vars, gets 403) to `curl -so /dev/null -w '%{http_code}' http://127.0.0.1:51515/ | grep -q 401`

### iptables fail2ban deduplication
- **Problem:** fail2ban rules accumulated (4x duplicates) because iptables-save persisted f2b chains, then f2b re-added on restart
- **Fix:** Stop fail2ban → delete stale rules from INPUT → restart fail2ban (adds once clean)
- **Persistence fix:** Modified `/etc/systemd/system/iptables-save.service` ExecStart to pipe through `grep -v "f2b-"` before saving to `rules.v4`

### Container security
- **searxng:** Changed `no-new-privileges=false` → `no-new-privileges=true` (confirmed healthy)
- **iscsid + iscsid.socket:** Disabled (unused iSCSI, was auto-activatable via socket)
- **Oracle unified-monitoring-agent:** Disabled (telemetry to Oracle Cloud)

### Audit logging
- **auditd** installed and configured at `/etc/audit/rules.d/cryptex.rules`
- Rules: auth.log writes, sudo exec, Docker socket access, SSH key changes, cron modifications

## Self-Sustaining Automation

### watchdog.sh (`/opt/cryptex/scripts/watchdog.sh`)
- Runs every 5 minutes via cron
- Restarts containers stuck in `unhealthy` state
- Disk exhaustion guard: auto-prunes Docker images + old backup archives at 95% disk
- Warning alert at 85% disk
- Truncates any single cryptex log >50MB to 10MB

### backup-verify.sh (`/opt/cryptex/scripts/backup-verify.sh`)
- Weekly (Saturday 4:00 AM UTC) via cron
- Verifies latest kopia snapshot on Backblaze B2 with 10% file sampling
- Confirmed working: 3 daily snapshots present, verification PASS

### logrotate
- Config at `/etc/logrotate.d/cryptex`
- Daily rotation, 14-day retention, compress+delaycompress for all `/var/log/cryptex-*.log`

## Infrastructure Patterns

### CF Tunnel → Host Service pattern
All services accessed via CF tunnel follow this bridge pattern because cloudflared runs in Docker:
```
CF Tunnel → cloudflared container → 172.18.0.1:<port> → nginx/socat on host → 127.0.0.1:<port> → service
```
- **zellij:** socat systemd service (`zellij-proxy.service`) bridges 172.18.0.1:8082 → 127.0.0.1:8082
- **code-server:** nginx config bridges 172.18.0.1:8084 → 127.0.0.1:8084
- **alist:** nginx proxy in `/etc/nginx/sites-enabled/alist-proxy.conf`

### Docker restart policy
All containers use `unless-stopped` — Docker auto-restarts crashed containers.

### Kopia backup chain
Daily cron → `backup.sh` → postgres dump + validation + tar.gz → kopia snapshot → Backblaze B2 (eu-central-003)
Weekly cron → `backup-verify.sh` → kopia snapshot verify (10% file sample)
