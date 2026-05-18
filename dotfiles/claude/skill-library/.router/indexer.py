import json, re, sys
from pathlib import Path
from datetime import datetime, timezone

library = Path(sys.argv[1])
output  = Path(sys.argv[2])
ts      = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

STOP = {
    'the','and','for','not','but','with','from','have','also','will','your',
    'more','what','which','about','this','that','when','skill','user','task',
    'need','should','use','how','can','are','you','its','any','all','been',
    'even','just','only','then','into','them','these','such','both','very',
    'make','does','used','using','like','than','after','over','trigger','load',
    'want','help','would','could','please','some','type','work','call','run',
}

CATS = {
    'infra':    ['docker','kube','terraform','linux','cloud','nginx','server',
                 'vps','remote','ci-cd','observ','sentry','signoz','reliab','email-deliv'],
    'dev':      ['clean','backend','frontend','api','database','perform',
                 'refactor','monorepo','review','edge','event','micro','vite','regex',
                 'codedoc','live-depend','meta-repo','locali','i18n','no-code',
                 'code','program','software','engineer','develop','architect',
                 'executing-plan','writing-plan','finishing','worktree','subagent',
                 'dispatching','parallel','skill-creator','skill-forge','skill-audit',
                 'super-brain','changelog','artifacts','mcp'],
    'ai':       ['second-brain','superhuman','prompt','llm','ml-ops','nlp',
                 'data-sci','agent','mastra','a2a','a2ui','computer-vision',
                 'langsmith','super-brainstorm','brainstorm','pkm','notebooklm',
                 'research','analyze','brief','image-gen','image'],
    'test':     ['test','cypress','playwright','jest','vitest','load','chaos','api-test',
                 'systematic-debug','verification','webapp-test'],
    'security': ['appsec','pentest','cloud-sec','crypto','incident',
                 'privacy','compliance','regulatory','employment-law','ip-manage'],
    'ui':       ['ultimate-ui','design','motion','responsive','figma','color','ux','access',
                 'ui-ux','impeccable','pixel-art','game-audio','game-balanc','unity'],
    'tools':    ['git','vim','shell','debug','cli','open-source','cmux','spreadsheet',
                 'using-git','requesting-code','receiving-code'],
    'scorm':    ['javascript','scorm','moodle','lms','js-debug','lms-help'],
    'seo':      ['seo','keyword','schema','core-web','content-seo','link',
                 'local-seo','programmatic','aeo','geo','on-site','technical-seo'],
    'data':     ['pipeline','warehouse','data-qual','analytic','streaming','data-warehouse','data-warehous'],
    'mobile':   ['react-native','ios','android','mobile'],
    'product':  ['product','user-stor','posthog','competitive','launch','discovery',
                 'agile','scrum','project-execut','technical-interview'],
    'writing':  ['technical-writ','developer-exp','internal-doc','presentation',
                 'content-research','content-market','copywrite','proposal',
                 'developer-advoc'],
    'business': ['saas','pricing','partner','api-monetiz','financial','legal',
                 'contract','sales','recruit','onboard','brand','budget',
                 'account-manage','bookkeep','community','compens','crm',
                 'email-market','employee','growth','lead-scor','social-media',
                 'startup','fundrais','tax','domain-name','copywrite','copywriting'],
    'custom':   ['custom','health','pkm-enrich','ref'],
}

def categorise(name):
    n = name.lower()
    for cat, pats in CATS.items():
        if any(p in n for p in pats):
            return cat
    return 'other'

def extract_fm(text, field):
    fm = re.match(r'^---\s*\n(.*?)\n---', text, re.DOTALL)
    if not fm: return ''
    body = fm.group(1)
    m = re.search(rf'^{re.escape(field)}:\s*(.*)$', body, re.MULTILINE)
    if not m: return ''
    val = m.group(1).strip()
    if val == '>':
        lines = body.split('\n')
        idx = next((i for i,l in enumerate(lines) if l.startswith(field+':')), None)
        if idx is None: return ''
        parts = [l.strip() for l in lines[idx+1:] if l.startswith(('  ','\t'))]
        val = ' '.join(parts)
    words = val.split()
    return ' '.join(words[:25]) + ('...' if len(words) > 25 else '')

def keywords(desc):
    words = re.findall(r'[a-z]{4,}', desc.lower())
    seen, out = set(), []
    for w in words:
        if w not in STOP and w not in seen:
            seen.add(w); out.append(w)
        if len(out) >= 14: break
    return ','.join(out)

skills = []

def scan(base, scope):
    if not base.exists(): return
    for skill_dir in sorted(base.iterdir()):
        if not skill_dir.is_dir(): continue
        if skill_dir.name.startswith('.'): continue
        if skill_dir.name == 'custom' and scope == 'library': continue
        sm = skill_dir / 'SKILL.md'
        if not sm.exists(): continue
        try:
            txt = sm.read_text(errors='replace')
        except Exception:
            continue
        name = extract_fm(txt, 'name') or skill_dir.name
        desc = extract_fm(txt, 'description') or 'No description.'
        date = extract_fm(txt, 'date') or ''
        kw   = keywords(desc)
        cat  = categorise(skill_dir.name)
        skills.append({
            'name':    name,
            'dir':     skill_dir.name,
            'scope':   scope,
            'cat':     cat,
            'desc':    desc,
            'kw':      kw,
            'refs':    (skill_dir / 'references').exists(),
            'scripts': (skill_dir / 'scripts').exists(),
            'date':    date,
            'path':    str(sm),
        })
        print(f"  {skill_dir.name:<42} [{cat}]")

scan(library, 'library')
scan(library / 'custom', 'custom')

# Fix Audit Item 7: Atomic Write
tmp_output = output.with_suffix('.tmp')
with open(tmp_output, 'w') as f:
    json.dump({
        '_meta': {'built': ts, 'count': len(skills), 'version': '2.0'},
        'skills': skills,
    }, f, indent=2)
tmp_output.replace(output)

print(f"\n✓  {len(skills)} skills indexed → {output}")
print("   /sk \"query\"  to search")
