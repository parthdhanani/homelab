---
name: containers-audit
description: "Audit all Cryptex containers for health, restart counts, image drift, and outdated pinned tags. Run on VPS."
trigger: /containers-audit
---

# /containers-audit

Audit the full Cryptex container fleet on the VPS.

## Steps

1. **Health check** — `docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"` — flag any not Up or showing Restarting
2. **Restart counts** — `docker inspect --format '{{.Name}} restarts={{.RestartCount}}' $(docker ps -aq)` — flag any > 3
3. **Image age** — `docker images --format "{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}"` — flag images older than 90 days
4. **Compose drift** — compare running image tags against pinned tags in compose files under `/opt/cryptex/` — flag any mismatch
5. **Dockhand alerts** — check `docker logs cryptex-dockhand --tail 20` for pending update notices

## Output format

Group findings by severity:
- 🔴 **Action needed** (unhealthy, restarting, major version behind)
- 🟡 **Watch** (high restart count, moderately stale image)
- ✅ **OK** (summary count only)
