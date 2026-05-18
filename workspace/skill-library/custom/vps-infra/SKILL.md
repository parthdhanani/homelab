---
name: vps-infra
description: Oracle Cloud Free Tier VPS, iptables, Docker/Nginx, Cryptex stack. Use when working on the VPS, firewall rules, Docker Compose, Cloudflare Tunnel, or Moodle server config.
date: 2026-04-04
context: fork
allowed-tools: Read, Bash
paths:
  - "**/cryptex-rebuild/**"
  - "**/docker-compose.yml"
  - "**/*.nginx.conf"
---

# /vps-infra — Oracle Cloud VPS Reference

## Critical Rules — Never Break These

1. **iptables**: Always `-I INPUT 6` (never `-A INPUT`). UFW is NOT active.
2. **Two-layer security**: Every port change needs BOTH iptables AND Oracle Console Security Lists.
3. **SSH lockout**: Never DROP port 22. Always have Console access before touching iptables.
4. **Port 22 recovery**: Only Oracle Console's "Emergency" rule can recover a locked-out VPS.

## iptables Cheatsheet

```bash
# Add rule (always position 6)
sudo iptables -I INPUT 6 -p tcp --dport PORT -j ACCEPT

# List with line numbers
sudo iptables -L INPUT -n --line-numbers

# Delete by line number
sudo iptables -D INPUT LINE_NUM

# Save rules (persists across reboot)
sudo netfilter-persistent save

# View current rules
sudo iptables -L INPUT -n -v
```

## Oracle Console Security List
- Navigate: Networking → Virtual Cloud Networks → VCN → Security Lists → Default
- Ingress rules: Add stateless rule, CIDR 0.0.0.0/0, Protocol TCP, Destination Port
- Changes take ~30s to propagate

## Cryptex Stack (22 containers)

**Key services:**
| Container | Internal URL | Purpose |
|---|---|---|
| `cryptex-moodle` | `http://cryptex-moodle:80` | Moodle LMS (PHP) |
| `n8n` | `http://n8n:5678` | Workflow automation |
| `forgejo` | `http://forgejo:3000` | Git server |
| `redis` | `redis:6379` | Sessions (DB2), n8n cache (DB0) |
| `postgres` | `postgres:5432` | Moodle + Forgejo DB |
| `cloudflare-tunnel` | — | All external traffic, no open inbound ports |
| `workstation` | TTYD | Claude Code + Bun + tmux |

**Docker Compose location:** `~/cryptex-rebuild/docker-compose.yml`

**Moodle specifics:**
- Webroot: `public/` (Moodle 5.x)
- Config: env vars, `sslproxy=true`, `forcelogin=0`, `autologinguests=1`
- Redis sessions: DB 2
- PHP import: use `scorm_add_instance()` / `scorm_update_instance()` — no REST API plugin needed
- Internal calls bypass Cloudflare 100MB limit: `http://cryptex-moodle:80`

## Common Docker Commands

```bash
# Tail logs for a service
docker compose logs -f SERVICE_NAME

# Restart single service
docker compose restart SERVICE_NAME

# Shell into container
docker exec -it CONTAINER_NAME bash

# Disk cleanup (run weekly)
docker system prune -f
journalctl --vacuum-size=100M

# Check resource usage
docker stats --no-stream
```

## Nginx / Cloudflare Tunnel

- All external traffic goes through Cloudflare Tunnel — no direct inbound ports open
- Nginx handles internal routing between containers
- SSL terminates at Cloudflare; internal traffic is HTTP

## Pending Implementations

1. **SCORM → Moodle automation**: Forgejo webhook → n8n → PHP CLI in Moodle container
   - Blocker: `EXEC: 1` in socket-proxy config (currently `EXEC: 0`)
   - Design doc: `~/Downloads/scorm-moodle-automation.md`

2. **PKM Telegram bot on VPS**: Claude `--channels` with Telegram plugin in workstation container
   - Requires: Bun + tmux in workstation Dockerfile, vault volume mount
   - Design doc: `~/Downloads/pkm-telegram-plan.md`

## Troubleshooting

**Port not responding externally** → Check BOTH iptables (`iptables -L INPUT -n`) AND Oracle Console Security Lists

**Container not starting** → `docker compose logs SERVICE` — usually env var missing or port conflict

**Disk full** → `df -h`, then `docker system prune`, `journalctl --vacuum-size=100M`

**Moodle 500 error** → Check `docker compose logs cryptex-moodle`, verify Redis connection, check PHP error log

**Save findings:** `/save` to log VPS decisions to memory
