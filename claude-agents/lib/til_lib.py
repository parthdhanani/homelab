#!/usr/bin/env python3
"""til_lib.py — note writing, spaced-repetition scheduling and email rendering for til.sh.

Split out of the shell job because the model's output contains backticks, quotes and $,
and because the scheduling arithmetic deserves a self-check. Stdlib only.

The schedule implements expanding-interval spacing (Cepeda et al. 2006): a note is shown
again at 7, 21, 60 and 150 days, then retired. Intervals expand because a memory that
survives a long gap needs a longer next gap; re-showing at a fixed 7 days spends attention
on things already known.

Older notes written before this system existed are enrolled with a STAGGERED due date —
one per week — so the backlog trickles back instead of arriving as one unreadable wall.

Run `python3 til_lib.py --demo` for the self-check.
"""
import html
import json
import os
import re
import sys
from datetime import date, timedelta

INTERVALS = [7, 21, 60, 150]   # days after each successive showing; then retired
MAX_REVIEW = 2                 # review cards per email — more and it gets archived unread

# Monochrome palette, matching the duel email and the psidex brand.
BG, CARD, LINE = "#0b0b0c", "#121214", "#26262a"
FG, DIM, FAINT = "#e8e8e6", "#8a8a94", "#5a5a63"
SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,sans-serif"
MONO = "ui-monospace,SFMono-Regular,Menlo,monospace"


# ---------------------------------------------------------------------------- parsing
def parse_front(text: str) -> dict:
    """Frontmatter key -> raw value. [^\\S\\n]* not \\s*: \\s eats newlines, so a key with
    an empty value would swallow the following line."""
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    head = text[3:end] if end > 0 else text[3:]
    out = {}
    for m in re.finditer(r"^([a-z_]+):[^\S\n]*(.*)$", head, re.M):
        v = m.group(2).strip()
        if len(v) > 1 and v[0] == v[-1] == '"':
            v = v[1:-1].replace('\\"', '"')
        out[m.group(1)] = v
    return out


def body_of(text: str) -> str:
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end > 0:
            text = text[end + 4:]
    return re.sub(r"^\s*#\s.*\n", "", text.lstrip(), count=1).strip()


