const API = "";
const CLUSTER_COLORS = {
  flows: "#5aab9c", links: "#b586c4", skills: "#8ab06a",
  agents: "#c97a52", crons: "#c15a5a", docs: "#7d92a8",
};
const BG = "#15130f";
const FONT_DISPLAY = "Fraunces, Georgia, serif";
const FONT_MONO = '"Plex Mono", ui-monospace, monospace';

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");
let width, height;
function resize() {
  width = canvas.width = window.innerWidth;
  height = canvas.height = window.innerHeight;
}
window.addEventListener("resize", resize);
resize();

let nodes = [];
let edges = [];
let expandedClusters = new Set();
let expandedGroups = new Set();
let layoutMode = "force";
let searchTerm = "";
let transform = { x: 0, y: 0, k: 1 };
let simulation = null;
let rootClusters = [];

function showLoading(on) {
  document.getElementById("loading").classList.toggle("hidden", !on);
}

async function fetchJSON(url) {
  showLoading(true);
  try {
    const res = await fetch(url);
    return await res.json();
  } finally {
    showLoading(false);
  }
}

async function loadRoot() {
  const g = await fetchJSON(`${API}/graph`);
  nodes = g.nodes.map(n => ({ ...n }));
  edges = g.edges.map(e => ({ ...e }));
  rootClusters = g.clusters;
  renderLegend(g.clusters);
  renderPanelList(g.clusters);
  const total = nodes.reduce((s, n) => s + (n.meta?.count || 0), 0);
  document.getElementById("search").placeholder = `Search ${total.toLocaleString()} items…`;
  runLayout();
  maybeShowOnboarding();
}

async function expandCluster(name) {
  if (expandedClusters.has(name)) return;
  const g = await fetchJSON(`${API}/graph?scope=${encodeURIComponent(name)}`);
  const summaryId = `cluster-${name}`;
  nodes = nodes.filter(n => n.id !== summaryId);
  const existingIds = new Set(nodes.map(n => n.id));
  for (const n of g.nodes) {
    if (!existingIds.has(n.id)) nodes.push({ ...n });
  }
  expandedClusters.add(name);
  renderPanelList(rootClusters);
  runLayout();
}

async function expandGroup(clusterName, groupId) {
  const key = `${clusterName}:${groupId}`;
  if (expandedGroups.has(key)) return;
  const url = `${API}/graph/cluster/${encodeURIComponent(clusterName)}?id=${encodeURIComponent(groupId)}`;
  const g = await fetchJSON(url);
  const existingIds = new Set(nodes.map(n => n.id));
  for (const n of g.nodes) {
    if (!existingIds.has(n.id)) nodes.push({ ...n });
  }
  for (const e of g.edges) edges.push({ ...e });
  expandedGroups.add(key);
  runLayout();
}

function collapseAll() {
  nodes = rootClusters.map(name => (
    { id: `cluster-${name}`, label: name, cluster: name, kind: "cluster_summary", meta: {} }
  ));
  edges = [];
  expandedClusters.clear();
  expandedGroups.clear();
  transform = { x: 0, y: 0, k: 1 };
  renderPanelList(rootClusters);
  runLayout();
}
document.getElementById("home-btn").onclick = collapseAll;

function renderLegend(clusters) {
  const el = document.getElementById("legend");
  el.innerHTML = clusters.map(name => `
    <span class="legend-item">
      <span class="legend-dot" style="background:${CLUSTER_COLORS[name] || "#888"}"></span>${name}
    </span>
  `).join("");
}

function renderPanelList(clusters) {
  const el = document.getElementById("panel-list");
  el.innerHTML = "";
  for (const name of clusters) {
    const btn = document.createElement("button");
    const count = nodes.filter(n => n.cluster === name).length;
    btn.innerHTML = `${name}<span class="count">${count}</span>`;
    if (expandedClusters.has(name)) btn.classList.add("expanded");
    btn.onclick = () => expandCluster(name);
    el.appendChild(btn);
  }
}

function computeDegrees() {
  const deg = {};
  for (const e of edges) {
    const s = e.source.id || e.source, t = e.target.id || e.target;
    deg[s] = (deg[s] || 0) + 1;
    deg[t] = (deg[t] || 0) + 1;
  }
  for (const n of nodes) n._degree = deg[n.id] || 0;
}

function nodeRadius(n) {
  if (n.kind === "cluster_summary") return 20 + Math.min(10, Math.sqrt(n.meta?.count || 0));
  if (n.kind === "community" || n.kind === "category" || n.kind === "department") {
    const weight = n.meta?.count || n.meta?.model_count || n.meta?.size || 0;
    return 10 + Math.min(9, Math.sqrt(weight) * 1.4);
  }
  return 4 + Math.min(6, (n._degree || 0) * 0.9);
}

