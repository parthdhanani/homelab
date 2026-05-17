# cryptex

Full infrastructure stack for psidex.com — Oracle Cloud ARM64, ~30 Docker containers, Cloudflare Tunnel.

> **Private repo.** Clone this to restore the exact setup on a new VPS.

See [homelab](https://github.com/parthdhanani/homelab) for the sanitized public reference with architecture diagram.

---

## Restore Sequence

Complete step-by-step to go from a fresh Oracle Cloud ARM64 instance to the full running stack.

### 1. Provision the VPS

Oracle Cloud Free Tier: Ubuntu 22.04, ARM64, 4 vCPU / 24GB RAM.

In Oracle Console → Networking → Security Lists: open ports **80** and **443** (TCP ingress). SSH (22) should already be open.

### 2. Bootstrap the host

```bash
# SSH in as ubuntu, then:
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex

# Bootstrap: iptables, Docker, swap, packages
sudo ./scripts/bootstrap.sh
```

`bootstrap.sh` sets up:
- Docker CE + compose plugin
- iptables rules (`-I INPUT 6`) for ports 80/443 (SSH already open)
- 4 GB swapfile (Oracle free tier has no swap by default)
- System packages: jq, socat, shellcheck, python3, etc.

### 3. Configure environment

```bash
cp .env.example .env
vim .env          # fill in ALL values — see comments in .env.example
chmod 600 .env
```

Key values required before first start:
- `CF_TUNNEL_TOKEN` — from Cloudflare Zero Trust dashboard
- All `*_DB_PASSWORD` values
- `MOODLE_ADMIN_PASSWORD`, `TRAXLRS_APP_KEY`, `FORGEJO_SECRET_KEY`
- `N8N_ENCRYPTION_KEY`, `KOPIA_PASSWORD`
- `VAULTWARDEN_ADMIN_TOKEN` — argon2id hash, generate with: `./scripts/gen-vaultwarden-token.sh`

### 4. Start the container stack

```bash
cd /opt/cryptex
docker compose up -d

# Watch startup
docker compose logs -f --tail 20
```

Allow 2-3 minutes for PostgreSQL init and Moodle first-run setup.

### 5. Install CLI tools and dotfiles

```bash
# Run as ubuntu (not root)
cd /opt/cryptex
bash scripts/install-tools.sh
```

This installs:
- **npm globals**: `@anthropic-ai/claude-code`, `@google/gemini-cli`, `claude-code-cache-fix`, `codeburn`
- **Python tools**: graphifyy, mkdocs-material, mkdocs-roamlinks-plugin, watchdog
- **Shell tools**: starship, zoxide, code-server, socat, jq, shellcheck
- **Dotfiles**: `~/.bashrc`, `~/.config/starship.toml`, `~/.claude/` (hooks, commands, settings, statusline)
- **Systemd services**: `code-server` (port 8080), `claude-cache-proxy` (port 9801)
- **Root crontab**: from `crontab.txt`

### 6. Authenticate AI tools

```bash
source ~/.bashrc

# Claude Code — requires ANTHROPIC_API_KEY in environment or:
claude auth login

# Gemini CLI
gemini auth login
```

### 7. Fix OB1 MCP URL

OB1 runs as a container; its IP is assigned at runtime:

```bash
OB1_IP=$(docker inspect cryptex-ob1 --format '{{.NetworkSettings.Networks.cryptex_default.IPAddress}}')
echo "OB1 IP: $OB1_IP"

# Update ~/.claude/settings.json → mcpServers.ob1.url
# e.g. http://172.18.0.52:8000/mcp
```

The user-prompt-submit hook also queries OB1 directly — update the IP there if it changed:
```bash
grep -n '172.18.0' ~/.claude/hooks/user-prompt-submit.sh
grep -n '172.18.0' ~/.claude/hooks/session-summary-to-pkm.sh
```

### 8. Restore from Kopia backup (disaster recovery)

```bash
# If restoring data from a previous installation:
./scripts/restore.sh /path/to/cryptex-TIMESTAMP.tar.gz

# Or restore from Kopia offsite (Backblaze B2):
# 1. Connect Kopia to B2 first (needs KOPIA_PASSWORD from .env):
docker exec cryptex-kopia kopia repository connect b2 \
    --bucket=YOUR_BUCKET --key-id=YOUR_KEY --key=YOUR_SECRET

# 2. List snapshots:
docker exec cryptex-kopia kopia snapshot list /backups

# 3. Restore:
docker exec cryptex-kopia kopia restore <snapshot-id> /opt/cryptex/backups/restored/
./scripts/restore.sh /opt/cryptex/backups/restored/cryptex-TIMESTAMP.tar.gz
```

### 9. Set up PKM vault

```bash
# Vault lives at /opt/cryptex/data/pkm (gitignored, backed up by backup.sh)
# Symlink for convenience:
ln -s /opt/cryptex/data/pkm ~/pkm

# If restoring from backup, pkm/ is included in the tarball.
# If starting fresh, clone or copy your vault here.
```

### 10. Verify

```bash
./scripts/health-check.sh

# Check CF tunnel is routing (all routes in docker-compose tunnel config)
docker logs cryptex-cloudflared --tail 20

# Check all containers healthy
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

---

## Day-to-Day

```bash
# Launch Claude Code workspace
ai                          # alias: cd ~/AI_Space && claude

# Health check
/opt/cryptex/scripts/health-check.sh

# Update single service
/opt/cryptex/scripts/update.sh <service>

# Update all services
/opt/cryptex/scripts/update.sh

# Manual backup
/opt/cryptex/scripts/backup.sh

# View logs
docker logs cryptex-<service> --tail 50 -f
```

---

## Crontab

Exact crontab is in `crontab.txt`. Install via:

```bash
sudo crontab crontab.txt
```

| Schedule | Job |
|---|---|
| `*/5 * * * *` | health-check-cron.sh + watchdog.sh |
| `*/15 * * * *` | notes-build.sh (Quartz/PKM static site) |
| `0 3 * * *` | backup.sh (daily at 03:00 UTC) |
| `0 4 * * 0` | docker system prune (Sunday) |
| `0 5 * * 0` | update.sh (Sunday) |
| `0 4 * * 6` | backup-verify.sh (Saturday) |
| `* * * * *` | Moodle cron |

---

## Dotfiles layout

```
dotfiles/
├── .bashrc                     # Shell config: aliases, PATH, starship/zoxide init
├── starship.toml               # Prompt: no-runtimes, fast
├── claude/
│   ├── settings.json           # Claude Code: hooks, MCP servers, permissions
│   ├── statusline-command.sh   # Status line script
│   ├── statusline.py           # Status line Python renderer
│   ├── claudeignore-template   # Auto-applied per project
│   ├── hooks/
│   │   ├── pre-tool-use.sh         # Safety: blocks force-push, cred access, unsafe mounts
│   │   ├── user-prompt-submit.sh   # OB1 semantic search + skill injection on every prompt
│   │   ├── session-summary-to-pkm.sh # Summarize session → PKM inbox + OB1 memory
│   │   ├── pre-compact.sh          # Inject context before autoCompact
│   │   ├── post-compact.sh         # Restore memory after compaction
│   │   ├── post-edit-lint.sh       # yamllint/shellcheck on edited files
│   │   ├── managed_hooks.sh        # SessionStart hook: show CLAUDE.md + memory
│   │   ├── managed_pre_compact.sh  # Compact helper
│   │   ├── skill-inject.py         # Skill library fuzzy match
│   │   └── validators/
│   │       └── iptables-check.sh   # Oracle VPS iptables safety validator
│   └── commands/
│       ├── dynamic.md, flow.md, plan.md, save.md, sk.md
└── code-server/
    └── config.yaml.example     # code-server: bind 127.0.0.1:8080, no auth
```

---

## Stack

| Category | Services |
|---|---|
| **Database** | PostgreSQL 16, PgBouncer, Redis, FerretDB (MongoDB-compatible) |
| **Auth** | Vaultwarden, Pocket ID (OIDC) |
| **LMS** | Moodle + TRAX xAPI LRS |
| **Dev** | Forgejo, Woodpecker CI, n8n |
| **AI** | LibreChat, SearXNG, OB1 memory engine |
| **Monitoring** | Uptime Kuma, Dockhand, AdGuard Home |
| **Storage** | Alist/OpenList, Kopia → Backblaze B2 |
| **Utilities** | Miniflux, ActualBudget, Shlink, Umami, Stirling PDF, IT-Tools |
| **Network** | Cloudflare Tunnel, code-server, Zellij web terminal |
| **CLI** | Claude Code, Gemini CLI, claude-code-cache-fix proxy (port 9801) |
