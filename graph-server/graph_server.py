#!/usr/bin/env python3
"""graph_server.py — read-only aggregator for the standalone Claude Code system graph.

Why this exists: the interactive graph frontend needs data that only exists
server-side (code-review-graph's SQLite DB, Graphify's precomputed json, host
systemd/filesystem state) — a browser can't query SQLite or scan the host, so
this exposes it as JSON over the docker bridge. Same trust model as stats.py.

Stdlib only. Binds the docker bridge host IP.
"""
import json
import os
import re
import sqlite3
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BIND = os.environ.get("GRAPH_BIND", "172.18.0.1")
PORT = int(os.environ.get("GRAPH_PORT", "8092"))

CRG_DB = os.path.expanduser("/home/ubuntu/AI_Space/.code-review-graph/graph.db")
GRAPHIFY_JSON = "/opt/cryptex/graphify-out/graph.json"
SKILL_INDEX = os.path.expanduser("~/.claude/skill-library/.router/index.json")
DEPARTMENTS_MD = os.path.expanduser("~/.claude/departments.md")
DOCS_DIR = "/home/ubuntu/AI_Space/docs"
MEMORY_DIR = os.path.expanduser("~/.claude/projects/-home-ubuntu-AI-Space/memory")
STATIC_DIR = "/opt/cryptex/graph-viz"

CLAUDE_AGENT_JOBS = [
    "news", "monitor", "jobhunt", "jobhunt-status-sync", "movies-tv", "movies",
    "til", "deepdive", "duel", "digest", "github", "movies-anime", "cartographer",
]
BUILTIN_AGENT_TYPES = [
    "claude", "claude-code-guide", "Explore", "general-purpose", "Plan",
    "statusline-setup",
]


def _run(cmd: list, timeout: int = 8) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def _job_status(job: str) -> dict:
    unit = f"claude-agent@{job}.service"
    out = _run(["systemctl", "show", unit, "-p", "ActiveState,ExecMainStartTimestamp"])
    props = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k] = v
    return {
        "active_state": props.get("ActiveState") or None,
        "last_start": props.get("ExecMainStartTimestamp") or None,
    }


def cluster_flows() -> dict:
    nodes, edges = [], []
    if not os.path.exists(CRG_DB):
        return {"nodes": nodes, "edges": edges}
    con = sqlite3.connect(f"file:{CRG_DB}?mode=ro", uri=True)
    try:
        cur = con.cursor()
        cur.execute(
            "SELECT id, name, level, parent_id, cohesion, size, dominant_language, "
            "description FROM communities"
        )
        for row in cur.fetchall():
            cid, name, level, parent_id, cohesion, size, lang, desc = row
            nodes.append({
                "id": f"flow-community-{cid}", "label": name, "cluster": "flows",
                "kind": "community",
                "meta": {"level": level, "cohesion": cohesion, "size": size,
                         "language": lang, "description": desc},
            })
            if parent_id is not None:
                edges.append({
                    "source": f"flow-community-{cid}",
                    "target": f"flow-community-{parent_id}", "kind": "parent",
                })
    finally:
        con.close()
    return {"nodes": nodes, "edges": edges}


def cluster_flows_expand(community_id: str) -> dict:
    nodes, edges = [], []
    if not os.path.exists(CRG_DB):
        return {"nodes": nodes, "edges": edges}
    con = sqlite3.connect(f"file:{CRG_DB}?mode=ro", uri=True)
    try:
        cur = con.cursor()
        cur.execute(
            "SELECT id, name, qualified_name, file_path, kind, line_start, line_end, "
            "language, signature, params, return_type FROM nodes "
            "WHERE community_id = ? LIMIT 500", (community_id,)
        )
        rows = cur.fetchall()
        qualified_to_node_id = {}
        for nid, name, qualified_name, file_path, node_kind, line_start, line_end, \
                language, signature, params, return_type in rows:
            node_id = f"flow-node-{nid}"
            qualified_to_node_id[qualified_name] = node_id
            nodes.append({
                "id": node_id, "label": name, "cluster": "flows", "kind": node_kind,
                "file_path": file_path,
                "meta": {
                    "qualified_name": qualified_name, "line_start": line_start,
                    "line_end": line_end, "language": language,
                    "signature": signature, "params": params,
                    "return_type": return_type,
                },
            })
        if qualified_to_node_id:
            placeholders = ",".join("?" for _ in qualified_to_node_id)
            qualified_names = list(qualified_to_node_id)
            cur.execute(
                f"SELECT source_qualified, target_qualified, kind FROM edges "
                f"WHERE source_qualified IN ({placeholders}) "
                f"AND target_qualified IN ({placeholders}) LIMIT 2000",
                qualified_names + qualified_names,
            )
            for src, tgt, etype in cur.fetchall():
                edges.append({
                    "source": qualified_to_node_id[src],
                    "target": qualified_to_node_id[tgt], "kind": etype,
                })
    finally:
        con.close()
    return {"nodes": nodes, "edges": edges}