function runLayout() {
  computeDegrees();
  if (simulation) simulation.stop();
  if (layoutMode === "force") {
    simulation = d3.forceSimulation(nodes)
      .force("charge", d3.forceManyBody().strength(-160))
      .force("center", d3.forceCenter(0, 0))
      .force("collide", d3.forceCollide(n => nodeRadius(n) + 8))
      .force("link", d3.forceLink(edges.filter(e => hasEnds(e))).id(d => d.id).distance(60).strength(0.3))
      .on("tick", draw);
  } else {
    applyStaticLayout(layoutMode);
    draw();
  }
}

function hasEnds(e) {
  const ids = new Set(nodes.map(n => n.id));
  return ids.has(e.source.id || e.source) && ids.has(e.target.id || e.target);
}

function applyStaticLayout(mode) {
  const n = nodes.length;
  const R = Math.min(width, height) * 0.35;
  if (mode === "circle") {
    nodes.forEach((node, i) => {
      const angle = (i / n) * Math.PI * 2;
      node.x = Math.cos(angle) * R;
      node.y = Math.sin(angle) * R;
    });
  } else if (mode === "hex") {
    const cols = Math.ceil(Math.sqrt(n));
    const spacing = (R * 2) / cols;
    nodes.forEach((node, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      const offset = (row % 2) * (spacing / 2);
      node.x = col * spacing - R + offset;
      node.y = row * spacing * 0.87 - R;
    });
  } else if (mode === "rings") {
    const byCluster = {};
    nodes.forEach(node => {
      byCluster[node.cluster] = byCluster[node.cluster] || [];
      byCluster[node.cluster].push(node);
    });
    const clusterNames = Object.keys(byCluster);
    clusterNames.forEach((cname, ci) => {
      const ringR = R * ((ci + 1) / clusterNames.length);
      const group = byCluster[cname];
      group.forEach((node, i) => {
        const angle = (i / group.length) * Math.PI * 2;
        node.x = Math.cos(angle) * ringR;
        node.y = Math.sin(angle) * ringR;
      });
    });
  }
}

function drawBackgroundGrid() {
  const spacing = 27;
  ctx.fillStyle = "rgba(201, 147, 47, 0.055)";
  for (let x = spacing / 2; x < width; x += spacing) {
    for (let y = spacing / 2; y < height; y += spacing) {
      ctx.beginPath();
      ctx.arc(x, y, 1, 0, Math.PI * 2);
      ctx.fill();
    }
  }
}