def yq(s: str) -> str:
    """YAML-safe double-quoted scalar — topics and questions contain colons."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ------------------------------------------------------------------------ md -> html
def md(text: str) -> str:
    """Minimal markdown for email. Inline styles only — no <style> block survives Gmail."""
    out, in_ul = [], False

    def inline(s):
        s = html.escape(s)
        s = re.sub(r"`([^`]+)`",
                   rf'<code style="font:12.5px {MONO};background:#1c1c20;'
                   rf'border:1px solid {LINE};border-radius:4px;padding:1px 5px">\1</code>', s)
        s = re.sub(r"\*\*([^*]+)\*\*", rf'<b style="color:{FG}">\1</b>', s)
        return s

    for raw in text.splitlines():
        line = raw.rstrip()
        if re.match(r"^\s*[-*]\s+", line):
            if not in_ul:
                out.append(f'<ul style="margin:8px 0;padding-left:20px;color:{DIM}">')
                in_ul = True
            item = inline(re.sub(r"^\s*[-*]\s+", "", line))
            out.append(f'<li style="margin:5px 0">{item}</li>')
            continue
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if not line.strip():
            continue
        if line.startswith("## "):
            out.append(f'<div style="font:600 12px {SANS};letter-spacing:.1em;'
                       f'text-transform:uppercase;color:{FAINT};margin:18px 0 7px">'
                       f'{inline(line[3:])}</div>')
        elif line.startswith("> "):
            out.append(f'<div style="font:15px/1.6 {SANS};color:{FG};border-left:2px solid {LINE};'
                       f'padding-left:14px;margin:4px 0 14px">{inline(line[2:])}</div>')
        elif re.match(r"^\d+\.\s", line):
            out.append(f'<div style="font:14px/1.6 {SANS};color:{DIM};margin:5px 0 5px 6px">'
                       f'{inline(line)}</div>')
        else:
            out.append(f'<div style="font:14px/1.65 {SANS};color:{DIM};margin:7px 0">'
                       f'{inline(line)}</div>')
    if in_ul:
        out.append("</ul>")
    return "".join(out)


# -------------------------------------------------------------------------- commands
def cmd_write(til_dir, week, rawfile):
    raw = open(rawfile, encoding="utf-8").read()
    written = 0
    for b in re.findall(r"===TIL===(.*?)===END===", raw, re.S):
        def grab(key):
            m = re.search(rf"^{key}:\s*(.*)$", b, re.M)
            return m.group(1).strip() if m else ""
        slug = re.sub(r"[^a-z0-9-]", "-", grab("SLUG").lower()).strip("-")[:60]
        topic, question, tags = grab("TOPIC"), grab("QUESTION"), grab("TAGS")
        m = re.search(r"^BODY:\s*$(.*)", b, re.M | re.S)
        body = m.group(1).strip() if m else ""
        if not (slug and topic and len(body) > 120):
            continue
        taglist = [t.strip() for t in tags.split(",") if t.strip()] or ["til"]
        if "til" not in taglist:
            taglist.insert(0, "til")
        path = os.path.join(til_dir, f"{week}-{slug}.md")
        if os.path.exists(path):        # idempotent: a re-run must not duplicate
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("---\n")
            fh.write(f"date: {week}\n")
            fh.write(f"topic: {yq(topic)}\n")
            if question:
                fh.write(f"question: {yq(question)}\n")
            fh.write(f"tags: [{', '.join(taglist)}]\n")
            fh.write("source: auto-generated from the week's commits and sessions\n")
            fh.write("---\n\n")
            fh.write(f"# 💡 {topic}\n\n{body}\n")
        written += 1
    print(written)


def all_notes(til_dir):
    """Reviewable notes only. Excludes TIL.md (a scratch link dump) and the historical
    `*-daily.md` files, which are read-later queues with topic 'Daily' — resurfacing those
    as recall questions would be noise, and noise is what gets the whole email archived."""
    out = []
    for f in sorted(os.listdir(til_dir)):
        if not f.endswith(".md") or f.startswith("."):
            continue
        if not re.match(r"^\d{4}-\d{2}-\d{2}-", f) or f.endswith("-daily.md"):
            continue
        out.append(f[:-3])
    return out


def cmd_schedule(til_dir, week, statefile, outfile):
    """Enrol unseen notes, then select what is due. Never mutates reps — that is `commit`,
    which only runs after the mail is actually accepted."""
    today = date.fromisoformat(week)
    state = json.load(open(statefile)) if os.path.exists(statefile) else {"notes": {}}
    notes = state.setdefault("notes", {})

    known = set(notes)
    fresh = [n for n in all_notes(til_dir) if n not in known]
    # This week's notes start the ladder immediately; the historical backlog is staggered
    # one per week so it trickles back rather than arriving all at once.
    backlog = sorted(n for n in fresh if not n.startswith(week))
    for n in fresh:
        if n.startswith(week):
            notes[n] = {"reps": 0, "due": str(today + timedelta(days=INTERVALS[0])),
                        "first": week}
    for i, n in enumerate(backlog):
        notes[n] = {"reps": 0, "due": str(today + timedelta(days=7 * (i + 1))), "first": n[:10]}

    json.dump(state, open(statefile, "w"), indent=1)

    due = []
    for n, r in sorted(notes.items(), key=lambda kv: (kv[1].get("due") or "9999", kv[0])):
        if r.get("due") and r["due"] <= week and not n.startswith(week):
            p = os.path.join(til_dir, n + ".md")
            if not os.path.exists(p):
                continue
            fm = parse_front(open(p, encoding="utf-8").read())
            due.append({"slug": n, "topic": fm.get("topic", n),
                        "question": fm.get("question", ""), "reps": r.get("reps", 0)})
        if len(due) >= MAX_REVIEW:
            break
    json.dump({"due": due}, open(outfile, "w"), indent=1)


def cmd_needq(duefile):
    for d in json.load(open(duefile))["due"]:
        if not d["question"]:
            print(f'{d["slug"]} :: {d["topic"]}')


def cmd_mergeq(duefile, qfile, til_dir):
    """Persist backfilled questions into the notes themselves, so this is a one-time cost
    per note rather than a model call on every resurface."""
    qs = {}
    for line in open(qfile, encoding="utf-8"):
        if "::" in line:
            k, v = line.split("::", 1)
            qs[k.strip()] = v.strip()
    data = json.load(open(duefile))
    for d in data["due"]:
        q = qs.get(d["slug"])
        if not q or d["question"]:
            continue
        d["question"] = q
        p = os.path.join(til_dir, d["slug"] + ".md")
        text = open(p, encoding="utf-8").read()
        if "\nquestion:" not in text and text.startswith("---"):
            text = re.sub(r"^(topic:.*\n)", rf"\1question: {yq(q)}\n", text, count=1, flags=re.M)
            open(p, "w", encoding="utf-8").write(text)
    json.dump(data, open(duefile, "w"), indent=1)


# ---------------------------------------------------------------------------- render
def card(n, question, topic, kind, meta):
    q = html.escape(question or topic)
    tag = (f'<span style="font:11px {SANS};letter-spacing:.09em;text-transform:uppercase;'
           f'color:{FAINT}">{kind}</span>')
    return (f'<tr><td style="padding:0 0 12px">'
            f'<table width="100%" cellpadding="0" cellspacing="0" style="background:{CARD};'
            f'border:1px solid {LINE};border-radius:12px"><tr><td style="padding:18px 20px">'
            f'<div style="margin-bottom:9px">'
            f'<span style="font:600 12px {MONO};color:{FAINT};margin-right:9px">{n:02d}</span>{tag}'
            f'<span style="float:right;font:11px {SANS};color:{FAINT}">{meta}</span></div>'
            f'<div style="font:500 16px/1.55 {SANS};color:{FG}">{q}</div>'
            f'</td></tr></table></td></tr>')


def answer(n, topic, body_html, path, footer):
    return (f'<tr><td style="padding:0 0 26px">'
            f'<div style="font:600 12px {MONO};color:{FAINT};margin-bottom:8px">{n:02d}</div>'
            f'<div style="font:600 16px/1.5 {SANS};color:{FG};margin-bottom:10px">'
            f'{html.escape(topic)}</div>{body_html}'
            f'<div style="font:11.5px {MONO};color:{FAINT};margin-top:12px">{html.escape(path)}</div>'
            f'{footer}</td></tr>')


def cmd_render(til_dir, week, duefile, outfile, new_count):
    new_count = int(new_count)
    new_slugs = [n for n in all_notes(til_dir) if n.startswith(week)][:new_count]
    due = json.load(open(duefile))["due"]

    items = []
    for s in new_slugs:
        fm = parse_front(open(os.path.join(til_dir, s + ".md"), encoding="utf-8").read())
        items.append({"slug": s, "topic": fm.get("topic", s), "question": fm.get("question", ""),
                      "kind": "new", "meta": "first pass", "reps": 0})
    for d in due:
        age = (date.fromisoformat(week) - date.fromisoformat(d["slug"][:10])).days
        items.append({**d, "kind": "recall",
                      "meta": f"{age}d later · review {d['reps'] + 1}"})

    cards, answers = [], []
    for i, it in enumerate(items, 1):
        cards.append(card(i, it["question"], it["topic"], it["kind"], it["meta"]))
        text = open(os.path.join(til_dir, it["slug"] + ".md"), encoding="utf-8").read()
        nxt = INTERVALS[it["reps"] + 1] if it["reps"] + 1 < len(INTERVALS) else None
        foot = (f'<div style="font:11.5px {SANS};color:{FAINT};margin-top:5px">'
                f'{"back in " + str(nxt) + " days" if nxt else "retired — you know this one"}'
                f'</div>')
        answers.append(answer(i, it["topic"], md(body_of(text)),
                              f'50 Collections/TIL/{it["slug"]}.md', foot))

    nq = sum(1 for i in items if i["kind"] == "new")
    nr = len(items) - nq
    line = " · ".join(x for x in [f"{nq} new" if nq else "", f"{nr} for recall" if nr else ""] if x)

    doc = f"""<div style="background:{BG};padding:32px 14px;font-family:{SANS}">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;margin:0 auto">
