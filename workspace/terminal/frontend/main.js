import { init, Terminal } from 'ghostty-web';
// Self-hosted JetBrains Mono — without this the CSS font stack silently fell
// back to the browser's generic monospace (no webfont was ever loaded).
import '@fontsource/jetbrains-mono/400.css';
import '@fontsource/jetbrains-mono/700.css';

await init();

// Canvas text is measured at font-load time; make sure the webfont is really
// available before the terminal takes its cell metrics, otherwise it renders
// (and measures) the fallback font instead.
await document.fonts.load('14px "JetBrains Mono"').catch(() => {});

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

function getCellMetrics() {
  return term.renderer?.metrics ?? null;
}

// herdr switches to its proper single-column mobile layout only when the
// terminal is <= mobile_width_threshold columns (64 by default, see
// ~/.config/herdr/config.toml). Forcing a minimum of 80 cols on mobile (the
// old fallback did this) guarantees herdr never sees a narrow terminal and
// tries to render the full desktop sidebar+pane layout on a phone screen —
// that's what "sidebar and things are lost" was.
const MOBILE_COLS_CAP = 56; // comfortably under the 64-col threshold

function fitTerm() {
  const wrapper = document.getElementById('terminal-wrapper');
  const rect = wrapper.getBoundingClientRect();
  const cell = getCellMetrics();
  if (cell && cell.width && cell.height) {
    let cols = Math.floor(rect.width / cell.width);
    const rows = Math.floor(rect.height / cell.height);
    if (isMobile) cols = Math.min(cols, MOBILE_COLS_CAP);
    term.resize(cols, rows);
    sizeEl.textContent = `${cols}×${rows}`;
    return { cols, rows };
  }
  // Fallback: estimate from font size — corrected once real metrics are ready (see waitForRealMetrics)
  const fontSize = isMobile ? 13 : 14;
  let cols = Math.floor(rect.width / (fontSize * 0.6));
  const rows = Math.floor(rect.height / (fontSize * 1.2));
  cols = isMobile ? Math.min(Math.max(cols, 40), MOBILE_COLS_CAP) : Math.max(cols, 80);
  term.resize(cols, Math.max(rows, 24));
  sizeEl.textContent = `${cols}×${rows}`;
  return { cols, rows: Math.max(rows, 24) };
}

// The fallback size estimate above is a guess and is usually wrong (leaves
// blank space or misjudges rows/cols). Poll for real cell metrics after
// open() and re-fit + re-send the corrected size once they're available.
function waitForRealMetrics(onReady, attempts = 0) {
  const cell = getCellMetrics();
  if (cell && cell.width && cell.height) { onReady(); return; }
  if (attempts > 40) return; // ~2s ceiling, give up quietly
  requestAnimationFrame(() => waitForRealMetrics(onReady, attempts + 1));
}

// WebSocket connection
const proto = location.protocol === 'https:' ? 'wss' : 'ws';
const ws = new WebSocket(`${proto}://${location.host}/ws`);
ws.binaryType = 'arraybuffer';

ws.onopen = () => {
  dot.className = 'dot';
  statusEl.textContent = 'Connected';
  // Send initial (possibly rough) size immediately so the PTY isn't left unsized
  const { cols, rows } = fitTerm();
  ws.send(JSON.stringify({ type: 'resize', cols, rows }));
  // Correct it once ghostty-web has real font-cell metrics — fixes the
  // undersized-terminal/blank-space-at-bottom issue on first load.
  waitForRealMetrics(() => {
    const fitted = fitTerm();
    ws.send(JSON.stringify({ type: 'resize', cols: fitted.cols, rows: fitted.rows }));
  });
  // Fonts loading late can also shift cell metrics; re-fit once more after that.
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => {
      const fitted = fitTerm();
      ws.send(JSON.stringify({ type: 'resize', cols: fitted.cols, rows: fitted.rows }));
    });
  }
};

ws.onclose = () => {
  dot.className = 'dot disconnected';
  statusEl.textContent = 'Disconnected — reload to reconnect';
};

ws.onerror = () => {
  dot.className = 'dot disconnected';
  statusEl.textContent = 'Connection error';
};

// Rolling plain-text tail of recent output (ANSI stripped) — used to detect
// what kind of prompt is currently on screen, so the mobile toolbar can show
// only the buttons that are actually relevant instead of a static wall of 24.
const ANSI_RE = /\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\r/g;
let recentText = '';
const RECENT_TEXT_MAX = 4000;

function appendRecentText(chunk) {
  recentText = (recentText + chunk).replace(ANSI_RE, '');
  if (recentText.length > RECENT_TEXT_MAX) {
    recentText = recentText.slice(-RECENT_TEXT_MAX);
  }
}

