#!/usr/bin/env python3
import sys, json, subprocess, os, glob

data = json.load(sys.stdin)

# ── Parse fields ─────────────────────────────────────────────────────────────
cwd        = data.get("workspace", {}).get("current_dir") or data.get("cwd", "")
model_id   = (data.get("model") or {}).get("id", "")
model_name = (data.get("model") or {}).get("display_name", "")
ctx_used   = (data.get("context_window") or {}).get("used_percentage")
five_h     = (data.get("rate_limits") or {}).get("five_hour",  {}).get("used_percentage")
seven_d    = (data.get("rate_limits") or {}).get("seven_day",  {}).get("used_percentage")
cost       = (data.get("cost") or {}).get("total_cost_usd")

# ── ANSI ─────────────────────────────────────────────────────────────────────
R  = "\033[0m"
B  = "\033[1m"
D  = "\033[2m"
fw = "\033[97m"
fg = "\033[92m"
fy = "\033[93m"
fr = "\033[91m"
fc = "\033[96m"
fb = "\033[94m"
fm = "\033[95m"
fk = "\033[90m"
fo = "\033[38;5;214m"
fp = "\033[38;5;141m"
ft = "\033[38;5;80m"

SEP = f"{fk} ► {R}"

# ── Glyphs (plain Unicode — works with any font) ──────────────────────────────
G = {
    "user":    "◉",
    "folder":  "⌂",
    "branch":  "⎇",
    "gauge":   "◈",
    "coin":    "¢",
    "bat_lo":  "○",
    "bat_md":  "◑",
    "bat_hi":  "●",
    "brain":   "◆",   # Opus
    "rocket":  "▲",   # Sonnet
    "leaf":    "◇",   # Haiku
}

# ── Path ──────────────────────────────────────────────────────────────────────
home = os.path.expanduser("~")
short_cwd = cwd.replace(home, "~", 1) if cwd.startswith(home) else cwd

# ── Git branch ────────────────────────────────────────────────────────────────
branch = ""
if cwd:
    try:
        r = subprocess.run(
            ["/usr/bin/git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=2
        )
        branch = r.stdout.strip()
    except Exception:
        pass

# ── Model glyph ───────────────────────────────────────────────────────────────
if   "opus"   in model_id: mg, mc = G["brain"],  fp
elif "sonnet" in model_id: mg, mc = G["rocket"], ft
elif "haiku"  in model_id: mg, mc = G["leaf"],   fg
else:                       mg, mc = G["rocket"], fb

# ── Effort ────────────────────────────────────────────────────────────────────
effort = "medium"
try:
    cfg = json.load(open(os.path.expanduser("~/.claude/settings.json")))
    effort = cfg.get("effortLevel", "medium")
except Exception:
    pass

effort_map = {
    "low":    (G["bat_lo"], fk, "low"),
    "medium": (G["bat_md"], fy, "med"),
    "high":   (G["bat_hi"], fo, "high"),
}
eg, ec, el = effort_map.get(effort, effort_map["medium"])

# ── Context bar ───────────────────────────────────────────────────────────────
ctx_seg = ""
if ctx_used is not None:
    pct     = round(ctx_used)
    filled  = pct * 8 // 100
    bar     = "▰" * filled + "▱" * (8 - filled)
    bc      = fr if pct >= 80 else fy if pct >= 50 else fg
    ctx_seg = f"{fk}{G['gauge']}{R} {bc}{bar}{R} {D}{pct}%{R}"

# ── Rate limits ───────────────────────────────────────────────────────────────
rate_parts = []
for val, label in [(five_h, "5h"), (seven_d, "7d")]:
    if val is not None:
        p  = round(val)
        c  = fr if p >= 80 else fy if p >= 50 else fk
        rate_parts.append(f"{c}{label}:{p}%{R}")
rate_seg = f"{fk}⚡{R} {' '.join(rate_parts)}" if rate_parts else ""

# ── Cost ──────────────────────────────────────────────────────────────────────
cost_seg = f"{fk}{G['coin']}{R} {D}${cost:.3f}{R}" if cost is not None else ""

# ── Cache health (reads session JSONL, detects flush events) ──────────────────
cache_seg = ""
session_id = data.get("session_id", "")
if session_id:
    pattern = os.path.expanduser(f"~/.claude/projects/*/{session_id}.jsonl")
    matches = glob.glob(pattern)
    if matches:
        try:
            with open(matches[0]) as f:
                usages = [
                    json.loads(line).get("message", {}).get("usage")
                    for line in f
                    if line.strip()
                ]
            usages = [u for u in usages if u]
            if usages:
                def hit_rate(u):
                    cr = u.get("cache_read_input_tokens", 0)
                    cw = u.get("cache_creation_input_tokens", 0)
                    it = u.get("input_tokens", 0)
                    tot = cr + cw + it
                    return (cr * 100 // tot) if tot > 0 else -1

                last_hit = hit_rate(usages[-1])
                flushes  = sum(1 for u in usages if 0 <= hit_rate(u) < 50)

                if last_hit == -1:
                    cache_seg = f"{fk}cache --{R}"
                elif last_hit < 50:
                    cache_seg = f"{fr}⚠cache {last_hit}%{R}"
                elif last_hit < 90:
                    cache_seg = f"{fy}cache {last_hit}%{R}"
                else:
                    cache_seg = f"{fg}cache {last_hit}%{R}"

                if flushes > 0:
                    flush_c = fr if flushes >= 5 else fy
                    cache_seg += f" {flush_c}({flushes}f){R}"
        except Exception:
            pass

# ── Assemble ──────────────────────────────────────────────────────────────────
parts = [
    f"{fm}{G['user']}{R} {B}{fw}parthdhanani{R}",
    f"{fb}{G['folder']}{R} {fc}{short_cwd}{R}",
]
if branch:
    parts.append(f"{fg}{G['branch']}{R} {fg}{branch}{R}")
if model_name:
    parts.append(f"{mc}{mg}{R} {D}{model_name}{R}{SEP}{ec}{eg}{R} {D}{el}{R}")
if ctx_seg:
    parts.append(ctx_seg)
if rate_seg:
    parts.append(rate_seg)
if cost_seg:
    parts.append(cost_seg)
if cache_seg:
    parts.append(cache_seg)

print(SEP.join(parts))
