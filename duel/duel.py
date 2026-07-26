#!/usr/bin/env python3
"""duel.py — poster-vs-poster taste ranking over the PKM watched-films collection.

Why this exists: every PKM surface that asked Parth to type prose is dead (TIL since
April, ReadLater since March, 1 of 161 movie notes has a personal note). This one asks
for a single tap, so it can't die the same way. Output is an Elo ranking that (a) gives
the weekly movie picker a real taste signal instead of counting genre strings and
(b) answers "which film could I talk about for an hour" for the YouTube channel.

Stdlib only. Binds the docker bridge host IP so the nginx container can proxy to it;
that address is not internet-routable on its own.
"""
import base64
import hashlib
import hmac
import html
import json
import math
import os
import random
import re
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(BASE, "state")
PKM = os.environ.get("PKM", "/opt/cryptex/data/pkm")
MOVIES = os.path.join(PKM, "50 Collections", "Movies")
RANK_NOTE = os.path.join(PKM, "50 Collections", "Movies", "🏆 Taste Ranking.md")

RATINGS = os.path.join(STATE, "ratings.json")
VOTES = os.path.join(STATE, "votes.jsonl")
SECRET_FILE = os.path.join(STATE, "secret")

BIND = os.environ.get("DUEL_BIND", "172.18.0.1")
PORT = int(os.environ.get("DUEL_PORT", "8090"))
PREFIX = "/d"
K = 32
START = 1500.0
TOKEN_DAYS = 21


def secret() -> bytes:
    with open(SECRET_FILE, "rb") as fh:
        return fh.read().strip()


