#!/usr/bin/env python3
"""
Count drafted-but-unposted LinkedIn posts for the weekly digest.

Why this exists: on 2026-07-25 the four posts in wip/linkedin-posts.md were found
written (2026-07-07) with no evidence any had been posted 18 days later — the same
drafted-but-not-sent pattern as the application tracker. The fix is NOT to draft more
posts. It is to make the unposted count visible in the one weekly digest that already
reports jobhunt sends bluntly.

Marking convention (deliberately minimal — no database, no state file):
    ## Post 1 — the freeze bug                      → unposted
    ## Post 1 — the freeze bug [POSTED 2026-07-30]   → posted

Run: python3 linkedin_queue.py [path]
"""

import re
import sys
from pathlib import Path

DEFAULT_PATH = Path("/home/ubuntu/AI_Space/wip/linkedin-posts.md")

_HEADING = re.compile(r"^##\s+Post\s+(\d+)\s*(?:—|-|:)?\s*(.*)$", re.MULTILINE)
_POSTED = re.compile(r"\[POSTED\s+(\d{4}-\d{2}-\d{2})\]", re.IGNORECASE)
# Post 4 is explicitly gated on the Storyline sample being live — counting it as
# "ready to post" would be a false nag, so blocked posts are reported separately.
_BLOCKED = re.compile(r"POST ONLY AFTER|BLOCKED|do not post", re.IGNORECASE)


def scan(text: str) -> dict:
    posts = []
    for m in _HEADING.finditer(text):
        title = m.group(2).strip()
        posts.append({
            "n": int(m.group(1)),
            "title": _POSTED.sub("", title).strip(" —-"),
            "posted": (_POSTED.search(title).group(1) if _POSTED.search(title) else None),
            "blocked": bool(_BLOCKED.search(title)),
        })
    ready = [p for p in posts if not p["posted"] and not p["blocked"]]
    return {
        "total": len(posts),
        "posted": [p for p in posts if p["posted"]],
        "blocked": [p for p in posts if p["blocked"] and not p["posted"]],
        "ready": ready,
    }


def summarize(path: Path = DEFAULT_PATH) -> str:
    # No "linkedin:" prefix — the caller (digest.sh) already labels the line.
    if not path.exists():
        return "source file missing"
    s = scan(path.read_text(encoding="utf-8", errors="replace"))
    if s["total"] == 0:
        return "no drafted posts found"
    bits = [f"{len(s['ready'])} drafted and ready to post", f"{len(s['posted'])} posted"]
    if s["blocked"]:
        bits.append(f"{len(s['blocked'])} blocked on a dependency")
    line = ", ".join(bits)
    if s["ready"]:
        line += " | oldest ready: #%d %s" % (s["ready"][0]["n"], s["ready"][0]["title"])
    return line


def demo():
    sample = """
## Post 1 — the freeze bug [POSTED 2026-07-30]
body
## Post 2 — localization war story
body
## Post 3 — the numbers post
body
## Post 4 — the sample launch (POST ONLY AFTER 3.6 IS LIVE)
body
"""
    s = scan(sample)
    assert s["total"] == 4, s["total"]
    assert len(s["posted"]) == 1, "POSTED marker not detected"
    assert len(s["blocked"]) == 1, "dependency-gated post counted as ready — false nag"
    assert len(s["ready"]) == 2, f"ready count wrong: {len(s['ready'])}"
    assert s["ready"][0]["n"] == 2, "oldest ready post should be #2"
    # a posted post must never also count as ready, even if it looks blocked
    both = scan("## Post 9 — x (POST ONLY AFTER y) [POSTED 2026-01-01]\n")
    assert len(both["ready"]) == 0 and len(both["posted"]) == 1, "posted+blocked mishandled"
    # empty / missing input must not raise
    assert scan("")["total"] == 0
    assert "missing" in summarize(Path("/nonexistent/nope.md"))

    print("linkedin_queue.py: all checks passed")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        demo()
    else:
        print(summarize(Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PATH))
