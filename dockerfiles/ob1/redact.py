"""
Secret redaction at ingest — applied in main.py's _remember() before chunking/embedding.

Why here and not at the callers: there are six write paths into /api/remember
(pkm-watcher.sh, session-summary-to-pkm.sh, crg-ob1-sync.sh, daily-report.sh x2) plus
the MCP tool and bulk_import.py. Redacting in each is six places to forget. _remember()
is the single choke point every one of them routes through, so one filter here covers
all of them, now and for whatever calls it next.

Placed before chunk_text() deliberately: a secret split across a chunk boundary would
survive per-chunk filtering, and embedding happens per chunk. Redact the whole document
once, up front, and neither the vector nor the stored row ever sees the plaintext.

Design bias: FALSE POSITIVES ARE CHEAP, false negatives are not. This indexes a personal
PKM, not user data — mangling a stray high-entropy string in a note costs a slightly worse
search hit. Missing a live credential puts it in a database that full-text search will
happily hand back later. When in doubt, redact.

Run the self-check: python3 redact.py
"""

import re

PLACEHOLDER = "[REDACTED]"

# Auth scheme labels that are never themselves secrets. See the assignment guard below.
_SCHEME_WORDS = {"Bearer", "bearer", "Basic", "basic", "Token", "token"}

# Ordered: specific vendor formats first, generic entropy heuristics last, so a recognised
# key is labelled by kind rather than swallowed by the catch-all.
_PATTERNS: list[tuple[str, re.Pattern]] = [
    # ── Vendor-specific, unambiguous prefixes ────────────────────────────────
    ("aws-akid", re.compile(r"\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b")),
    ("github", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("openai", re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b")),
    ("anthropic", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("slack", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}\b")),
    ("google", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("stripe", re.compile(r"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}\b")),
    ("hf", re.compile(r"\bhf_[A-Za-z0-9]{30,}\b")),
    ("nvidia", re.compile(r"\bnvapi-[A-Za-z0-9_-]{40,}\b")),
    ("telegram-bot", re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}\b")),

    # ── Structured credentials ───────────────────────────────────────────────
    # PEM private keys: whole block, not just the header.
    ("private-key", re.compile(
        r"-----BEGIN[A-Z ]*PRIVATE KEY-----.*?-----END[A-Z ]*PRIVATE KEY-----",
        re.DOTALL)),
    ("ssh-key", re.compile(r"\bssh-(?:rsa|ed25519|dss)\s+[A-Za-z0-9+/=]{40,}")),
    # JWT — three base64url segments. Often carries live session auth.
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    # URLs with inline credentials: postgres://user:pw@host, https://u:p@host
    ("url-cred", re.compile(r"\b([a-zA-Z][a-zA-Z0-9+.-]*://[^\s:/@]+):([^\s/@]+)@")),
    # Authorization: Bearer <token>  /  Basic <b64>
    ("auth-header", re.compile(
        r"\b(Authorization\s*:\s*(?:Bearer|Basic|Token)\s+)([A-Za-z0-9._~+/=-]{12,})",
        re.IGNORECASE)),

    # ── Assignment shapes: KEY=value / "key": "value" / key: value ───────────
    # This is what actually catches this box's own .env (CF_TUNNEL_TOKEN,
    # POSTGRES_PASSWORD, TRAXLRS_APP_KEY, SMTP_PASSWORD, ...). Keyed on the NAME,
    # so the value doesn't have to look like anything in particular.
    ("assignment", re.compile(
        r"""(?ix)
        \b( [A-Za-z0-9_.-]{0,40}
            (?: password | passwd | secret | token | api[_-]?key | apikey
              | access[_-]?key | secret[_-]?key | private[_-]?key | auth
              | credential | client[_-]?secret | app[_-]?key | webhook )
            [A-Za-z0-9_.-]{0,20} )
        ( ["']? \s* (?: = | : ) \s* ["']? )   # separator, incl. JSON's closing+opening quotes
        ( [^\s"'`,;]{6,} )                    # the value
        """)),
]

# Generic high-entropy opaque strings (this box's own tokens are 43/53/70 chars of
# base64ish with no delimiters and no vendor prefix — nothing above would catch them).
# Only fires on long unbroken runs that mix cases/digits, which ordinary prose,
# file paths, and git SHAs do not produce.
_ENTROPY = re.compile(r"\b(?=[A-Za-z0-9_-]*[a-z])(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{32,}\b")

# Things the entropy rule would otherwise eat. Checked before redacting a bare token.
# Git SHAs are all-hex (no uppercase+lowercase+digit mix requirement met) so they mostly
# fail _ENTROPY already; these cover the rest.
_ENTROPY_ALLOW = re.compile(
    r"""(?ix)
    ^(?: sha256 | sha512 | md5 )[:-] |          # digest labels
    ^[0-9a-f]{32,}$                             # pure hex: git SHA, checksum, uuid-ish
    """)


def redact_secrets(text: str) -> str:
    """Return text with credential-shaped substrings replaced by [REDACTED].

    Idempotent: running it on already-redacted text is a no-op, so a document that
    passes through more than once (re-ingest, bulk_import of an exported note) does
    not accumulate placeholders.
    """
    if not text:
        return text

    for kind, pat in _PATTERNS:
        if kind == "url-cred":
            # keep scheme://user, drop only the password
            text = pat.sub(lambda m: f"{m.group(1)}:{PLACEHOLDER}@", text)
        elif kind == "auth-header":
            text = pat.sub(lambda m: f"{m.group(1)}{PLACEHOLDER}", text)
        elif kind == "assignment":
            # keep the key name and the original separator — "POSTGRES_PASSWORD=[REDACTED]"
            # is far more useful context than a bare placeholder, and the name is not the
            # secret. Only group(3), the value, is destroyed.
            #
            # The guard exists because "Authorization: Bearer <tok>" matches both the
            # auth-header rule (which runs first and kills <tok>) and this one, whose
            # "value" is then the surviving word "Bearer". Without the skip, the second
            # pass destroys the label the first pass deliberately kept. The same guard
            # gives idempotence on already-redacted text.
            text = pat.sub(
                lambda m: m.group(0)
                if m.group(3) in _SCHEME_WORDS or m.group(3).startswith(PLACEHOLDER)
                else f"{m.group(1)}{m.group(2)}{PLACEHOLDER}",
                text)
        else:
            text = pat.sub(f"{PLACEHOLDER}", text)

    def _entropy_sub(m: re.Match) -> str:
        tok = m.group(0)
        if _ENTROPY_ALLOW.search(tok):
            return tok
        return PLACEHOLDER

    return _ENTROPY.sub(_entropy_sub, text)


def demo():
    r = redact_secrets

    # ── Vendor keys ──────────────────────────────────────────────────────────
    assert "AKIAIOSFODNN7EXAMPLE" not in r("key AKIAIOSFODNN7EXAMPLE here"), "AWS AKID leaked"
    assert "ghp_" not in r("token ghp_" + "a" * 36), "GitHub PAT leaked"
    assert "sk-ant-" not in r("sk-ant-api03-" + "x" * 40), "Anthropic key leaked"
    assert "AIza" not in r("AIza" + "B" * 35), "Google API key leaked"
    assert "hf_" not in r("hf_" + "q" * 34), "HuggingFace token leaked"
    assert "nvapi-" not in r("nvapi-" + "z" * 60), "NVIDIA token leaked"
    assert "xoxb-" not in r("xoxb-123456789-abcdefghij"), "Slack token leaked"

    # ── This box's real secret shapes (43/53/70 chars, no vendor prefix) ─────
    ob1_shape = "Kj8mQ2vX9pL4nR7wT1yU6bA3cD5eF0gH2iJ4kL6mN8o"          # 43
    cf_shape = "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9fG1hJ3kL5m"   # 53
    assert PLACEHOLDER in r(f"the token is {ob1_shape}"), "43-char opaque token leaked"
    assert PLACEHOLDER in r(f"cf key {cf_shape}"), "53-char opaque token leaked"

    # ── .env assignment shapes actually present in /opt/cryptex/.env ─────────
    for line, keyname, value in [
        ("POSTGRES_PASSWORD=hunter2swordfish", "POSTGRES_PASSWORD", "hunter2swordfish"),
        ("CF_TUNNEL_TOKEN=abc123def456ghi789", "CF_TUNNEL_TOKEN", "abc123def456ghi789"),  # gitleaks:allow — invented fixture, not a live token
        ("SMTP_PASSWORD=correct-horse-battery", "SMTP_PASSWORD", "correct-horse-battery"),
        ("TRAXLRS_APP_KEY=base64:aGVsbG93b3JsZA==", "TRAXLRS_APP_KEY", "aGVsbG93b3JsZA"),
        ('api_key: "sk_something_secret_here"', "api_key", "sk_something_secret_here"),
        ('"client_secret": "s3cr3tv4lu3here"', "client_secret", "s3cr3tv4lu3here"),
    ]:
        out = r(line)
        assert PLACEHOLDER in out, f"assignment not redacted: {line}"
        assert value not in out, f"secret VALUE survived redaction: {line} -> {out}"
        # key name survives — the useful half of the context
        assert keyname in out, f"key name lost, context destroyed: {out}"
    assert "hunter2swordfish" not in r("POSTGRES_PASSWORD=hunter2swordfish"), "password value leaked"

    # ── Structured credentials ───────────────────────────────────────────────
    assert "hunter2" not in r("postgres://ob1:hunter2@cryptex-pgvector:5432/ob1"), "DSN password leaked"
    assert "ob1" in r("postgres://ob1:hunter2@cryptex-pgvector:5432/ob1"), "DSN over-redacted (user lost)"
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"  # gitleaks:allow — jwt.io's public example token
    assert jwt not in r(f"cookie={jwt}"), "JWT leaked"
    pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----"
    assert "MIIEow" not in r(pem), "PEM body leaked"
    assert "Bearer" in r("Authorization: Bearer abcdef123456XYZ"), "auth header label lost"
    assert "abcdef123456XYZ" not in r("Authorization: Bearer abcdef123456XYZ"), "bearer token leaked"

    # ── False positives: ordinary content must survive ───────────────────────
    keep = [
        "The backup.sh script writes home-tooling.tar.gz to /backups nightly.",
        "See /opt/cryptex/dockerfiles/ob1/main.py line 151 for _remember().",
        "commit fa7dfa0 — Plan: alerting architecture, single channel",
        "Run docker compose up -d and check http://172.18.0.52:8000/health",
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "A normal sentence about passwords in general, no value attached.",
    ]
    for s in keep:
        assert r(s) == s, f"false positive on ordinary text: {s!r} -> {r(s)!r}"

    # ── Idempotence: re-ingesting redacted text must not compound ────────────
    once = r("POSTGRES_PASSWORD=hunter2swordfish and token " + ob1_shape)
    assert r(once) == once, "not idempotent — placeholders accumulate on re-ingest"

    # ── Empty / None-ish input ───────────────────────────────────────────────
    assert r("") == ""
    assert r("   ") == "   "

    print("redact.py: all checks passed")


if __name__ == "__main__":
    demo()
