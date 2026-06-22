#!/usr/bin/env bash
# 05-dotfiles.sh — install user dotfiles (~/.claude, ~/AI_Space, shell rc files).
# Runs as the target user (ubuntu), NOT root.
#
# ~/.claude and ~/AI_Space are two actively-updated checkouts of the SAME
# private GitHub repo (parthdhanani/dotfiles) on different branches:
#   ~/.claude   -> branch main
#   ~/AI_Space  -> branch master
# Neither is the dotfiles/claude/ snapshot vendored inside this cryptex repo
# (that's a one-time 2026-05-18 export that drifts immediately and must never
# be restored from). Clone the real repo/branches instead. Requires SSH
# access to the private repo already configured (see README.md "What is NOT
# automated").
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
require_user

TARGET_HOME="${HOME:-/home/ubuntu}"
SRC="$REPO_ROOT/dotfiles"
DOTFILES_REPO="${DOTFILES_REPO:-git@github.com:parthdhanani/dotfiles.git}"

log "============ 05-dotfiles: user shell + claude + AI_Space ============"

# clone_or_skip <dest-dir> <branch>
clone_or_skip() {
  local dest="$1" branch="$2"
  if [ -d "$dest/.git" ]; then
    if git -C "$dest" remote get-url origin 2>/dev/null | grep -q "dotfiles"; then
      skip "$dest already a dotfiles git checkout"
    else
      warn "$dest exists with a different git remote — leaving as-is, not touching"
    fi
  elif [ -d "$dest" ]; then
    if [ ! -d "${dest}.backup-pre-bootstrap" ]; then
      mv "$dest" "${dest}.backup-pre-bootstrap"
      ok "backed up existing $dest to ${dest}.backup-pre-bootstrap"
    fi
    git clone --branch "$branch" "$DOTFILES_REPO" "$dest"
    ok "cloned dotfiles repo (branch $branch) into $dest"
  else
    git clone --branch "$branch" "$DOTFILES_REPO" "$dest"
    ok "cloned dotfiles repo (branch $branch) into $dest"
  fi
}

# -------- ~/.claude (branch main) --------
CLAUDE_DIR="$TARGET_HOME/.claude"
clone_or_skip "$CLAUDE_DIR" main

if [ -d "$CLAUDE_DIR" ]; then
  # Ensure hook scripts are executable
  find "$CLAUDE_DIR/hooks" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/hooks" -name "*.py" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/scripts" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR" -maxdepth 1 -name "statusline*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR" -maxdepth 1 -name "statusline*.py" -exec chmod +x {} \; 2>/dev/null || true
fi

# -------- ~/AI_Space (branch master) --------
clone_or_skip "$TARGET_HOME/AI_Space" master

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