def cluster_links() -> dict:
    if not os.path.exists(GRAPHIFY_JSON):
        return {"nodes": [], "edges": []}
    with open(GRAPHIFY_JSON, encoding="utf-8") as fh:
        data = json.load(fh)
    communities = {}
    for n in data.get("nodes", []):
        cid = n.get("community")
        cname = n.get("community_name") or f"community-{cid}"
        info = communities.setdefault(cid, {"name": cname, "count": 0, "file_types": {}})
        info["count"] += 1
        ftype = n.get("file_type", "unknown")
        info["file_types"][ftype] = info["file_types"].get(ftype, 0) + 1
    nodes = [
        {"id": f"link-community-{cid}", "label": info["name"], "cluster": "links",
         "kind": "community",
         "meta": {
             "count": info["count"],
             "file_types": sorted(info["file_types"].items(), key=lambda kv: -kv[1])[:6],
         }}
        for cid, info in communities.items()
    ]
    return {"nodes": nodes, "edges": []}


def cluster_links_expand(community_id: str) -> dict:
    if not os.path.exists(GRAPHIFY_JSON):
        return {"nodes": [], "edges": []}
    with open(GRAPHIFY_JSON, encoding="utf-8") as fh:
        data = json.load(fh)
    try:
        cid = int(community_id)
    except ValueError:
        cid = community_id
    wanted = {
        n["id"] for n in data.get("nodes", []) if n.get("community") == cid
    }
    nodes = [
        {"id": f"link-node-{n['id']}", "label": n.get("label", n["id"]),
         "cluster": "links", "kind": n.get("file_type", "unknown"),
         "file_path": n.get("source_file"),
         "meta": {
             "file_type": n.get("file_type"), "source_location": n.get("source_location"),
             "origin": n.get("_origin"),
         }}
        for n in data.get("nodes", []) if n["id"] in wanted
    ][:500]
    edges = [
        {"source": f"link-node-{e['source']}", "target": f"link-node-{e['target']}",
         "kind": e.get("relation", "link"),
         "meta": {"weight": e.get("weight"), "confidence": e.get("confidence")}}
        for e in data.get("links", [])
        if e.get("source") in wanted and e.get("target") in wanted
    ][:2000]
    return {"nodes": nodes, "edges": edges}


def cluster_skills() -> dict:
    if not os.path.exists(SKILL_INDEX):
        return {"nodes": [], "edges": []}
    with open(SKILL_INDEX, encoding="utf-8") as fh:
        data = json.load(fh)
    cats = {}
    for s in data.get("skills", []):
        cat = s.get("cat", "uncategorized")
        cats.setdefault(cat, 0)
        cats[cat] += 1
    nodes = [
        {"id": f"skill-cat-{cat}", "label": cat, "cluster": "skills",
         "kind": "category", "meta": {"count": count}}
        for cat, count in cats.items()
    ]
    return {"nodes": nodes, "edges": []}


def cluster_skills_expand(cat: str) -> dict:
    if not os.path.exists(SKILL_INDEX):
        return {"nodes": [], "edges": []}
    with open(SKILL_INDEX, encoding="utf-8") as fh:
        data = json.load(fh)
    nodes, edges = [], []
    for s in data.get("skills", []):
        if s.get("cat", "uncategorized") != cat:
            continue
        node_id = f"skill-{s['name']}"
        nodes.append({
            "id": node_id, "label": s["name"], "cluster": "skills", "kind": s.get("scope", "skill"),
            "file_path": s.get("path"),
            "meta": {"desc": s.get("desc"), "kw": s.get("kw"), "scope": s.get("scope")},
        })
        edges.append({"source": f"skill-cat-{cat}", "target": node_id, "kind": "contains"})
    return {"nodes": nodes, "edges": edges}


