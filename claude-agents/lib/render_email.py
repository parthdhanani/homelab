#!/usr/bin/env python3
"""render_email.py "<Title>" "<subtitle>" ["<severity>"]  — markdown on stdin -> polished
HTML email on stdout. Monochrome editorial style, Gmail-safe inline styles. Parses ##
sections and '- ' item lists of the form:  - **[Headline](url)** — description. (source)

SEVERITY (optional 3rd arg) distinguishes alert mail from routine digest mail so the two
are visually distinct in the inbox, not identical cards that require opening to tell apart:
  "warning"  — amber left border + badge (needs attention, not urgent)
  "critical" — red left border + badge (real problem, check now)
  omitted    — routine digest, unchanged monochrome card (default, all existing callers)
"""
import sys, re, html

TITLE = sys.argv[1] if len(sys.argv) > 1 else "Brief"
SUBTITLE = sys.argv[2] if len(sys.argv) > 2 else ""
SEVERITY = sys.argv[3] if len(sys.argv) > 3 else ""

INK, MUTED, FAINT, RULE, BG, CARD = "#161616", "#5c5c5c", "#8a8a8a", "#e6e3dd", "#ffffff", "#fbfaf8"
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

SEVERITY_COLOR = {"warning": "#a66a00", "critical": "#b3261e"}
ACCENT = SEVERITY_COLOR.get(SEVERITY, "")
BORDER_LEFT = f"border-left:4px solid {ACCENT};" if ACCENT else ""
BADGE = (f'<div style="display:inline-block;margin-top:8px;padding:3px 9px;'
         f'border-radius:20px;background:{ACCENT}1a;color:{ACCENT};'
         f'font:700 11px/1 {FONT};letter-spacing:.06em;text-transform:uppercase">'
         f'{SEVERITY}</div>') if ACCENT else ""

def inline(s):
    """Convert inline markdown (links, bold) to HTML, escaping the rest."""
    out, i = [], 0
    # protect [text](url) and **bold** by tokenizing
    pattern = re.compile(r'\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|`([^`]+)`')
    for m in pattern.finditer(s):
        out.append(html.escape(s[i:m.start()]))
        if m.group(1) is not None:  # link
            out.append(f'<a href="{html.escape(m.group(2),quote=True)}" '
                       f'style="color:{INK};text-decoration:none;border-bottom:1px solid {FAINT}">'
                       f'{html.escape(m.group(1))}</a>')
        elif m.group(3) is not None:  # bold (may contain a link -> recurse)
            out.append(f'<strong style="font-weight:600">{inline(m.group(3))}</strong>')
        else:  # code
            out.append(f'<code style="background:{CARD};padding:1px 4px;border-radius:3px;'
                       f'font-size:13px">{html.escape(m.group(4))}</code>')
        i = m.end()
    out.append(html.escape(s[i:]))
    return ''.join(out)

def split_source(text):
    """Pull a trailing (source.com) parenthetical off the end."""
    m = re.search(r'\s*\(([^()]+)\)\s*$', text)
    if m and ('.' in m.group(1) or ',' in m.group(1)) and len(m.group(1)) < 80:
        return text[:m.start()].rstrip(), m.group(1)
    return text, None

rows = []
def section(label):
    rows.append(
        f'<tr><td style="padding:26px 0 6px 0;border-top:1px solid {RULE}">'
        f'<div style="font:600 12px/1 {FONT};letter-spacing:.12em;text-transform:uppercase;'
        f'color:{FAINT}">{html.escape(label)}</div></td></tr>')

def item(md):
    img = None
    m = re.match(r'^!\[[^\]]*\]\(([^)]+)\)\s*', md)
    if m:
        img = m.group(1)
        md = md[m.end():]
    md, source = split_source(md)
    # split off a leading **bold** span first: some items legitimately contain an
    # em-dash *inside* the bold (e.g. "**Book Title — Author**"), and a naive split
    # on the first em-dash grabs that one instead of the real headline/description
    # separator, breaking the bold markup. Match the bold span by its own ** delimiters.
    bm = re.match(r'^(\*\*[^*]+\*\*)\s*—\s*(.*)$', md)
    if bm:
        head, desc = bm.group(1), bm.group(2)
    else:
        parts = re.split(r'\s+—\s+', md, maxsplit=1)
        head, desc = parts[0], (parts[1] if len(parts) > 1 else "")
    head = inline(head)
    desc = inline(desc)
    block = (f'<div style="font:600 15px/1.4 {FONT};color:{INK};margin:0 0 3px 0">{head}</div>')
    if desc:
        block += f'<div style="font:400 14px/1.55 {FONT};color:{MUTED}">{desc}</div>'
    if source:
        block += (f'<div style="font:400 12px/1.4 {FONT};color:{FAINT};margin-top:4px">'
                  f'{html.escape(source)}</div>')
    if img:
        block = (f'<img src="{html.escape(img,quote=True)}" width="72" height="72" '
                  f'style="border-radius:6px;object-fit:cover;float:left;margin:0 12px 8px 0" alt="">'
                  + block)
    rows.append(f'<tr><td style="padding:14px 0;border-top:1px solid {CARD};overflow:hidden">{block}'
                f'<div style="clear:both"></div></td></tr>')

def para(md):
    rows.append(f'<tr><td style="padding:8px 0;font:400 14px/1.6 {FONT};color:{MUTED}">'
                f'{inline(md)}</td></tr>')

for raw in sys.stdin.read().splitlines():
    line = raw.rstrip()
    s = line.strip()
    if not s:
        continue
    if s.startswith('## '):
        section(s[3:].strip())
    elif s.startswith('### '):
        section(s[4:].strip())
    elif s.startswith('# '):
        section(s[2:].strip())
    elif re.match(r'^[-*]\s+', s):
        item(re.sub(r'^[-*]\s+', '', s))
    elif re.match(r'^\d+\.\s+', s):
        item(re.sub(r'^\d+\.\s+', '', s))
    else:
        para(s)

sub = f'<div style="font:400 13px/1.4 {FONT};color:{FAINT};margin-top:3px">{html.escape(SUBTITLE)}</div>' if SUBTITLE else ""
print(f"""<!DOCTYPE html><html><body style="margin:0;padding:0;background:{BG}">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{BG}">
<tr><td align="center" style="padding:28px 16px">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:{CARD};border:1px solid {RULE};{BORDER_LEFT}border-radius:10px">
<tr><td style="padding:28px 30px 18px 30px">
<div style="font:700 22px/1.2 {FONT};color:{INK};letter-spacing:-.01em">{html.escape(TITLE)}</div>{sub}{BADGE}
</td></tr>
<tr><td style="padding:0 30px 24px 30px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{''.join(rows)}</table>
</td></tr>
</table></td></tr></table></body></html>""")