def sign(msg: str) -> str:
    mac = hmac.new(secret(), msg.encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(mac).decode().rstrip("=")[:27]


def make_token(days: int = TOKEN_DAYS) -> str:
    exp = int(time.time()) + days * 86400
    return f"{exp}.{sign(str(exp))}"


def token_ok(tok: str) -> bool:
    if not tok or "." not in tok:
        return False
    exp, mac = tok.split(".", 1)
    if not exp.isdigit() or not hmac.compare_digest(mac, sign(exp)):
        return False
    return int(exp) > time.time()


# ---------------------------------------------------------------- collection

def _yaml_head(text: str) -> str:
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    return text[3:end] if end != -1 else ""


def _field(head: str, key: str) -> str:
    # [^\S\n]* not \s*: \s matches newlines, so a key with an empty value would
    # greedily swallow the following line (this bit the block-sequence genres parse).
    m = re.search(rf"^{key}:[^\S\n]*(.*)$", head, re.M)
    if not m:
        return ""
    return m.group(1).strip().strip('"').strip("'")


def _list_field(head: str, key: str) -> list:
    """Handles both `genres: [A, B]` and the block-sequence form."""
    m = re.search(rf"^{key}:[^\S\n]*(.*)$", head, re.M)
    if not m:
        return []
    inline = m.group(1).strip()
    if inline.startswith("["):
        return [g.strip().strip('"').strip("'") for g in inline[1:-1].split(",") if g.strip()]
    if inline:
        return [inline.strip('"')]
    out = []
    for line in head[m.end():].splitlines():
        if re.match(r"^\s+-\s+", line):
            out.append(re.sub(r"^\s+-\s+", "", line).strip().strip('"'))
        elif line.strip():
            break
    return out


COLLECTIONS = {
    "movies": ("Movies", "🎬"),
    "tv": ("TV Shows", "📺"),
    "anime": ("Anime", "🌸"),
    "books": ("Books", "📚"),
}


def _read_note(path: str, fid: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return {}
    head = _yaml_head(text)
    status = _field(head, "status") or "unknown"
    return {
        "id": fid,
        "title": _field(head, "title") or fid,
        "year": _field(head, "year"),
        "director": _field(head, "director") or _field(head, "author"),
        "genres": _list_field(head, "genres"),
        "poster": _field(head, "poster_url") or _field(head, "cover_url"),
        "status": status,
        "overview": _field(head, "overview"),
        "path": path,
        "enriched": bool(_field(head, "title")),
    }


def load_collection(kind: str) -> dict:
    """All notes in one collection, whatever their status."""
    folder = COLLECTIONS.get(kind, ("Movies",))[0]
    base = os.path.join(PKM, "50 Collections", folder)
    out = {}
    if not os.path.isdir(base):
        return out
    for name in sorted(os.listdir(base)):
        if not name.endswith(".md") or name.startswith(("🏆", "📋", "📚")):
            continue
        item = _read_note(os.path.join(base, name), name[:-3])
        if item:
            out[name[:-3]] = item
    return out


def load_films() -> dict:
    """Watched films only — the duel pool. Ranking a film you haven't seen is meaningless."""
    return {k: v for k, v in load_collection("movies").items() if v["status"] == "watched"}


# ---------------------------------------------------------------- elo

def load_ratings() -> dict:
    try:
        with open(RATINGS, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_ratings(r: dict) -> None:
    tmp = RATINGS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(r, fh, indent=1, sort_keys=True)
    os.replace(tmp, RATINGS)


def rec(ratings: dict, fid: str) -> dict:
    """Mutating accessor — ONLY for the vote path. Read paths must use `peek`:
    calling this from pick_pair silently created a 1500/0 entry for every film it
    looked at, which the next save flushed to disk and which polluted the ranking
    note with 31 unvoted rows."""
    return ratings.setdefault(fid, {"elo": START, "n": 0})


def peek(ratings: dict, fid: str) -> dict:
    return ratings.get(fid) or {"elo": START, "n": 0}


def seen_pairs() -> set:
    """Pairs already judged — never ask the same question twice."""
    out = set()
    try:
        with open(VOTES, encoding="utf-8") as fh:
            for line in fh:
                try:
                    v = json.loads(line)
                except ValueError:
                    continue
                if "w" in v and "l" in v:
                    out.add(frozenset((v["w"], v["l"])))
    except OSError:
        pass
    return out


def expected(a: float, b: float) -> float:
    return 1.0 / (1.0 + 10 ** ((b - a) / 400.0))


def apply_vote(ratings: dict, win: str, lose: str) -> None:
    w, l = rec(ratings, win), rec(ratings, lose)
    ew = expected(w["elo"], l["elo"])
    # provisional films move faster: a film with 2 votes shouldn't be pinned by K=32
    kw = K * 2 if w["n"] < 5 else K
    kl = K * 2 if l["n"] < 5 else K
    w["elo"] += kw * (1 - ew)
    l["elo"] -= kl * (1 - ew)
    w["n"] += 1
    l["n"] += 1


def pick_pair(films: dict, ratings: dict, seen: set = None) -> tuple:
    """Choose the most informative unasked question.

    1. COVERAGE — A is drawn uniformly from the films with the fewest votes, so every
       film is duelled once before any film is duelled twice. (The old version sampled
       from the top third by vote count, which let popular films recur ~2x expected.)
    2. INFORMATION — B minimises  votes(b) + |Elo(a) - Elo(b)| / 100.  A close-Elo
       matchup is genuinely uncertain, so its outcome carries information; 1900 vs 1100
       tells you nothing you didn't already know. Under-voted opponents break ties.
    3. NO REPEATS — pairs already judged are excluded outright. Only if A has faced
       everyone does the exclusion relax, and then the least-recently-asked pair wins.

    Pure: never mutates `ratings`.
    """
    ids = list(films)
    if len(ids) < 2:
        return None
    if seen is None:
        seen = seen_pairs()

    fewest = min(peek(ratings, f)["n"] for f in ids)
    a = random.choice([f for f in ids if peek(ratings, f)["n"] == fewest])
    ea = peek(ratings, a)["elo"]

    others = [f for f in ids if f != a]
    fresh = [f for f in others if frozenset((a, f)) not in seen]
    pool = fresh or others  # A has met everyone: allow a rematch rather than stall

    def cost(f):
        r = peek(ratings, f)
        return r["n"] + abs(r["elo"] - ea) / 100.0

    # Randomise only among candidates genuinely TIED near the best cost. A blind
    # `pool[:3]` slice would keep 3 candidates even when only one is actually good,
    # which broke coverage: a once-voted film got offered while a never-voted one waited.
    pool.sort(key=lambda f: (cost(f), random.random()))
    best = cost(pool[0])
    tied = [f for f in pool if cost(f) <= best + 0.25]
    b = random.choice(tied[:3])
    return (a, b) if random.random() < 0.5 else (b, a)


def write_ranking(films: dict, ratings: dict) -> None:
    # n > 0 only: a film that was merely *considered* for a pair is not ranked.
    rows = [(fid, r) for fid, r in ratings.items() if fid in films and r.get("n", 0) > 0]
    if not rows:
        return
    rows.sort(key=lambda kv: -kv[1]["elo"])
    total = sum(r["n"] for _, r in rows) // 2
    lines = [
        "---",
        "tags: [movie, taste, generated]",
        "cssclasses: [no-title]",
        "---",
        "",
        "# 🏆 Taste Ranking",
        "",
        f"> Generated by the duel service — {total} head-to-head votes across "
        f"{len(rows)} watched films. Elo, K={K}. Do not edit by hand; regenerated on every vote.",
        "",
        "| # | Film | Elo | Votes | Genres |",
        "|---|---|---|---|---|",
    ]
    for i, (fid, r) in enumerate(rows, 1):
        f = films[fid]
        title = f["title"] + (f" ({f['year']})" if f["year"] else "")
        conf = "" if r["n"] >= 5 else " ¹"
        lines.append(
            f"| {i} | [[{fid}\\|{title}]]{conf} | {r['elo']:.0f} | {r['n']} | "
            f"{', '.join(f['genres'][:3])} |"
        )
    unrated = [f for f in films if peek(ratings, f)["n"] == 0]
    lines += ["", "¹ fewer than 5 votes — provisional.", ""]
    if unrated:
        lines += [f"**Not yet duelled ({len(unrated)}):** " + ", ".join(sorted(unrated)), ""]
    tmp = RANK_NOTE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, RANK_NOTE)


# ---------------------------------------------------------------- html

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0b0b0c;color:#e8e8e6;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:28px 16px 48px}
.h{font-size:13px;letter-spacing:.14em;text-transform:uppercase;opacity:.45;margin-bottom:6px}
.q{font-size:19px;font-weight:600;margin-bottom:22px;text-align:center}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:14px;width:100%;max-width:680px}
form{margin:0}
button{all:unset;cursor:pointer;display:block;width:100%;background:#151517;border:1px solid #26262a;
border-radius:14px;overflow:hidden;transition:border-color .15s,transform .1s}
button:hover{border-color:#5b5b66}
button:active{transform:scale(.985)}
.p{width:100%;aspect-ratio:2/3;object-fit:cover;display:block;background:#1c1c20}
.np{width:100%;aspect-ratio:2/3;display:flex;align-items:center;justify-content:center;
background:#1c1c20;font-size:13px;opacity:.4;padding:16px;text-align:center}
.m{padding:11px 13px}
.t{font-weight:600;font-size:15px;line-height:1.25}
.s{font-size:12.5px;opacity:.5;margin-top:3px}
.f{margin-top:26px;font-size:13px;opacity:.4;text-align:center;max-width:520px}
.f a{color:#8a8a94}
.big{font-size:15px;opacity:.75;margin-top:20px;text-align:center}
@media(max-width:520px){.pair{gap:10px}.q{font-size:17px}}
"""


def page(body: str, title: str = "Taste duel") -> bytes:
    return (
        "<!doctype html><html><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        "<meta name=robots content='noindex,nofollow'>"
        f"<title>{html.escape(title)}</title><style>{CSS}{LIST_CSS}</style></head><body>{body}</body></html>"
    ).encode()


def card(f: dict, tok: str, other: str, side: str) -> str:
    poster = (
        f"<img class=p src='{html.escape(f['poster'])}' alt=''>"
        if f["poster"]
        else f"<div class=np>{html.escape(f['title'])}</div>"
    )
    sub = " · ".join(x for x in [f["year"], f["director"]] if x)
    return (
        f"<form method=post action='{PREFIX}/vote'>"
        f"<input type=hidden name=t value='{html.escape(tok)}'>"
        f"<input type=hidden name=w value='{html.escape(f['id'])}'>"
        f"<input type=hidden name=l value='{html.escape(other)}'>"
        f"<button type=submit>{poster}<div class=m><div class=t>{html.escape(f['title'])}</div>"
        f"<div class=s>{html.escape(sub)}</div></div></button></form>"
    )


def render_pair(tok: str, films: dict, ratings: dict, done: int = 0) -> bytes:
    pair = pick_pair(films, ratings)
    if not pair:
        return page("<div class=q>Not enough watched films to duel yet.</div>")
    a, b = pair
    voted = sum(r["n"] for r in ratings.values()) // 2
    head = f"{done} this session · {voted} total" if done else f"{voted} votes so far"
    body = (
        f"<div class=h>{html.escape(head)}</div>"
        "<div class=q>Which one would you rather rewatch tonight?</div>"
        f"<div class=pair>{card(films[a], tok, b, 'a')}{card(films[b], tok, a, 'b')}</div>"
        "<div class=f>Tap either poster. Keeps going as long as you do — "
        "close the tab whenever you're bored.</div>"
    )
    return page(body)


LIST_CSS = """
.wrap{width:100%;max-width:1080px}
.tabs{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 16px}
.tab{padding:8px 15px;border-radius:999px;background:#151517;border:1px solid #26262a;
color:#b8b8c0;text-decoration:none;font-size:14px}
.tab.on{background:#e8e8e6;color:#0b0b0c;border-color:#e8e8e6;font-weight:600}
.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:18px;font-size:13px}
.bar a{color:#8a8a94;text-decoration:none;padding:5px 11px;border-radius:8px;border:1px solid #26262a}
.bar a.on{color:#e8e8e6;border-color:#5b5b66}
#q{flex:1;min-width:170px;background:#151517;border:1px solid #26262a;border-radius:9px;
padding:9px 13px;color:#e8e8e6;font-size:14px;outline:none}
#q:focus{border-color:#5b5b66}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:14px}
.it{background:#151517;border:1px solid #26262a;border-radius:12px;overflow:hidden;position:relative}
.it .p,.it .np{width:100%;aspect-ratio:2/3;object-fit:cover;display:block;background:#1c1c20}
.it .np{display:flex;align-items:center;justify-content:center;font-size:12px;opacity:.4;padding:10px;text-align:center}
.it .m{padding:9px 10px}
.it .t{font-size:13px;font-weight:600;line-height:1.3}
.it .s{font-size:11.5px;opacity:.45;margin-top:3px}
.rk{position:absolute;top:7px;left:7px;background:rgba(11,11,12,.86);border:1px solid #3a3a42;
border-radius:7px;padding:2px 7px;font-size:11.5px;font-weight:700}
.st{position:absolute;top:7px;right:7px;border-radius:7px;padding:2px 7px;font-size:10.5px;
background:rgba(11,11,12,.86);border:1px solid #3a3a42}
.st.w{color:#7fd18e;border-color:#2f5c39}
.stats{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:20px;font-size:13px;opacity:.55}
.cta{display:inline-block;background:#e8e8e6;color:#0b0b0c;text-decoration:none;font-weight:600;
padding:10px 20px;border-radius:10px;font-size:14px;margin-bottom:20px}
.empty{opacity:.4;padding:40px 0;text-align:center}

/* --- prose: /notes/* renders vault markdown, so it needs real reading typography --- */
.doc{max-width:70ch;font-size:15.5px;line-height:1.68;color:#c2c2ca}
.doc h1,.doc h2,.doc h3,.doc h4{color:#e8e8e6;line-height:1.35;margin:30px 0 10px}
.doc h1{font-size:23px}.doc h2{font-size:19px}.doc h3{font-size:16.5px}.doc h4{font-size:15px}
.doc h2,.doc h3{border-top:1px solid #1e1e22;padding-top:22px}
.doc p{margin:12px 0}
.doc ul{margin:12px 0;padding-left:20px}.doc li{margin:7px 0}
.doc blockquote{margin:14px 0;padding:2px 0 2px 15px;border-left:2px solid #33333b;color:#e8e8e6}
.doc code{background:#1c1c20;border:1px solid #26262a;border-radius:5px;padding:1px 5px;font-size:13px}
.doc a{color:#9aa8c8}
.doc .wl{color:#e8e8e6;border-bottom:1px dotted #4a4a55}
.doc table{border-collapse:collapse;margin:16px 0;width:100%;font-size:14px}
.doc td{border-bottom:1px solid #1e1e22;padding:7px 12px 7px 0;vertical-align:top}
/* Wide tables scroll inside themselves rather than pushing the page sideways on a phone */
.doc{overflow-x:auto}

.notes{max-width:70ch}
.til{background:#151517;border:1px solid #26262a;border-radius:12px;margin-bottom:10px}
.til summary{padding:15px 17px;cursor:pointer;font-size:15px;line-height:1.5;color:#e8e8e6;
list-style:none;display:flex;gap:11px;align-items:baseline}
.til summary::-webkit-details-marker{display:none}
.til summary::after{content:'▸';margin-left:auto;opacity:.35;font-size:13px}
.til[open] summary::after{content:'▾'}
.til[open] summary{border-bottom:1px solid #1e1e22}
.til .d{font-size:11.5px;opacity:.4;white-space:nowrap;font-variant-numeric:tabular-nums}
.til .body{padding:4px 17px 15px;font-size:14.5px;line-height:1.65;color:#b4b4bd}
.til .body h1,.til .body h2,.til .body h3,.til .body h4{font-size:12px;letter-spacing:.09em;
text-transform:uppercase;color:#6a6a74;margin:16px 0 6px}
.til .body blockquote{margin:8px 0 12px;padding-left:13px;border-left:2px solid #33333b;color:#e8e8e6}
.til .body code{background:#1c1c20;border:1px solid #26262a;border-radius:5px;padding:1px 5px;font-size:12.5px}
.til .body ul{padding-left:19px;margin:9px 0}.til .body li{margin:5px 0}
.til .body p{margin:9px 0}
"""


def list_page(kind: str, q_status: str = "") -> bytes:
    items = load_collection(kind)
    ratings = load_ratings()
    ranked = sorted(
        [(k, r) for k, r in ratings.items() if r.get("n", 0) > 0],
        key=lambda kv: -kv[1]["elo"],
    )
    rank_of = {k: i + 1 for i, (k, _) in enumerate(ranked)}

    rows = list(items.values())
    if q_status:
        rows = [r for r in rows if r["status"] == q_status]
    # ranked first (best to worst), then everything else alphabetically
    rows.sort(key=lambda r: (rank_of.get(r["id"], 10_000), r["title"].lower()))

    total = len(items)
    watched = sum(1 for r in items.values() if r["status"] == "watched")
    towatch = sum(1 for r in items.values() if r["status"] in ("to-watch", "to-read"))
    stubs = sum(1 for r in items.values() if not r["enriched"])

    tabs = "".join(
        f"<a class='tab{' on' if k == kind else ''}' href='/list/{k}'>{ico} {name}</a>"
        for k, (name, ico) in COLLECTIONS.items()
    ) + "<a class=tab href='/notes/taste-map'>🗺️ Notes</a>"
    sfilter = "".join(
        f"<a class='{'on' if q_status == s else ''}' href='/list/{kind}{'?status=' + s if s else ''}'>{lbl}</a>"
        for s, lbl in [("", "All"), ("watched", "Seen"), ("to-watch", "To watch"), ("to-read", "To read")]
    )

    cards = []
    for r in rows:
        poster = (
            f"<img class=p loading=lazy src='{html.escape(r['poster'])}' alt=''>"
            if r["poster"]
            else f"<div class=np>{html.escape(r['title'])}</div>"
        )
        rk = f"<div class=rk>#{rank_of[r['id']]}</div>" if r["id"] in rank_of else ""
        seen = r["status"] == "watched"
        st = f"<div class='st{' w' if seen else ''}'>{'seen' if seen else html.escape(r['status'][:8])}</div>"
        sub = " · ".join(x for x in [r["year"], (r["genres"] or [""])[0]] if x)
        cards.append(
            f"<div class=it data-s=\"{html.escape((r['title'] + ' ' + ' '.join(r['genres'])).lower())}\">"
            f"{poster}{rk}{st}<div class=m><div class=t>{html.escape(r['title'])}</div>"
            f"<div class=s>{html.escape(sub)}</div></div></div>"
        )

    body = f"""<div class=wrap>
<div class=h>Collections</div>
<div class=q style="text-align:left;margin-bottom:16px">{COLLECTIONS[kind][0]}</div>
<div class=tabs>{tabs}</div>
<div class=stats><span>{total} total</span><span>{watched} seen</span>
<span>{towatch} queued</span><span>{len(ranked)} ranked</span>
{f'<span>{stubs} missing metadata</span>' if stubs else ''}</div>
<div class=bar><input id=q placeholder="Filter by title or genre…" autocomplete=off>{sfilter}</div>
<a class=cta href="/d/?t={html.escape(make_token(1))}">Rank these →</a>
<div class=grid id=g>{''.join(cards) or "<div class=empty>Nothing here yet.</div>"}</div>
</div>
<script>
const q=document.getElementById('q'),g=document.getElementById('g');
q.addEventListener('input',()=>{{const v=q.value.toLowerCase().trim();
for(const el of g.children){{el.style.display=!v||(el.dataset.s||'').includes(v)?'':'none';}}}});
</script>"""
    return page(body, f"{COLLECTIONS[kind][0]} — watchlist")


# --------------------------------------------------------------------------- /notes
# The automations (cartographer, duel ranking, weekly TIL) all write markdown into the
# vault, which until now was only readable in Obsidian — i.e. only at a desk. These are
# the surfaces worth having on a phone, so they get a read-only render here.
#
# Whitelist of explicit paths, never a user-supplied one: this process can read the whole
# vault including _Private, so accepting a path from the query string would be a traversal
# hole behind nothing but Cloudflare Access.
NOTE_VIEWS = {
    "taste-map": ("Taste map", "🗺️", "40 Synthesis/taste-map.md"),
    "ranking": ("Ranking", "🏆", "50 Collections/Movies/🏆 Taste Ranking.md"),
    "cinema": ("Cinema MOC", "🎞️", "_Meta/MOC/Cinema-and-Arts.md"),
}
TIL_DIR = "50 Collections/TIL"


def _md_inline(s: str) -> str:
    """Escape first, then re-introduce the few inline forms. Order matters: escaping after
    would mangle the tags we just emitted, and escaping never lets raw HTML through."""
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    # No space just inside the asterisks: without that, "2 * 3 = 6 and 4 * 5" renders as
    # italics swallowing the middle of the line.
    s = re.sub(r"(?<![*\w])\*(\S(?:[^*\n]*\S)?)\*(?!\w)", r"<i>\1</i>", s)
    # [[Note|Display]] and [[Note]] — rendered as plain text, not links: these point at
    # vault paths this server does not route, and a dead link is worse than none.
    s = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"<span class=wl>\2</span>", s)
    s = re.sub(r"\[\[([^\]]+)\]\]", r"<span class=wl>\1</span>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
               r"<a href='\2' rel='noopener noreferrer nofollow'>\1</a>", s)
    return s


def md_to_html(text: str) -> str:
    out, in_ul, in_tbl = [], False, False

    def close():
        nonlocal in_ul, in_tbl
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if in_tbl:
            out.append("</table>")
            in_tbl = False

    for raw in text.splitlines():
        line = raw.rstrip()
        st = line.strip()
        if not st or st == "---":
            close()
            continue
        if st.startswith("|"):
            cells = [c.strip() for c in st.strip("|").split("|")]
            if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                continue                      # the |---|---| separator row
            if not in_tbl:
                close()
                out.append("<table>")
                in_tbl = True
            out.append("<tr>" + "".join(f"<td>{_md_inline(c)}</td>" for c in cells) + "</tr>")
            continue
        if re.match(r"^\s*[-*]\s+", st):
            if not in_ul:
                close()
                out.append("<ul>")
                in_ul = True
            item = _md_inline(re.sub(r"^\s*[-*]\s+", "", st))
            out.append(f"<li>{item}</li>")
            continue
        close()
        m = re.match(r"^(#{1,6})\s+(.*)$", st)
        if m:
            lvl = min(len(m.group(1)), 4)
            out.append(f"<h{lvl}>{_md_inline(m.group(2))}</h{lvl}>")
        elif st.startswith("> "):
            out.append(f"<blockquote>{_md_inline(st[2:])}</blockquote>")
        else:
            out.append(f"<p>{_md_inline(st)}</p>")
    close()
    return "".join(out)


def read_note(rel: str) -> tuple:
    """(frontmatter dict, body) for a vault-relative path. Missing file -> ({}, '')."""
    p = os.path.join(PKM, rel)
    try:
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return {}, ""
    fm = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end > 0:
            for m in re.finditer(r"^([a-z_]+):[^\S\n]*(.*)$", text[3:end], re.M):
                v = m.group(2).strip()
                fm[m.group(1)] = v[1:-1] if len(v) > 1 and v[0] == v[-1] == '"' else v
            text = text[end + 4:]
    return fm, text.strip()


def til_notes() -> list:
    """Newest first. Same exclusions as the TIL job: TIL.md is a scratch link dump and
    *-daily.md are read-later queues, neither is a lesson."""
    d = os.path.join(PKM, TIL_DIR)
    out = []
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for f in sorted(names, reverse=True):
        if not f.endswith(".md") or not re.match(r"^\d{4}-\d{2}-\d{2}-", f) or f.endswith("-daily.md"):
            continue
        fm, body = read_note(f"{TIL_DIR}/{f}")
        out.append({"slug": f[:-3], "date": fm.get("date", f[:10]),
                    "topic": fm.get("topic", f[11:-3]),
                    "question": fm.get("question", ""), "body": body})
    return out


def notes_nav(active: str) -> str:
    tabs = "".join(
        f"<a class='tab{' on' if k == active else ''}' href='/notes/{k}'>{ico} {name}</a>"
        for k, (name, ico, _) in NOTE_VIEWS.items()
    )
    tabs += f"<a class='tab{' on' if active == 'til' else ''}' href='/notes/til'>💡 TIL</a>"
    tabs += "<a class=tab href='/list/movies'>🎬 Collections</a>"
    return f"<div class=tabs>{tabs}</div>"


def til_page() -> bytes:
    notes = til_notes()
    items = []
    for n in notes:
        q = html.escape(n["question"] or n["topic"])
        # <details>: the answer stays collapsed so the page is a recall surface, matching
        # the weekly email. Reading the answer has to be a deliberate act or the testing
        # effect is lost.
        items.append(
            f"<details class=til><summary><span class=d>{html.escape(n['date'])}</span>{q}</summary>"
            f"<div class=body>{md_to_html(n['body'])}</div></details>"
        )
    body = (f"<div class=wrap><div class=h>Notes</div>"
            f"<div class=q style='text-align:left;margin-bottom:16px'>Today I learned</div>"
            f"{notes_nav('til')}"
            f"<div class=stats><span>{len(notes)} notes</span>"
            f"<span>tap to reveal the answer</span></div>"
            f"<div class=notes>{''.join(items) or '<div class=empty>No TILs yet.</div>'}</div></div>")
    return page(body, "TIL")


def note_page(key: str) -> bytes:
    name, _, rel = NOTE_VIEWS[key]
    fm, text = read_note(rel)
    if not text:
        inner = "<div class=empty>Not generated yet.</div>"
    else:
        inner = f"<div class=doc>{md_to_html(text)}</div>"
    meta = f"<div class=stats><span>{html.escape(rel)}</span>" + (
        f"<span>updated {html.escape(fm['date'])}</span>" if fm.get("date") else "") + "</div>"
    body = (f"<div class=wrap><div class=h>Notes</div>"
            f"<div class=q style='text-align:left;margin-bottom:16px'>{html.escape(name)}</div>"
            f"{notes_nav(key)}{meta}{inner}</div>")
    return page(body, name)


class Handler(BaseHTTPRequestHandler):
    server_version = "duel"

    def log_message(self, *a):  # quiet; systemd journal gets the errors that matter
        pass

    def _send(self, code: int, body: bytes, ctype: str = "text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = u.path.rstrip("/") or "/"
        if path in (f"{PREFIX}/health", "/health"):
            return self._send(200, b"ok", "text/plain")

        # /list/* is the browsable collection view. No token: it is only reachable on
        # watch.psidex.com, which sits behind Cloudflare Access (login-gated). The
        # token-gated /d/ path is the one exposed on the public psidex.com host.
        if path == "/list" or path.startswith("/list/"):
            kind = path[6:].strip("/") or "movies"
            if kind not in COLLECTIONS:
                return self._send(404, page("<div class=q>No such collection</div>"))
            return self._send(200, list_page(kind, (q.get("status") or [""])[0]))

        # /notes/* renders what the automations write into the vault. Same trust model as
        # /list: no token, Cloudflare Access is the gate. The key is looked up in a fixed
        # dict — never joined onto a user-supplied path.
        if path == "/notes" or path.startswith("/notes/"):
            key = path[7:].strip("/") or "taste-map"
            if key == "til":
                return self._send(200, til_page())
            if key not in NOTE_VIEWS:
                return self._send(404, page("<div class=q>No such note</div>"))
            return self._send(200, note_page(key))

        if path not in (PREFIX, "/"):
            return self._send(404, page("<div class=q>Not found</div>"))
        tok = (q.get("t") or [""])[0]
        if not token_ok(tok):
            return self._send(
                403, page("<div class=q>This duel link has expired.</div>"
                          "<div class=f>A fresh one arrives with the next weekly email.</div>")
            )
        films, ratings = load_films(), load_ratings()
        self._send(200, render_pair(tok, films, ratings))

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.rstrip("/") != f"{PREFIX}/vote":
            return self._send(404, page("<div class=q>Not found</div>"))
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > 4096:
            return self._send(400, page("<div class=q>Bad request</div>"))
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        tok = (form.get("t") or [""])[0]
        win = (form.get("w") or [""])[0]
        lose = (form.get("l") or [""])[0]
        if not token_ok(tok):
            return self._send(403, page("<div class=q>This duel link has expired.</div>"))
        films, ratings = load_films(), load_ratings()
        if win not in films or lose not in films or win == lose:
            return self._send(400, page("<div class=q>Unknown film.</div>"))
        apply_vote(ratings, win, lose)
        save_ratings(ratings)
        with open(VOTES, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"t": int(time.time()), "w": win, "l": lose}) + "\n")
        try:
            write_ranking(films, ratings)
        except OSError:
            pass  # vote is recorded; the note is a derived view, never block on it
        done = sum(1 for _ in open(VOTES, encoding="utf-8")) if os.path.exists(VOTES) else 0
        self._send(200, render_pair(tok, films, ratings, done=done))


def demo():
    """Self-check: token, Elo direction/conservation, pair sanity, frontmatter parsing."""
    t = make_token()
    assert token_ok(t), "fresh token must validate"
    assert not token_ok("999.deadbeef"), "forged mac must fail"
    assert not token_ok(f"{int(time.time())-1}.{sign(str(int(time.time())-1))}"), "expired must fail"
    assert not token_ok(""), "empty must fail"

    r = {}
    apply_vote(r, "A", "B")
    assert r["A"]["elo"] > START > r["B"]["elo"], "winner up, loser down"
    assert abs((r["A"]["elo"] + r["B"]["elo"]) - 2 * START) < 1e-9, "equal K conserves total"
    assert r["A"]["n"] == r["B"]["n"] == 1

    # an upset must move more than an expected win
    r2 = {"S": {"elo": 1900.0, "n": 9}, "W": {"elo": 1100.0, "n": 9}}
    before = r2["W"]["elo"]
    apply_vote(r2, "W", "S")
    upset = r2["W"]["elo"] - before
    r3 = {"S": {"elo": 1900.0, "n": 9}, "W": {"elo": 1100.0, "n": 9}}
    b3 = r3["S"]["elo"]
    apply_vote(r3, "S", "W")
    assert upset > (r3["S"]["elo"] - b3), "upset must swing harder than the expected result"

    head = _yaml_head('---\ntitle: "X"\nstatus: watched\ngenres:\n  - Drama\n  - Crime\n---\nbody')
    assert _field(head, "title") == "X"
    assert _list_field(head, "genres") == ["Drama", "Crime"], "block sequence"
    assert _list_field('genres: [A, B]', "genres") == ["A", "B"], "inline list"
    assert _list_field("", "genres") == []

    fake = {k: {"id": k, "title": k, "year": "", "director": "", "genres": [], "poster": "", "path": ""}
            for k in "abcdef"}
    for _ in range(50):
        a, b = pick_pair(fake, {}, seen=set())
        assert a != b and a in fake and b in fake

    # regression: pick_pair must NOT create rating entries just by looking. This bug
    # wrote all 31 films into ratings.json at 1500/0 on the first real vote and filled
    # the ranking note with unvoted rows.
    rr = {}
    for _ in range(30):
        pick_pair(fake, rr, seen=set())
    assert rr == {}, "pick_pair must not mutate ratings"

    # coverage: every film duelled once before any film goes twice
    counts = {k: 0 for k in fake}
    rr, seen = {}, set()
    for _ in range(3):  # 3 pairs = 6 slots = one full pass over 6 films
        a, b = pick_pair(fake, rr, seen=seen)
        seen.add(frozenset((a, b)))
        apply_vote(rr, a, b)
        counts[a] += 1
        counts[b] += 1
    assert set(counts.values()) == {1}, f"coverage broken: {counts}"

    # no-repeat: a judged pair must not be re-offered while fresh pairs exist
    seen2 = {frozenset(("a", "b"))}
    for _ in range(40):
        assert frozenset(pick_pair(fake, {}, seen=seen2)) not in seen2, "re-offered a judged pair"

    # informativeness: at equal vote counts, near-Elo opponents must dominate
    ratings_i = {k: {"elo": e, "n": 5} for k, e in
                 zip("abcdef", [1500, 1505, 1495, 1900, 1100, 1850])}
    picks = [set(pick_pair(fake, ratings_i, seen=set())) for _ in range(200)]
    close = sum(1 for p in picks if p <= {"a", "b", "c"})
    assert close > 60, f"close-Elo pairs should dominate, got {close}/200"

    # --- markdown rendering for /notes -------------------------------------------------
    # Escaping is the point: this renders vault files, some written by a model, straight
    # into a page. Anything that looks like markup must come out inert.
    h = md_to_html("# T\n\n## S\n\n> quote `x` **b**\n\n- one\n- two\n\n"
                   "| a | b |\n|---|---|\n| 1 | 2 |\n\n[[Note|Disp]] and [[Bare]]\n"
                   "<script>alert(1)</script>\n[link](https://x.test)\n")
    assert "<h1>T</h1>" in h and "<h2>S</h2>" in h, h
    assert "<blockquote>" in h and "<code>x</code>" in h and "<b>b</b>" in h
    assert h.count("<li>") == 2 and "<table>" in h
    assert "<td>1</td><td>2</td>" in h, h
    assert "|---|" not in h, "table separator row leaked"
    assert "<span class=wl>Disp</span>" in h and "<span class=wl>Bare</span>" in h
    assert "<script>" not in h and "&lt;script&gt;" in h, "raw HTML escaped into output"
    assert "href='https://x.test'" in h and "noopener" in h
    # a bare * in prose must not become italics and eat the rest of the line
    assert "<i>" not in md_to_html("2 * 3 = 6 and 4 * 5")

    # /notes routing whitelist: keys map to fixed vault paths, never to user input
    for k, (_, _, rel) in NOTE_VIEWS.items():
        assert not rel.startswith("/") and ".." not in rel, rel
        assert "_Private" not in rel, "note view must never point into _Private"

    # a missing note renders an empty state instead of raising
    assert read_note("40 Synthesis/does-not-exist.md") == ({}, "")

    print("duel.py self-check OK")


if __name__ == "__main__":
    import sys

    if "--demo" in sys.argv:
        demo()
    elif "--token" in sys.argv:
        print(make_token())
    elif "--rank" in sys.argv:
        write_ranking(load_films(), load_ratings())
        print(f"wrote {RANK_NOTE}")
    else:
        srv = ThreadingHTTPServer((BIND, PORT), Handler)
        print(f"duel serving on {BIND}:{PORT}{PREFIX}", flush=True)
        srv.serve_forever()
