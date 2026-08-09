#!/usr/bin/env python3
"""gh_gate.py — fact-check and filter the GitHub digest against the real GitHub API.

The model's own star counts are unreliable (2026-07-28 digest claimed OpenHands
at 38k when it was 82.5k, frp at 85k when it was 108k), and it recommended four
tools Parth already runs. So eligibility is decided here, from API facts, not
from the model's prose.

Reads digest markdown on stdin, writes filtered markdown on stdout, and prints a
per-repo decision table to stderr.

Three independent gates:

  1. OWNED     — repo matches the deterministic stack inventory. Always dropped.
                 This is the "stop recommending what I already run" gate.

  2. CATEGORY  — more than MAX_PER_CATEGORY repos from one job-to-be-done cluster
                 in a single issue. Dropped past the cap. This is the "stop
                 re-answering the same question with a different repo" gate.

  3. NOVELTY   — a repo qualifies as a "hidden gem" by EITHER of two paths, so a
                 genuine fast riser is never filtered out by a flat star ceiling:

                   small : stars <= SMALL_STARS  (quietly good, under the radar)
                   riser : stars/month >= RISER_VELOCITY and age <= RISER_MAX_AGE_MO
                           (breaking out right now — high stars but EARNED fast)

                 Calibrated 2026-07-30 on measured data:
                   riser side  openclaw 47204/mo, browser-use 5128/mo, strix 3882/mo
                   mature side neko 285/mo, wg-easy 426/mo, homepage 673/mo, frp 852/mo
                 1500/mo sits in the empty band between those two populations.

Trending section is fact-checked (stars corrected, dead/archived repos dropped)
but NOT novelty-gated — trending is allowed to be famous by definition.

Self-check: python3 gh_gate.py --selftest   (offline, no API calls)
"""
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

SMALL_STARS = int(os.environ.get("GEM_SMALL_STARS", "5000"))
RISER_VELOCITY = float(os.environ.get("GEM_RISER_VELOCITY", "1500"))
RISER_MAX_AGE_MO = float(os.environ.get("GEM_RISER_MAX_AGE_MO", "18"))
MAX_PER_CATEGORY = int(os.environ.get("GEM_MAX_PER_CATEGORY", "2"))
STALE_MONTHS = float(os.environ.get("GEM_STALE_MONTHS", "12"))
SECONDS_PER_MONTH = 2629800.0

# Job-to-be-done clusters. Derived from the real 113-item backlog (2026-07-30),
# where the digest had re-pitched ~8 tunnel/VPN tools and ~9 monitoring tools
# across 17 weeks without ever repeating a single URL.
CATEGORIES = {
    "tunnel/vpn/nat": r"tunnel|vpn|wireguard|nat|reverse.?prox|ingress|mesh|frp|rathole|chisel|zerotier|tailscale",
    "monitoring/uptime": r"uptime|monitor|observab|metric|healthcheck|status.?page|alerting|dashboard.*(server|host)|smart.?monitor",
    "docker-mgmt": r"docker|container|compose|orchestrat|deploy.*(panel|ui)|paas",
    "ai-coding": r"code.?review|coding.?agent|ai.?engineer|copilot|autocomplete|refactor.*ai|llm.*code|code.*llm",
    "agent-skills": r"\bskill|\bagent|mcp|prompt|claude|anthropic",
    "scorm/xapi": r"scorm|xapi|lrs|e-?learn|moodle|tin.?can",
    "notes/pkm": r"note|pkm|knowledge.?base|wiki|bookmark|read.?it.?later|memo",
    "backup/dr": r"backup|restic|snapshot|disaster|restore|archive",
    "auth/identity": r"oidc|oauth|sso|identity|auth(elia|entik)?|keycloak|password|vault",
}

ITEM_RE = re.compile(r"^-\s+\*\*\[([^\]]+)\]\(https://github\.com/([^)/]+/[^)/#?]+)/?\)\*\*\s*(.*)$")
HEADING_RE = re.compile(r"^##\s+(.*)$")


