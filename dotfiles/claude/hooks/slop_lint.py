#!/usr/bin/env python3
"""slop_lint — flags AI-generated UI tells in frontend files.

The "pre-flight check" from taste-skill, made runnable. Detects the LLM-output
signatures that survive even when the design is good: em/en-dashes, numbered
eyebrows, middle-dot strips, social-proof cliches, generic names, scroll cues,
filler verbs, pure black/white, custom cursors.

Usage:
    slop_lint.py <file_or_dir> [more...] [--quiet]

--quiet  suppress the "clean" confirmation (used by the post-edit hook so it
         stays silent unless there is something to flag).

Exit code: 0 always (advisory; never blocks a build). Violations go to stdout.
"""
import os
import re
import sys

EXTS = (".html", ".htm", ".jsx", ".tsx", ".vue", ".svelte", ".astro")
SKIP = ("node_modules", "/dist/", "/build/", "/vendor/", ".min.", "/.git/")

# (severity, label, compiled regex, hint)
RULES = [
    ("HIGH", "em/en-dash", re.compile(r"—|–|&mdash;|&ndash;"),
     "the #1 AI tell. Use a hyphen '-', a comma, a period, or parentheses."),
    ("HIGH", "numbered-eyebrow", re.compile(r">\s*0\d\s*[/.·]|\bNo\.?\s*0?\d\b|\b(Stage|Step|Phase|Pass)\s+(One|Two|Three|Four|Five|\d+|0\d)\b"),
     "drop '01 /', 'No. 02', 'Stage 1'. Name the thing in plain language."),
    ("HIGH", "generic-name", re.compile(r"\bJohn Doe\b|\bJane Doe\b|\bAcme\b|\bNexus\b|SmartFlow|Cloudly|Lorem ipsum", re.I),
     "use realistic, contextual names/brands, not placeholders."),
    ("HIGH", "social-proof-cliche", re.compile(r"Quietly (trusted|in use)|From the field|Field notes|On our desks", re.I),
     "say 'Used at' / 'Trusted by', or skip the label."),
    ("HIGH", "scroll-cue", re.compile(r"Scroll to (explore|begin|continue|walk|discover)|↓\s*scroll|\bScroll down\b", re.I),
     "the user knows what scrolling is. Remove the cue."),
    ("HIGH", "filler-verb", re.compile(r"\b(Elevate|Seamless(ly)?|Unleash|Supercharge|Revolutioniz\w*|Next-Gen|Effortless(ly)?|Cutting-edge)\b", re.I),
     "use a concrete verb that says what it actually does."),
    ("INFO", "middle-dot-strip", re.compile(r"(·|&middot;).*(·|&middot;).*(·|&middot;)"),
     "3+ middle-dots on a line is a decoration strip. Use columns or line breaks."),
    ("INFO", "pure-black/white", re.compile(r"#000000\b|#000\b|#ffffff\b|#fff\b|rgb\(\s*0,\s*0,\s*0\s*\)"),
     "pure black/white never appears in nature. Tint it (zinc-950, off-white)."),
    ("INFO", "custom-cursor", re.compile(r"cursor:\s*url\(|cursor:\s*none"),
     "custom cursors are dated and accessibility-hostile."),
    ("INFO", "fake-version-eyebrow", re.compile(r"\b(BETA|ALPHA|EARLY ACCESS|INVITE-ONLY)\b|\bv0\.\d"),
     "version/preview eyebrows belong only on real launch pages."),
]

COMMENT = re.compile(r"<!--.*?-->|\{/\*.*?\*/\}", re.S)


def scan(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return []
    # Blank out comments so our own annotations are not flagged (keep line count)
    cleaned = COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), raw)
    out = []
    for n, line in enumerate(cleaned.splitlines(), 1):
        for sev, label, rx, hint in RULES:
            if rx.search(line):
                out.append((sev, label, n, hint))
    return out


def collect(targets):
    files = []
    for t in targets:
        if os.path.isdir(t):
            for root, _, names in os.walk(t):
                for nm in names:
                    p = os.path.join(root, nm)
                    if nm.endswith(EXTS) and not any(s in p for s in SKIP):
                        files.append(p)
        elif t.endswith(EXTS) and not any(s in t for s in SKIP):
            files.append(t)
    return files


def main():
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    quiet = "--quiet" in sys.argv
    if not args:
        print("usage: slop_lint.py <file_or_dir> [...] [--quiet]")
        return
    total = 0
    for f in collect(args):
        hits = scan(f)
        if not hits:
            continue
        rel = os.path.relpath(f)
        print(f"\n[slop] {rel}")
        for sev, label, n, hint in hits:
            mark = "✗" if sev == "HIGH" else "·"
            print(f"  {mark} L{n:<4} {label:<20} {hint}")
        total += len(hits)
    if total:
        print(f"\n[slop] {total} AI tell(s) flagged. Fix the ✗ items before shipping UI.")
    elif not quiet:
        print("[slop] ✓ no AI tells found.")


if __name__ == "__main__":
    main()
