# Claude Code — Parth Dhanani

## Tools

| Tool | When |
|---|---|
| `gemini` CLI | Files >15k lines, output >800 words, bulk 50+ items |
| Jina Reader | JS-heavy sites WebFetch can't parse: use `https://r.jina.ai/<url>` |

## Model

`/model` to switch. Haiku: quick. Sonnet: code/debug. Opus: architecture/infra.

## Behaviour

- No filler. Direct. Assume technical competency.
- Confirm approach before writing code. Surgical edits only.
- State assumptions. Never guess requirements. If multiple interpretations exist, present them — don't pick silently.
- No abstractions, error handling, or configurability beyond what was asked.
- Before adding new infrastructure (daemons, secret managers, encryption layers): state the problem it solves and wait for go-ahead.
- Remove imports/vars/functions YOUR changes made unused; leave pre-existing dead code alone.
- Multi-step tasks: state `1. [step] → verify: [check]` plan before executing.
- Self-verify before declaring done.
- Compact at ~80% context (`/compact`).
- Read multiple files in parallel (simultaneous tool calls).
- `.gemini-plan.md` = Gemini codebase map. Read before implementing. Delete on completion.
- `.gemini-docs.md` = Gemini live API research. Treat as current docs. Delete on completion.
- External doc RAG: `/notebooklm`. Large codebase context: `brief` or `/flow`.

## Context

- Platform: macOS + Oracle Cloud Free Tier VPS
- Work: JS/SCORM/xAPI, Moodle LMS, nginx/Docker/iptables
- Oracle VPS: iptables always `-I INPUT 6`. UFW not active. Both iptables + Security Lists required.
- VPS is the primary work target — confirm host (VPS vs Mac) before installing tools or modifying system configs.
- CF tunnels use `172.18.0.1:<port>` bridge — after any network/proxy/bind change, verify public URL before calling done.
- VPS state: `~/.claude/vps-context.md` — read before VPS/infra work.

## Knowledge Base

Vault: `/Users/parthdhanani/Library/Mobile Documents/iCloud~md~obsidian/Documents/PKM/`
Before any KB task read: `_Meta/Index.md` + `_Meta/KB-Rules.md` (vault root has `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` shims that point to these)
Shortcuts: About→`_Meta/About.md` · Projects→`10 Projects/` · Capture→`00 Capture/Inbox.md` · TIL→`50 Collections/TIL/`

## Skills

`/sk [domain]` · `/flow` for complex/multi-tool · `/save` after decisions · `/notebooklm` for external docs/generation

**Skill auto-add rule:** If the user suggests a skill or says one is relevant, evaluate whether it fills a genuine gap not covered by existing skills. If yes: use `/sk skill-forge` to build it into `~/.claude/skill-library/custom/`, then run `bash ~/.claude/skill-library/.router/build-index.sh` to re-index. State what gap it fills before building — don't build silently.