def cluster_agents() -> dict:
    nodes, edges = [], []
    if os.path.exists(DEPARTMENTS_MD):
        with open(DEPARTMENTS_MD, encoding="utf-8") as fh:
            text = fh.read()
        dept = None
        dept_counts = {}
        for line in text.splitlines():
            hm = re.match(r"^##\s*Department:\s*(.+)$", line)
            if hm:
                dept = hm.group(1).strip()
                dept_id = f"agent-dept-{dept}"
                if not any(n["id"] == dept_id for n in nodes):
                    nodes.append({
                        "id": dept_id, "label": dept, "cluster": "agents",
                        "kind": "department", "meta": {},
                    })
                continue
            row = re.match(r"^\|\s*`?([^|`]+)`?\s*\|\s*(.+?)\s*\|$", line)
            if row and dept and "---" not in line and "Model" not in line:
                model, owns = row.group(1).strip(), row.group(2).strip()
                model_id = f"agent-model-{dept}-{model}"
                nodes.append({
                    "id": model_id, "label": model, "cluster": "agents",
                    "kind": "model", "meta": {"owns": owns},
                })
                edges.append({"source": f"agent-dept-{dept}", "target": model_id, "kind": "has_model"})
                dept_counts[dept] = dept_counts.get(dept, 0) + 1
        for n in nodes:
            if n["kind"] == "department":
                n["meta"]["model_count"] = dept_counts.get(n["label"], 0)
    for job in CLAUDE_AGENT_JOBS:
        st = _job_status(job)
        nodes.append({
            "id": f"agent-job-{job}", "label": job, "cluster": "agents",
            "kind": "scheduled_job", "meta": st,
        })
    for kind in BUILTIN_AGENT_TYPES:
        nodes.append({
            "id": f"agent-builtin-{kind}", "label": kind, "cluster": "agents",
            "kind": "builtin_type", "meta": {},
        })
    return {"nodes": nodes, "edges": edges}


def cluster_crons() -> dict:
    nodes = []
    out = _run(["systemctl", "list-timers", "--no-pager", "--all"])
    lines = [l for l in out.splitlines() if l.strip()]
    for line in lines:
        parts = line.split()
        if len(parts) >= 9 and parts[-1].endswith(".service"):
            unit = parts[-2] if parts[-2].endswith(".timer") else None
            svc = parts[-1]
            # columns: NEXT(5 tokens incl weekday+tz) LEFT LAST(5) PASSED UNIT ACTIVATES
            # LEFT and PASSED are single "N left"/"N ago"-style tokens found by position
            # from the end, since NEXT/LAST each vary in token count by locale/timezone.
            next_run = " ".join(parts[:5]) if len(parts) > 8 else None
            nodes.append({
                "id": f"cron-{svc}", "label": svc, "cluster": "crons",
                "kind": "systemd_timer",
                "meta": {"timer": unit, "next_run": next_run, "raw": line.strip()},
            })
    for user in ("root", "ubuntu"):
        out = _run(["sudo", "-n", "crontab", "-l", "-u", user])
        for i, line in enumerate(out.splitlines()):
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                fields = stripped.split(None, 5)
                schedule = " ".join(fields[:5]) if len(fields) >= 6 else None
                command = fields[5] if len(fields) >= 6 else stripped
                nodes.append({
                    "id": f"cron-{user}-{i}", "label": stripped,
                    "cluster": "crons", "kind": "crontab_entry",
                    "meta": {"user": user, "schedule": schedule, "command": command},
                })
    return {"nodes": nodes, "edges": []}


def cluster_docs() -> dict:
    nodes, edges = [], []
    if os.path.isdir(DOCS_DIR):
        for root, dirs, files in os.walk(DOCS_DIR):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in files:
                if f.endswith(".md"):
                    p = os.path.join(root, f)
                    rel = os.path.relpath(p, DOCS_DIR)
                    try:
                        st = os.stat(p)
                        size, mtime = st.st_size, st.st_mtime
                    except OSError:
                        size, mtime = None, None
                    preview = None
                    try:
                        with open(p, encoding="utf-8", errors="replace") as fh:
                            preview = fh.read(240).strip()
                    except OSError:
                        pass
                    nodes.append({
                        "id": f"doc-{rel}", "label": rel, "cluster": "docs",
                        "kind": "doc_file", "file_path": p,
                        "meta": {"size": size, "mtime": mtime, "preview": preview},
                    })
    memory_index = os.path.join(MEMORY_DIR, "MEMORY.md")
    if os.path.exists(memory_index):
        with open(memory_index, encoding="utf-8") as fh:
            text = fh.read()
        entries = re.findall(r"\[(.+?)\]\((.+?)\)", text)
        for title, path in entries:
            node_id = f"memory-{path}"
            full = os.path.join(MEMORY_DIR, path)
            size = None
            try:
                size = os.stat(full).st_size
            except OSError:
                pass
            nodes.append({
                "id": node_id, "label": title, "cluster": "docs",
                "kind": "memory_entry", "file_path": full,
                "meta": {"size": size},
            })
    for f in os.listdir(MEMORY_DIR) if os.path.isdir(MEMORY_DIR) else []:
        if not f.endswith(".md"):
            continue
        p = os.path.join(MEMORY_DIR, f)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        src_id = f"memory-{f}"
        for link in re.findall(r"\[\[(.+?)\]\]", text):
            edges.append({"source": src_id, "target": f"memory-{link}.md", "kind": "links_to"})
    return {"nodes": nodes, "edges": edges}


