# Phase 2: VPS Claude Code → Mac Terminal Setup

## Overview
This sets up a secure reverse SSH tunnel from Mac to VPS that allows VPS Claude Code to access your Mac terminal with your approval via a native macOS dialog.

## Part A: VPS Setup

### Step 1: Generate VPS→Mac keypair (run on VPS)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/mac_key -C "vps-claude-to-mac" -N ""
cat ~/.ssh/mac_key.pub
# Copy the output (starts with ssh-ed25519)
```

### Step 2: Add SSH config for Mac access (run on VPS)
```bash
cat >> ~/.ssh/config << 'EOF'

Host mac
  HostName localhost
  Port 2222
  User YOUR_MAC_USERNAME
  IdentityFile ~/.ssh/mac_key
  StrictHostKeyChecking no
EOF
```
Replace `YOUR_MAC_USERNAME` with your actual Mac username (run `whoami` on Mac to find it).

---

## Part B: Mac Setup

### Step 1: Enable Remote Login
System Preferences → General → Sharing → Remote Login → ON (your user only)

### Step 2: Add VPS public key to authorized_keys
```bash
# On Mac terminal
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAA...PASTE_HERE" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```
Replace `AAAA...PASTE_HERE` with the full output from VPS Step 1 above.

### Step 3: Create approval dialog script
```bash
mkdir -p ~/bin
cat > ~/bin/ssh-approve.sh << 'SCRIPT_EOF'
#!/bin/bash
RESULT=$(osascript -e 'display dialog "Claude Code (VPS) is requesting Mac terminal access." buttons {"Deny", "Allow"} default button "Deny" with icon caution with title "SSH Access Request" giving up after 30')

if [[ "$RESULT" == *"Allow"* ]]; then
    exec /bin/bash ${SSH_ORIGINAL_COMMAND:+-c "$SSH_ORIGINAL_COMMAND"}
else
    echo "Access denied."
    exit 1
fi
SCRIPT_EOF
chmod +x ~/bin/ssh-approve.sh
```

### Step 4: Wrap VPS key with ForceCommand
```bash
# Edit ~/.ssh/authorized_keys
# Find the line with "vps-claude-to-mac" that you added in Step 2
# Replace the whole line with this (keep the ssh-ed25519 key part):
command="/Users/YOUR_MAC_USERNAME/bin/ssh-approve.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...PASTE_HERE vps-claude-to-mac
```
Replace `YOUR_MAC_USERNAME` with your Mac username, and `AAAA...PASTE_HERE` with VPS's mac_key.pub from earlier.

### Step 5: Generate tunnel authentication key (separate from approval key)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/mac_tunnel_key -N ""
cat ~/.ssh/mac_tunnel_key.pub
# Copy this output
```

### Step 6: Create autossh LaunchAgent
```bash
cat > ~/Library/LaunchAgents/com.cryptex.reverse-tunnel.plist << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cryptex.reverse-tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/autossh</string>
        <string>-M</string><string>0</string>
        <string>-N</string>
        <string>-o</string><string>ServerAliveInterval=60</string>
        <string>-o</string><string>ServerAliveCountMax=3</string>
        <string>-o</string><string>ExitOnForwardFailure=yes</string>
        <string>-o</string><string>StrictHostKeyChecking=no</string>
        <string>-R</string><string>2222:localhost:22</string>
        <string>-i</string><string>/Users/YOUR_MAC_USERNAME/.ssh/mac_tunnel_key</string>
        <string>ubuntu@YOUR_VPS_IP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/cryptex-tunnel.log</string>
</dict>
</plist>
PLIST_EOF
```
Replace `YOUR_MAC_USERNAME` and `YOUR_VPS_IP` with actual values.

### Step 7: Install autossh and load LaunchAgent
```bash
brew install autossh
launchctl load ~/Library/LaunchAgents/com.cryptex.reverse-tunnel.plist

# Check it's running
launchctl list | grep com.cryptex
```

---

## Part C: VPS Final Setup

### Step 1: Add Mac's tunnel key to authorized_keys (run on VPS)
```bash
echo "ssh-ed25519 AAAA...MAC_TUNNEL_PUBKEY_HERE mac-autossh-tunnel" >> ~/.ssh/authorized_keys
```
Replace with the output from Mac Step 5 above.

---

## Testing

### From VPS, run:
```bash
ssh mac
```

You should see a native macOS dialog asking "Claude Code (VPS) is requesting Mac terminal access" with [Deny] [Allow] buttons.

- Click **Allow** → shell opens on Mac, Claude Code can continue
- Click **Deny** → "Access denied" returned to VPS

---

## Troubleshooting

**autossh tunnel not connecting:**
```bash
tail -f /tmp/cryptex-tunnel.log
# Or manually test:
autossh -M0 -N -R 2222:localhost:22 -i ~/.ssh/mac_tunnel_key ubuntu@YOUR_VPS_IP
```

**osascript dialog not appearing:**
- Make sure `ssh-approve.sh` has execute permission: `chmod +x ~/bin/ssh-approve.sh`
- Test locally: `~/bin/ssh-approve.sh`

**SSH key permissions wrong:**
```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys ~/.ssh/mac_key ~/.ssh/mac_tunnel_key
chmod 644 ~/.ssh/mac_key.pub ~/.ssh/mac_tunnel_key.pub
```