function draw() {
  ctx.save();
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, width, height);
  drawBackgroundGrid();
  ctx.translate(width / 2 + transform.x, height / 2 + transform.y);
  ctx.scale(transform.k, transform.k);

  for (const e of edges) {
    const s = typeof e.source === "object" ? e.source : nodes.find(n => n.id === e.source);
    const t = typeof e.target === "object" ? e.target : nodes.find(n => n.id === e.target);
    if (!s || !t || s.x == null || t.x == null) continue;
    ctx.strokeStyle = "#5a5240";
    ctx.globalAlpha = 0.3;
    ctx.lineWidth = 1 / transform.k;
    ctx.beginPath();
    ctx.moveTo(s.x, s.y);
    ctx.lineTo(t.x, t.y);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;

  const term = searchTerm.trim().toLowerCase();
  for (const n of nodes) {
    if (n.x == null) continue;
    const match = term && n.label.toLowerCase().includes(term);
    const dim = term && !match;
    const r = nodeRadius(n);
    const color = CLUSTER_COLORS[n.cluster] || "#888";

    const isContainer = n.kind === "cluster_summary" || n.kind === "community" ||
      n.kind === "category" || n.kind === "department";

    // Every cluster carries its own ambient halo, scaled to how full it is —
    // this is what makes the map read as "alive" data rather than a wireframe.
    // Search match gets the brighter, wider brass ring on top of that.
    if (isContainer && !dim) {
      const glowR = r * 2.1;
      const glow = ctx.createRadialGradient(n.x, n.y, r * 0.2, n.x, n.y, glowR);
      glow.addColorStop(0, color + "4d");
      glow.addColorStop(1, color + "00");
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(n.x, n.y, glowR, 0, Math.PI * 2);
      ctx.fill();
    }
    if (match) {
      const glowR = r * 2.6;
      const glow = ctx.createRadialGradient(n.x, n.y, r * 0.3, n.x, n.y, glowR);
      glow.addColorStop(0, "#c9932f77");
      glow.addColorStop(1, "#c9932f00");
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(n.x, n.y, glowR, 0, Math.PI * 2);
      ctx.fill();
    }

    if (isContainer) {
      // Packed-dot cloud makes size legible at a glance — a 7,500-item
      // cluster visibly reads as fuller than a 16-item one before any click.
      ctx.beginPath();
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      ctx.fillStyle = dim ? "#221f18" : "#1d1a15";
      ctx.fill();
      ctx.lineWidth = 1 / transform.k;
      ctx.strokeStyle = dim ? "#332e26" : color;
      ctx.globalAlpha = dim ? 1 : 0.55;
      ctx.stroke();
      ctx.globalAlpha = 1;
      for (const dot of blobDots(n, r)) {
        ctx.beginPath();
        ctx.arc(n.x + dot.x, n.y + dot.y, dot.s / transform.k, 0, Math.PI * 2);
        ctx.fillStyle = dim ? "#4a4432" : color;
        ctx.fill();
      }
      ctx.beginPath();
      ctx.arc(n.x, n.y, r * 0.22, 0, Math.PI * 2);
      ctx.fillStyle = dim ? "#3a352a" : color;
      ctx.fill();
    } else {
      ctx.beginPath();
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      ctx.fillStyle = dim ? "#3a352a" : color;
      ctx.fill();
      ctx.lineWidth = 1 / transform.k;
      ctx.strokeStyle = dim ? "#4a4432" : "#15130f";
      ctx.stroke();
    }
    if (match) {
      ctx.lineWidth = 1.6 / transform.k;
      ctx.strokeStyle = "#c9932f";
      ctx.beginPath();
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      ctx.stroke();
    }
    if (r >= 12 || match) {
      const isCluster = n.kind === "cluster_summary";
      ctx.fillStyle = dim ? "#4a4432" : "#ece5d5";
      if (isCluster || n.kind === "community" || n.kind === "category" || n.kind === "department") {
        ctx.font = `600 ${13 / transform.k}px ${FONT_DISPLAY}`;
        const label = isCluster ? n.label.toUpperCase() : n.label;
        ctx.fillText(label, n.x + r + 6, n.y + 4);
        if (n.meta?.count != null) {
          ctx.fillStyle = dim ? "#3a352a" : "#7a7260";
          ctx.font = `${10 / transform.k}px ${FONT_MONO}`;
          ctx.fillText(`${n.meta.count}`, n.x + r + 6, n.y + 18 / transform.k);
        }
      } else {
        ctx.font = `${11 / transform.k}px ${FONT_MONO}`;
        ctx.fillText(n.label, n.x + r + 5, n.y + 4);
      }
    }
  }
  ctx.restore();
}

// A cluster node reads as "a container full of things" only if it visibly
// looks full — a plain circle with a number can't distinguish a 16-item
// cluster from a 7,500-item one. Render each cluster/group as a packed
// cloud of small dots scaled to its real count, seeded per-node so the
// cloud doesn't reshuffle every frame.
function seededRand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}
function hashId(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return h;
}
function blobDots(n, r) {
  if (n._blobDots && n._blobR === r) return n._blobDots;
  const count = n.meta?.count || n.meta?.model_count || 0;
  const dotCount = Math.max(6, Math.min(90, Math.round(Math.sqrt(count || 1) * 6)));
  const rand = seededRand(hashId(n.id));
  const dots = [];
  for (let i = 0; i < dotCount; i++) {
    const angle = rand() * Math.PI * 2;
    const dist = Math.sqrt(rand()) * r * 0.82;
    dots.push({ x: Math.cos(angle) * dist, y: Math.sin(angle) * dist, s: 0.9 + rand() * 1.1 });
  }
  n._blobDots = dots;
  n._blobR = r;
  return dots;
}

function nodeAt(px, py) {
  const x = (px - width / 2 - transform.x) / transform.k;
  const y = (py - height / 2 - transform.y) / transform.k;
  let best = null, bestDist = Infinity;
  for (const n of nodes) {
    if (n.x == null) continue;
    const d = Math.hypot(n.x - x, n.y - y);
    const r = nodeRadius(n) + 4;
    if (d <= r && d < bestDist) { best = n; bestDist = d; }
  }
  return best;
}

