#!/usr/bin/env python3
"""enrich.py — fill in stub collection notes from OMDb.

A "stub" is a note carrying only `status:` and a heading: no year, genres, poster or
synopsis. 109 of the 278 collection notes were stubs (Anime 41/43, TV 31/42, Movies 37/161),
which had two consequences: the /list/{tv,anime} pages rendered as bare title lists, and
cartographer.sh was reasoning about taste while blind to those entries.

Writes the SAME schema the existing enriched notes use — frontmatter field order, the
poster embed, the `# Title (Year)` heading, the blockquote synopsis and the detail table —
because the vault's Dataview queries and duel.py both read those field names. Deriving the
schema from a real note rather than inventing one is the whole reason this matches.

Safety properties, in order of how much they'd cost to get wrong:
  - Only ever touches files it identifies as stubs. An enriched note is skipped, so a
    re-run cannot clobber data, and a partial run is simply resumable.
  - Preserves `status:`, `date_added:` and any `## My Notes` body the user wrote. Those are
    the only human-authored bytes in these files and they are not reconstructible.
  - Writes atomically (temp file + os.replace) — a killed process leaves the original
    intact rather than a half-written note.
  - Never invents data. A miss leaves the stub exactly as it was and is reported, because
    a stub is honest and a hallucinated cast list is not.

OMDb's free tier is 1000 requests/day, so this stays well under with 109 notes and a
courtesy delay. Run `python3 enrich.py --demo` for the self-check.
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

PKM = os.environ.get("PKM", "/opt/cryptex/data/pkm")
COLLECTIONS = os.path.join(PKM, "50 Collections")

# tag + OMDb type per collection. OMDb's `type` filter matters: searching "Akira" without
# type=movie can return a series, and writing series data into a film note is worse than
# leaving the stub.
KINDS = {
    "Movies":   ("movie", "movie"),
    "TV Shows": ("tv-show", "series"),
    "Anime":    ("anime", None),     # anime spans films and series — let OMDb decide
}

# Files that are indexes/queues, not titles. Enriching these would be nonsense.
SKIP_PREFIXES = ("🏆", "📋", "📚", "to-watch-bulk", "to-read-bulk")

# Filenames that OMDb cannot resolve, mapped to an imdbID (never a corrected title string).
# Two distinct failure modes are collapsed here, both found by running the real batch:
#   - typos and parentheticals the bulk import left behind ("Buffy a vampire",
#     "TRUE DETECTIVES (season 1)");
#   - titles where OMDb's exact match is actively WRONG rather than absent. Searching
#     "Once Upon a Time in Hollywood" returns an obscure 2016 film (tt4010884) because
#     Tarantino's real title carries an ellipsis — so the lookup succeeds and writes the
#     wrong movie. That one is the reason this map pins IDs instead of titles: a corrected
#     title is still a guess routed through the same fuzzy endpoint, an ID is not.
ALIASES = {
    "AVATAR (animation)":        "tt0417299",   # Avatar: The Last Airbender (2005)
    "Buffy a vampire":           "tt0118276",   # Buffy the Vampire Slayer (1997)
    "Pataal Lok":                "tt9680440",   # Paatal Lok (2020), India — NOT tt9680508,
                                                # which is "Dog's Most Wanted". Verified by
                                                # querying t=Paatal+Lok&type=series and
                                                # checking Country, not by eyeballing an ID.
    "TRUE DETECTIVES (season 1)": "tt2356777",  # True Detective (2014)
    "One upon a time in Hollywood": "tt7131622",  # Once Upon a Time... in Hollywood (2019)
}
# "into the forest of fireflies" (Hotarubi no Mori e, 2011) is absent from OMDb entirely —
# deliberately left as a stub rather than aliased to a near-miss.


def key() -> str:
    """The OMDb key, from the env or from the vault script that already holds it.

    Deliberately NOT copied into a new file: `_Meta/Scripts/batchMovieImport.js` is the
    existing source of truth (private repo), and a second copy is a second thing to rotate.
    """
    k = os.environ.get("OMDB_API_KEY")
    if k:
        return k.strip()
    js = os.path.join(PKM, "_Meta/Scripts/batchMovieImport.js")
    with open(js, encoding="utf-8") as fh:
        m = re.search(r'API_KEY\s*=\s*"([^"]+)"', fh.read())
    if not m:
        raise SystemExit("no OMDB_API_KEY in env and none found in batchMovieImport.js")
    return m.group(1)


def is_stub(text: str) -> bool:
    """A stub has no `title:` field. That single check is what the whole run keys off, so
    it is deliberately the same test used to count them, not a looser heuristic."""
    head = text[3:text.find("\n---", 3)] if text.startswith("---") else ""
    return not re.search(r"^title:", head, re.M)


def front_field(text: str, name: str) -> str:
    head = text[3:text.find("\n---", 3)] if text.startswith("---") else ""
    m = re.search(rf"^{name}:[^\S\n]*(.*)$", head, re.M)
    return m.group(1).strip().strip('"') if m else ""


def user_body(text: str) -> str:
    """Whatever the user wrote under `## My Notes`. Almost always empty — 1 of 161 movie
    notes has content — but that one is exactly the thing that must not be lost."""
    m = re.search(r"^## My Notes\s*\n(.*)$", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def fetch(title: str, api_key: str, kind: str | None, timeout: int = 20) -> dict | None:
    """OMDb lookup: exact title first, then search-and-take-best. Returns None on a miss.

    The two-step matters for this vault: filenames like 'AUTOMATA' and 'Pushpak' miss on
    `t=` (OMDb's exact match is picky about case-insensitive-but-complete titles) yet hit
    on `s=`. Trying only one drops roughly a fifth of the list.
    """
    base = "https://www.omdbapi.com/?apikey=" + urllib.parse.quote(api_key)
    typ = f"&type={kind}" if kind else ""

    def get(url):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception:
            return None

    # An alias short-circuits both lookups: it exists precisely because the fuzzy path
    # either misses or returns the wrong title.
    if title in ALIASES:
        d = get(f"{base}&i={ALIASES[title]}&plot=short")
        return d if d and d.get("Response") == "True" else None

    d = get(f"{base}&t={urllib.parse.quote(title)}{typ}&plot=short")
    if d and d.get("Response") == "True":
        return d
    s = get(f"{base}&s={urllib.parse.quote(title)}{typ}")
    if not s or s.get("Response") != "True" or not s.get("Search"):
        return None
    # Prefer an exact case-insensitive title match among the results; else the first.
    want = title.strip().lower()
    best = next((x for x in s["Search"] if x.get("Title", "").lower() == want), s["Search"][0])
    d = get(f"{base}&i={urllib.parse.quote(best['imdbID'])}&plot=short")
    return d if d and d.get("Response") == "True" else None


def yaml_list(csv: str) -> str:
    items = [x.strip() for x in (csv or "").split(",") if x.strip() and x.strip() != "N/A"]
    inner = ", ".join('"' + i.replace('"', "") + '"' for i in items)
    return "[" + inner + "]"


def q(s: str) -> str:
    """Double-quoted YAML scalar. Escapes quotes and backslashes; strips newlines, which
    OMDb plots occasionally contain and which would otherwise break the frontmatter."""
    s = (s or "").replace("\\", "\\\\").replace('"', '\\"')
    return '"' + " ".join(s.split()) + '"'


def rt_value(d: dict) -> str:
    for r in d.get("Ratings", []) or []:
        if r.get("Source") == "Rotten Tomatoes":
            return r.get("Value", "N/A")
    return "N/A"


def build(d: dict, tag: str, status: str, date_added: str, notes: str) -> str:
    """Render the note. Field order mirrors the existing enriched notes exactly."""
    title = d.get("Title", "")
    year = (d.get("Year") or "").replace("–", "–")
    poster = d.get("Poster", "") or ""
    if poster == "N/A":
        poster = ""
    runtime = re.sub(r"[^0-9]", "", d.get("Runtime", "") or "")
    imdb = d.get("imdbRating", "N/A")
    trailer = ("https://www.youtube.com/results?search_query="
               + urllib.parse.quote(f"{title} trailer"))
    # year is unquoted when it's a bare 4-digit number, matching the movie notes, but
    # quoted for a TV range like 2018–2020 which is not a valid YAML number.
    year_yaml = year if re.fullmatch(r"\d{4}", year) else q(year)

    fm = [
        "---",
        f"title: {q(title)}",
        f"year: {year_yaml}",
        f"director: {q(d.get('Director', 'N/A'))}",
        f"writer: {q(d.get('Writer', 'N/A'))}",
        f"genres: {yaml_list(d.get('Genre', ''))}",
        f"cast: {yaml_list(d.get('Actors', ''))}",
        f"language: {q(d.get('Language', 'N/A'))}",
        f"country: {q(d.get('Country', 'N/A'))}",
        f"rating_imdb: {imdb if re.fullmatch(r'[0-9.]+', imdb or '') else q(imdb or 'N/A')}",
        f"rating_rt: {q(rt_value(d))}",
        f"status: {status}",
        f"poster_url: {q(poster)}",
        f"imdb_id: {q(d.get('imdbID', ''))}",
        f"trailer_link: {q(trailer)}",
        f"overview: {q(d.get('Plot', ''))}",
        f"runtime_min: {runtime or 0}",
        f"awards: {q(d.get('Awards', 'N/A'))}",
        f"date_added: {q(date_added)}",
        f"tags: [{tag}]",
        "---",
        "",
    ]
    body = []
    if poster:
        body.append(f"![poster]({poster})")
        body.append("")
    body.append(f"# {title}" + (f" ({year})" if year else ""))
    body.append("")
    plot = d.get("Plot", "")
    if plot and plot != "N/A":
        body += [f"> {plot}", ""]
    body += [
        "| Field | Value |",
        "|---|---|",
        f"| Director | {d.get('Director', 'N/A')} |",
        f"| Cast | {d.get('Actors', 'N/A')} |",
        f"| Genres | {d.get('Genre', 'N/A')} |",
        f"| Runtime | {d.get('Runtime', 'N/A')} |",
        f"| IMDB | ⭐ {imdb} |",
        f"| Rotten Tomatoes | 🍅 {rt_value(d)} |",
        f"| Trailer | [Watch Trailer]({trailer}) |",
    ]
    # The user's own words are the only irreplaceable bytes here — carried through verbatim.
    if notes:
        body += ["", "## My Notes", "", notes]
    return "\n".join(fm + body) + "\n"


def write_atomic(path: str, text: str) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def stubs(collection: str) -> list:
    d = os.path.join(COLLECTIONS, collection)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md") or f.startswith(SKIP_PREFIXES):
            continue
        p = os.path.join(d, f)
        try:
            t = open(p, encoding="utf-8").read()
        except OSError:
            continue
        if is_stub(t):
            out.append((p, f[:-3], t))
    return out


def run(collection: str, limit: int = 0, delay: float = 0.35, dry: bool = False):
    tag, kind = KINDS[collection]
    api_key = key()
    todo = stubs(collection)
    if limit:
        todo = todo[:limit]
    done, missed = [], []
    for path, name, text in todo:
        d = fetch(name, api_key, kind)
        if not d:
            missed.append(name)
            continue
        # Stubs predate the date_added convention, so fall back to the file's own mtime —
        # that IS when the title entered the vault. An empty string would render as
        # `date_added: ""`, which Dataview sorts as before-everything.
        added = front_field(text, "date_added")
        if not added:
            added = time.strftime("%Y-%m-%d", time.gmtime(os.path.getmtime(path)))
        note = build(d, tag,
                     front_field(text, "status") or "to-watch",
                     added,
                     user_body(text))
        if not dry:
            write_atomic(path, note)
        done.append((name, d.get("Title", ""), d.get("Year", "")))
        time.sleep(delay)
    return done, missed


def demo():
    import tempfile
    sample = {
        "Title": "Akira", "Year": "1988", "Runtime": "124 min",
        "Genre": "Animation, Action, Drama", "Director": "Katsuhiro Ôtomo",
        "Writer": 'He said "hi", again', "Actors": "Mitsuo Iwata, N/A",
        "Language": "Japanese", "Country": "Japan", "imdbRating": "8.0",
        "Ratings": [{"Source": "Rotten Tomatoes", "Value": "90%"}],
        "Poster": "https://example.com/p.jpg", "imdbID": "tt0094625",
        "Plot": "A secret military project\nendangers Neo-Tokyo.", "Awards": "N/A",
    }
    out = build(sample, "anime", "to-watch", "2026-03-16", "I loved the bike.")
    assert out.startswith("---\ntitle: \"Akira\"\nyear: 1988\n"), out[:80]
    # a bare year stays numeric; a TV range must be quoted or the YAML is invalid
    tv = build(dict(sample, Year="2018–2020"), "tv-show", "watched", "", "")
    assert 'year: "2018–2020"' in tv, tv[:120]
    # quotes inside a value are escaped, not left to break the frontmatter
    assert 'writer: "He said \\"hi\\", again"' in out, out
    # a plot containing a newline must not break out of the scalar
    assert "overview: \"A secret military project endangers Neo-Tokyo.\"" in out
    # N/A is dropped from list fields rather than stored as a fake cast member
    assert 'cast: ["Mitsuo Iwata"]' in out, out
    assert 'genres: ["Animation", "Action", "Drama"]' in out
    assert "runtime_min: 124" in out
    assert "| IMDB | ⭐ 8.0 |" in out and "🍅 90%" in out
    # the user's own words survive; status and date_added are carried, not regenerated
    assert out.rstrip().endswith("I loved the bike."), out[-60:]
    assert "status: to-watch" in out and 'date_added: "2026-03-16"' in out
    assert "status: watched" in tv
    # missing poster must not emit a broken embed
    nop = build(dict(sample, Poster="N/A"), "movie", "to-watch", "", "")
    assert "![poster]" not in nop and 'poster_url: ""' in nop

    # stub detection: the enriched output must no longer look like a stub, or a second
    # pass would rewrite it and the run would not be idempotent
    assert is_stub("---\nstatus: to-watch\ntags: [movie]\n---\n\n# X\n")
    assert not is_stub(out)
    # a note with a My Notes section but no title is still a stub (worth enriching)
    assert is_stub("---\nstatus: watched\n---\n\n# X\n\n## My Notes\n\nGood.\n")

    # Every alias must be a real imdbID, not a corrected title — a title string would be
    # re-fuzzed by the same endpoint that got it wrong in the first place.
    assert all(re.fullmatch(r"tt\d{7,}", v) for v in ALIASES.values()), ALIASES

    d = tempfile.mkdtemp()
    p = os.path.join(d, "x.md")
    write_atomic(p, "a")
    write_atomic(p, "b")
    assert open(p).read() == "b" and not os.path.exists(p + ".tmp")
    print("enrich: all checks passed")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0] == "--demo":
        demo()
        sys.exit(0)
    coll = a[0]
    if coll not in KINDS:
        raise SystemExit(f"unknown collection {coll!r}; one of {list(KINDS)}")
    lim = int(a[1]) if len(a) > 1 else 0
    dry = "--dry" in a
    ok, miss = run(coll, lim, dry=dry)
    print(f"{coll}: {len(ok)} enriched, {len(miss)} not found")
    for n, t, y in ok:
        print(f"  + {n}" + (f"  ->  {t} ({y})" if t.lower() != n.lower() else f"  ({y})"))
    for m in miss:
        print(f"  ? {m}")
