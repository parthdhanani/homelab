#!/usr/bin/env bash
# 05-dotfiles.sh — install user dotfiles (~/.claude, shell rc files).
# Runs as the target user (ubuntu), NOT root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
require_user

TARGET_HOME="${HOME:-/home/ubuntu}"
SRC="$REPO_ROOT/dotfiles"

log "============ 05-dotfiles: user shell + claude ============"

# -------- ~/.claude --------
if [ -d "$SRC/claude" ]; then
  CLAUDE_DIR="$TARGET_HOME/.claude"
  if [ -d "$CLAUDE_DIR" ] && [ ! -L "$CLAUDE_DIR" ]; then
    # Existing non-symlink — back up once
    if [ ! -d "$CLAUDE_DIR.backup-pre-bootstrap" ]; then
      mv "$CLAUDE_DIR" "$CLAUDE_DIR.backup-pre-bootstrap"
      ok "backed up existing ~/.claude to ~/.claude.backup-pre-bootstrap"
    fi
  fi

  if [ ! -d "$CLAUDE_DIR" ]; then
    mkdir -p "$CLAUDE_DIR"
  fi

  # Rsync repo dotfiles/claude/ into ~/.claude/ WITHOUT deleting user runtime dirs
  # (sessions, cache, projects, telemetry are not in repo and must survive)
  rsync -a --update "$SRC/claude/" "$CLAUDE_DIR/"
  ok "synced ~/.claude (additive — runtime dirs preserved)"

  # Ensure hook scripts are executable
  find "$CLAUDE_DIR/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/hooks" -name "*.py" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR" -maxdepth 1 -name "statusline*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR" -maxdepth 1 -name "statusline*.py" -exec chmod +x {} \; 2>/dev/null || true
fi

# -------- shell rc files --------
if [ -d "$SRC/shell" ]; then
  for f in .bashrc .profile .bash_aliases .tmux.conf; do
    if [ -f "$SRC/shell/$f" ]; then
      if [ -f "$TARGET_HOME/$f" ] && ! cmp -s "$SRC/shell/$f" "$TARGET_HOME/$f"; then
        cp "$TARGET_HOME/$f" "$TARGET_HOME/${f}.pre-bootstrap" 2>/dev/null || true
      fi
      install_file "$SRC/shell/$f" "$TARGET_HOME/$f" 644 "$USER:$USER"
    fi
  done
  if [ -f "$SRC/shell/starship.toml" ]; then
    mkdir -p "$TARGET_HOME/.config"
    install_file "$SRC/shell/starship.toml" "$TARGET_HOME/.config/starship.toml" 644 "$USER:$USER"
  fi
  if [ -f "$SRC/shell/.gitconfig" ]; then
    # Don't overwrite user gitconfig if it already has [user] block
    if [ ! -f "$TARGET_HOME/.gitconfig" ] || ! grep -q "\[user\]" "$TARGET_HOME/.gitconfig"; then
      install_file "$SRC/shell/.gitconfig" "$TARGET_HOME/.gitconfig" 644 "$USER:$USER"
    else
      skip ".gitconfig: user already has one"
    fi
  fi
fi

log "============ 05-dotfiles: complete ============"