let dragging = false, dragNode = null, lastX = 0, lastY = 0, dragMoved = false;
canvas.addEventListener("mousedown", e => {
  const n = nodeAt(e.clientX, e.clientY);
  dragMoved = false;
  if (n && n.kind !== "cluster_summary") {
    dragNode = n;
  } else {
    dragging = true;
  }
  lastX = e.clientX; lastY = e.clientY;
});
const tooltip = document.getElementById("tooltip");
canvas.addEventListener("mousemove", e => {
  const dx = e.clientX - lastX, dy = e.clientY - lastY;
  if (dragNode || dragging) dragMoved = true;
  if (dragNode) {
    dragNode.x += dx / transform.k;
    dragNode.y += dy / transform.k;
    dragNode.fx = dragNode.x; dragNode.fy = dragNode.y;
    draw();
  } else if (dragging) {
    transform.x += dx; transform.y += dy;
    draw();
  } else {
    const hover = nodeAt(e.clientX, e.clientY);
    if (hover) {
      canvas.style.cursor = "pointer";
      let hint = "Click to open";
      if (hover.kind !== "cluster_summary" && hover.kind !== "community" &&
          hover.kind !== "category" && hover.kind !== "department") {
        hint = "Click for details";
      }
      tooltip.innerHTML = `<div class="tt-kind">${hover.cluster} · ${hover.kind}</div>${hover.label}<div class="tt-kind">${hint}</div>`;
      tooltip.style.left = `${e.clientX + 14}px`;
      tooltip.style.top = `${e.clientY + 14}px`;
      tooltip.classList.remove("hidden");
    } else {
      canvas.style.cursor = "grab";
      tooltip.classList.add("hidden");
    }
  }
  lastX = e.clientX; lastY = e.clientY;
});
window.addEventListener("mouseup", () => { dragging = false; dragNode = null; });
canvas.addEventListener("wheel", e => {
  e.preventDefault();
  const factor = e.deltaY < 0 ? 1.1 : 0.9;
  transform.k = Math.max(0.1, Math.min(6, transform.k * factor));
  draw();
});
canvas.addEventListener("click", async e => {
  if (dragMoved) return;
  const n = nodeAt(e.clientX, e.clientY);
  if (!n) return;
  tooltip.classList.add("hidden");
  if (n.kind === "cluster_summary") {
    await expandCluster(n.cluster);
    return;
  }
  if (n.kind === "community" || n.kind === "category" || n.kind === "department") {
    await expandGroup(n.cluster, n.id.split("-").pop());
    return;
  }
  await openInspector(n);
});

