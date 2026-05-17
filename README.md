# cryptex

Full infrastructure stack for psidex.com — Oracle Cloud ARM64, ~30 Docker containers, Cloudflare Tunnel.

> **Private repo.** Clone this to restore the exact setup on a new VPS.

---

## Fresh Install

```bash
# 1. Provision Oracle Cloud ARM64 (Ubuntu 22.04), then:
git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex
cd /opt/cryptex

# 2. Run VPS bootstrap (iptables, packages, Docker, systemd services)
sudo ./scripts/bootstrap.sh

# 3. Set up environment
cp .env.example .env
# Fill in all values in .env — see .env.example for required vars
chmod 600 .env

# 4. Deploy
./scripts/deploy.sh
```

---

## Restore from Backup

```bash
# After fresh install + deploy.sh:
./scripts/restore.sh /path/to/cryptex-TIMESTAMP.tar.gz

# Or restore from Kopia (B2):
docker exec cryptex-kopia kopia snapshot list /backups
docker exec cryptex-kopia kopia restore <snapshot-id> /opt/cryptex/backups/restored/
./scripts/restore.sh /opt/cryptex/backups/restored/cryptex-TIMESTAMP.tar.gz
```

---

## Day-to-Day

```bash
# Health check
./scripts/health-check.sh

# Update single service
./scripts/update.sh <service>        # e.g. ./scripts/update.sh n8n

# Update all services
./scripts/update.sh

# Manual backup
./scripts/backup.sh

# View logs
docker logs cryptex-<service> --tail 50 -f
```

---

## Crontab

```cron
30 2 * * *   /opt/cryptex/scripts/backup.sh >> /var/log/cryptex-backup.log 2>&1
0  3 * * 0   /opt/cryptex/scripts/backup-verify.sh >> /var/log/cryptex-backup-verify.log 2>&1
*/5 * * * *  /opt/cryptex/scripts/health-check-cron.sh
*/5 * * * *  /opt/cryptex/scripts/watchdog.sh
0  4 * * 0   docker system prune -af >> /var/log/cryptex-prune.log 2>&1
0  5 * * 0   /opt/cryptex/scripts/update.sh >> /var/log/cryptex-update.log 2>&1
* * * * *    docker exec cryptex-moodle php /var/www/html/admin/cli/cron.php >> /var/log/cryptex-moodle-cron.log 2>&1
*/15 * * * * /opt/cryptex/scripts/quartz-build.sh >> /var/log/cryptex-quartz.log 2>&1
```

---

## Stack

See [homelab](https://github.com/parthdhanani/homelab) for the sanitized public version with architecture diagram.
