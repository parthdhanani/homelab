# dotfiles

Personal dev workspace running on Oracle Cloud (ARM64 Ubuntu) + macOS.

## Contents

| Path | What it is |
|---|---|
| `skill-library/` | Claude Code skill system — 52 custom skills + router (search, import, sync) |
| `.claude/skills/` | Claude Code custom skills (Gemini CLI shorthand) |
| `.claudeignore` | Paths excluded from Claude Code context window |
| `.gemini-pkm/` | Gemini CLI ↔ PKM vault bridge scripts |
| `pkm-mac/` | Mac-side PKM capture scripts — Alfred hotkey + Vaultwarden integration |
| `setup-mac-ssh.md` | Reverse SSH tunnel setup: VPS → Mac terminal with native approval dialog |

## Stack

- **VPS:** Oracle Cloud Always-Free ARM64 · ~30 Docker containers · Cloudflare Tunnel (no open ports)
- **AI tooling:** Claude Code CLI + Gemini CLI wired to a self-hosted semantic memory engine
- **PKM:** Obsidian vault on VPS · SilverBullet PWA · Alfred capture on Mac · iOS PWA
- **Key services:** n8n · Forgejo · Vaultwarden · Moodle · Kopia backups → Backblaze B2
