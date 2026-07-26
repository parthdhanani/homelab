#!/usr/bin/env python3
"""fixlinks.py — repair Obsidian wikilinks in a generated MOC against real filenames.

The model is told to use exact filenames and reliably doesn't: it appends the year
("[[Oldboy (2003)]]" for a file called "Oldboy.md"), normalises ALL-CAPS titles, or drops
a subtitle. Re-prompting doesn't fix this class of error — resolving it mechanically does,
and unlike a re-prompt it's verifiable.

Rewrites a resolvable link to [[Real File Name|Display Text]] so the MOC still reads with
the year visible while the link actually opens. Unresolvable links are left ALONE, not
deleted — a visible broken link is a signal that the title was hallucinated; silently
removing it hides that.

Run `python3 fixlinks.py --demo` for the self-check.
"""
import os
import re
import sys


def norm(s: str) -> str:
    """Tier-1 key: lowercase, trailing parentheticals dropped, punctuation flattened.
    'A.I. Artificial Intelligence' and 'AI Artificial Intelligence (2001)' collapse to one.
    The loop matters — the model emits '(2019) (CLIP) (2019)' and one strip isn't enough."""
    s = s.strip()
    while True:
        t = re.sub(r"\s*\([^()]*\)\s*$", "", s).strip()
        if t == s or not t:
            break
        s = t
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def loose(s: str) -> str:
    """Tier-2 key: also drops a leading article and everything after a colon/dash subtitle.
    'Nameless Gangster: Rules of the Time' -> 'namelessgangster', 'The Shape of Water' ->
    'shapeofwater'. Deliberately lossy, so it is only consulted after tier 1 misses."""
    s = re.sub(r"\s*\([^()]*\)\s*$", "", s.strip())
    s = re.sub(r"^(the|a|an)\s+", "", s, flags=re.I)
    s = re.split(r"\s*[:–—-]\s+", s)[0]
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def index(root: str):
    """(tier1, tier2, collisions). First writer wins so results are stable across runs.
    A tier-2 key that maps to two different files is DROPPED, not guessed — a wrong link
    is worse than a visible broken one."""
    exact, out, l2, dupes, collisions = {}, {}, {}, set(), []
    for dirpath, dirs, files in os.walk(root):
        # _Private is off-limits by standing rule; .obsidian/.trash are noise. Pruned in
        # place so os.walk never descends into them.
        dirs[:] = [d for d in dirs if d not in ("_Private", ".obsidian", ".trash", ".git")]
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            stem = f[:-3]
            exact[stem] = True
            k = norm(stem)
            if not k:
                continue
            if k in out and out[k] != stem:
                collisions.append((out[k], stem))
            else:
                out[k] = stem
            # Every file gets a tier-2 key, including ones where it equals the tier-1 key:
            # the LINK may carry a subtitle the FILENAME lacks ("Nameless Gangster: Rules
            # of the Time" -> "Nameless Gangster.md"), so the loose key must exist on the
            # file side even when the file itself has nothing to strip.
            lk = loose(stem)
            if lk:
                if lk in l2 and l2[lk] != stem:
                    dupes.add(lk)
                else:
                    l2[lk] = stem
    for k in dupes:
        l2.pop(k, None)
    return out, l2, exact, collisions


def fix(text: str, idx: dict, l2: dict = None, exact: dict = None):
    l2 = l2 or {}
    exact = exact if exact is not None else {v: True for v in idx.values()}
    fixed = broken = already = 0
    unresolved = []

    def repl(m):
        nonlocal fixed, broken, already
        target, _, alias = m.group(1).partition("|")
        target = target.strip()
        # Obsidian accepts a path-style link ("Collections/Movies/to-watch-bulk"); the
        # basename is what identifies the note. Checking only the full string reported
        # these as broken when they resolve fine in the app.
        if target in exact or target.rsplit("/", 1)[-1] in exact:
            already += 1
            return m.group(0)
        real = idx.get(norm(target)) or l2.get(loose(target))
        if not real:
            broken += 1
            unresolved.append(target)
            return m.group(0)               # leave visible, don't hide a hallucination
        fixed += 1
        display = alias.strip() or target
        return f"[[{real}|{display}]]" if display != real else f"[[{real}]]"

    out = re.sub(r"\[\[([^\]]+)\]\]", repl, text)
    return out, {"fixed": fixed, "already": already, "broken": broken,
                 "unresolved": unresolved}