CLUSTER_LOADERS = {
    "flows": cluster_flows, "links": cluster_links, "skills": cluster_skills,
    "agents": cluster_agents, "crons": cluster_crons, "docs": cluster_docs,
}
CLUSTER_EXPANDERS = {
    "flows": cluster_flows_expand, "links": cluster_links_expand,
    "skills": cluster_skills_expand,
}


def build_graph(scope: str = None) -> dict:
    if scope and scope in CLUSTER_LOADERS:
        result = CLUSTER_LOADERS[scope]()
        return {"nodes": result["nodes"], "edges": result["edges"],
                "clusters": [scope]}
    nodes, edges = [], []
    for name, loader in CLUSTER_LOADERS.items():
        result = loader()
        summary_id = f"cluster-{name}"
        nodes.append({
            "id": summary_id, "label": name, "cluster": name,
            "kind": "cluster_summary", "meta": {"count": len(result["nodes"])},
        })
    return {"nodes": nodes, "edges": edges, "clusters": list(CLUSTER_LOADERS)}


ALLOWED_CONTENT_ROOTS = (
    os.path.expanduser("~/.claude"),
    "/home/ubuntu/AI_Space/docs",
    "/home/ubuntu/AI_Space/.code-review-graph",
)


def get_node_content(file_path: str) -> dict:
    """Read file content for the inspector panel, given a path the client already
    has from a previously-fetched node (cluster/expand loaders are stateless and
    re-run on every request, so re-finding a leaf node by id alone is wasteful —
    the client already knows file_path from when it fetched the node)."""
    if not file_path:
        return {"content": None}
    real = os.path.realpath(file_path)
    if not any(real.startswith(root) for root in ALLOWED_CONTENT_ROOTS):
        return {"content": None}
    if not os.path.isfile(real):
        return {"content": None}
    try:
        with open(real, encoding="utf-8", errors="replace") as fh:
            return {"content": fh.read(20000)}
    except OSError:
        return {"content": None}


class Handler(BaseHTTPRequestHandler):
    server_version = "graph-server"

    def log_message(self, *a):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _static(self, path):
        full = os.path.join(STATIC_DIR, path.lstrip("/") or "index.html")
        if not os.path.isfile(full):
            self.send_response(404)
            self.end_headers()
            return
        ctype = "text/html"
        if full.endswith(".js"):
            ctype = "application/javascript"
        elif full.endswith(".css"):
            ctype = "text/css"
        elif full.endswith(".woff2"):
            ctype = "font/woff2"
        elif full.endswith(".ttf"):
            ctype = "font/ttf"
        with open(full, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # No Cache-Control meant browsers fell back to heuristic caching and kept
        # serving stale JS/CSS across edits during active development.
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = parse_qs(parsed.query)

        if path == "/graph":
            scope = qs.get("scope", [None])[0]
            self._json(build_graph(scope))
        elif path.startswith("/graph/cluster/"):
            name = path[len("/graph/cluster/"):]
            group_id = qs.get("id", [None])[0]
            expander = CLUSTER_EXPANDERS.get(name)
            if not expander:
                self._json({"error": "unknown or non-expandable cluster"}, 404)
                return
            if group_id is None:
                self._json({"error": "missing ?id= group to expand"}, 400)
                return
            self._json(expander(group_id))
        elif path.startswith("/node/"):
            file_path = qs.get("file_path", [None])[0]
            self._json(get_node_content(file_path))
        else:
            self._static(path)


def demo():
    """Self-check: each cluster loader returns a shape-correct dict against live paths."""
    for name, loader in CLUSTER_LOADERS.items():
        result = loader()
        assert "nodes" in result and "edges" in result, name
        assert isinstance(result["nodes"], list), name
    g = build_graph()
    assert set(g["clusters"]) == set(CLUSTER_LOADERS)
    assert len(g["nodes"]) == len(CLUSTER_LOADERS)
    real_file = os.path.expanduser("~/.claude/departments.md")
    assert get_node_content(real_file)["content"]
    assert get_node_content("/etc/shadow")["content"] is None
    print("graph_server.py self-check OK")


if __name__ == "__main__":
    import sys

    if "--demo" in sys.argv:
        demo()
    else:
        srv = ThreadingHTTPServer((BIND, PORT), Handler)
        print(f"graph-server serving on {BIND}:{PORT}/", flush=True)
        srv.serve_forever()
