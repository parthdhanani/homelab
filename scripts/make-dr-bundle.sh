#!/bin/bash
# make-dr-bundle.sh — assemble + ENCRYPT the Cryptex disaster-recovery key bundle.
# Contains no secrets itself; it only reads them and writes an encrypted blob.
# Output: /home/ubuntu/AI_Space/important/dr-key-bundle.tar.gz.enc  (gitignored)
#
# Run it yourself so YOU set the passphrase (never stored anywhere):
#   bash /opt/cryptex/scripts/make-dr-bundle.sh
set -euo pipefail

DEST="/home/ubuntu/AI_Space/important/dr-key-bundle.tar.gz.enc"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
B="$STAGE/dr-key-bundle"
mkdir -p "$B"

echo "Collecting secrets..."
cp /opt/cryptex/.env "$B/cryptex.env"
# repository.config is root:root 600 — needs sudo to read (regenerable from .env,
# but include it so the bundle is fully self-contained).
if sudo cp /opt/cryptex/data/kopia/config/repository.config "$B/kopia-repository.config" 2>/dev/null; then
  sudo chown "$(id -u):$(id -g)" "$B/kopia-repository.config"
else
  echo "  WARN: kopia repository.config not readable (regenerable from .env on restore)"
fi
cp /home/ubuntu/AI_Space/important/github_key      "$B/github_key"     2>/dev/null \
  || echo "  WARN: github_key not found"
cp /home/ubuntu/AI_Space/important/github_key.pub  "$B/github_key.pub" 2>/dev/null || true

cat > "$B/RESTORE-README.txt" <<'TXT'
CRYPTEX DR KEY BUNDLE — break-glass recovery
============================================
DECRYPT:
  openssl enc -d -aes-256-cbc -pbkdf2 -in dr-key-bundle.tar.gz.enc | tar -xz

CONTENTS:
  cryptex.env              full .env (B2 creds, KOPIA_PASSWORD, all 106 secrets)
  kopia-repository.config  kopia B2 connection config
  github_key / .pub        SSH key to clone the private cryptex + dotfiles repos

FULL REBUILD (details in cryptex repo: bootstrap/README.md):
  1. terraform apply                      # provision fresh Oracle ARM VPS -> public IP
  2. ssh ubuntu@<ip>  (use your Mac key)  # provisioned at apply time
  3. install clone key:
       mkdir -p ~/.ssh && cp github_key ~/.ssh/ && chmod 600 ~/.ssh/github_key
       eval "$(ssh-agent)" && ssh-add ~/.ssh/github_key
  4. git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex && cd /opt/cryptex
  5. cp <bundle>/cryptex.env .env
     mkdir -p data/kopia/config && cp <bundle>/kopia-repository.config data/kopia/config/repository.config
  6. ./replicate.sh --skip-secrets        # system + Docker stack
  7. ./replicate.sh --restore             # pull latest snapshot from B2
  8. MANUAL: tailscale up ; Cloudflare DNS + Tunnel token ; admin first-logins
  (dotfiles repo restores ~/.claude + ~/AI_Space via bootstrap 05-dotfiles)
TXT

echo ""
echo "Set a STRONG passphrase. It is the ONLY way to decrypt this bundle —"
echo "store it separately from the file (physical note / different manager)."
read -rs -p "Passphrase: " P1; echo
read -rs -p "Confirm:    " P2; echo
[ -n "$P1" ] || { echo "ERROR: empty passphrase"; exit 1; }
[ "$P1" = "$P2" ] || { echo "ERROR: passphrases do not match"; exit 1; }
export BPASS="$P1"

tar -czf - -C "$STAGE" dr-key-bundle | openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BPASS -out "$DEST"
unset BPASS P1 P2
chmod 600 "$DEST"

echo ""
echo "==================================================================="
echo "Encrypted bundle written:"
ls -lh "$DEST"
sha256sum "$DEST"
echo ""
echo "NEXT:"
echo "  - Copy this .enc to OFFLINE storage (HDD + a 2nd location)."
echo "  - Verify it decrypts (see command below) BEFORE trusting it."
echo "  - Re-run this script whenever .env / keys change."
echo "==================================================================="
