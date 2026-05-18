# Secrets — sources & rotation

This file documents **where each secret comes from**. The real values live in `.env` (gitignored). Use this as your checklist when filling out `.env` on a fresh deployment.

## Auto-generatable (run `openssl rand -base64 32` or pick `gen` in `03-secrets.sh`)

| Variable | Notes |
|---|---|
| `POSTGRES_PASSWORD` | Root DB password. Once set, do not change without coordinated container restart. |
| `MOODLE_DB_PASSWORD`, `MOODLE_ADMIN_PASSWORD` | DB password set at init; admin set at install |
| `N8N_DB_PASSWORD`, `N8N_ENCRYPTION_KEY`, `N8N_ADMIN_PASSWORD` | Encryption key locks all credentials in n8n — never rotate without re-saving every credential |
| `FORGEJO_DB_PASSWORD`, `FORGEJO_SECRET_KEY` |  |
| `MINIFLUX_DB_PASSWORD`, `MINIFLUX_ADMIN_PASSWORD` |  |
| `LIBRECHAT_DB_PASSWORD`, `LIBRECHAT_JWT_SECRET`, `LIBRECHAT_JWT_REFRESH_SECRET`, `LIBRECHAT_CREDS_KEY`, `LIBRECHAT_CREDS_IV` | CREDS_IV must be 16-char hex, CREDS_KEY 32-char hex |
| `KOPIA_PASSWORD`, `KOPIA_SERVER_PASSWORD` | Repository encryption. **Critical** — losing this means backups are unrecoverable. |
| `ACTUALBUDGET_PASSWORD`, `ADGUARD_ADMIN_PASSWORD` |  |
| `FERRETDB_DB_PASSWORD`, `OB1_DB_PASSWORD` |  |
| `POCKETID_ENCRYPTION_KEY` | OIDC server signing key — rotating invalidates all existing sessions |
| `POCKETID_FORGEJO_CLIENT_SECRET`, `POCKETID_LIBRECHAT_CLIENT_SECRET`, `POCKETID_*_CLIENT_ID` | Generate in PocketID UI per OIDC client |
| `BANK_PDF_PASSWORD`, `PKM_BOT_TOKEN`, `NOTES_CAPTURE_TOKEN` | App-specific tokens |

## External — must be fetched from a vendor console

| Variable | Where |
|---|---|
| `CF_TUNNEL_TOKEN` | Cloudflare → Zero Trust → Networks → Tunnels → your tunnel → token |
| `TS_AUTHKEY` | Tailscale → Settings → Keys → "Generate auth key" (reusable, pre-approved if used during cloud-init) |
| `B2_KEY_ID`, `B2_APP_KEY`, `B2_BUCKET_NAME`, `B2_ENDPOINT` | Backblaze B2 → Application Keys (least-privilege, per-bucket) |
| `SMTP_USER`, `SMTP_PASSWORD` | Gmail → Security → 2-Step → App Passwords (16-char) |
| `GEMINI_API_KEY` | aistudio.google.com → API key |
| `GROQ_API_KEY` | console.groq.com → API keys |
| `OPENROUTER_KEY` | openrouter.ai → settings → keys |
| `NVIDIA_NIM_API_KEY` | build.nvidia.com → personal key |
| `N8N_API_KEY` | n8n UI → Settings → n8n API → Create (per-install, after first boot) |
| `OB1_API_KEY` | OB1 / Memento MCP — generated at first run |

## Identity / config

| Variable | Notes |
|---|---|
| `DOMAIN` | Your primary apex (e.g., `psidex.com`) |
| `AQUASOUL_DOMAIN` | Secondary site, leave empty to disable |
| `BANK_EMAIL_DOMAIN` | Domain used by the n8n bank-statement workflow |
| `MOODLE_ADMIN_EMAIL`, `TRAXLRS_ADMIN_EMAIL`, `N8N_ADMIN_EMAIL` | Admin email per service |
| `MOODLE_SITE_NAME` | Display name on Moodle homepage |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | Used by managed git hooks in the stack |
| `KOPIA_SERVER_USER` | Kopia API user (defaults to `kopia`) |

## Rotation playbook

| Secret | Rotation cost |
|---|---|
| DB passwords | Stop service → `ALTER USER … PASSWORD` → update `.env` → restart |
| `N8N_ENCRYPTION_KEY` | **Do not rotate** without exporting/re-importing every workflow credential |
| `KOPIA_PASSWORD` | **Do not rotate** without re-encrypting the repo (kopia repository change-password) |
| OIDC client secrets | Regenerate in PocketID → update consumer service's `.env` → restart consumer |
| API keys (Gemini, Groq, etc.) | Generate new in vendor console → swap in `.env` → restart any container using it |
| `CF_TUNNEL_TOKEN` | Generate new tunnel token in CF → update `.env` → restart `cryptex-cloudflared` |

## Out-of-band manual setup (first-run only)

These services bootstrap an admin user on first launch via web UI — they are **not** in `.env`:

- **Vaultwarden** — visit `https://vault.<DOMAIN>` → register first user → enable admin token via `scripts/gen-vaultwarden-token.sh`
- **Forgejo** — visit `https://git.<DOMAIN>` → installer asks for admin user details
- **PocketID** — initial setup token printed in `docker logs cryptex-pocketid` on first boot

## Storage of real secrets

Real `.env` lives in **two places only**:

1. The VPS, at `/opt/cryptex/.env` (mode 600, owner ubuntu).
2. Your password manager / encrypted vault (Vaultwarden recommended once it's up).

Do not Slack, email, screenshot, or paste into LLMs. The repo is private but private != public-safe.