ws.onmessage = (e) => {
  if (e.data instanceof ArrayBuffer) {
    const bytes = new Uint8Array(e.data);
    term.write(bytes);
    appendRecentText(new TextDecoder('utf-8', { fatal: false }).decode(bytes));
  } else {
    term.write(e.data);
    appendRecentText(e.data);
  }
  updateToolbarContext();
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

// Context-aware toolbar: instead of always showing every button, look at the
// last few lines of actual output and show only what's relevant right now.
const toolbarGroups = {
  numbered: document.getElementById('tk-group-numbered'),
  yesno: document.getElementById('tk-group-yesno'),
  default: document.getElementById('tk-group-default'),
  extra: document.getElementById('tk-group-extra'),
};
let extraExpanded = false;

function lastNonEmptyLines(text, n) {
  return text.split('\n').filter((l) => l.trim().length > 0).slice(-n);
}

function updateToolbarContext() {
  const tail = lastNonEmptyLines(recentText, 8);
  const tailJoined = tail.join('\n');

  const hasNumberedMenu = /(?:^|\n)\s*[❯>]?\s*[1-3]\.\s*\S/.test(tailJoined)
    && /(?:^|\n)\s*[1-3]\.\s*\S/.test(tailJoined);
  const hasYesNo = /\(y\/n\)|\[y\/n\]|yes\/no/i.test(tailJoined);

  toolbarGroups.numbered.style.display = hasNumberedMenu ? 'flex' : 'none';
  toolbarGroups.yesno.style.display = (!hasNumberedMenu && hasYesNo) ? 'flex' : 'none';
  toolbarGroups.default.style.display = 'flex'; // Enter/Esc/Ctrl-C/arrows: always useful
  toolbarGroups.extra.style.display = extraExpanded ? 'flex' : 'none';
}

document.getElementById('tk-more-toggle').addEventListener('click', () => {
  extraExpanded = !extraExpanded;
  toolbarGroups.extra.style.display = extraExpanded ? 'flex' : 'none';
});

updateToolbarContext();

// Mouse click/wheel forwarding (SGR mouse protocol) — herdr's own sidebar/tab
// clicks rely on the app receiving real mouse reports, which ghostty-web's
// canvas never sent on its own (it only handles browser-side text selection).
function pixelToCellCoords(clientX, clientY) {
  const cell = getCellMetrics();
  const termEl = document.getElementById('terminal');
  if (!cell || !cell.width || !cell.height) return null;
  const rect = termEl.getBoundingClientRect();
  const col = Math.floor((clientX - rect.left) / cell.width) + 1;
  const row = Math.floor((clientY - rect.top) / cell.height) + 1;
  return { col: Math.max(1, col), row: Math.max(1, row) };
}

function sendSgrMouse(button, clientX, clientY, isRelease) {
  if (!term.hasMouseTracking || !term.hasMouseTracking()) return;
  const pos = pixelToCellCoords(clientX, clientY);
  if (!pos) return;
  const suffix = isRelease ? 'm' : 'M';
  const seq = `\x1b[<${button};${pos.col};${pos.row}${suffix}`;
  if (ws.readyState === WebSocket.OPEN) ws.send(seq);
}

const termCanvasHost = document.getElementById('terminal');
termCanvasHost.addEventListener('mousedown', (e) => {
  const btn = e.button === 2 ? 2 : e.button === 1 ? 1 : 0;
  sendSgrMouse(btn, e.clientX, e.clientY, false);
});
termCanvasHost.addEventListener('mouseup', (e) => {
  const btn = e.button === 2 ? 2 : e.button === 1 ? 1 : 0;
  sendSgrMouse(btn, e.clientX, e.clientY, true);
});
// ghostty-web registers its own wheel handler directly on the canvas in the
// capture phase, and when the focused app hasn't enabled mouse tracking
// (Claude Code doesn't), it auto-translates wheel scroll into arrow-key
// sequences. Claude Code doesn't treat arrow keys as scroll — it wants Page
// Up/Down, which most Mac keyboards have no dedicated key for. Intercept the
// wheel event on `document` in the capture phase (fires before any listener
// on the canvas itself, since capture goes root -> target) and send real
// PageUp/PageDown sequences instead, stopping ghostty-web's own handler from
// also firing.
let wheelAccum = 0;
const WHEEL_PAGE_THRESHOLD = 120; // px of scroll before firing one PageUp/PageDown
document.addEventListener('wheel', (e) => {
  if (!termCanvasHost.contains(e.target)) return;
  if (term.hasMouseTracking && term.hasMouseTracking()) {
    // App wants real mouse reports (e.g. herdr's own sidebar) — use SGR wheel.
    sendSgrMouse(e.deltaY < 0 ? 64 : 65, e.clientX, e.clientY, false);
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  wheelAccum += e.deltaY;
  if (Math.abs(wheelAccum) >= WHEEL_PAGE_THRESHOLD) {
    const seq = wheelAccum < 0 ? '\x1b[5~' : '\x1b[6~'; // Page Up / Page Down
    if (ws.readyState === WebSocket.OPEN) ws.send(seq);
    wheelAccum = 0;
  }
  e.preventDefault();
  e.stopPropagation();
}, { passive: false, capture: true });
// Touch scroll on terminal canvas
let touchStartY = 0;
let touchTotalMove = 0;
document.getElementById('terminal').addEventListener('touchstart', (e) => {
  touchStartY = e.touches[0].clientY;
  touchTotalMove = 0;
}, { passive: true });
document.getElementById('terminal').addEventListener('touchmove', (e) => {
  const dy = touchStartY - e.touches[0].clientY;
  touchTotalMove += Math.abs(dy);
  touchStartY = e.touches[0].clientY;
  term.scrollLines(Math.round(dy / 20));
}, { passive: true });

// Taps count as clicks for touch devices too (tap-to-focus sidebar entries
// etc.) — but only if the touch didn't turn into a scroll drag.
const TAP_DRAG_THRESHOLD_PX = 8;
termCanvasHost.addEventListener('touchend', (e) => {
  if (touchTotalMove > TAP_DRAG_THRESHOLD_PX) return;
  if (!term.hasMouseTracking || !term.hasMouseTracking()) return;
  const t = e.changedTouches[0];
  if (!t) return;
  sendSgrMouse(0, t.clientX, t.clientY, false);
  sendSgrMouse(0, t.clientX, t.clientY, true);
});

// Focus terminal on load
setTimeout(() => term.focus(), 100);
