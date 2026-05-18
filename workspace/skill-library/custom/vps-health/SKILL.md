---
name: vps-health
description: "Broad VPS health check: disk, memory, iptables sanity, watchdog, backup recency, auditd, fail2ban. Run on VPS."
trigger: /vps-health
---

# /vps-health

Broad system health check for the Cryptex VPS.

## Steps

1. **Resources** — `df -h /` (flag >80% disk), `free -h` (flag if available <200MB), `uptime`
2. **Top processes** — `ps aux --sort=-%mem | head -10` — flag anything unexpected consuming >10% RAM
3. **iptables sanity** — `sudo iptables -L INPUT -n --line-numbers | wc -l` — if >50 rules, check for fail2ban accumulation
4. **Watchdog** — `systemctl is-active cryptex-watchdog.timer 2>/dev/null || echo inactive` and last run: `tail -5 /var/log/cryptex-watchdog.log 2>/dev/null`
5. **Backup recency** — `tail -10 /var/log/cryptex-backup-verify.log 2>/dev/null` — flag if last verify was >8 days ago or shows FAIL
6. **Auditd** — `systemctl is-active auditd`
7. **Fail2ban** — `sudo fail2ban-client status sshd 2>/dev/null | grep -E 'Currently|Total'`
8. **Docker disk** — `docker system df`

## Output format

One-line status per check. Flag issues clearly. End with overall verdict: HEALTHY / NEEDS ATTENTION / CRITICAL.
