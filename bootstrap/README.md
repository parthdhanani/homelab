# Bootstrap — Cryptex replication kit

This dir is the **idempotent** rebuild path: fresh Oracle VPS → fully running Cryptex stack.

## Quickstart on a brand-new VPS

```bash
# 1. Clone repo + SSH key staging
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex

# 2. One-shot bootstrap (asks for .env values interactively)
./replicate.sh

# OR: skeleton .env first, edit, then run
./replicate.sh --skeleton-env
nano .env             # fill in real values
./replicate.sh --skip-secrets

# Verify
./replicate.sh --check-only
```

## Phases (each script is independently re-runnable)

| Script | Privilege | What it does |
|---|---|---|
| `00-system.sh` | sudo | apt prereqs, docker-ce, iptables+f2b, nginx, sysctl, auditd |
| `01-systemd.sh` | sudo | install custom .service / .timer units, enable + start |
| `02-cron.sh` | sudo | install root + ubuntu crontabs, ensure log targets |
| `03-secrets.sh` | user | fill `.env` (interactive / skeleton / check) |
| `04-stack.sh` | user (docker) | `docker compose pull && up -d`, wait for core |
| `05-dotfiles.sh` | user | sync `~/.claude` + shell rc files (preserves runtime) |
| `06-restore.sh` | user | (opt-in, destructive) Kopia restore of `data/` |
| `lib.sh` | — | shared helpers; sourced by all phases |
| `../replicate.sh` | user | orchestrator: chains all phases with banners |

## Idempotency contract

Every helper in `lib.sh` is **check-before-act**:

- `ensure_apt` — skips if package installed
- `install_file` — skips if `cmp -s` matches
- `ensure_systemd_unit` — diffs file, only restarts if changed
- `install_cron` — diffs current vs target crontab
- `ensure_line` — `grep -F` before append
- `ensure_symlink` — verifies target before relinking

You can re-run `./replicate.sh` after manual changes — it will reconcile, never corrupt.

## Disaster recovery flow

```bash
# Fresh Oracle ARM64 Ubuntu 22.04 instance, you have SSH
ssh ubuntu@new-vps
sudo apt-get update && sudo apt-get install -y git
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex

# 1. Restore .env from your password manager (or paste values interactively)
./replicate.sh --skeleton-env
nano .env

# 2. Run base bootstrap (system + stack, no data)
./replicate.sh --skip-secrets

# 3. Restore stateful data from Kopia
./replicate.sh --restore     # asks for confirmation, runs 06-restore.sh

# 4. Verify
./replicate.sh --check-only
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Expected time: ~15-25 min on Oracle Always-Free ARM (4 OCPU / 24GB).

## What is NOT automated

- **Oracle Security List rules** — open 22/tcp, 80/tcp, 443/tcp via OCI console
- **DNS / Cloudflare records** — set per `workspace/AI_Space-README.md` domain map
- **Cloudflare Tunnel creation** — paste the `TUNNEL_TOKEN` into `.env`
- **Vaultwarden admin user, Forgejo admin user, PocketID setup** — first-login via web UI
- **Backblaze B2 bucket + access keys** — generate in B2 console, paste keys into `.env`
- **Mac-side autossh** — see `workspace/setup-mac-ssh.md`