<tr><td style="padding-bottom:6px">
  <div style="font:12px {SANS};letter-spacing:.16em;text-transform:uppercase;color:{FAINT}">
    Today I learned · {week}</div>
  <div style="font:600 21px {SANS};color:{FG};margin:8px 0 4px">Answer first, then scroll</div>
  <div style="font:13.5px/1.6 {SANS};color:{DIM};margin-bottom:22px">
    {line}. Try each one from memory — a wrong guess before seeing the answer
    is what makes it stick. Answers are at the bottom.</div>
</td></tr>
{"".join(cards)}
<tr><td style="padding:34px 0 22px">
  <div style="height:1px;background:{LINE}"></div>
  <div style="font:12px {SANS};letter-spacing:.16em;text-transform:uppercase;color:{FAINT};
    margin-top:22px">Answers</div>
</td></tr>
{"".join(answers)}
<tr><td style="border-top:1px solid {LINE};padding-top:16px">
  <div style="font:11.5px/1.7 {SANS};color:{FAINT}">
    Written from this week's commits and session summaries — edit or delete freely,
    they're plain notes in the vault.<br><br>
    <b style="color:{DIM}">Why this layout.</b>
    Questions before answers: attempting recall and failing beats re-reading
    (testing effect, Roediger &amp; Karpicke 2006) — re-reading feels like learning and
    mostly isn't.<br>
    Old notes return at 7 / 21 / 60 / 150 days, then retire: expanding intervals beat
    massed review (spacing effect, Cepeda et al. 2006).<br>
    Capped at five cards, because a long one gets archived unread.
  </div>
