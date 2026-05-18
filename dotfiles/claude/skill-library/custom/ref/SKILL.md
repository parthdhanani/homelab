---
name: ref
description: Search vault technical references. Use when you need nginx config patterns, iptables rules, VPS Oracle Cloud setup, Docker deployment, SCORM timing patterns, Moodle quirks, remote server troubleshooting, or any domain-specific technical reference.
date: 2026-03-22
---

# REF — Personal Reference Guide Search

Searches your vault's `_Meta/Skills Reference/` directory for technical knowledge, patterns, and troubleshooting.

Vault: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/_Meta/Skills Reference/`

---

## Supported References

### Quick Reference Guides
1. **javascript-troubleshooting.md**
   - SCORM 1.2 API quick reference
   - Moodle AJAX patterns
   - LMS red flags and fixes
   - Async/await gotchas
   - Timing issues with SCORM

2. **remote-server-management.md**
   - Oracle Cloud VPS rules
   - iptables configuration (always `-I INPUT 6`)
   - UFW status (not active on free tier)
   - Nginx reverse proxy setup
   - Docker commands
   - systemd services
   - Common diagnostics (df, htop, ss, lsof)
   - Error fixes (502, permission denied, out of disk, port blocked)

### Workflow Checklists
3. **SCORM-Debug-Checklist.md**
   - API initialization checklist
   - Data persistence validation
   - Completion & exit verification
   - Frame & context checks
   - Specific issue solutions

4. **VPS-Deployment-Checklist.md**
   - Pre-deployment setup
   - App deployment steps
   - Nginx configuration
   - Firewall rule configuration
   - SSL setup
   - Post-deployment checks
   - Recovery procedures (if locked out)

### System Documentation
5. **Vault-Backup-Recovery.md**
   - Backup strategy
   - iCloud sync verification
   - Manual backup procedures
   - Recovery scenarios
   - Disaster recovery checklist

---

## Usage

### Mode 1: Search by Topic
`/ref scorm timing`
- Searches both guides for "scorm" AND "timing"
- Returns matching sections with context

### Mode 2: Search by Error
`/ref 502 bad gateway`
- Searches for error patterns
- Returns fix steps from reference guides

### Mode 3: Search by Tool
`/ref iptables`
- Searches for tool-specific rules and commands
- Returns best practices and examples

---

## Search Strategy

1. Search across all reference sources:
   - `javascript-troubleshooting.md` (guides)
   - `remote-server-management.md` (guides)
   - `SCORM-Debug-Checklist.md` (workflow)
   - `VPS-Deployment-Checklist.md` (workflow)
   - `Vault-Backup-Recovery.md` (system docs)

2. Search for keyword matches (case-insensitive):
   - Exact phrase matches (highest priority)
   - Keyword matches (medium priority)
   - Related section matches (lower priority)

3. Return matching sections with 1-2 lines of context before/after

4. Prioritize workflow checklist matches when user is asking about debugging or deployment:
   - `/ref scorm debug` → Return SCORM-Debug-Checklist.md first
   - `/ref vps deploy` → Return VPS-Deployment-Checklist.md first
   - `/ref backup` → Return Vault-Backup-Recovery.md first

5. If no matches found, suggest related topics or say "Not found in vault. Would you like me to help you create a reference note?"

---

## Examples

**Query:** `/ref scorm api`
**Returns:**
```
From javascript-troubleshooting.md:

SCORM Quick Reference
- All SCORM 1.2 values must be **strings**
- `suspend_data` limit: **4096 chars**
- API lives in parent frames: `window.API`, `window.parent.API`
- Call sequence: `LMSInitialize('')` → `LMSSetValue` → `LMSCommit` → `LMSFinish('')`
```

**Query:** `/ref iptables position`
**Returns:**
```
From remote-server-management.md:

Oracle Cloud VPS Rules
- **iptables position**: Always `-I INPUT 6`, never `-A INPUT`
- **Never DROP port 22** — you will lock yourself out
```

---

## Notes

- **Vault-first:** Always reference vault guides before suggesting generic solutions
- **Context matters:** If multiple matches, return the most specific section
- **Preserve formatting:** Keep tables, code blocks, and bullet points intact
- **Link to source:** Mention which guide the info came from
- **Encourage updates:** If user finds the guide is missing something, suggest adding to vault via `/pkm til` or updating the reference file directly

