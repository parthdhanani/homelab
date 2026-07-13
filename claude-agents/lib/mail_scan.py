#!/usr/bin/env python3
"""mail_scan.py — read-only IMAP scan for job-application signal emails.
Stdlib only (imaplib/email), reuses the Gmail App Password already in /opt/cryptex/.env
(SMTP_USER/SMTP_PASSWORD) — same account, IMAP is just another protocol on it.

Usage: mail_scan.py --since-days N [--kind applied|status]
Prints one JSON object per line to stdout: {date, sender, subject, kind, company_guess}
"applied" = application-confirmation senders/subjects (LinkedIn Easy Apply, Greenhouse,
Lever, Workday, generic "your application was sent/received").
"status"  = interview/offer/rejection senders/subjects (used later, same mechanism).
"""
import argparse
import datetime
import email
import email.header
import imaplib
import json
import os
import re
import sys

ENV_PATH = "/opt/cryptex/.env"

# Real-world calibration (2026-07-12, against parth1707ster@gmail.com's actual mail):
# sender-domain alone is NOT a safe trigger — Indeed reuses noreply@indeed.com for job-alert
# digests and "you received a request" noise, not just real applications. Subject content is
# the only reliable signal; sender patterns are dropped as classifiers (domain is still used
# for company_guess). "was viewed by X" is LinkedIn's actual first confirmation, not "was sent".
APPLIED_SUBJECT_PATTERNS = [
    r"your application (for .+ )?(was|has been) (sent|submitted|received|viewed)",
    r"application (received|confirmation|submitted)",
    r"thank you for applying",
    r"we('| ha)?ve received your application",
    r"^application for .+ at .+",  # Indeed's actual confirmation subject format
]
STATUS_SUBJECT_PATTERNS = [
    r"interview", r"next steps", r"we('re| are) moving forward",
    r"unfortunately", r"not moving forward", r"other candidates",
    r"news on your .+ application",
    # bare "offer"/"congratulations" false-positive on insurance/travel confirmations
    # ("Congratulations your Travel Policy is issued") — require job/offer context.
    r"job offer", r"offer letter", r"pleased to (offer|extend)",
    r"congratulations.*(position|role|offer|joining|hired)",
]


def load_env(path):
    creds = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return creds


def decode_header(raw):
    if not raw:
        return ""
    parts = email.header.decode_header(raw)
    out = []
    for text, enc in parts:
        if isinstance(text, bytes):
            out.append(text.decode(enc or "utf-8", errors="replace"))
        else:
            out.append(text)
    return "".join(out)


def guess_company(sender, subject):
    m = re.search(r"@([a-zA-Z0-9.-]+)\.[a-zA-Z]{2,}", sender)
    domain = m.group(1) if m else ""
    domain = re.sub(r"^(mail|no-?reply|jobs?|careers?|hr|talent)\.?", "", domain, flags=re.I)
    # subject often has "... at Company" or "... - Company"
    m2 = re.search(r"(?:at|@|[-–])\s*([A-Z][A-Za-z0-9&.,' ]{2,40})\s*$", subject)
    return (m2.group(1).strip() if m2 else domain).strip(" -")[:60]


# "application submitted/received" also fires on credit-card, loan, insurance, and account
# emails ("Application Submitted for Amazon Pay ICICI Bank Credit Card") — found in real
# 2026-07-13 backfill against parth1707ster@gmail.com. Exclude on these regardless of an
# otherwise-matching applied/status pattern.
FINANCE_NOISE = re.compile(
    r"credit card|debit card|bank account|\bloan\b|insurance|\bpolicy\b|\bpnr\b|"
    r"\bcibil\b|demat|mutual fund|\bemi\b", re.I)


def classify(sender, subject):
    hay_sub = subject.lower()
    if FINANCE_NOISE.search(hay_sub):
        return None
    for pat in APPLIED_SUBJECT_PATTERNS:
        if re.search(pat, hay_sub, re.I):
            return "applied"
    for pat in STATUS_SUBJECT_PATTERNS:
        if re.search(pat, hay_sub, re.I):
            return "status"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since-days", type=int, default=1)
    ap.add_argument("--kind", choices=["applied", "status", "all"], default="all")
    args = ap.parse_args()

    creds = load_env(ENV_PATH)
    user = creds.get("SMTP_USER")
    pw = creds.get("SMTP_PASSWORD")
    if not user or not pw:
        print("ERROR: SMTP_USER/SMTP_PASSWORD not found in " + ENV_PATH, file=sys.stderr)
        sys.exit(1)

    since = (datetime.date.today() - datetime.timedelta(days=args.since_days)).strftime("%d-%b-%Y")

    imap = imaplib.IMAP4_SSL("imap.gmail.com")
    try:
        imap.login(user, pw)
        # All Mail, not INBOX: application-confirmation mail is often auto-filtered/archived
        # out of the inbox before you see it — All Mail catches it regardless of filters.
        imap.select('"[Gmail]/All Mail"', readonly=True)
        typ, data = imap.search(None, f'(SINCE "{since}")')
        if typ != "OK":
            print(f"ERROR: IMAP search failed: {typ}", file=sys.stderr)
            sys.exit(1)
        ids = data[0].split()
        for msg_id in ids:
            typ, msg_data = imap.fetch(msg_id, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
            if typ != "OK" or not msg_data or not msg_data[0]:
                continue
            raw = msg_data[0][1]
            m = email.message_from_bytes(raw)
            sender = decode_header(m.get("From", ""))
            subject = decode_header(m.get("Subject", ""))
            date_hdr = m.get("Date", "")
            msgid = m.get("Message-Id", "") or m.get("Message-ID", "")
            kind = classify(sender, subject)
            if kind is None:
                continue
            if args.kind != "all" and kind != args.kind:
                continue
            print(json.dumps({
                "message_id": msgid,
                "date": date_hdr,
                "sender": sender,
                "subject": subject,
                "kind": kind,
                "company_guess": guess_company(sender, subject),
            }))
    finally:
        try:
            imap.logout()
        except Exception:
            pass


if __name__ == "__main__":
    main()
