#!/usr/bin/env python3
"""Auto-inject a custom skill when the prompt matches above threshold.
Reads custom-scoped skills from skill-library index, scores against prompt,
prints SKILL.md (capped at MAX_LINES) if top score >= THRESHOLD.
"""
import json, re, sys
from pathlib import Path

THRESHOLD = 1.5   # tune up if false positives, down if misses
MAX_LINES = 60

STOP = {
    'the','and','for','not','but','with','from','have','also','will','your',
    'more','what','which','about','this','that','when','skill','user','task',
    'need','should','use','how','can','are','you','its','any','all','been',
    'even','just','only','then','into','them','these','such','both','very',
    'make','does','used','using','like','than','after','over','trigger','load',
    'want','help','would','could','please','some','type','work','call','run',
}

def tok(s):
    return {w for w in re.findall(r'[a-z]{3,}', s.lower()) if w not in STOP}

def score(q_set, skill):
    if not q_set:
        return 0.0
    n = tok(skill.get('name', '') + ' ' + skill.get('dir', ''))
    d = tok(skill.get('desc', ''))
    k = tok(skill.get('kw', ''))
    s = (len(q_set & n) / len(q_set) * 2.5 +
         len(q_set & d) / len(q_set) * 1.0 +
         len(q_set & k) / len(q_set) * 0.8)
    slug = skill.get('dir', '').replace('-', ' ')
    if slug and slug in ' '.join(q_set):
        s += 1.5
    return s

def main():
    if len(sys.argv) < 2:
        return
    idx = Path.home() / '.claude/skill-library/.router/index.json'
    if not idx.exists():
        return
    try:
        data = json.loads(idx.read_text())
        custom = [s for s in data.get('skills', []) if s.get('scope') == 'custom']
    except Exception:
        return

    q = tok(sys.argv[1][:300])
    if not q:
        return

    ranked = sorted(
        [(score(q, s), s) for s in custom],
        key=lambda x: x[0], reverse=True
    )
    if not ranked or ranked[0][0] < THRESHOLD:
        return

    sc, best = ranked[0]
    p = Path(best['path'])
    if not p.exists():
        return

    lines = p.read_text(errors='replace').splitlines()[:MAX_LINES]
    print(f'[SKILL:{best["dir"]}] auto-loaded (score:{sc:.1f})')
    print('\n'.join(lines))

if __name__ == '__main__':
    main()