def gh_meta(slug):
    """Fetch live repo facts. Returns None if the repo is gone/renamed/inaccessible."""
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{slug}", "--jq",
             "[.full_name,.stargazers_count,.created_at,.pushed_at,.archived]|@tsv"],
            capture_output=True, text=True, timeout=25,
        )
        if out.returncode != 0 or not out.stdout.strip():
            return None
        full, stars, created, pushed, archived = out.stdout.strip().split("\t")
        return {
            "full_name": full,
            "stars": int(stars),
            "created": created,
            "pushed": pushed,
            "archived": archived == "true",
        }
    except Exception:
        return None


def _epoch(iso):
    try:
        return subprocess.run(["date", "-d", iso, "+%s"], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def enrich(meta, now):
    created = _epoch(meta["created"])
    pushed = _epoch(meta["pushed"])
    age_mo = max((now - int(created)) / SECONDS_PER_MONTH, 1.0) if created else 1.0
    idle_mo = (now - int(pushed)) / SECONDS_PER_MONTH if pushed else 0.0
    meta["age_mo"] = age_mo
    meta["idle_mo"] = idle_mo
    meta["velocity"] = meta["stars"] / age_mo
    return meta


def categorize(text):
    low = text.lower()
    for name, pat in CATEGORIES.items():
        if re.search(pat, low):
            return name
    return None


def classify(meta, owned, is_gem_section, cat_counts):
    """Return (keep: bool, reason: str)."""
    slug = meta["full_name"].lower()
    name = slug.split("/")[-1]
    if slug in owned or name in owned:
        return False, "OWNED"
    if meta["archived"]:
        return False, "ARCHIVED"
    if meta["idle_mo"] > STALE_MONTHS:
        return False, f"STALE {meta['idle_mo']:.0f}mo"

    if is_gem_section:
        small = meta["stars"] <= SMALL_STARS
        riser = meta["velocity"] >= RISER_VELOCITY and meta["age_mo"] <= RISER_MAX_AGE_MO
        if not (small or riser):
            return False, f"NOT-GEM {meta['stars']}★ {meta['velocity']:.0f}/mo"
        tag = "small" if small else "riser"
    else:
        tag = "trending"

    cat = meta.get("category")
    if cat:
        if cat_counts[cat] >= MAX_PER_CATEGORY:
            return False, f"CAT-FULL {cat}"
        cat_counts[cat] += 1
    return True, tag


def render(meta, label, desc, tag):
    """Rewrite the line with API-true stars and a provenance tag."""
    desc = re.sub(r"\(★[^)]*\)\s*$", "", desc).strip()
    desc = re.sub(r"^[—–-]\s*", "", desc).strip()  # model already emits the em-dash
    # If the label is a slug, use the canonical one — GitHub renames repos
    # (All-Hands-AI/OpenHands -> OpenHands/OpenHands) and a stale label next to a
    # redirected URL looks like a broken link.
    if "/" in label:
        label = meta["full_name"]
    stars = meta["stars"]
    star_s = f"{stars/1000:.1f}k" if stars >= 1000 else str(stars)
    extra = f" _[{tag} · {meta['velocity']:.0f}★/mo]_" if tag in ("small", "riser") else ""
    return f"- **[{label}](https://github.com/{meta['full_name']})** — {desc} (★ {star_s}){extra}"


def process(text, owned, now):
    out, table = [], []
    cat_counts = defaultdict(int)
    is_gem = False
    section_body = defaultdict(list)
    order = []
    current = None

    for line in text.splitlines():
        h = HEADING_RE.match(line)
        if h:
            current = line
            order.append(current)
            is_gem = "hidden gem" in h.group(1).lower()
            section_body[current] = []
            section_body[current + "\x00gem"] = is_gem
            continue
        m = ITEM_RE.match(line.strip())
        if not m or current is None:
            if current is not None and line.strip():
                section_body[current].append(("raw", line))
            continue
        label, slug, desc = m.group(1), m.group(2), m.group(3)
        meta = gh_meta(slug)
        if meta is None:
            table.append(f"  DROP  {slug:<42} DEAD/404")
            continue
        enrich(meta, now)
        meta["category"] = categorize(f"{label} {desc} {slug}")
        keep, reason = classify(meta, owned, section_body[current + "\x00gem"], cat_counts)
        table.append(
            f"  {'KEEP' if keep else 'DROP'}  {meta['full_name']:<42} "
            f"{meta['stars']:>7}★ {meta['velocity']:>7.0f}/mo  {reason}"
        )
        if keep:
            section_body[current].append(("item", render(meta, label, desc, reason)))

    for sec in order:
        items = [t for k, t in section_body[sec] if k == "item"]
        if not items:
            continue  # SKIP a category entirely rather than emit an empty heading
        out.append(sec)
        out.extend(items)
        out.append("")
    return "\n".join(out).strip() + "\n", table


# ---------------------------------------------------------------- self-check
def selftest():
    now = 1785400000
    owned = {"pocket-id/pocket-id", "pocket-id", "kopia", "louislam/uptime-kuma", "uptime-kuma"}

    def mk(full, stars, age_mo, idle_mo=0.0, archived=False, cat=None):
        return {"full_name": full, "stars": stars, "age_mo": age_mo, "idle_mo": idle_mo,
                "archived": archived, "velocity": stars / age_mo, "category": cat}

    cc = defaultdict(int)
    # already-running tool is dropped no matter how good it looks
    assert classify(mk("pocket-id/pocket-id", 8631, 23.6), owned, True, cc)[1] == "OWNED"
    assert classify(mk("louislam/uptime-kuma", 89621, 60.9), owned, True, cc)[1] == "OWNED"
    # mature-and-famous is not a hidden gem
    cc = defaultdict(int)
    assert classify(mk("m1k1o/neko", 21785, 76.5), owned, True, cc)[0] is False
    assert classify(mk("gethomepage/homepage", 31752, 47.2), owned, True, cc)[0] is False
    # THE FAST-RISER CASE: high stars but earned fast -> kept as a gem
    cc = defaultdict(int)
    keep, reason = classify(mk("openclaw/openclaw", 384542, 8.1), owned, True, cc)
    assert keep and reason == "riser", (keep, reason)
    keep, reason = classify(mk("browser-use/browser-use", 107279, 20.9), owned, True, cc)
    assert keep is False, "20.9mo old exceeds the 18mo riser window"
    cc = defaultdict(int)
    keep, reason = classify(mk("usestrix/strix", 45719, 11.8), owned, True, cc)
    assert keep and reason == "riser", (keep, reason)
    # quiet small tool -> kept
    cc = defaultdict(int)
    assert classify(mk("sablierapp/sablier", 2829, 69.3), owned, True, cc)[1] == "small"
    # archived + stale are dropped
    cc = defaultdict(int)
    assert classify(mk("x/y", 100, 10, archived=True), owned, True, cc)[1] == "ARCHIVED"
    assert classify(mk("x/z", 100, 30, idle_mo=20), owned, True, cc)[1].startswith("STALE")
    # category cap: 3rd tunnel tool in one issue is dropped
    cc = defaultdict(int)
    a = classify(mk("a/one", 900, 10, cat="tunnel/vpn/nat"), owned, True, cc)
    b = classify(mk("b/two", 900, 10, cat="tunnel/vpn/nat"), owned, True, cc)
    c = classify(mk("c/three", 900, 10, cat="tunnel/vpn/nat"), owned, True, cc)
    assert a[0] and b[0] and not c[0], (a, b, c)
    assert c[1] == "CAT-FULL tunnel/vpn/nat"
    # trending section ignores novelty but still drops owned
    cc = defaultdict(int)
    assert classify(mk("fatedier/frp", 108447, 127.3), owned, False, cc)[0] is True
    # categorizer
    assert categorize("a reverse proxy tunnel for NAT") == "tunnel/vpn/nat"
    assert categorize("beautiful uptime monitoring") == "monitoring/uptime"
    # empty section is omitted entirely
    body, _ = process("## Hidden Gems & Self-Hosting\n", set(), now)
    assert "Hidden Gems" not in body, body
    print("gh_gate selftest OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    inv_path = sys.argv[1] if len(sys.argv) > 1 else None
    owned = set()
    if inv_path and os.path.exists(inv_path):
        with open(inv_path) as f:
            owned = {l.strip().lower() for l in f if l.strip()}
    now = int(subprocess.run(["date", "+%s"], capture_output=True, text=True).stdout.strip())
    text = sys.stdin.read()
    body, table = process(text, owned, now)
    sys.stderr.write("gh_gate decisions (%d inventory tokens):\n%s\n" % (len(owned), "\n".join(table)))
    sys.stdout.write(body)


if __name__ == "__main__":
    main()
