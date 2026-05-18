#!/usr/bin/env python3
"""
~/.claude/skill-library/.router/search.py
One job: search the index, return ranked candidates.
"""
import json, re, sys, argparse, subprocess, os
from pathlib import Path
from datetime import datetime, timezone

INDEX  = Path.home() / ".claude/skill-library/.router/index.json"
BUILD  = Path.home() / ".claude/skill-library/.router/build-index.sh"
LIBRARY = Path.home() / ".claude/skill-library"
STALE  = 90  # days before warning

STOP = {
    'the','and','for','not','but','with','from','have','also','will','your',
    'more','what','which','about','this','that','when','skill','user','task',
    'need','should','use','how','can','are','you','its','any','all','been',
    'even','just','only','then','into','them','these','such','both','very',
    'make','does','used','using','like','than','after','over','want','help',
    'would','could','please','some','get','give','find','show','tell','know',
    'thing','things',
}

def get_lib_mtime(library_path):
    if not library_path.exists(): return 0
    max_mtime = 0
    for root, dirs, files in os.walk(library_path):
        if '.router' in root or '__pycache__' in root: continue
        mtime = os.path.getmtime(root)
        if mtime > max_mtime: max_mtime = mtime
        for f in files:
            if f.startswith("."): continue
            f_mtime = os.path.getmtime(os.path.join(root, f))
            if f_mtime > max_mtime: max_mtime = f_mtime
    return max_mtime

def load():
    rebuild_needed = False
    if not INDEX.exists():
        rebuild_needed = True
    else:
        try:
            index_mtime = INDEX.stat().st_mtime
            lib_mtime = get_lib_mtime(LIBRARY)
            if lib_mtime > index_mtime:
                rebuild_needed = True
        except Exception:
            pass

    if rebuild_needed:
        print("Index missing or stale — building now...")
        subprocess.run(["bash", str(BUILD)], check=True)
        
    with open(INDEX) as f:
        data = json.load(f)
    return data["skills"], data.get("_meta", {})

def core_dirs():
    # Audit Item 1 Fix: Removed broken ACTIVE tracking.
    # Native context tracking is not possible via filesystem.
    return set()

def tok(text):
    return [w for w in re.findall(r'[a-z]{3,}', text.lower()) if w not in STOP]

def score(q_set, skill):
    if not q_set: return 0.0
    n = set(tok(skill.get('name','') + ' ' + skill.get('dir','')))
    d = set(tok(skill.get('desc','')))
    k = set(tok(skill.get('kw','')))
    s = (len(q_set & n)/len(q_set)*2.5 +
         len(q_set & d)/len(q_set)*1.0 +
         len(q_set & k)/len(q_set)*0.8)
    raw = ' '.join(q_set)
    slug = skill.get('dir','').replace('-',' ').replace('/',' ')
    if slug and slug in raw: s += 1.5
    return round(s, 3)

def stale_warn(skill):
    d = skill.get('date','')
    if not d: return ''
    try:
        age = (datetime.now(timezone.utc) -
               datetime.strptime(d, '%Y-%m-%d').replace(tzinfo=timezone.utc)).days
        return f" ⚠ {age}d old" if age > STALE else ''
    except Exception:
        return ''

def search(query, top=5):
    skills, meta = load()
    active = core_dirs()
    q = set(tok(query))
    ranked = sorted([(score(q,s),s) for s in skills],
                    key=lambda x:x[0], reverse=True)
    return [(sc,s) for sc,s in ranked if sc > 0.0][:top], meta, active

def list_skills(cat_filter=None):
    skills, meta = load()
    grouped = {}
    for s in skills:
        c = s.get('cat','other')
        if cat_filter and c != cat_filter: continue
        grouped.setdefault(c, []).append(s)
    total = meta.get('count', len(skills))
    print(f"\n📚  Skill Library — {total} skills  (built {meta.get('built','?')[:10]})\n")
    order = ['scorm','infra','dev','ai','test','security','ui','tools',
             'seo','data','mobile','product','writing','business','custom','other']
    for cat in order:
        if cat not in grouped: continue
        print(f"  [{cat.upper()}]")
        for s in sorted(grouped[cat], key=lambda x: x['dir']):
            refs       = " ·refs"     if s.get('refs')              else ""
            custom     = " ·custom"   if s.get('scope')=='custom'   else ""
            stale      = stale_warn(s)
            print(f"    {s['dir']:<40} {s['desc'][:48]}...{refs}{custom}{stale}")
        print()
    print(f"  Search: /sk \"query\"  |  Add: skadd user/repo --skill name  |  Rebuild: skbuild\n")

def main():
    p = argparse.ArgumentParser()
    p.add_argument('query', nargs='*')
    p.add_argument('--top',  type=int, default=5)
    p.add_argument('--list', action='store_true')
    p.add_argument('--cat',  default=None)
    args = p.parse_args()

    if args.list or not args.query:
        list_skills(args.cat); return

    query   = ' '.join(args.query)
    results, meta, active = search(query, args.top)

    print(f"QUERY: {query}")
    print(f"LIBRARY: {meta.get('count','?')} skills  |  INDEX: {meta.get('built','?')[:10]}")
    print(f"RESULTS:")

    if not results:
        print("  NO MATCH")
        print("  → skadd AbsolutelySkilled/AbsolutelySkilled --skill <n>")
        return

    for i,(sc,s) in enumerate(results):
        conf       = "HIGH" if sc>1.5 else "MED" if sc>0.5 else "LOW"
        refs       = " [+refs]"   if s.get('refs')            else ""
        custom     = " [custom]"  if s.get('scope')=='custom' else ""
        stale      = stale_warn(s)
        print(f"  {i+1}. [{conf}] {s['dir']:<36} {s['desc'][:52]}...{refs}{custom}{stale}")

    best = results[0][1]
    print(f"\nLOAD: cat {best['path']}")

if __name__ == '__main__':
    main()
