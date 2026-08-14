const express = require('express');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const http = require('http');
const path = require('path');

const PORT = parseInt(process.env.PORT || '8085', 10);
const HOST = process.env.HOST || '127.0.0.1';
const CMD = process.env.TERM_CMD || '/opt/cryptex/workspace/terminal/herdr-session.sh';
const CMD_ARGS = (process.env.TERM_ARGS || '').split(' ').filter(Boolean);

// Cloudflare Access injects this header on every request that actually
// passed through the CF edge + Access policy check. A container reaching
// this service directly via the Docker gateway (172.18.0.1:8085), bypassing
// the tunnel entirely, cannot forge it — Cloudflare strips/overwrites any
// client-supplied copy at the edge. This is app-level defense-in-depth for
// the case where CF Access itself is misconfigured, removed, or bypassed by
// a network-level route (see VPS-AUDIT-2026-08-14.md, HIGH finding #1).
// debt: presence-check only, not full JWT signature verification against
// CF's JWKS — upgrade if this service ever needs to defend against a
// forged/replayed header rather than just a missing one.
const REQUIRE_CF_ACCESS = process.env.REQUIRE_CF_ACCESS !== 'false';
function hasCfAccess(req) {
  return !REQUIRE_CF_ACCESS || Boolean(req.headers['cf-access-jwt-assertion']);
}

const app = express();
app.use((req, res, next) => {
  if (!hasCfAccess(req)) {
    console.warn(`[!] rejected ${req.method} ${req.path} — no Cf-Access-Jwt-Assertion header (ip: ${req.headers['x-forwarded-for'] || req.socket.remoteAddress})`);
    return res.status(403).send('Forbidden');
  }
  next();
});
app.use(express.static(path.join(__dirname, 'dist')));
// SPA fallback
app.get('*', (_, res) => res.sendFile(path.join(__dirname, 'dist', 'index.html')));

const server = http.createServer(app);
const wss = new WebSocketServer({
  server,
  path: '/ws',
  verifyClient: (info, cb) => {
    if (hasCfAccess(info.req)) return cb(true);
    console.warn(`[!] rejected WS upgrade — no Cf-Access-Jwt-Assertion header (ip: ${info.req.headers['x-forwarded-for'] || info.req.socket.remoteAddress})`);
    cb(false, 403, 'Forbidden');
  },
});

// A synchronous throw from pty.spawn (or anything else in this callback)
// used to crash the whole process — taking down every other connected
// session with it. herdr's own daemon survives a server.js crash/restart
// fine (see memory: KillMode=process), but there's no reason one bad
// connection should still drop everyone else's socket in the meantime.
wss.on('connection', (ws, req) => {
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
  console.log(`[+] connection from ${ip}`);

  let ptyProcess;
  try {
    ptyProcess = pty.spawn(CMD, CMD_ARGS, {
      name: 'xterm-256color',
      cols: 220,
      rows: 50,
      cwd: process.env.HOME,
      env: {
        ...process.env,
        TERM: 'xterm-256color',
        COLORTERM: 'truecolor',
        LANG: 'en_US.UTF-8',
      },
    });
  } catch (err) {
    console.error(`[!] failed to spawn pty for ${ip}: ${err.message}`);
    ws.send(`\r\n\x1b[31mFailed to start terminal session: ${err.message}\x1b[0m\r\n`);
    ws.close();
    return;
  }

  ptyProcess.onData((data) => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });

  ptyProcess.onExit(({ exitCode }) => {
    console.log(`[-] pty exited (${exitCode})`);
    if (ws.readyState === ws.OPEN) {
      ws.send('\r\n\x1b[31mSession ended. Reload to reconnect.\x1b[0m\r\n');
      ws.close();
    }
  });

  ws.on('message', (msg) => {
    try {
      const text = msg.toString();
      // Check if it's a resize control message
      if (text.startsWith('{')) {
        const data = JSON.parse(text);
        if (data.type === 'resize' && data.cols && data.rows) {
          ptyProcess.resize(data.cols, data.rows);
          return;
        }
      }
      ptyProcess.write(text);
    } catch {
      ptyProcess.write(msg.toString());
    }
  });

  ws.on('close', () => {
    console.log(`[-] disconnected ${ip}`);
    try { ptyProcess.kill(); } catch { /* already gone */ }
  });

  ws.on('error', (err) => {
    console.error(`[!] ws error: ${err.message}`);
    try { ptyProcess.kill(); } catch { /* already gone */ }
  });
});

server.listen(PORT, HOST, () => {
  console.log(`cryptex-terminal listening on ${HOST}:${PORT}`);
  console.log(`command: ${CMD} ${CMD_ARGS.join(' ')}`);
});

// Previously unhandled — an uncaught exception anywhere (not just inside the
// per-connection try/catch above) would crash silently with just a bare node
// stack trace in the journal. Log clearly and exit so systemd's
// Restart=always brings it back cleanly; herdr's own session state survives
// a server.js restart regardless (KillMode=process).
process.on('uncaughtException', (err) => {
  console.error(`[!] uncaughtException: ${err.stack || err}`);
  process.exit(1);
});
process.on('unhandledRejection', (reason) => {
  console.error(`[!] unhandledRejection: ${reason}`);
  process.exit(1);
});
