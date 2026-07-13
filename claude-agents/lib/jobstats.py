#!/usr/bin/env python3
"""jobstats.py — weekly send-tracking numbers for the digest.
Counts drafted roles and Gmail-confirmed Applied events in the last N days, using each
entry's own embedded email date (not the section header date) — the header reflects when
an entry was *logged*, which for backfilled status-sync entries can be years after the
real event. Reading the true per-entry date avoids over-counting old history as "this week".
"""
import argparse
import re
import sys
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

QUEUE_PATH = "/opt/cryptex/data/pkm/10 Projects/job-queue.md"

# jobhunt.sh drafts: "1. **Role @ Company** ..." or "**Role @ Company** ..."
DRAFT_RE = re.compile(r"^\s*(?:\d+\.\s*)?\*\*[^*]+@[^*]+\*\*", re.M)
SECTION_RE = re.compile(r"^## (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}) UTC\s*$", re.M)
# status-sync entries: "- **Applied**/**Status update** — ... — <RFC2822-ish date>" — may
# span multiple physical lines (folded email subjects), so match greedily up to the next
# bullet or end of section, then pull the trailing date off the end of that blob.
STATUS_ENTRY_RE = re.compile(
    r"^- \*\*(Applied|Status update)\*\* — (.+?)(?=\n- \*\*|\n##|\Z)", re.M | re.S)
TRAILING_DATE_RE = re.compile(r"—\s*([A-Za-z]{3},\s*\d{1,2}\s+[A-Za-z]{3}\s+\d{4}[^\n]*)\s*$")


def parse_entry_date(date_str):
    date_str = date_str.strip()
    # header folding can leave a stray leading fragment before the real RFC2822 date;
    # anchor on the weekday-comma pattern which always starts the real date.
    m = re.search(r"[A-Za-z]{3},\s*\d{1,2}\s+[A-Za-z]{3}\s+\d{4}.*", date_str)
    if not m:
        return None
    try:
        return parsedate_to_datetime(m.group(0))
    except (TypeError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--path", default=QUEUE_PATH)
    args = ap.parse_args()

    try:
        text = open(args.path).read()
    except FileNotFoundError:
        print("0 drafted, 0 applied (no job-queue.md yet)")
        return

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)

    # drafted: count within sections whose header date falls in the window (drafts are
    # always logged same-day, so the header date is accurate for these).
    sections = re.split(r"(?=^## \d{4}-\d{2}-\d{2})", text, flags=re.M)
    drafted = 0
    for sec in sections:
        m = re.match(r"## (\d{4}-\d{2}-\d{2})", sec)
        if not m:
            continue
        try:
            sec_date = datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if sec_date >= cutoff - timedelta(days=1):
            drafted += len(DRAFT_RE.findall(sec))

    # applied: use each entry's own embedded date, not the section header (backfilled
    # entries share today's header but describe events from years ago).
    applied = 0
    for kind, blob in STATUS_ENTRY_RE.findall(text):
        if kind != "Applied":
            continue
        m = TRAILING_DATE_RE.search(blob)
        if not m:
            continue
        dt = parse_entry_date(m.group(1))
        if dt and dt >= cutoff:
            applied += 1

    print(f"{drafted} drafted, {applied} applied (confirmed via Gmail) — last {args.days}d")


if __name__ == "__main__":
    main()
