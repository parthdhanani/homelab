# PKM Mac side — install (5 min)

You'll get: `⌘⌥N` → capture popup → text → ↵ → lands in VPS Inbox. And Alfred snippets `;ok ;an ;gh ;cf` → paste a Vaultwarden secret at cursor.

## 0. Prereqs

```bash
brew install bitwarden-cli   # bw CLI
bw config server https://vault.<your-domain>   # or wherever your Vaultwarden lives
bw login <your-email>                          # one-time
export BW_SESSION=$(bw unlock --raw)        # add to ~/.zshrc as bw_unlock alias
```

Save the Notes Capture token in Vaultwarden web UI:
- New item → Login → Name: `Notes Capture Token` → Password: `<your-notes-capture-token>`

## 1. Drop the scripts on Mac

From VPS (run on Mac):
```bash
mkdir -p ~/bin
scp ubuntu@<your-vps>:/home/ubuntu/AI_Space/pkm-mac/*.sh ~/bin/
chmod +x ~/bin/note.sh ~/bin/key.sh
```

## 2. Alfred capture workflow (⌘⌥N)

Alfred Preferences → Workflows → `+` (bottom-left) → Blank Workflow

**Name:** PKM Capture · **Trigger:** Hotkey ⌘⌥N

Drag connections:
1. **Hotkey** (⌘⌥N) → **Keyword** → `Run Script`
   - Hotkey: ⌘⌥N, Argument: `Argument Required`
2. **Keyword** input → **Run Script**:
   - Language: `/bin/bash`
   - Script: `$HOME/bin/note.sh "{query}"`
3. **Run Script** → **Post Notification**: `{query}`

Or — simpler one-trigger: Hotkey → "Argument from Alfred" → Run Script `$HOME/bin/note.sh "{query}"`. Alfred prompts for text, calls script.

## 3. Alfred Vaultwarden snippets

Alfred Preferences → Workflows → `+` → Blank Workflow · **Name:** Vaultwarden Keys

For each: ⌘ + click empty space → Triggers → **Snippet**:

| Keyword | Action |
|---|---|
| `;ok` | Run Script: `$HOME/bin/key.sh openai` |
| `;an` | Run Script: `$HOME/bin/key.sh anthropic` |
| `;gh` | Run Script: `$HOME/bin/key.sh github` |
| `;cf` | Run Script: `$HOME/bin/key.sh cloudflare` |

(Pre-create matching items in Vaultwarden first: items literally named `openai`, `anthropic`, `github`, `cloudflare` with password = the actual key.)

## 4. iOS — Add capture PWA to Home Screen

Once SilverBullet auth path is decided (CF Access vs Pocket ID), the URL `https://notes.<your-domain>/c?t=<TOKEN>` will be a one-tap capture PWA.

Safari → load that URL → Share → Add to Home Screen → name "Capture". Tap home icon → textarea → ↵ → done.

## 5. Test

```bash
~/bin/note.sh "first capture from Mac via Alfred path"
# Should see: ✓ captured  + macOS notification
```

Then `tail -1 /path/to/pkm/00\ Capture/Inbox.md` on VPS — your line is there.
