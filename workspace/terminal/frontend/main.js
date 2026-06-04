import { init, Terminal } from 'ghostty-web';

await init();

const isMobile = window.matchMedia('(hover: none) and (pointer: coarse)').matches
  || window.innerWidth <= 768;

const term = new Terminal({
  fontSize: isMobile ? 13 : 14,
  fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
  theme: {
    background: '#0d1117',
    foreground: '#e6edf3',
    cursor: '#388bfd',
    cursorAccent: '#0d1117',
    black: '#484f58',
    red: '#ff7b72',
    green: '#3fb950',
    yellow: '#d29922',
    blue: '#388bfd',
    magenta: '#bc8cff',
    cyan: '#39c5cf',
    white: '#b1bac4',
    brightBlack: '#6e7681',
    brightRed: '#ffa198',
    brightGreen: '#56d364',
    brightYellow: '#e3b341',
    brightBlue: '#79c0ff',
    brightMagenta: '#d2a8ff',
    brightCyan: '#56d4dd',
    brightWhite: '#f0f6fc',
  },
  allowProposedApi: true,
  scrollback: 5000,
});

term.open(document.getElementById('terminal'));

// Fit terminal to container
const dot = document.getElementById('dot');
const statusEl = document.getElementById('status');
const sizeEl = document.getElementById('size-label');

function fitTerm() {
  const wrapper = document.getElementById('terminal-wrapper');
  const rect = wrapper.getBoundingClientRect();
  // ghostty-web: measure cell size from a test render
  const cellWidth = term._core ? term._core._renderService?.dimensions?.css?.cell?.width : null;
  const cellHeight = term._core ? term._core._renderService?.dimensions?.css?.cell?.height : null;
  if (cellWidth && cellHeight) {
    const cols = Math.floor(rect.width / cellWidth);
    const rows = Math.floor(rect.height / cellHeight);
    term.resize(cols, rows);
    sizeEl.textContent = `${cols}×${rows}`;
    return { cols, rows };
  }
  // Fallback: estimate from font size
  const fontSize = isMobile ? 13 : 14;
  const cols = Math.floor(rect.width / (fontSize * 0.6));
  const rows = Math.floor(rect.height / (fontSize * 1.2));
  term.resize(Math.max(cols, 80), Math.max(rows, 24));
  sizeEl.textContent = `${cols}×${rows}`;
  return { cols: Math.max(cols, 80), rows: Math.max(rows, 24) };
}

// WebSocket connection
const proto = location.protocol === 'https:' ? 'wss' : 'ws';
const ws = new WebSocket(`${proto}://${location.host}/ws`);
ws.binaryType = 'arraybuffer';

ws.onopen = () => {
  dot.className = 'dot';
  statusEl.textContent = 'Connected';
  // Send initial size
  const { cols, rows } = fitTerm();
  ws.send(JSON.stringify({ type: 'resize', cols, rows }));
};

ws.onclose = () => {
  dot.className = 'dot disconnected';
  statusEl.textContent = 'Disconnected — reload to reconnect';
};

ws.onerror = () => {
  dot.className = 'dot disconnected';
  statusEl.textContent = 'Connection error';
};

ws.onmessage = (e) => {
  if (e.data instanceof ArrayBuffer) {
    term.write(new Uint8Array(e.data));
  } else {
    term.write(e.data);
  }
};

term.onData((data) => {
  if (ws.readyState === WebSocket.OPEN) ws.send(data);
});

// Resize handling
const resizeObserver = new ResizeObserver(() => {
  const { cols, rows } = fitTerm();
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'resize', cols, rows }));
  }
});
resizeObserver.observe(document.getElementById('terminal-wrapper'));

// Also handle visualViewport resize (mobile keyboard appearing)
if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', () => {
    const { cols, rows } = fitTerm();
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }));
    }
  });
}

// Mobile toolbar key mappings
const keyMap = {
  'ctrl-c': '\x03',
  'ctrl-z': '\x1a',
  'ctrl-d': '\x04',
  'ctrl-a': '\x01',
  'ctrl-e': '\x05',
  'ctrl-l': '\x0c',
  'enter': '\r',
  '1-enter': '1\r',
  '2-enter': '2\r',
  '3-enter': '3\r',
  'y-enter': 'y\r',
  'n-enter': 'n\r',
  'esc': '\x1b',
  'tab': '\t',
  'up': '\x1b[A',
  'down': '\x1b[B',
  'right': '\x1b[C',
  'left': '\x1b[D',
};

document.getElementById('mobile-toolbar').addEventListener('click', (e) => {
  const btn = e.target.closest('.tk');
  if (!btn) return;
  const send = btn.dataset.send;
  const literal = btn.dataset.literal;
  const seq = send ? keyMap[send] : literal;
  if (seq && ws.readyState === WebSocket.OPEN) {
    ws.send(seq);
    term.focus();
  }
});

// Touch scroll on terminal canvas
let touchStartY = 0;
document.getElementById('terminal').addEventListener('touchstart', (e) => {
  touchStartY = e.touches[0].clientY;
}, { passive: true });
document.getElementById('terminal').addEventListener('touchmove', (e) => {
  const dy = touchStartY - e.touches[0].clientY;
  touchStartY = e.touches[0].clientY;
  term.scrollLines(Math.round(dy / 20));
}, { passive: true });

// Focus terminal on load
setTimeout(() => term.focus(), 100);
