#!/usr/bin/env bash
# install-tools.sh — provision all CLI tools for the cryptex VPS environment
# Run as the ubuntu user (not root). Uses sudo where needed.
# Idempotent: safe to re-run.

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${BLUE}▶ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }

# ── System packages ────────────────────────────────────────────────────────────
step "System packages"
sudo apt-get update -q
sudo apt-get install -y -q \
    curl wget git jq socat unzip build-essential \
    python3 python3-pip python3-venv \
    shellcheck yamllint

ok "System packages installed"

# ── Node.js (via nvm or existing) ─────────────────────────────────────────────
step "Node.js"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
node --version && ok "Node.js $(node --version)"

# npm global prefix in home (no sudo for npm installs)
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
grep -q 'npm-global' ~/.bashrc || echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
export PATH=~/.npm-global/bin:$PATH

# ── npm globals ────────────────────────────────────────────────────────────────
step "npm globals"
npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    claude-code-cache-fix \
    codeburn
ok "npm globals: claude-code, gemini-cli, claude-code-cache-fix, codeburn"

# ── Python tools ───────────────────────────────────────────────────────────────
step "Python tools"
pip3 install --user --quiet \
    graphifyy \
    watchdog \
    yamllint
ok "Python tools installed"

# ── Starship prompt ────────────────────────────────────────────────────────────
step "Starship"
if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sh -s -- --yes
fi
ok "Starship $(starship --version | head -1)"

# ── Zoxide ────────────────────────────────────────────────────────────────────
step "Zoxide"
if ! command -v zoxide &>/dev/null; then
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi
ok "Zoxide $(zoxide --version)"

# ── code-server ───────────────────────────────────────────────────────────────
step "code-server"
if ! command -v code-server &>/dev/null; then
    curl -fsSL https://code-server.dev/install.sh | sh
fi
ok "code-server $(code-server --version | head -1)"

# Create code-server config from example if not present
if [ ! -f ~/.config/code-server/config.yaml ]; then
    mkdir -p ~/.config/code-server
    cp "$(dirname "$0")/../dotfiles/code-server/config.yaml.example" \
        ~/.config/code-server/config.yaml
    ok "code-server config created at ~/.config/code-server/config.yaml"
fi

# code-server systemd service (runs on port 8080, accessed via CF tunnel)
if [ ! -f /etc/systemd/system/code-server.service ]; then
    sudo tee /etc/systemd/system/code-server.service > /dev/null <<'EOF'
[Unit]
Description=code-server
After=network.target

[Service]
Type=simple
User=ubuntu
ExecStart=/usr/lib/code-server/bin/code-server --config /home/ubuntu/.config/code-server/config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable code-server
    sudo systemctl start code-server
    ok "code-server systemd service enabled and started"
fi

# ── claude-code-cache-fix proxy ───────────────────────────────────────────────
step "claude-code-cache-fix proxy (port 9801)"
if ! systemctl is-active --quiet claude-cache-proxy 2>/dev/null; then
    sudo tee /etc/systemd/system/claude-cache-proxy.service > /dev/null <<'EOF'
[Unit]
Description=Claude Code Cache-Fix Proxy
After=network.target

[Service]
Type=simple
User=ubuntu
ExecStart=/home/ubuntu/.npm-global/bin/claude-code-cache-fix --port 9801
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable claude-cache-proxy
    sudo systemctl start claude-cache-proxy
    ok "claude-cache-proxy service enabled on port 9801"
else
    ok "claude-cache-proxy already running"
fi

# ── Claude Code dotfiles ───────────────────────────────────────────────────────
step "Claude Code config"
DOTFILES="$(dirname "$0")/../dotfiles"
CLAUDE_DIR=~/.claude

mkdir -p "$CLAUDE_DIR/hooks/validators" "$CLAUDE_DIR/commands"

# Settings (only copy if not already present)
if [ ! -f "$CLAUDE_DIR/settings.json" ]; then
    cp "$DOTFILES/claude/settings.json" "$CLAUDE_DIR/settings.json"
    ok "~/.claude/settings.json installed"
else
    warn "~/.claude/settings.json already exists — skipping (review and merge manually)"
fi

# Hooks
cp "$DOTFILES/claude/hooks/"*.sh "$CLAUDE_DIR/hooks/"
cp "$DOTFILES/claude/hooks/"*.py "$CLAUDE_DIR/hooks/"
cp "$DOTFILES/claude/hooks/validators/"*.sh "$CLAUDE_DIR/hooks/validators/"
chmod +x "$CLAUDE_DIR/hooks/"*.sh "$CLAUDE_DIR/hooks/validators/"*.sh
ok "Claude hooks installed and made executable"

# Commands
cp "$DOTFILES/claude/commands/"*.md "$CLAUDE_DIR/commands/"
ok "Claude commands installed"

# Statusline
cp "$DOTFILES/claude/statusline-command.sh" "$CLAUDE_DIR/"
cp "$DOTFILES/claude/statusline.py" "$CLAUDE_DIR/"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
ok "Statusline installed"

# claudeignore template
cp "$DOTFILES/claude/claudeignore-template" "$CLAUDE_DIR/"
ok "claudeignore-template installed"

# ── Shell config ──────────────────────────────────────────────────────────────
step "Shell config"
if [ ! -f ~/.bashrc.bak ]; then
    cp ~/.bashrc ~/.bashrc.bak
    ok "~/.bashrc backed up to ~/.bashrc.bak"
fi
cp "$DOTFILES/.bashrc" ~/.bashrc
ok "~/.bashrc installed"

mkdir -p ~/.config
cp "$DOTFILES/starship.toml" ~/.config/starship.toml
ok "~/.config/starship.toml installed"

# ── Crontab ───────────────────────────────────────────────────────────────────
step "Crontab"
CRON_FILE="$(dirname "$0")/../crontab.txt"
if sudo crontab -l 2>/dev/null | grep -q 'CRYPTEX-MANAGED'; then
    warn "Root crontab already has CRYPTEX-MANAGED block — skipping (review crontab.txt manually)"
else
    sudo crontab "$CRON_FILE"
    ok "Root crontab installed from crontab.txt"
fi

# ── AI workspace ─────────────────────────────────────────────────────────────
step "AI_Space workspace"
if [ ! -d ~/AI_Space ]; then
    mkdir -p ~/AI_Space
    ok "~/AI_Space created — run 'ai' to launch Claude Code from it"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Install complete. Next steps:${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  1. source ~/.bashrc              — reload shell"
echo "  2. claude auth login             — authenticate Claude Code (needs ANTHROPIC_API_KEY)"
echo "  3. gemini auth login             — authenticate Gemini CLI"
echo "  4. cd /opt/cryptex && docker compose up -d  — start the container stack"
echo "  5. Review ~/.claude/settings.json MCP URLs — update OB1 IP after containers start"
echo "     docker inspect cryptex-ob1 | grep IPAddress"
echo ""
echo "  See README.md → Restore Sequence for full post-clone walkthrough."
echo ""