</td></tr></table></div>"""
    open(outfile, "w", encoding="utf-8").write(doc)


def cmd_subject(new_count, due_count):
    n, d = int(new_count), int(due_count)
    if n and d:
        print(f"💡 TIL — {n} new, {d} to recall")
    elif n:
        print(f"💡 TIL — {n} new")
    else:
        print(f"🔁 TIL recall — {d} from the archive")


def cmd_commit(duefile, statefile, week):
    """Advance the ladder only after the mail was sent — a failed send must re-offer the
    same cards next week rather than silently pushing them 60 days out."""
    today = date.fromisoformat(week)
    state = json.load(open(statefile)) if os.path.exists(statefile) else {"notes": {}}
    for d in json.load(open(duefile))["due"]:
        r = state["notes"].get(d["slug"])
        if not r:
            continue
        r["reps"] = r.get("reps", 0) + 1
        r["due"] = (str(today + timedelta(days=INTERVALS[r["reps"]]))
                    if r["reps"] < len(INTERVALS) else None)
    json.dump(state, open(statefile, "w"), indent=1)


# ----------------------------------------------------------------------------- check
def demo():
    import tempfile
    d = tempfile.mkdtemp()
    til = os.path.join(d, "TIL")
    os.makedirs(til)

    # -- frontmatter: quoted values, colons in the value, no line-swallowing
    probe = os.path.join(d, "probe.md")
    open(probe, "w").write(
        '---\ndate: 2026-01-01\ntopic: "Thing: it breaks"\nquestion: "Why: does it?"\n'
        "tags: [til]\n---\n\n# 💡 Thing\n\nbody\n")
    fm = parse_front(open(probe).read())
    assert fm["topic"] == "Thing: it breaks", fm
    assert fm["question"] == "Why: does it?", fm
    assert fm["tags"] == "[til]", fm

    # An older note from before the question field existed — must still be reviewable.
    open(os.path.join(til, "2026-01-01-a.md"), "w").write(
        '---\ndate: 2026-01-01\ntopic: "Thing: it breaks"\ntags: [til]\n---\n'
        "\n# 💡 Thing\n\n> rule\n\n## Why\nmech\n")

    # -- write: parses the block, refuses thin bodies, is idempotent
    raw = os.path.join(d, "raw.txt")
    open(raw, "w").write(
        "===TIL===\nSLUG: umask-setgid\nTOPIC: setgid does not set permissions\n"
        "QUESTION: A dir is setgid group ubuntu and root cron writes there. Why is it 644?\n"
        "TAGS: til, linux\nBODY:\n> the rule\n\n## What happened\n" + "x" * 130 +
        "\n===END===\n===TIL===\nSLUG: thin\nTOPIC: t\nTAGS: til\nBODY:\nshort\n===END===\n")
    import io
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    cmd_write(til, "2026-07-25", raw)
    cmd_write(til, "2026-07-25", raw)          # second run must add nothing
    sys.stdout = old
    assert buf.getvalue().split() == ["1", "0"], buf.getvalue()
    w = open(os.path.join(til, "2026-07-25-umask-setgid.md")).read()
    assert 'question: "A dir is setgid' in w
    assert not os.path.exists(os.path.join(til, "2026-07-25-thin.md")), "thin body written"

    # -- schedule: backlog staggers one per week, this week's note is not self-reviewed
    st, dj = os.path.join(d, "s.json"), os.path.join(d, "due.json")
    for i, n in enumerate(["2026-02-01-b", "2026-03-01-c"]):
        open(os.path.join(til, n + ".md"), "w").write(
            f'---\ndate: {n[:10]}\ntopic: "T{i}"\ntags: [til]\n---\n\n# 💡 T{i}\n\nbody\n')
    cmd_schedule(til, "2026-07-25", st, dj)
    notes = json.load(open(st))["notes"]
    assert notes["2026-07-25-umask-setgid"]["due"] == "2026-08-01", notes
    backlog_due = sorted(notes[n]["due"] for n in ["2026-01-01-a", "2026-02-01-b", "2026-03-01-c"])
    assert backlog_due == ["2026-08-01", "2026-08-08", "2026-08-15"], backlog_due
    assert json.load(open(dj))["due"] == [], "nothing should be due on enrolment week"

    # -- a later run: backlog comes due, capped at MAX_REVIEW, this week's note excluded
    cmd_schedule(til, "2026-08-20", st, dj)
    due = json.load(open(dj))["due"]
    assert len(due) == MAX_REVIEW, due
    assert all(not x["slug"].startswith("2026-08-20") for x in due)
    assert due[1]["question"].startswith("A dir is setgid"), due[1]

    # -- needq / mergeq: only the question-less note is asked about, and it persists
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    cmd_needq(dj)
    sys.stdout = old
    asked = [l.split("::")[0].strip() for l in buf.getvalue().splitlines() if l.strip()]
    assert asked == ["2026-01-01-a"], (asked, due)
    qf = os.path.join(d, "q.txt")
    open(qf, "w").write("2026-01-01-a :: What actually fails here: and why?\n")
    cmd_mergeq(dj, qf, til)
    assert parse_front(open(os.path.join(til, "2026-01-01-a.md")).read())["question"] \
        == "What actually fails here: and why?"
    assert json.load(open(dj))["due"][0]["question"].startswith("What actually")

    # -- commit: the ladder expands, and only after a send
    before = json.load(open(st))["notes"][due[0]["slug"]]["due"]
    cmd_commit(dj, st, "2026-08-20")
    after = json.load(open(st))["notes"][due[0]["slug"]]
    assert after["reps"] == 1 and after["due"] == "2026-09-10", after
    assert after["due"] != before
    for _ in range(len(INTERVALS)):             # retires, never crashes past the last rung
        cmd_commit(dj, st, "2026-08-20")
    assert json.load(open(st))["notes"][due[0]["slug"]]["due"] is None

    # -- render: every card has a matching answer, and the answer text is NOT in the
    #    question half — the whole design fails if the answer is visible above the fold
    out = os.path.join(d, "mail.html")
    cmd_render(til, "2026-08-20", dj, out, 0)
    doc = open(out).read()
    head, _, tail = doc.partition(">Answers<")
    assert tail, "no answers divider"
    assert head.count("border-radius:12px") == MAX_REVIEW, head.count("border-radius:12px")
    assert "mech" not in head, "answer body leaked into the question section"
    assert "mech" in tail
    assert "Roediger" in tail

    # -- markdown: escaping, code, headings, lists
    h = md("## Why\n- a `b` c\n> **rule** <script>\n")
    assert "&lt;script&gt;" in h and "<code" in h and "<li" in h and "<script>" not in h

    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    cmd_subject(0, 2); cmd_subject(2, 0); cmd_subject(1, 1)
    sys.stdout = old
    assert "recall" in buf.getvalue().splitlines()[0]
    print("til_lib: all checks passed")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] == "--demo":
        demo()
    else:
        cmd = sys.argv[1]
        {"write": cmd_write, "schedule": cmd_schedule, "needq": cmd_needq,
         "mergeq": cmd_mergeq, "render": cmd_render, "subject": cmd_subject,
         "commit": cmd_commit}[cmd](*sys.argv[2:])
