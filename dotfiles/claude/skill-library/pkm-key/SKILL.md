---
name: pkm-key
version: 0.1.0
description: >
  Fetch a secret (API key, password, token) from Vaultwarden via the bw CLI and put it on
  the clipboard with auto-clear. Use whenever the user asks for a key, token, secret,
  password, or credential by name — phrases like "get my X key", "openai key", "anthropic
  token", "github token", "what's my X password". Never echo secret values into the
  conversation; always copy to clipboard and confirm by name only. Triggers also when
  user runs commands needing API auth and the env var isn't set.
category: tools
tags: [secrets, vaultwarden, bw, security, credentials, keys]
platforms: [claude-code]
license: MIT
---

# pkm-key — Vaultwarden secret retrieval

## Prerequisite

`bw` (Bitwarden CLI) installed and unlocked. Check:
```bash
bw status | grep -q '"status":"unlocked"' || echo "bw locked — run: bw unlock"
```

If locked, instruct user to run `bw unlock` themselves and paste the session key as `BW_SESSION` env var. **Never** ask for or store the master password.

## Behaviour

Input: secret item name (e.g., "openai", "anthropic", "github", "notes capture token").

```bash
NAME="$1"
SECRET=$(bw get password "$NAME" 2>/dev/null) || { echo "Not found: $NAME"; exit 1; }

# Copy to clipboard, never echo
case "$(uname)" in
  Darwin) echo -n "$SECRET" | pbcopy ;;
  Linux)  echo -n "$SECRET" | xclip -selection clipboard 2>/dev/null \
            || echo -n "$SECRET" | wl-copy 2>/dev/null \
            || { echo "no clipboard tool"; exit 1; } ;;
esac

# Auto-clear after 30s in background
( sleep 30 && echo -n "" | pbcopy 2>/dev/null || echo -n "" | xclip -selection clipboard 2>/dev/null ) &
echo "✓ '$NAME' on clipboard, clears in 30s"
```

## Hard rules

- **Never echo the secret value to stdout, the chat, or any log.**
- **Never write the secret to a file** unless explicitly asked and warned.
- **Auto-clear within 30 seconds** — protects against forgotten clipboards.
- **Confirm by name only** — never say partial values, never say length, never say "starts with".
- If user explicitly says "show me" or "print it" → still don't. Tell them to `bw get password $NAME` directly, that's their decision not yours.

## Common items (suggest if user is vague)

- `openai` — OpenAI API key
- `anthropic` — Anthropic / Claude API key
- `github` — GitHub PAT
- `cloudflare` — Cloudflare API token
- `notes capture token` — PKM capture endpoint bearer
- `vaultwarden master` — never fetch this; that's your master password

## Adding new secrets

If the user wants to STORE a secret (not fetch), use:
```bash
bw create item '{"type":1,"name":"<NAME>","login":{"password":"<VALUE>"}}' | bw encode | xargs -I{} bw create item {}
```

Or just instruct them to add it via the Vaultwarden web UI — easier and safer than constructing JSON.
