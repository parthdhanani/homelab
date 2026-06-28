#!/usr/bin/env bash
# pkm-github-sync.sh — push a SANITIZED mirror of the PKM vault to the private
# GitHub repo `pkm`. Excludes 50 Collections/_Private (live credentials + personal
# notes) entirely, plus reinstallable obsidian plugin bundles. Secret-gated: aborts
# if any live-key pattern reaches the mirror. Runs as ubuntu (needs ~/.config/gh
# token for the HTTPS push). The full vault, incl. _Private, stays on VPS + Kopia/B2.
set -euo pipefail

SRC=/opt/cryptex/data/pkm
MIRROR=/home/ubuntu/pkm-mirror
TAG=pkm-github-sync

[ -d "$SRC" ] || { echo "$TAG: source $SRC missing"; exit 1; }
[ -d "$MIRROR/.git" ] || { echo "$TAG: mirror $MIRROR not initialized"; exit 1; }

# Plain --delete (NOT --delete-excluded: that would nuke the mirror's own .git).
# Excluded paths are protected from --delete, so we rm any stragglers explicitly.
rsync -a --delete \
  --exclude='/.git' \
  --exclude='50 Collections/_Private' \
  --exclude='.obsidian/plugins' \
  --exclude='.obsidian/workspace*' \
  --exclude='.trash' \
  "$SRC/" "$MIRROR/"
rm -rf "$MIRROR/.obsidian/plugins" "$MIRROR/50 Collections/_Private" "$MIRROR/.trash"

# Hard fail if _Private somehow slipped through (belt).
if find "$MIRROR" -path '*_Private*' 2>/dev/null | grep -q .; then
  echo "$TAG: ABORT — _Private present in mirror"; exit 1
fi

# Defense-in-depth secret gate (ignore obsidian minified-bundle false positives).
HITS=$(grep -rinE \
  '(sk-proj-|sk-or-v1-|gsk_[A-Za-z0-9]{30}|hf_[A-Za-z0-9]{30}|pplx-[A-Za-z0-9]{20}|AIzaSy[A-Za-z0-9_-]{30}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|-----BEGIN [A-Z ]*PRIVATE KEY)' \
  "$MIRROR" --include='*.md' --include='*.json' --include='*.txt' --include='*.yaml' \
  --include='*.yml' --include='*.env' --include='*.csv' 2>/dev/null \
  | grep -vi '/\.obsidian/' || true)
if [ -n "$HITS" ]; then
  echo "$TAG: ABORT — secret pattern in mirror:"; echo "$HITS" | head -3; exit 1
fi

cd "$MIRROR"
git add -A
if git diff --cached --quiet; then echo "$TAG: no changes"; exit 0; fi
git -c user.email=parth1707ster@gmail.com -c user.name='Parth Dhanani' \
  commit -q -m "pkm sync $(date -u +%Y-%m-%d)"
git push -q origin main
echo "$TAG: pushed $(git rev-parse --short HEAD)"
