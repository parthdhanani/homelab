# Cryptex

Self-hosted personal-cloud stack — ~30 Docker containers behind a Cloudflare Tunnel, running on Oracle Cloud Always-Free ARM64.

This repo is **the canonical replication kit**: a fresh Oracle VPS → fully running stack with one command.

## TL;DR

```bash
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex
./replicate.sh                  # interactive bootstrap (00 → 05)
```

Re-running `./replicate.sh` at any time is safe — every step is idempotent.

For full DR (including data restore from Kopia):
```bash
./replicate.sh --restore
```

See [`bootstrap/README.md`](bootstrap/README.md) for the phase-by-phase reference.

## What's in the box

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The whole stack — Postgres, n8n, Forgejo, Vaultwarden, Moodle, LibreChat, LM, Kopia, Cloudflared, etc. |
| `replicate.sh` | One-command idempotent bootstrap. Orchestrates `bootstrap/*` |
| `bootstrap/` | Phased scripts (`00-system` → `06-restore`) — each independently re-runnable |
| `system/` | Captured host state: iptables, systemd units, nginx, fail2ban, cron, packages, sysctl |
| `dotfiles/` | `~/.claude` (skills, hooks, commands, agents) + shell rc files |
| `configs/` | Per-service config (nginx, postgres init, pgbouncer, adguard, moodle, n8n workflows, …) |
| `scripts/` | Operational scripts: backup, watchdog, health-check, container-update-notify, … |
| `dockerfiles/` | Custom images (moodle, traxlrs, portfolio, …) |
| `terraform/` | Oracle Cloud infra (optional) |
| `mcp/` | Model Context Protocol servers used by the stack |
| `workspace/` | AI_Space companion (skill-library reference, mac SSH setup, credentials template) |
| `legacy/` | Archived v2-rebuild for historical diff/reference |
| `.env.example` | Template — copy to `.env`, fill values per `SECRETS.md` |
| `SECRETS.md` | Where each secret comes from (CF console, B2, etc.) and rotation playbook |

## Stack overview

Public surface — all behind Cloudflare Tunnel, no open ports:

| Domain pattern | Service |
|---|---|
| `yourdomain.com` | Portfolio (static nginx) |
| `vault.yourdomain.com` | Vaultwarden (password manager) |
| `git.yourdomain.com` | Forgejo (git forge) |
| `chat.yourdomain.com` | LibreChat (AI frontend) |
| `n8n.yourdomain.com` | n8n (automation) |
| `learn.yourdomain.com` | Moodle LMS |
| `lrs.yourdomain.com` | TRAX xAPI LRS |
| `files.yourdomain.com` | Alist (cloud file browser) |
| `money.yourdomain.com` | ActualBudget |
| `news.yourdomain.com` | Miniflux (RSS) |
| `notes.yourdomain.com` | MkDocs (PKM published) |
| `go.yourdomain.com` | Shlink (URL shortener) |
| `analytics.yourdomain.com` | Umami |
| `id.yourdomain.com` | PocketID (OIDC provider) |
| `status.yourdomain.com` | Uptime Kuma |
| `tools.yourdomain.com` | IT-Tools |
| `search.yourdomain.com` | SearXNG |
| `pdf.yourdomain.com` | Stirling-PDF |
| `dns.yourdomain.com` | AdGuard Home (DoH + admin UI) |

Internal:

- `cryptex-postgres` + `cryptex-pgbouncer` + `cryptex-pgvector` — DB layer
- `cryptex-redis`, `cryptex-ferretdb`, `cryptex-mongodb` — auxiliary stores
- `cryptex-kopia` — encrypted backups → Backblaze B2 daily
- `cryptex-dockhand` — container management UI
- `cryptex-ob1` — semantic memory MCP, used by Claude Code

## Replication on a fresh Oracle VPS

Prereqs (one-time, manual, in OCI console):

1. Launch an Always-Free **ARM64** Ubuntu 22.04 instance (4 OCPU / 24 GB).
2. Open Security List rules: 22/tcp (SSH), 80/tcp, 443/tcp.
3. SSH key added to instance.
4. Note your Cloudflare account + a tunnel name you'll create.

Then:

```bash
ssh ubuntu@<your-vps-ip>
sudo apt-get update && sudo apt-get install -y git
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex

# Either run interactively
./replicate.sh

# Or, if you'll paste values via nano
./replicate.sh --skeleton-env
nano .env                                  # fill CHANGE_ME_* from your password manager
./replicate.sh --skip-secrets

# DR (with data restore from Kopia)
./replicate.sh --restore
```

Expected time end-to-end on Always-Free ARM: 15–25 minutes (mostly image pulls).

## What is NOT automated

- Oracle Security List + reserved public IP — manual in OCI console
- DNS A/CNAME records pointing to your CF Tunnel — manual in your DNS host
- Cloudflare Tunnel creation + token — manual in CF Zero Trust dashboard
- First-run admin user setup (Vaultwarden, Forgejo, PocketID) — via web UI
- Backblaze B2 bucket + application keys — manual in B2 console
- Mac-side autossh tunnel — see `workspace/setup-mac-ssh.md`

## Day-2 operations

```bash
# Update all containers (also runs weekly via cron)
./update.sh

# Manual backup (also runs daily at 03:00 UTC via cron)
sudo ./scripts/backup.sh

# Health check
sudo ./scripts/health-check.sh

# View what cron does
cat system/cron/root.crontab
```

## Why "replicate" instead of just "deploy"?

A deploy script gets you a running stack once. This kit makes the entire VPS — system layer + container stack + user tooling — **reproducible**: identical state on a fresh machine, no tribal knowledge. The goal is **zero-effort rebuild** the next time Oracle reclaims your instance, you migrate clouds, or you need to clone for staging.

## Security posture

- SSH: key-only auth, `PermitRootLogin no`, `MaxAuthTries 3`, Tailscale-interface bound
- fail2ban: sshd + recidive jails, `maxretry 2`, 24h ban
- iptables: default DROP policy, Oracle Security List + OS-level
- Docker socket: Tecnativa socket-proxy only (EXEC=0, START=0, STOP=0)
- All secrets in `.env` (gitignored) — `secrets.env.template` documents every variable
- CF Zero Trust Access on all internal subdomains — public portfolio + status page exempt

## Backup and recovery

Daily at 03:00 UTC:
1. `pg_dumpall` (validates all expected databases are present before proceeding)
2. OB1 pgvector dump, FerretDB dump, Vaultwarden SQLite `.backup`
3. n8n config + workflow export, Moodle uploads, PKM vault, Forgejo repos
4. Kopia snapshot of `/backups` → Backblaze B2 (encrypted, deduplicated)

Weekly Saturday: 10% sample verify against B2.

Restore from scratch: `./bootstrap/restore.sh cryptex.key` on a blank VPS.

RPO: 24h. RTO: ~30 minutes.

## License

MIT — see `LICENSE`.
