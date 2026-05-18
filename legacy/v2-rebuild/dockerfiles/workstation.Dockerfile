# CRYPTEX Workstation — HolyClaude-style web terminal (CloudCLI + Claude Code)
# Replaces TTYD with CloudCLI for a richer browser-based terminal experience
# Auth: Cloudflare Zero Trust (primary)
#
# Features:
#   - CloudCLI web terminal (browser UI with tabs, file browser, clipboard)
#   - Claude Code CLI (claude auth persisted via volume)
#   - Playwright + Chromium (agentic browser automation)
#   - Gemini CLI + Google Workspace CLI
#   - tmux (persistent sessions — PKM Claude Channels survives reconnects)
#   - Bun (required by Claude Channels telegram plugin)
#   - qpdf + pdftotext (PDF processing for bank statement workflows)
#   - PKM vault at /root/vault (Obsidian vault, synced via Forgejo)
#   - RO mounts for VPS config inspection (set in docker-compose.yml)
#
# gws (Google Workspace CLI): one-time OAuth after deploy
#   Run inside terminal: gws auth login
#   Token persisted in /root/.config/gws (mounted volume)

FROM node:22-alpine

RUN apk add --no-cache \
    bash \
    git \
    curl \
    openssh-client \
    python3 \
    py3-pip \
    make \
    g++ \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    qpdf \
    poppler-utils \
    tmux \
    vim \
    jq \
  && npm install -g \
    @anthropic-ai/claude-code \
    @googleworkspace/cli \
    bun \
    wetty@2.5.0 \
  && (npx playwright install-deps 2>/dev/null || true) \
  && apk del make g++

# Playwright: use system Chromium
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Git config via environment (set in docker-compose.yml)
ENV GIT_AUTHOR_NAME=""
ENV GIT_AUTHOR_EMAIL=""
ENV GIT_COMMITTER_NAME=""
ENV GIT_COMMITTER_EMAIL=""

# Create workspace, Claude directory, and vault
RUN mkdir -p /root/.claude /root/workspace /root/vault

# PKM startup script (starts Claude Channels in tmux if PKM bot token is set)
COPY workstation-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /root/workspace

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["wetty", "--port", "3000", "--base", "/", "--command", "bash", "--allow-iframe"]