def demo():
    import tempfile
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "Movies"))
    names = ["A Bittersweet Life", "A.I. Artificial Intelligence", "ANOTHER EARTH", "Oldboy",
             "Nameless Gangster", "Shape of Water", "Matrix (1999)", "Serenity (2019)",
             "The dark knight (2008)", "Ambush", "Ambush: Second Wave"]
    for n in names:
        open(os.path.join(d, "Movies", n + ".md"), "w").write("x")

    idx, l2, exact, coll = index(d)
    assert coll == [], coll
    assert idx[norm("Oldboy (2003)")] == "Oldboy"
    assert idx[norm("AI Artificial Intelligence")] == "A.I. Artificial Intelligence"
    assert idx[norm("Another Earth")] == "ANOTHER EARTH"
    # nested/repeated parentheticals must all strip — the model emits "(2019) (CLIP) (2019)"
    assert norm("Serenity (2019) (CLIP) (2019)") == norm("Serenity")
    # a filename that CONTAINS the year still resolves when the link repeats it
    assert idx[norm("Matrix (1999) ()")] == "Matrix (1999)"
    assert idx[norm("The dark knight (2008) ()")] == "The dark knight (2008)"
    # tier 2: subtitle and leading article
    assert l2[loose("Nameless Gangster: Rules of the Time (2012)")] == "Nameless Gangster"
    assert l2[loose("The Shape of Water (2017)")] == "Shape of Water"
    # tier 2 ambiguity is dropped, never guessed: Ambush vs Ambush: Second Wave
    assert loose("Ambush: Second Wave") not in l2, l2

    src = ("[[A Bittersweet Life (2005)]] and [[Oldboy]] and [[Another Earth (2011)]] "
           "and [[Totally Made Up Film (1999)]] and [[Oldboy|the Park one]] "
           "and [[Nameless Gangster: Rules of the Time (2012)]] "
           "and [[Serenity (2019) (CLIP) (2019)]] "
           "and [[Collections/Movies/Oldboy|path style]]")
    out, st = fix(src, idx, l2, exact)
    assert "[[A Bittersweet Life|A Bittersweet Life (2005)]]" in out, out
    assert "[[ANOTHER EARTH|Another Earth (2011)]]" in out, out
    assert "[[Nameless Gangster|Nameless Gangster: Rules of the Time (2012)]]" in out, out
    assert "[[Serenity (2019)|Serenity (2019) (CLIP) (2019)]]" in out, out
    assert "[[Oldboy]]" in out and "[[Oldboy|the Park one]]" in out, out
    assert "[[Totally Made Up Film (1999)]]" in out, "unresolved link must survive"
    assert "[[Collections/Movies/Oldboy|path style]]" in out, "path link must be left alone"
    assert st["broken"] == 1 and st["unresolved"] == ["Totally Made Up Film (1999)"], st
    assert st["fixed"] == 4 and st["already"] == 3, st

    # idempotent: a second pass changes nothing
    again, st2 = fix(out, idx, l2, exact)
    assert again == out, "second pass must be a no-op"
    assert st2["fixed"] == 0

    # a link whose display already equals the file gets no redundant alias
    o3, _ = fix("[[Oldboy (2003)]]", idx, l2, exact)
    assert o3 == "[[Oldboy|Oldboy (2003)]]", o3
    print("fixlinks: all checks passed")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] == "--demo":
        demo()
    else:
        path, root = sys.argv[1], sys.argv[2]
        idx, l2, exact, coll = index(root)
        text = open(path, encoding="utf-8").read()
        out, st = fix(text, idx, l2, exact)
        if out != text:
            open(path, "w", encoding="utf-8").write(out)
        print(f"{st['fixed']} repaired, {st['already']} already exact, {st['broken']} unresolved")
        for u in st["unresolved"][:12]:
            print("  UNRESOLVED:", u)
        if coll:
            print(f"  note: {len(coll)} filename collisions ignored")