function fmtBytes(n) {
  if (n == null) return null;
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}
function fmtAge(mtime) {
  if (mtime == null) return null;
  const days = Math.floor((Date.now() / 1000 - mtime) / 86400);
  if (days < 1) return "today";
  if (days === 1) return "1d ago";
  return `${days}d ago`;
}
function pill(label) {
  return `<span class="pill">${label}</span>`;
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function flyTo(n) {
  if (n.x == null) return;
  transform.x = -n.x * transform.k;
  transform.y = -n.y * transform.k;
  draw();
}

async function openInspector(n) {
  document.getElementById("inspector").classList.remove("hidden");
  document.getElementById("inspector-title").textContent = n.label;
  const meta = n.meta || {};

  const actionsEl = document.getElementById("inspector-actions");
  actionsEl.innerHTML = "";
  const flyBtn = document.createElement("button");
  flyBtn.textContent = "Fly to";
  flyBtn.onclick = () => flyTo(n);
  actionsEl.appendChild(flyBtn);
  if (n.file_path) {
    const copyBtn = document.createElement("button");
    copyBtn.textContent = "Copy path";
    copyBtn.onclick = () => {
      navigator.clipboard.writeText(n.file_path);
      copyBtn.textContent = "Copied";
      setTimeout(() => { copyBtn.textContent = "Copy path"; }, 1200);
    };
    actionsEl.appendChild(copyBtn);
  }

  const pills = [pill(n.cluster), pill(n.kind)];
  if (meta.size != null) pills.push(pill(fmtBytes(meta.size)));
  if (meta.mtime != null) pills.push(pill(fmtAge(meta.mtime)));
  if (meta.language) pills.push(pill(meta.language));
  if (meta.line_start != null) pills.push(pill(`L${meta.line_start}${meta.line_end && meta.line_end !== meta.line_start ? `-${meta.line_end}` : ""}`));
  if (meta.scope && meta.scope !== n.kind) pills.push(pill(meta.scope));
  if (meta.count != null) pills.push(pill(`${meta.count} items`));
  if (meta.model_count != null) pills.push(pill(`${meta.model_count} models`));
  document.getElementById("inspector-pills").innerHTML = pills.join("");

  const skipKeys = new Set(["size", "mtime", "language", "line_start", "line_end", "scope", "count", "model_count", "preview"]);
  const metaRows = [];
  if (n.file_path) metaRows.push(`<div><span class="meta-k">path</span>${n.file_path}</div>`);
  for (const [k, v] of Object.entries(meta)) {
    if (skipKeys.has(k) || v == null || v === "") continue;
    const val = typeof v === "object" ? JSON.stringify(v) : v;
    metaRows.push(`<div><span class="meta-k">${k}</span>${escapeHtml(val)}</div>`);
  }
  document.getElementById("inspector-meta").innerHTML = metaRows.join("");

  const connEl = document.getElementById("inspector-connections");
  connEl.innerHTML = "";
  const connections = edges.filter(e => {
    const s = e.source.id || e.source, t = e.target.id || e.target;
    return s === n.id || t === n.id;
  });
  for (const c of connections) {
    const s = c.source.id || c.source, t = c.target.id || c.target;
    const other = s === n.id ? t : s;
    const li = document.createElement("li");
    li.textContent = `${c.kind} → ${other}`;
    li.onclick = () => {
      const target = nodes.find(x => x.id === other);
      if (target) openInspector(target);
    };
    connEl.appendChild(li);
  }

  const contentEl = document.getElementById("inspector-content");
  if (n.file_path) {
    const detail = await fetchJSON(`${API}/node/${encodeURIComponent(n.id)}?file_path=${encodeURIComponent(n.file_path)}`);
    contentEl.innerHTML = detail.content ? renderMarkdown(detail.content) : "<em>(no file content)</em>";
  } else if (meta.preview) {
    contentEl.innerHTML = renderMarkdown(meta.preview);
  } else {
    contentEl.innerHTML = "<em>(no file content)</em>";
  }
}

// Small, deliberately non-exhaustive markdown renderer — just enough structure
// (headings/bold/italic/code/lists) to make skill/doc/memory files readable
// in the inspector without pulling in a dependency.
function renderMarkdown(text) {
  const lines = escapeHtml(text).split("\n");
  const out = [];
  let inList = false;
  const closeList = () => { if (inList) { out.push("</ul>"); inList = false; } };
  for (let line of lines) {
    const h = line.match(/^(#{1,4})\s+(.*)$/);
    if (h) {
      closeList();
      out.push(`<h${h[1].length + 2}>${inline(h[2])}</h${h[1].length + 2}>`);
      continue;
    }
    const li = line.match(/^\s*[-*]\s+(.*)$/);
    if (li) {
      if (!inList) { out.push("<ul>"); inList = true; }
      out.push(`<li>${inline(li[1])}</li>`);
      continue;
    }
    closeList();
    if (line.trim() === "") { out.push(""); continue; }
    out.push(`<p>${inline(line)}</p>`);
  }
  closeList();
  return out.join("\n");
}
function inline(s) {
  return s
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "<em>$1</em>");
}
document.getElementById("inspector-close").onclick = () => {
  document.getElementById("inspector").classList.add("hidden");
};

document.getElementById("search").addEventListener("input", e => {
  searchTerm = e.target.value;
  const term = searchTerm.trim().toLowerCase();
  const statusEl = document.getElementById("search-status");
  if (!term) {
    statusEl.textContent = "";
    draw();
    return;
  }
  const matches = nodes.filter(n => n.x != null && n.label.toLowerCase().includes(term));
  statusEl.textContent = matches.length
    ? `${matches.length} match${matches.length === 1 ? "" : "es"}`
    : "no matches (try expanding a panel first)";
  if (matches.length) {
    const mx = matches.reduce((s, n) => s + n.x, 0) / matches.length;
    const my = matches.reduce((s, n) => s + n.y, 0) / matches.length;
    transform.x = -mx * transform.k;
    transform.y = -my * transform.k;
  }
  draw();
});

function maybeShowOnboarding() {
  if (localStorage.getItem("graph-viz-onboarded")) return;
  document.getElementById("onboarding").classList.remove("hidden");
}
document.getElementById("onboarding-dismiss").onclick = () => {
  document.getElementById("onboarding").classList.add("hidden");
  localStorage.setItem("graph-viz-onboarded", "1");
};
document.getElementById("help-btn").onclick = () => {
  document.getElementById("onboarding").classList.remove("hidden");
};

for (const btn of document.querySelectorAll("#layout-toggles button")) {
  btn.addEventListener("click", () => {
    document.querySelectorAll("#layout-toggles button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    layoutMode = btn.dataset.layout;
    nodes.forEach(n => { n.fx = null; n.fy = null; });
    runLayout();
  });
}

document.getElementById("expand-all").onclick = async () => {
  for (const name of ["flows", "links", "skills", "agents", "crons", "docs"]) {
    await expandCluster(name);
  }
};
document.getElementById("collapse-all").onclick = collapseAll;

loadRoot();
