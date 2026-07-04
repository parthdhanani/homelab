const express = require('express');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const http = require('http');
const path = require('path');

const PORT = parseInt(process.env.PORT || '8085', 10);
const HOST = process.env.HOST || '127.0.0.1';
const CMD = process.env.TERM_CMD || '/opt/cryptex/workspace/terminal/herdr-session.sh';
const CMD_ARGS = (process.env.TERM_ARGS || '').split(' ').filter(Boolean);

const app = express();
app.use(express.static(path.join(__dirname, 'dist')));
// SPA fallback
app.get('*', (_, res) => res.sendFile(path.join(__dirname, 'dist', 'index.html')));

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

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
