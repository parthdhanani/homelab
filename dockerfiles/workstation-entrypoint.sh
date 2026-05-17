#!/bin/sh
# CRYPTEX Workstation entrypoint
# Starts PKM Claude Channels session in tmux if PKM_BOT_TOKEN is set

# Start PKM session in background (non-blocking)
if [ -n "${PKM_BOT_TOKEN:-}" ]; then
    # Give container 10s to settle, then start Claude Channels in tmux
    (sleep 10 && \
     tmux new-session -d -s pkm -c /root/vault \
       "claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions 2>&1 | tee /root/pkm.log" \
    ) &
fi

# Patch wetty to trust X-Forwarded-Proto from Cloudflare reverse proxy.
# Without this, wetty generates ws:// CSP connect-src (instead of wss://)
# causing a black screen when accessed over HTTPS via Cloudflare Tunnel.
# Patch wetty@2.5.0 to trust X-Forwarded-Proto from Cloudflare reverse proxy.
# wetty 2.5.0 ships self-contained web_modules (works in browser without bundler).
# wetty 2.7.0 ships bare npm imports — broken in browser. Pinned to 2.5.0.
#
# Patch 1: security.js  — wss:// CSP + allow cloudflareinsights.com script
# Patch 2: socketServer.js — set Express trust proxy (2.5.0 moved app init here vs server.js in 2.7.0)
_SEC=/usr/local/lib/node_modules/wetty/build/server/socketServer/security.js
_SRV=/usr/local/lib/node_modules/wetty/build/server/socketServer.js
node -e "
const fs = require('fs');
let p1 = false, p2 = false, p3 = false;
// Patch 1: security.js — trust X-Forwarded-Proto for wss:// CSP + allow Cloudflare domains
let s = fs.readFileSync('$_SEC', 'utf8');
const old1 = \"(req.protocol === 'http' ? 'ws://' : 'wss://') + req.get('host')\";
const new1 = \"((req.headers['x-forwarded-proto'] || req.protocol) === 'https' ? 'wss://' : 'ws://') + (req.headers['x-forwarded-host'] || req.get('host'))\";
if (s.includes(old1)) { s = s.replace(old1, new1); p1 = true; }
const old2 = \"scriptSrc: [\\\"'self'\\\", \\\"'unsafe-inline'\\\", \\\"'unsafe-eval'\\\"]\";
const new2 = \"scriptSrc: [\\\"'self'\\\", \\\"'unsafe-inline'\\\", \\\"'unsafe-eval'\\\", 'https://static.cloudflareinsights.com']\";
if (s.includes(old2)) { s = s.replace(old2, new2); p2 = true; }
fs.writeFileSync('$_SEC', s);
// Patch 2: socketServer.js — set trust proxy on Express app (2.5.0 structure)
let r = fs.readFileSync('$_SRV', 'utf8');
const old3 = 'const app = express();';
const new3 = 'const app = express(); app.set(\"trust proxy\", true);';
if (r.includes(old3) && !r.includes('trust proxy')) { fs.writeFileSync('$_SRV', r.replace(old3, new3)); p3 = true; }
process.stderr.write('wetty-patch: wss=' + p1 + ' cf-csp=' + p2 + ' trust-proxy=' + p3 + '\n');
" 2>&1 | tee -a /tmp/wetty-patch.log || true

# Start wetty (web terminal)
exec "$@"
