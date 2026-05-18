---
name: pkm-bridge
description: Manages the integration between Gemini CLI and the user's Personal Knowledge Management (PKM) system. Use when Gemini CLI needs to read shared memory from the PKM or sync session summaries back to the PKM Inbox.
---

# PKM Bridge

This skill automates the shared memory layer between Gemini CLI and the PKM vault.

## Workflows

### 1. Refreshing Context (Read)

Always read the PKM memory index at the start of a session or when requested.

- **Path**: `/home/ubuntu/pkm/_Meta/AI/memory/MEMORY.md`
- **Command**: `cat /home/ubuntu/pkm/_Meta/AI/memory/MEMORY.md`

### 2. Syncing Session (Write)

Before ending a session or after significant milestones, summarize your work and sync it to the PKM Inbox.

- **Command**: `./scripts/sync.sh "Your summary here"`
- **Target**: `/home/ubuntu/pkm/00 Capture/Inbox.md`

## Reference

- **Memory Vault**: `/home/ubuntu/pkm/`
- **Session History**: `/home/ubuntu/pkm/00 Capture/Inbox.md`
